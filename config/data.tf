# =============================================================================
# data.tf — Data sources that read init/ outputs from SSM Parameter Store
#
# All secrets (mongo password) and infrastructure ARNs (lambda role) are read
# from SSM so that config/ requires no direct access to init/'s Terraform
# state. Variable overrides are supported for all values (see variables.tf).
# =============================================================================

locals {
  ssm_param_prefix = var.ssm_param_prefix != "" ? var.ssm_param_prefix : "/${var.project_name}"
}

# Current AWS account identity — used to construct the STS assumed-role ARN
# in vault_auth.tf without hard-coding the account ID.
data "aws_caller_identity" "current" {}

# MongoDB vault_admin user password — written to SSM by init/ssm.tf.
# Vault uses this to authenticate to MongoDB when configuring the database
# secrets engine connection.
data "aws_ssm_parameter" "mongo_vault_password" {
  name            = "${local.ssm_param_prefix}/mongo-vault-password"
  with_decryption = true
}

# Lambda execution IAM role ARN — written to SSM by init/ssm.tf.
# Vault's AWS auth role is bound to this ARN so only the Lambda can
# authenticate with Vault using its execution role identity.
data "aws_ssm_parameter" "lambda_role_arn" {
  name = "${local.ssm_param_prefix}/lambda-role-arn"
}
