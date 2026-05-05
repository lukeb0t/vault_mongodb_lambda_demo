# =============================================================================
# variables.tf — Input variables for the vault-mongo-demo module
#
# All variables have sensible defaults so the module can be deployed with a
# single `terraform apply` in a fresh account.  Override via a .tfvars file
# or -var flags when you need non-default behaviour.
# =============================================================================

# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy all resources into. Must match a region that has the Vault Lambda Extension layer published (see locals.tf for the supported list)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short identifier used as a name prefix for every resource and tag. Keep it lowercase and hyphenated (e.g. 'vault-demo'). Changing this value after first apply will force replacement of all resources."
  type        = string
  default     = "vault-mongo-demo"
}

# ── VPC ───────────────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = <<-EOT
    ID of an existing VPC to deploy into.
    Leave empty (default) to have the module create a new /16 VPC.
    When providing an existing VPC you must also set private_subnet_ids and
    public_subnet_ids, and ensure the public subnets have a default route to
    an Internet Gateway.
  EOT
  type        = string
  default     = ""
}

variable "private_subnet_ids" {
  description = "List of existing private subnet IDs for Lambda. Required when vpc_id is provided. Subnets must span at least two AZs (AWS Lambda requirement)."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "List of existing public subnet IDs. Required when vpc_id is provided. The EC2 instance is placed in the first subnet in this list."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block for the newly created VPC. Only used when vpc_id is empty. Must be a valid RFC-1918 block large enough to accommodate the three /24 subnets this module creates."
  type        = string
  default     = "10.0.0.0/16"
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

variable "ec2_instance_type" {
  description = "EC2 instance type for the combined Vault + MongoDB server. t3.medium provides enough RAM for both Docker containers during a demo. Increase to t3.large or larger for sustained load."
  type        = string
  default     = "t3.medium"
}

variable "vault_ui_cidr" {
  description = <<-EOT
    CIDR block allowed to reach the Vault web UI (port 8200) and the
    mongo-express web UI (port 8081) from the internet.
    Default is 0.0.0.0/0 (open) for demo convenience — restrict to your
    office or VPN CIDR in any environment that matters.
    Example: "203.0.113.42/32"
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "mongo_express_username" {
  description = "Username for the mongo-express web UI basic auth. Defaults to 'admin'."
  type        = string
  default     = "mongo_demo_admin"
}

# ── Lambda ────────────────────────────────────────────────────────────────────

variable "lambda_schedule_expression" {
  description = "EventBridge (CloudWatch Events) schedule expression controlling how often the demo Lambda runs. Uses rate() or cron() syntax. Default runs every 5 minutes."
  type        = string
  default     = "rate(5 minutes)"
}

# The Vault Lambda Extension is published by HashiCorp as a public Lambda layer.
# Find the latest ARN for your region at:
# https://developer.hashicorp.com/vault/docs/platform/aws/lambda-extension
variable "vault_lambda_extension_layer_arn" {
  description = "Override the Vault Lambda Extension layer ARN. Leave empty to use the regional default defined in locals.tf (currently version 25 / extension v0.13.2). Set this if you need a specific version or are deploying to a region not in the default map."
  type        = string
  default     = ""
}
