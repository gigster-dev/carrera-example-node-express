#!/bin/bash
set -e

SERVICE=$1
ENVIRONMENT=$2
PROJECT_PATH=$3
SERVICE_PATH=$4
DOCKERFILE_PATH=$5
STAGE=$6

GIT_COMMIT_SHA=$(git rev-parse HEAD)
GIT_COMMIT_SHA_SHORT=$(git rev-parse --short HEAD)
DEPLOY_SCRIPT_TIMESTAMP=$(date +"%s")
DEPLOY_SCRIPT_TIMESTAMP_PRETTY=$(date "+%H:%M:%S %m/%d/%Y")
TAG=$GIT_COMMIT_SHA.$DEPLOY_SCRIPT_TIMESTAMP
NAMESPACE=cli250-$ENVIRONMENT
ENVIRONMENT_FOLDER=cli250-$ENVIRONMENT
SERVICE_ROOT=$PROJECT_PATH/$SERVICE_PATH
DOCKERFILE=$SERVICE_ROOT/$DOCKERFILE_PATH
SERVICE_NAME=cli250-$SERVICE
SERVICE_TAG=$SERVICE_NAME:$TAG
SECRET_NAME=cli250-$SERVICE-secrets
ENCRYPTED_ENV_NAME="${SERVICE_NAME}-secrets"
CONFIGMAP_NAME=cli250-$SERVICE-configmap
DEPLOY_PATH=$PROJECT_PATH/deploy
TMP_DEPLOYMENT_JSON="${DEPLOY_PATH}/${SERVICE_NAME}-deployment-tmp.json"
TMP_DIR="/tmp/gig"
TMP_LAST_DOCKER_IMAGE="${TMP_DIR}/gig.${SERVICE_NAME}.dockerimage"
TMP_DOCKER_ARTIFACT="${TMP_DIR}/gig.${SERVICE_NAME}.tar"
mkdir -p $TMP_DIR

usage() {
  echo "USAGE: ${PROGNAME} <SERVICE> <ENVIRONMENT> <PROJECT_PATH> <SERVICE_PATH> <DOCKERFILE_PATH> [<STAGE>]"
  echo ""
  echo "ARGS:"
  echo "Example:
  ${PROGNAME} api dev ./ ./api ./Dockerfile
  ${PROGNAME} api dev ./../giggy ./ ./Dockerfile deploy
  ${PROGNAME} web staging ./ ./ ./web/Dockerfile build
  "
  exit 0
}

handle_environments() {
  if [ "$ENVIRONMENT" = "uat" ]; then
    PROVIDER_KIND=gcp
    GCP_PROJECT_ID=${GCP_PROJECT_ID:-"gde-cli250"}
    IMAGE_PREFIX="gcr.io/${GCP_PROJECT_ID}"
    login_function=gigster_network_login
  fi
  if [ "$ENVIRONMENT" = "dev" ]; then
    PROVIDER_KIND=gcp
    GCP_PROJECT_ID=${GCP_PROJECT_ID:-"gde-cli250"}
    IMAGE_PREFIX="gcr.io/${GCP_PROJECT_ID}"
    login_function=gigster_network_login
  fi
}

# define login functions
gigster_network_login() {
    KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
    GCP_ACCOUNT_ID=${GCP_ACCOUNT_ID:-$(gcloud config get-value account)}
    echo "Deploying with google account $GCP_ACCOUNT_ID"
    if ! echo "$GCP_ACCOUNT_ID" | grep -q "@gigsternetwork.com$"; then
      echo "WARNING: $GCP_ACCOUNT_ID is not allowed to deploy. Sign in using a gigsternetwork google account: \`gcloud auth login <account>@gigsternetwork.com\`";
    fi
    KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}

    echo "yes" | gcloud auth configure-docker --project $GCP_PROJECT_ID
}

login_into_provider() {
  handle_environments
  echo "*** authenticating with $PROVIDER_KIND ***"
  $login_function
  if [ -z "${LOGIN_METHOD}" ]; then
    eval $(${LOGIN_METHOD})
  else
      >&2 echo "ERROR: Env var LOGIN_METHOD is not set. Are you using the right login method?"
     exit 1
  fi
}

