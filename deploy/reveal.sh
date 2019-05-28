#!/bin/bash -e

usage() {
  echo "USAGE: ${PROGNAME} <SECRET_TYPE> <SERVICE> <ENVIRONMENT>"
  echo ""
  echo "ARGS:"
  echo "Example:
  ${PROGNAME} env api staging
  ${PROGNAME} keys api staging
  "
  exit 0
}

if [ "${#@}" -ne "3" ]; then
  usage
fi

CWD=$( cd $(dirname "${BASH_SOURCE[0]}") && pwd )

SECRET_TYPE=${1}
SERVICE=${2}
ENVIRONMENT=${3}

GDE_WORKSPACE=cli250
K8S_NAMESPACE="${GDE_WORKSPACE}-${ENVIRONMENT}"
PROGNAME=${PROGNAME-$(basename ${0})}
#SEALED_SECRETS_FILE="${SERVICE}.secrets.sealed"
OUT_ROOT="${CWD}/${GDE_WORKSPACE}-${ENVIRONMENT}"

set_environment() {
  # Use context based on provider for the environment
  if [ "$ENVIRONMENT" = "uat" ]; then
    KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
  fi
  if [ "$ENVIRONMENT" = "dev" ]; then
    KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
  fi
}

reveal_keys() {
  # reveal keys
  SECRET_NAME="${GDE_WORKSPACE}-${SERVICE}-keys"
  SECRET_EXISTS=$(kubectl get secret "${SECRET_NAME}" --context ${KUBE_CONTEXT} -n ${K8S_NAMESPACE})
  if [ $? -ne 0 ]; then
    >&2 echo "Did you apply the ${SERVICE} service with keys to ${ENVIRONMENT}?"
    exit 1
  fi

  KEYS_CONTENT=$(kubectl get secrets "${SECRET_NAME}" --context ${KUBE_CONTEXT} -n ${K8S_NAMESPACE} -o json \
    | jq -r "select(.data != null) | .data | map_values(@base64d) | \
     to_entries|map(\"\n\(.key)\n-----------\n\(.value|tostring)\n\")|.[]")
  if [ $? -ne 0 ]; then
    exit 1
  fi

  echo -e "${KEYS_CONTENT}"
}

reveal_env() {
  # reveal env
  SECRET_NAME="${GDE_WORKSPACE}-${SERVICE}-secrets"
  SECRET_EXISTS=$(kubectl get secret "${SECRET_NAME}" --context ${KUBE_CONTEXT} -n ${K8S_NAMESPACE})
  if [ $? -ne 0 ]; then
    >&2 echo "Did you deploy the ${SERVICE} service to ${ENVIRONMENT}?"
    exit 1
  fi

  ENV_CONTENT=$(kubectl get secrets "${SECRET_NAME}" --context ${KUBE_CONTEXT} -n ${K8S_NAMESPACE} -o json \
    | jq -r "select(.data != null) | .data | map_values(@base64d) | to_entries|map(\"\(.key)=\(.value|tostring)\")|.[]")
  if [ $? -ne 0 ]; then
    exit 1
  fi

  echo "############### env for ${SERVICE} within ${ENVIRONMENT} ###############"
  echo -e $ENV_CONTENT
}

# check_secrets_directory
set_environment
if [ "${SECRET_TYPE}" = "env" ]; then
  reveal_env
elif [ "${SECRET_TYPE}" = "keys" ]; then
  reveal_keys
else
  echo "Please select 'env' or 'keys'"
fi
