# =============================================================================
# variables.tf — Input variables for the config/ Terraform run
#
# Most variables have defaults that match the init/ defaults so both runs
# stay in sync without extra configuration. Vault credentials default to ""
# which tells the Vault provider to use VAULT_ADDR / VAULT_TOKEN env vars.
# =============================================================================

variable "aws_region" {
  description = "AWS region where infrastructure was deployed by init/."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix. Must match the value used in init/ so SSM parameter paths align."
  type        = string
  default     = "vault-mongo-demo"
}

variable "ssm_param_prefix" {
  description = "SSM Parameter Store path prefix. Defaults to /<project_name>. Must match init/."
  type        = string
  default     = ""
}

variable "vault_addr" {
  description = <<-EOT
    Vault server address (e.g. http://1.2.3.4:8200). If empty (default), the
    Vault provider reads the VAULT_ADDR environment variable. Export before
    running terraform apply: export VAULT_ADDR=$(aws ssm get-parameter ...)
  EOT
  type        = string
  default     = ""
}

variable "vault_token" {
  description = <<-EOT
    Vault root token for initial configuration. If empty (default), the Vault
    provider reads the VAULT_TOKEN environment variable. Export before running
    terraform apply: export VAULT_TOKEN=$(aws ssm get-parameter ...)
    For production, replace the root token with a narrowly-scoped service token.
  EOT
  type      = string
  default   = ""
  sensitive = true
}

variable "mongo_db_name" {
  description = "MongoDB database name the Lambda will read/write. Must match the value used in init/."
  type        = string
  default     = "mongoDB_demo"
}
