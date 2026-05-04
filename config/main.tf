# =============================================================================
# main.tf — config/ entrypoint
#
# Configures Vault (auth methods, database secrets engine, policies) using the
# HashiCorp Vault Terraform provider. Run this AFTER init/ has completed and
# the Vault server is initialized and unsealed.
#
# Authentication:
#   The Vault provider reads VAULT_ADDR and VAULT_TOKEN from environment
#   variables by default. Use scripts/get-config-vars.sh to populate them
#   from SSM Parameter Store, or pass var.vault_addr / var.vault_token
#   explicitly.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # AWS provider — reads SSM parameters and IAM role ARNs
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Vault provider — configures auth methods, secrets engines, roles, policies
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "demo"
      ManagedBy   = "terraform"
    }
  }
}

# The Vault provider authenticates using:
#   1. var.vault_addr / var.vault_token if explicitly set, OR
#   2. VAULT_ADDR / VAULT_TOKEN environment variables (standard Vault workflow)
#
# Use scripts/get-config-vars.sh to load these from SSM:
#   eval $(../scripts/get-config-vars.sh)
provider "vault" {
  # If variables are empty strings, null is passed and the provider falls back
  # to the VAULT_ADDR / VAULT_TOKEN environment variables.
  address = var.vault_addr != "" ? var.vault_addr : null
  token   = var.vault_token != "" ? var.vault_token : null
}