docker_build() {
  DOCKER_SERVICE_TAG="${SERVICE_TAG}"
  echo "*** building image ${DOCKER_SERVICE_TAG} ***"
  [[ -f "${DOCKERFILE}" ]] || { echo "$DOCKERFILE does not exist." 1>&2 ; exit 1; }
  DOCKER_BUILD_ARGS=""
  BUILD_ARGS_FILE="${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/${SERVICE_NAME}.buildargs"
  if [ -f "${BUILD_ARGS_FILE}" ]; then
    DOCKER_BUILD_ARGS=$(awk 'length { sub ("\\\\$", " "); \
      printf " --build-arg %s", $0  } END { print ""  }' $@ "${BUILD_ARGS_FILE}")
  fi

  # build the docker image
  docker build -f "${DOCKERFILE}" -t ${DOCKER_SERVICE_TAG} ${DOCKER_BUILD_ARGS} ${SERVICE_ROOT}
  # persist the last built id
  docker save -o "${TMP_DOCKER_ARTIFACT}" "${DOCKER_SERVICE_TAG}"
  echo "DOCKER_SERVICE_TAG=${DOCKER_SERVICE_TAG}" > "${TMP_LAST_DOCKER_IMAGE}"
}

check_docker_image_tag_exists() {
  # check if need to read from disk
  if [ -z "${DOCKER_SERVICE_TAG}" ] || [ "${DOCKER_SERVICE_TAG}" = "" ] && [ -f "${TMP_LAST_DOCKER_IMAGE}" ]; then
    source $TMP_LAST_DOCKER_IMAGE
    docker load --input "${TMP_DOCKER_ARTIFACT}"
  fi
  # check if you need to read from disk
  if [ -z "${DOCKER_SERVICE_TAG}" ] || [ "${DOCKER_SERVICE_TAG}" = "" ]; then
      >&2 echo "ERROR: env var DOCKER_SERVICE_TAG is not defined.  Did you build the docker image?"
     exit 1
  fi
  DOCKER_IMAGE_TAG="${IMAGE_PREFIX}/${DOCKER_SERVICE_TAG}"
}

docker_push() {
  echo "*** pushing image ${DOCKER_IMAGE_TAG} ***"
  check_docker_image_tag_exists
  docker tag ${DOCKER_SERVICE_TAG} ${DOCKER_IMAGE_TAG}
  docker push ${DOCKER_IMAGE_TAG}
}

k8s_create_configmap() {
  # create the configmap
  kubectl delete configmap $CONFIGMAP_NAME -n=$NAMESPACE --context $KUBE_CONTEXT || echo \
    "Failed to delete deployment configmap. OK for first time deployment."
  touch "$DEPLOY_PATH/${ENVIRONMENT_FOLDER}/.config"
  kubectl create configmap $CONFIGMAP_NAME --from-env-file="$DEPLOY_PATH/${ENVIRONMENT_FOLDER}/.config" -n=$NAMESPACE --context $KUBE_CONTEXT
}

k8s_apply_encrypted_file() {
  ENCRYPTED_FILE=$1
  K8S_SECRET_NAME=$2

  if [ -f "${ENCRYPTED_FILE}" ]; then
    echo "Applying encrypted file ${ENCRYPTED_FILE}"
    >&1 kubectl delete sealedsecret ${K8S_SECRET_NAME} -n $NAMESPACE --context $KUBE_CONTEXT || echo \
      "NOTICE: No sealedsecret ${K8S_SECRET_NAME} to delete. Skipping."
    kubectl apply -f ${ENCRYPTED_FILE} -n $NAMESPACE --context $KUBE_CONTEXT
  else
    >&2 echo "ERROR: encrypted file ${ENCRYPTED_FILE} not found."
    exit 1
  fi
}

k8s_update_deployment_image() {
  DEPLOYMENT_CONTENTS="$(cat "$TMP_DEPLOYMENT_JSON")"
  DEPLOYMENT_CONTENTS="${DEPLOYMENT_CONTENTS//__IMAGE__/$DOCKER_IMAGE_TAG}"
  echo "$DEPLOYMENT_CONTENTS" > "$TMP_DEPLOYMENT_JSON"
}

