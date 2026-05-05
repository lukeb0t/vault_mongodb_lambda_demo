# =============================================================================
# terraform.tfvars — Default variable overrides for config/
#
# Export VAULT_ADDR and VAULT_TOKEN from SSM before running terraform apply:
#
#   export VAULT_ADDR=$(aws ssm get-parameter \
#     --name '/vault-mongo-demo/vault-addr' --region us-east-1 \
#     --query Parameter.Value --output text)
#
#   export VAULT_TOKEN=$(aws ssm get-parameter \
#     --name '/vault-mongo-demo/root-token' --with-decryption \
#     --region us-east-1 --query Parameter.Value --output text)
#
# Only set vault_addr / vault_token here to override the env vars above.
# =============================================================================

aws_region   = "us-east-1"
project_name = "vault-mongo-demo"

# vault_addr  = "http://YOUR_EC2_IP:8200"
# vault_token = "hvs.xxxxxxxxx"

# MongoDB database the Lambda will read/write (must match init/)
# mongo_db_name = "mongoDB_demo"
