#!/bin/bash
set -e

ACTION=$1
DIR=$2
ENVIRONMENT=$3
SUFFIX=$4
OPA_BLAST_RADIUS=$5

RG_LOCATION_SHORT="we"
RG_LOCATION_LONG="westeurope"
BACKEND_KEY="${ENVIRONMENT}.terraform.tfstate"
BACKEND_RG="rg-${ENVIRONMENT}-${RG_LOCATION_SHORT}-${SUFFIX}"
BACKEND_KV="kv-${ENVIRONMENT}-${RG_LOCATION_SHORT}-${SUFFIX}"
BACKEND_KV_KEY="sops"
BACKEND_NAME="sa${ENVIRONMENT}${RG_LOCATION_SHORT}${SUFFIX}"
CONTAINER_NAME="tfstate-${DIR}"
ENVIRONMENT_FILE="/tmp/${ENVIRONMENT}.env"

if [ -z "${OPA_BLAST_RADIUS}" ]; then
  OPA_BLAST_RADIUS=50
fi

prepare () {
  AZURE_SUBSCRIPTION_ID=$(az account show --output tsv --query id)
  AZURE_TENANT_ID=$(az account show --output tsv --query tenantId)
  tf-prepare --resource-group-name="${BACKEND_RG}" --resource-group-location="${RG_LOCATION_LONG}" --subscription-id="${AZURE_SUBSCRIPTION_ID}" --tenant-id="${AZURE_TENANT_ID}" --storage-account-name="${BACKEND_NAME}" --storage-account-container="${CONTAINER_NAME}" --keyvault-name="${BACKEND_KV}" --keyvault-key-name="${BACKEND_KV_KEY}"
}

plan () {
  rm -f .terraform/plans/${ENVIRONMENT}
  terraform init -input=false -backend-config="key=${BACKEND_KEY}" -backend-config="resource_group_name=${BACKEND_RG}" -backend-config="storage_account_name=${BACKEND_NAME}" -backend-config="container_name=${CONTAINER_NAME}" -backend-config="snapshot=true"

  set +e
  terraform workspace select ${ENVIRONMENT} 2> /dev/null
  if [ $? -ne 0 ]; then
    terraform workspace new ${ENVIRONMENT}
    terraform workspace select ${ENVIRONMENT}
  fi
  set -e

  mkdir -p .terraform/plans
  terraform plan -input=false -var-file="variables/${ENVIRONMENT}.tfvars" -var-file="variables/common.tfvars" -var-file="../global.tfvars" -out=".terraform/plans/${ENVIRONMENT}"
  terraform show -json .terraform/plans/${ENVIRONMENT} > .terraform/plans/${ENVIRONMENT}.json
  cat /opt/opa-policies/data.json | jq ".blast_radius = ${OPA_BLAST_RADIUS}" > /tmp/opa-data.json
  opa test /opt/opa-policies -v
  OPA_AUTHZ=$(opa eval --format pretty --data /tmp/opa-data.json --data /opt/opa-policies/terraform.rego --input .terraform/plans/${ENVIRONMENT}.json "data.terraform.analysis.authz")
  OPA_SCORE=$(opa eval --format pretty --data /tmp/opa-data.json --data /opt/opa-policies/terraform.rego --input .terraform/plans/${ENVIRONMENT}.json "data.terraform.analysis.score")
  if [[ "${OPA_AUTHZ}" == "true" ]]; then
    echo "INFO: OPA Authorization: true (score: ${OPA_SCORE} / blast_radius: ${OPA_BLAST_RADIUS})"
    rm -rf .terraform/plans/${ENVIRONMENT}.json
  else
    echo "ERROR: OPA Authorization: false (score: ${OPA_SCORE} / blast_radius: ${OPA_BLAST_RADIUS})"
    rm -rf .terraform/plans/${ENVIRONMENT}.json
    rm -rf .terraform/plans/${ENVIRONMENT}
    exit 1
  fi
  SOPS_KEY_ID="$(az keyvault key show --name ${BACKEND_KV_KEY} --vault-name ${BACKEND_KV} --query key.kid --output tsv)"
  sops --encrypt --azure-kv ${SOPS_KEY_ID} .terraform/plans/${ENVIRONMENT} > .terraform/plans/${ENVIRONMENT}.enc
  rm -rf .terraform/plans/${ENVIRONMENT}
}