k8s_sed_custom_values() {
  DEPLOYMENT_CONTENTS="$(cat "$TMP_DEPLOYMENT_JSON")"
  SED_ARGS_FILE="${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/sed-${SERVICE}.json"
  if [ -f "${SED_ARGS_FILE}" ]; then
    ALL_KV=$(jq -r ' to_entries | .[] | tojson' < ${SED_ARGS_FILE})
    for EACH_KV in $ALL_KV;
    do
      EACH_KEY=$(echo $EACH_KV | jq -r '.key')
      EACH_VALUE=$(echo $EACH_KV | jq -r '.value')
      DEPLOYMENT_CONTENTS="${DEPLOYMENT_CONTENTS//$EACH_KEY/$EACH_VALUE}"
      echo "$DEPLOYMENT_CONTENTS" > "$TMP_DEPLOYMENT_JSON"
    done;
  fi
}

k8s_update_deployment_volumes() {
  # requires TMP file to be created
  # Load sealed files
  ENCRYPTED_FILE=($(find "${DEPLOY_PATH}/$ENVIRONMENT_FOLDER" -name "keys.${SERVICE}.encrypted.json"))

  VOLUME_NAME="$SERVICE_NAME-volumes"
  SECRET_NAME="$SERVICE_NAME-keys"
  VOLUME_MOUNT_PATH="/var/keys"

  VOLUMES='{"spec": {"template": {"spec": { "volumes": [
      { "name": "volume-name-placeholder",
        "secret": {
          "defaultMode": 420,
          "secretName": "secret-key-name-placeholder"
        }
      }
    ]}
  }}}'
  VOLUMES=$(jq '.spec.template.spec.volumes[0].name = $volumeName' \
    --arg volumeName ${VOLUME_NAME} <<< $VOLUMES)
  VOLUMES=$(jq '.spec.template.spec.volumes[0].secret.secretName = $secretName' \
    --arg secretName ${SECRET_NAME} <<< $VOLUMES)

  DEPLOYMENT_CONTENTS=$(kubectl patch --local -o json --dry-run=true -f ${TMP_DEPLOYMENT_JSON} -p "${VOLUMES}")
  echo "${DEPLOYMENT_CONTENTS}" > ${TMP_DEPLOYMENT_JSON}

  VOLUME_MOUNTS='{"spec": {"template": {"spec":
    { "containers": [
      { "name": "container-name-placeholder",
        "volumeMounts": [
        { "name": "volume-name-placeholder",
          "mountPath": "mount-path-placeholder",
          "readOnly": true
        }
      ]}
    ]}
  }}}'
  CONTAINERS=$(cat ${TMP_DEPLOYMENT_JSON} | jq -r '.spec.template.spec.containers[].name')
  for CONTAINER_NAME in $CONTAINERS
  do
    VOLUME_MOUNTS=$(jq '.spec.template.spec.containers[].name = $containerName' \
    --arg containerName ${CONTAINER_NAME} <<< $VOLUME_MOUNTS)
    VOLUME_MOUNTS=$(jq '.spec.template.spec.containers[].volumeMounts[].name = $volumeName' \
      --arg volumeName ${VOLUME_NAME} <<< $VOLUME_MOUNTS)
    VOLUME_MOUNTS=$(jq '.spec.template.spec.containers[].volumeMounts[].mountPath = $mountPath' \
      --arg mountPath ${VOLUME_MOUNT_PATH} <<< $VOLUME_MOUNTS)
    DEPLOYMENT_CONTENTS=$(kubectl patch --local -o json --dry-run=true -f ${TMP_DEPLOYMENT_JSON} -p "${VOLUME_MOUNTS}")
    echo "${DEPLOYMENT_CONTENTS}" > ${TMP_DEPLOYMENT_JSON}
  done
}

