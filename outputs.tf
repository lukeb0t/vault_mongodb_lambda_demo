# =============================================================================
# outputs.tf — Module outputs
#
# Useful values printed after `terraform apply`.  Sensitive values (tokens,
# passwords) are stored in SSM Parameter Store rather than in outputs.
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC (created by this module or provided via var.vpc_id)."
  value       = local.vpc_id
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

output "ec2_public_ip" {
  description = "Public IP of the Vault + MongoDB EC2 instance. Use this to access the Vault UI and mongo-express from a browser."
  value       = aws_instance.vault_mongo.public_ip
}

output "ec2_private_ip" {
  description = "Private IP of the EC2 instance inside the VPC. Used by Lambda to reach Vault and MongoDB."
  value       = aws_instance.vault_mongo.private_ip
}

# ── Web UIs ───────────────────────────────────────────────────────────────────

output "vault_ui_url" {
  description = "Vault web UI URL. Open in a browser and sign in with the root token retrieved via retrieve_vault_token_cmd. Available ~5 minutes after apply (bootstrap must complete first)."
  value       = "http://${aws_instance.vault_mongo.public_ip}:8200/ui"
}

output "mongo_express_url" {
  description = "mongo-express web UI URL. A browser-based MongoDB client — no credentials required (basic auth disabled for demo). Available ~5 minutes after apply."
  value       = "http://${aws_instance.vault_mongo.public_ip}:8081"
}

# ── SSH ───────────────────────────────────────────────────────────────────────

output "ssh_command" {
  description = "SSH into the EC2 instance via EC2 Instance Connect Endpoint. No SSH key pair is required — authentication uses your IAM credentials. Requires AWS CLI v2 and sufficient IAM permissions (ec2-instance-connect:OpenTunnel)."
  value       = "aws ec2-instance-connect ssh --instance-id ${aws_instance.vault_mongo.id} --os-user ec2-user --region ${var.aws_region}"
}

# ── Vault ─────────────────────────────────────────────────────────────────────

output "vault_address" {
  description = "Vault server address reachable from inside the VPC (e.g. from Lambda or via an SSH tunnel)."
  value       = "http://${aws_instance.vault_mongo.private_ip}:8200"
}

output "vault_root_token_ssm_path" {
  description = "SSM Parameter Store path (SecureString) containing the Vault root token. Written by the bootstrap script ~5 minutes after apply."
  value       = "${local.ssm_param_prefix}/root-token"
}

output "vault_init_output_ssm_path" {
  description = "SSM Parameter Store path (SecureString) containing the full JSON output of `vault operator init` — includes recovery keys for the KMS auto-unseal configuration."
  value       = "${local.ssm_param_prefix}/init-output"
}

output "retrieve_vault_token_cmd" {
  description = "AWS CLI command to print the Vault root token from SSM Parameter Store."
  value       = "aws ssm get-parameter --name '${local.ssm_param_prefix}/root-token' --with-decryption --region ${var.aws_region} --query Parameter.Value --output text"
}

# ── Lambda ────────────────────────────────────────────────────────────────────

output "lambda_function_name" {
  description = "Name of the demo Lambda function."
  value       = aws_lambda_function.demo.function_name
}

output "lambda_function_arn" {
  description = "ARN of the demo Lambda function."
  value       = aws_lambda_function.demo.arn
}

output "lambda_log_group" {
  description = "CloudWatch Log Group for the demo Lambda. View logs in the AWS console or with: aws logs tail <log_group> --follow"
  value       = aws_cloudwatch_log_group.lambda.name
}

# ── KMS ───────────────────────────────────────────────────────────────────────

output "kms_key_arn" {
  description = "ARN of the KMS key used for Vault auto-unseal. Do not delete this key — Vault cannot unseal without it."
  value       = aws_kms_key.vault_unseal.arn
}