apply () {
  terraform init -input=false -backend-config="key=${BACKEND_KEY}" -backend-config="resource_group_name=${BACKEND_RG}" -backend-config="storage_account_name=${BACKEND_NAME}" -backend-config="container_name=${CONTAINER_NAME}" -backend-config="snapshot=true"
  terraform workspace select ${ENVIRONMENT}
  SOPS_KEY_ID="$(az keyvault key show --name ${BACKEND_KV_KEY} --vault-name ${BACKEND_KV} --query key.kid --output tsv)"
  sops --decrypt --azure-kv ${SOPS_KEY_ID} .terraform/plans/${ENVIRONMENT}.enc > .terraform/plans/${ENVIRONMENT}
  rm -rf .terraform/plans/${ENVIRONMENT}.enc
  set +e
  terraform apply ".terraform/plans/${ENVIRONMENT}"
  EXIT_CODE=$?
  set -e
  rm -rf .terraform/plans/${ENVIRONMENT}
  exit $EXIT_CODE
}

destroy () {
  terraform init -input=false -backend-config="key=${BACKEND_KEY}" -backend-config="resource_group_name=${BACKEND_RG}" -backend-config="storage_account_name=${BACKEND_NAME}" -backend-config="container_name=${CONTAINER_NAME}" -backend-config="snapshot=true"
  terraform workspace select ${ENVIRONMENT}
  
  echo "-------"
  echo "You are about to run terraform destroy on ${DIR} in ${ENVIRONMENT}"
  echo "-------"
  
  echo -n "Please confirm by writing \"${DIR}/${ENVIRONMENT}\": "
  read VERIFICATION_INPUT

  if [[ "${VERIFICATION_INPUT}" == "${DIR}/${ENVIRONMENT}" ]]; then
    terraform destroy -var-file="variables/${ENVIRONMENT}.tfvars" -var-file="variables/common.tfvars" -var-file="../global.tfvars"
  else
    echo "Wrong input detected (${VERIFICATION_INPUT}). Exiting..."
    exit 1
  fi
}

state_remove () {
  terraform init -input=false -backend-config="key=${BACKEND_KEY}" -backend-config="resource_group_name=${BACKEND_RG}" -backend-config="storage_account_name=${BACKEND_NAME}" -backend-config="container_name=${CONTAINER_NAME}" -backend-config="snapshot=true"
  terraform workspace select ${ENVIRONMENT}
  TF_STATE_OBJECTS=$(terraform state list)
  
  echo "-------"
  echo "You are about to run terraform state rm on ${DIR} in ${ENVIRONMENT}"
  echo "-------"
  
  echo -n "Please confirm by writing \"${DIR}/${ENVIRONMENT}\": "
  read VERIFICATION_INPUT

  if [[ "${VERIFICATION_INPUT}" == "${DIR}/${ENVIRONMENT}" ]]; then
    echo -n "Please enter what to grep regex arguments (default: grep -E \".*\"): "
    read GREP_ARGUMENT
    GREP_ARGUMENT=${GREP_ARGUMENT:-.*}
    TF_STATE_TO_REMOVE=$(echo "${TF_STATE_OBJECTS}" | grep -E "${GREP_ARGUMENT}")
    TF_STATE_TO_REMOVE_COUNT=$(echo "${TF_STATE_TO_REMOVE}" | wc -l)
    
    echo "You are about to remove the following objects from the terraform state: "
    echo ""
    echo "-------"
    echo "${TF_STATE_TO_REMOVE}"
    echo "-------"
    echo ""

    echo -n "Please confirm the number of objects that will be removed (${TF_STATE_TO_REMOVE_COUNT}): "
    read VERIFICATION_INPUT_COUNT
    if [[ ${VERIFICATION_INPUT_COUNT} -eq ${TF_STATE_TO_REMOVE_COUNT} ]]; then
      for TF_STATE_OBJECT in ${TF_STATE_TO_REMOVE}; do
        terraform state rm ${TF_STATE_OBJECT}
      done
    else
      echo "Wrong input detected (${VERIFICATION_INPUT_COUNT}). Exiting..."
      exit 1
    fi
  else
    echo "Wrong input detected (${VERIFICATION_INPUT}). Exiting..."
    exit 1
  fi
}



envup() {
  if [ -f ${ENVIRONMENT_FILE} ]; then
    set -a
    source ${ENVIRONMENT_FILE}
    set +a
  fi
}

envup
cd /tmp/$DIR

case $ACTION in
  plan )
    plan
    ;;

  apply )
    apply
    ;;

  destroy )
    destroy
    ;;

  prepare )
    prepare
    ;;

  state-remove )
    state_remove
    ;;
esac
