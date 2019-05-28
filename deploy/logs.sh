#!/bin/bash
set -e

SERVICE=$1
ENVIRONMENT=$2
PROJECT_PATH=${3:-"$( cd $( dirname "${0}")/.. && pwd )"}
FLAGS="${@:4}"

ENVIRONMENT_NAME=cli250-$ENVIRONMENT
DEPLOY_PATH=$PROJECT_PATH/deploy

if [ $# -lt 3 ]; then
	echo "Must specify service, environment, and project path."
	echo "If you are trying to log all services, pass in '' for service."

	# show usage
	sh "$DEPLOY_PATH"/kubetail.sh

	exit 1
fi

# Use context based on provider for the environment
if [ "$ENVIRONMENT" = "uat" ]; then
  KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
fi
if [ "$ENVIRONMENT" = "dev" ]; then
  KUBE_CONTEXT=${KUBE_CONTEXT:-gke_gde-core_us-east1-c_gde-core}
fi

sh "$DEPLOY_PATH"/kubetail.sh $SERVICE -n $ENVIRONMENT_NAME --context $KUBE_CONTEXT $FLAGS
