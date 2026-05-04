# =============================================================================
# locals.tf — Computed values derived from variables and data sources
#
# Centralises logic that is referenced by multiple resource files so there is
# a single place to update when requirements change.
# =============================================================================

locals {
  # ── VPC resolution ──────────────────────────────────────────────────────────
  # When vpc_id is empty the module creates its own VPC; otherwise it uses the
  # caller-supplied IDs.  The boolean flag drives count = on every VPC resource.
  create_vpc = var.vpc_id == ""

  vpc_id = local.create_vpc ? aws_vpc.main[0].id : var.vpc_id

  # Lambda requires subnets in at least two AZs; the module creates private_a
  # (AZ[0]) and private_b (AZ[1]) for this purpose.
  private_subnet_ids = local.create_vpc ? [
    aws_subnet.private_a[0].id,
    aws_subnet.private_b[0].id,
  ] : var.private_subnet_ids

  # The EC2 instance is placed in the first public subnet.
  public_subnet_ids = local.create_vpc ? [
    aws_subnet.public[0].id,
  ] : var.public_subnet_ids

  # ── SSM parameter namespace ─────────────────────────────────────────────────
  # All SSM parameters written by the bootstrap script live under this prefix,
  # which keeps them isolated from other projects in the same account.
  ssm_param_prefix = "/${var.project_name}"

  # ── Vault Lambda Extension layer ARNs ───────────────────────────────────────
  # HashiCorp publishes the extension as a public Lambda layer from account
  # 634166935893.  Version 25 corresponds to extension release v0.13.2.
  # Run this to find newer versions:
  #   aws lambda list-layer-versions \
  #     --layer-name vault-lambda-extension \
  #     --region us-east-1 \
  #     --query 'LayerVersions[*].[Version,Description]'
  vault_extension_layer_arns = {
    "us-east-1"      = "arn:aws:lambda:us-east-1:634166935893:layer:vault-lambda-extension:25"
    "us-east-2"      = "arn:aws:lambda:us-east-2:634166935893:layer:vault-lambda-extension:25"
    "us-west-1"      = "arn:aws:lambda:us-west-1:634166935893:layer:vault-lambda-extension:25"
    "us-west-2"      = "arn:aws:lambda:us-west-2:634166935893:layer:vault-lambda-extension:25"
    "eu-west-1"      = "arn:aws:lambda:eu-west-1:634166935893:layer:vault-lambda-extension:25"
    "eu-west-2"      = "arn:aws:lambda:eu-west-2:634166935893:layer:vault-lambda-extension:25"
    "eu-central-1"   = "arn:aws:lambda:eu-central-1:634166935893:layer:vault-lambda-extension:25"
    "ap-southeast-1" = "arn:aws:lambda:ap-southeast-1:634166935893:layer:vault-lambda-extension:25"
    "ap-southeast-2" = "arn:aws:lambda:ap-southeast-2:634166935893:layer:vault-lambda-extension:25"
    "ap-northeast-1" = "arn:aws:lambda:ap-northeast-1:634166935893:layer:vault-lambda-extension:25"
  }

  # If the caller supplied an explicit ARN, use it; otherwise look up the region
  # in the map above.  The fallback at the end of `lookup` references version 17
  # (the oldest tested release) so regions not in the map still get a valid ARN
  # rather than an error — though targeting an unlisted region is unsupported.
  vault_extension_layer_arn = var.vault_lambda_extension_layer_arn != "" ? (
    var.vault_lambda_extension_layer_arn
  ) : lookup(local.vault_extension_layer_arns, var.aws_region, "arn:aws:lambda:${var.aws_region}:634166935893:layer:vault-lambda-extension:17")
}
