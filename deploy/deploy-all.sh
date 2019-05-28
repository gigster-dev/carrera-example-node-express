#!/bin/bash
set -e

ENVIRONMENT=$1
PROJECT_PATH=${2:-"."}
STAGE=${3:-""}
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
DEPLOY_PATH="${PROJECT_PATH}/deploy"

if [ "${#@}" -lt "2" ] || [ "${#@}" -gt "3" ]; then
  echo "Must specify an environment"
  echo "bash deploy/deploy-all.sh staging"
  echo "bash deploy/deploy-all.sh staging . build"
  exit 1
fi

# deploy web
bash ${DEPLOY_PATH}/deploy.sh web $ENVIRONMENT $PROJECT_PATH ./ ./Dockerfile $STAGE

echo "Success! All services deployed to $ENVIRONMENT."
