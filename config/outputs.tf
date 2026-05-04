# =============================================================================
# outputs.tf — config/ run outputs
# =============================================================================

output "vault_auth_backend_path" {
  description = "Mount path of the AWS auth backend."
  value       = vault_auth_backend.aws.path
}

output "vault_auth_role_name" {
  description = "Name of the Vault AWS auth role bound to the Lambda IAM role."
  value       = vault_aws_auth_backend_role.lambda.role
}

output "vault_database_mount_path" {
  description = "Mount path of the database secrets engine."
  value       = vault_mount.database.path
}

output "vault_database_role_name" {
  description = "Name of the Vault database role for dynamic MongoDB credentials."
  value       = vault_database_secret_backend_role.lambda.name
}

output "vault_policy_name" {
  description = "Name of the Vault ACL policy assigned to Lambda tokens."
  value       = vault_policy.lambda.name
}

output "vault_db_creds_path" {
  description = "Vault API path to request dynamic MongoDB credentials. Used by VAULT_DB_CREDS_PATH Lambda env var."
  value       = "${vault_mount.database.path}/creds/${vault_database_secret_backend_role.lambda.name}"
}

output "lambda_invoke_test_cmd" {
  description = "AWS CLI command to invoke the Lambda and verify the full demo flow."
  value       = "aws lambda invoke --function-name ${var.project_name}-demo --region ${var.aws_region} /tmp/out.json && cat /tmp/out.json"
}
