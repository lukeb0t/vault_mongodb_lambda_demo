#!/usr/bin/env bash
# =============================================================================
# get-config-vars.sh — Load Vault connection variables from SSM Parameter Store
#
# Reads the Vault address and root token written by init/ and exports them as
# VAULT_ADDR and VAULT_TOKEN environment variables for use by the config/
# Terraform run.
#
# Usage:
#   eval $(./scripts/get-config-vars.sh)
#   cd config && terraform init && terraform apply
#
# Override the SSM prefix or region:
#   SSM_PREFIX=/my-prefix AWS_REGION=eu-west-1 eval $(./scripts/get-config-vars.sh)
# =============================================================================
set -euo pipefail

PREFIX="${SSM_PREFIX:-/vault-mongo-demo}"
REGION="${AWS_REGION:-us-east-1}"

VAULT_ADDR=$(aws ssm get-parameter \
  --name "${PREFIX}/vault-addr" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

VAULT_TOKEN=$(aws ssm get-parameter \
  --name "${PREFIX}/root-token" \
  --region "$REGION" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text)

echo "export VAULT_ADDR=${VAULT_ADDR}"
echo "export VAULT_TOKEN=${VAULT_TOKEN}"