k8s_apply_deployment() {
  # apply the manifests to the environment
  cp "${DEPLOY_PATH}/$SERVICE_NAME-deployment.yaml" $TMP_DEPLOYMENT_JSON

  DEPLOYMENT_ANNOTATION="Git commit ${GIT_COMMIT_SHA_SHORT} deployed at ${DEPLOY_SCRIPT_TIMESTAMP_PRETTY} - ${DOCKER_IMAGE_TAG}"
  # update deployment manifest image tag
  k8s_update_deployment_image

  # add custom logic
  k8s_sed_custom_values

  # update deployment manifest volume
  ENCRYPTED_KEY_FILE="${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/keys.${SERVICE}.encrypted.json"
  if [ -f "$ENCRYPTED_KEY_FILE" ]; then
    k8s_apply_encrypted_file ${ENCRYPTED_KEY_FILE} "${SERVICE_NAME}-keys"
    k8s_update_deployment_volumes
  else
    >&1 kubectl delete sealedsecret "${SERVICE_NAME}-keys" -n $NAMESPACE --context $KUBE_CONTEXT && echo \
      "NOTICE: Removing sealedsecret ${SERVICE_NAME}-keys in environment." || true
  fi

  # apply environment secrets
  ENCRYPTED_ENV_FILE="${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/.env.$SERVICE.encrypted.json"
  k8s_apply_encrypted_file ${ENCRYPTED_ENV_FILE} "${SERVICE_NAME}-secrets"

  # apply services manifests
  if [ -f "${DEPLOY_PATH}/$SERVICE_NAME-service.yaml" ]; then
    kubectl apply -f ${DEPLOY_PATH}/$SERVICE_NAME-service.yaml -n=$NAMESPACE --context $KUBE_CONTEXT
  else
    echo "WARNING: ${SERVICE} service manifest not found; service will not be deployed."
  fi

  # apply ingress manifests
  if [ -f "${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/$SERVICE_NAME-ingress.yaml" ]; then
    kubectl apply -f ${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/$SERVICE_NAME-ingress.yaml -n=$NAMESPACE --context $KUBE_CONTEXT
  elif [ "$PROVIDER_KIND" = "gcp" ]; then
    echo "WARNING: ${SERVICE} has no ingress defined and will not be externally accessible."
  fi

  # apply deployment manifests
  kubectl apply -f $TMP_DEPLOYMENT_JSON -n=$NAMESPACE --context $KUBE_CONTEXT
  kubectl annotate deploy $SERVICE_NAME -n=$NAMESPACE --context $KUBE_CONTEXT kubernetes.io/change-cause="$DEPLOYMENT_ANNOTATION" --overwrite
  rm $TMP_DEPLOYMENT_JSON
}

k8s_wait_for_deployment() {
  if [ "$PROVIDER_KIND" = "aws" ] || [ -f "${DEPLOY_PATH}/${ENVIRONMENT_FOLDER}/$SERVICE_NAME-ingress.yaml" ]; then
    URL="https://${SERVICE_NAME}-${ENVIRONMENT}.$PROVIDER_KIND.gigsternetwork.com"
  else
    URL="https://${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local."
  fi

  kubectl rollout status deployments $SERVICE_NAME -n=$NAMESPACE --context $KUBE_CONTEXT

  if [ "$PROVIDER_KIND" = "gcp" ]; then
    echo "NOTE: The URL will not resolve unless the service returns a 200 status code at the root path: '/'"
  fi
  echo "Visit ${URL} to access your deployment."
}

apply_k8s_manifests() {
  echo "*** applying k8s manifests to $ENVIRONMENT ***"
  check_docker_image_tag_exists
  echo "Using image $DOCKER_IMAGE_TAG for $SERVICE"
  k8s_create_configmap
  k8s_apply_deployment
  k8s_wait_for_deployment

  # remove any persistance
  # rm $TMP_LAST_DOCKER_IMAGE
}

run_tests() {
  check_docker_image_tag_exists
  TEST_UNIT_SERVICE_PATH="${DEPLOY_PATH}/test_${SERVICE}.sh"
  touch ${TEST_UNIT_SERVICE_PATH}
  chmod +x ${TEST_UNIT_SERVICE_PATH}
  TEST_UNIT_EXECUTION="${TEST_UNIT_SERVICE_PATH} ${DOCKER_SERVICE_TAG}"
  echo "** running tests via $TEST_UNIT_SERVICE_PATH **"
  eval "$TEST_UNIT_EXECUTION"
}

# main execution
if [ "${#@}" -lt "5" ] || [ "${#@}" -gt "6" ]; then
  usage
fi

if [ "${STAGE}" = "build" ]; then
  echo " ** Running Build Stage ** "
  handle_environments
  docker_build
elif [ "${STAGE}" = "test" ]; then
  echo " ** Running Tests Stage ** "
  run_tests
elif [ "${STAGE}" = "push" ]; then
  echo " ** Running Push Stage ** "
  login_into_provider
  docker_push
elif [ "${STAGE}" = "deploy" ]; then
  echo " ** Running Deploy Stage ** "
  login_into_provider
  apply_k8s_manifests
else
  echo " ** Running Build, Test, Push and Deploy Stages ** "
  login_into_provider
  docker_build
  run_tests
  docker_push
  apply_k8s_manifests
fi

echo "*** Done! ***"