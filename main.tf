# =============================================================================
# main.tf — Root module entrypoint
#
# Declares:
#   • Terraform + provider version constraints
#   • AWS provider with default resource tags
#   • Shared data sources used by multiple sub-modules
#   • Random passwords for MongoDB (generated once, stored in Terraform state)
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # AWS provider — all infrastructure resources
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Random provider — generates MongoDB passwords that survive plan/apply cycles
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    # Archive provider — zips the Lambda source directory for deployment
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    # Null provider — drives the `npm install` local-exec before zipping Lambda
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every resource created by this module gets these tags automatically.
  # Individual resources may add more tags via their own `tags` block.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "demo"
      ManagedBy   = "terraform"
    }
  }
}

# ── Data Sources ──────────────────────────────────────────────────────────────

# Discover the AZs available in the chosen region so subnet CIDRs can be
# distributed across them without hard-coding AZ names.
data "aws_availability_zones" "available" {
  state = "available"
}

# Current AWS account ID — used to construct ARNs in IAM policies.
data "aws_caller_identity" "current" {}

# Latest Amazon Linux 2023 (x86_64, HVM) AMI published by Amazon.
# AL2023 ships with the SSM agent and ec2-instance-connect pre-installed,
# which is required for keypair-free SSH via the EC2 Instance Connect Endpoint.
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Random Passwords ──────────────────────────────────────────────────────────
# Passwords are generated once and stored in Terraform state.
# `special = false` avoids shell-escaping issues inside the user_data script
# and MongoDB connection strings.

# Password for the MongoDB root 'admin' user (used only by the EC2 bootstrap
# script to create subordinate users; never exposed to Lambda).
resource "random_password" "mongo_admin" {
  length  = 20
  special = false
}

# Password for the 'vault_admin' MongoDB user that Vault uses to manage
# dynamic credential rotation.  Vault stores this password internally after
# the initial connection is configured.
resource "random_password" "mongo_vault" {
  length  = 20
  special = false
}
