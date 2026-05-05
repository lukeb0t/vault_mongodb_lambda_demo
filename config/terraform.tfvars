# =============================================================================
# terraform.tfvars — Default variable overrides for config/
#
# VAULT_ADDR and VAULT_TOKEN are sourced from SSM automatically via:
#   eval $(../scripts/get-config-vars.sh)
#
# Only override these here if you are not using get-config-vars.sh.
# =============================================================================

aws_region   = "us-east-1"
project_name = "vault-mongo-demo"

# vault_addr  = "http://YOUR_EC2_IP:8200"
# vault_token = "hvs.xxxxxxxxx"

# MongoDB database the Lambda will read/write (must match init/)
# mongo_db_name = "mongoDB_demo"
