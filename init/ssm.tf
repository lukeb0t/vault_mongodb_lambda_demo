# =============================================================================
# ssm.tf — SSM Parameter Store entries written by Terraform (not user_data)
#
# These parameters bridge init/ outputs to the config/ Terraform run so that
# config/ can read them via data sources without requiring Terraform remote
# state or manual variable passing.
# =============================================================================

# Vault server address — written immediately after EC2 is created (public IP
# is known at apply time). Used by config/ to configure the Vault provider.
resource "aws_ssm_parameter" "vault_addr" {
  name        = "${local.ssm_param_prefix}/vault-addr"
  description = "Vault server public address. Used by the config/ Terraform run to configure the Vault provider."
  type        = "String"
  value       = "http://${aws_instance.vault_mongo.public_ip}:8200"

  tags = {
    Name = "${var.project_name}-vault-addr"
  }
}

# Vault admin MongoDB user password — written by Terraform so config/ can
# configure the Vault database secrets engine without reading TF state.
resource "aws_ssm_parameter" "mongo_vault_password" {
  name        = "${local.ssm_param_prefix}/mongo-vault-password"
  description = "Password for the vault_admin MongoDB user. Used by config/ to configure the Vault database secrets engine connection."
  type        = "SecureString"
  value       = random_password.mongo_vault.result

  tags = {
    Name = "${var.project_name}-mongo-vault-password"
  }
}

# Lambda IAM role ARN — written by Terraform so config/ can bind the Vault
# AWS auth role to the Lambda execution role without reading TF state.
resource "aws_ssm_parameter" "lambda_role_arn" {
  name        = "${local.ssm_param_prefix}/lambda-role-arn"
  description = "ARN of the Lambda execution IAM role. Used by config/ to create the Vault AWS auth role binding."
  type        = "String"
  value       = aws_iam_role.lambda.arn

  tags = {
    Name = "${var.project_name}-lambda-role-arn"
  }
}
