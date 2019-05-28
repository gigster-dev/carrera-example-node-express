#!/bin/bash -e

usage() {
  echo "USAGE: ${PROGNAME} <SECRET_TYPE> <SERVICE> <ENVIRONMENT> [-c | --commit]"
  echo ""
  echo "ARGS:"
  echo "Example:
  ${PROGNAME} env api staging
  ${PROGNAME} keys api staging
  ${PROGNAME} env api staging -c
  "
  exit 0
}

if [ "${#@}" -lt "3" ] || [ "${#@}" -gt "4" ]; then
  usage
fi

CWD=$( cd $(dirname "${BASH_SOURCE[0]}") && pwd )

SECRET_TYPE=${1}
SERVICE=${2}
ENVIRONMENT=${3}

KUBESEAL=${KUBESEAL-kubeseal}
PROGNAME=${PROGNAME-$(basename ${0})}
GDE_WORKSPACE=cli250
K8S_NAMESPACE="${GDE_WORKSPACE}-${ENVIRONMENT}"

if [[ "$OSTYPE" == "linux-gnu" ]]; then
	FIND_CMD_FILE_TYPE="-type f"
	BASE64_CMD_DECODE_FLAG="-d"
elif [[ "$OSTYPE" == "darwin"* ]]; then
	FIND_CMD_FILE_TYPE="-type file"
	BASE64_CMD_DECODE_FLAG="-D"
else
	echo "Unsupported OS - exiting..."
    exit 211
fi

KEY_DIR="${CWD}/${GDE_WORKSPACE}-${ENVIRONMENT}/keys"
UNENCRYPTED_FILES=""
SOURCES_FILES=()

# set commit flag if found in arguments
HAS_COMMIT_FLAG=false
if [[ "${@}" =~ "--commit" ]] || [[ "${@}" =~ "-c" ]]; then
  HAS_COMMIT_FLAG=true
fi

encrypt_file() {
  OUT_FILE=${1}
  TMP_FILE=${OUT_FILE}.tmp
  echo "*** encrypting ${UNENCRYPTED_FILES[@]} into ${OUT_FILE} ***"

  # create secret manifest from file
  kubectl create secret generic ${SECRET_NAME} \
    "${SOURCES_FILES[@]}" \
    --context ${KUBE_CONTEXT} \
    --namespace ${K8S_NAMESPACE} \
    --output json \
    --dry-run > ${TMP_FILE}
  if [ $? -ne 0 ]; then
      >&2 echo "ERROR: reading from $SOURCES_FILES"
      exit 1
  fi

  NUM_VARS=$(cat ${TMP_FILE} | jq '.data | length')
  if [ $NUM_VARS -gt 0 ]; then
    # create sealedsecret manifest from secret manifest
    echo "Encrypting env file with $NUM_VARS vars" 
    $KUBESEAL \
      --format json \
      --namespace ${K8S_NAMESPACE} \
      --context ${KUBE_CONTEXT} < ${TMP_FILE} > ${OUT_FILE}
    if [ $? -ne 0 ]; then
        >&2 echo "ERROR: creating an sealed secret: $SOURCES_FILES"
        exit 1
    fi
  else
    echo "No environment vars detected. Encryption is ignored." 
    cp ${TMP_FILE} ${OUT_FILE}
  fi

  # remove temp file
  rm -f ${TMP_FILE}
  echo "encrypted \"${SECRET_NAME}\" written to \"${OUT_FILE}\"."
}

set_environment() {
  # Use context based on provider for the environment
  if [ "$ENVIRONMENT" = "uat" ]; then
    KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
  fi
  if [ "$ENVIRONMENT" = "dev" ]; then
    KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
  fi
}

encrypt_keys() {
  echo "*** creating the encrypted key file ***"
  SECRET_NAME="${GDE_WORKSPACE}-${SERVICE}-keys"
  KEY_OUT_FILE="${CWD}/${GDE_WORKSPACE}-${ENVIRONMENT}/keys.${SERVICE}.encrypted.json"

  if [ -d ${KEY_DIR} ]; then
    UNENCRYPTED_FILES+=($(find ${KEY_DIR} ${FIND_CMD_FILE_TYPE}))
    for KEY_FILE in "${UNENCRYPTED_FILES[@]}"; do
      if [ -f "${KEY_FILE}" ]; then
        SOURCES_FILES+=("--from-file=${KEY_FILE}")
      fi
    done
  fi
  encrypt_file $KEY_OUT_FILE
}

encrypt_env() {
  echo "*** creating the encrypted env file ***"
  ENV_FILE="${CWD}/${GDE_WORKSPACE}-${ENVIRONMENT}/.env.${SERVICE}"
  SECRET_NAME="${GDE_WORKSPACE}-${SERVICE}-secrets"

  if [ -f "${ENV_FILE}" ]; then
    SOURCES_FILES=("--from-env-file=${ENV_FILE}")
    ENV_OUT_FILE="${ENV_FILE}.encrypted.json"
    encrypt_file ${ENV_OUT_FILE}
  else 
    >&2 echo "ERROR: Cannot find $ENV_FILE - please create an .env.$SERVICE file."
    exit 1
  fi
}

commit_encrypted_secret() {
  if [ $HAS_COMMIT_FLAG = true ]; then
    echo "*** committing ${OUT_FILE} to the git repo ***"
    cd "${CWD}"
    git stash
    git add ${OUT_FILE}
    if [ "${HAS_ENV}" = true ]; then
      git add ${ENV_OUT_FILE}
    fi
    git commit -m "Add encrypted secrets for $SERVICE for $ENVIRONMENT"
    git stash apply
    echo "Encrypted secrets have been committed. Push your changes to share."
  else
    echo "You should commit the changes to these files."
  fi
}

# check_secrets_directory
set_environment
if [ "${SECRET_TYPE}" = "env" ]; then
  encrypt_env
  commit_encrypted_secret
elif [ "${SECRET_TYPE}" = "keys" ]; then
  encrypt_keys
  commit_encrypted_secret
else
  echo "Please select 'env' or 'keys'"
fi
