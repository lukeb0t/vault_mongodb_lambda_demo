# =============================================================================
# vault_auth.tf — Vault AWS IAM authentication method
#
# Enables the AWS auth backend and creates an IAM role binding so the Lambda
# function can authenticate to Vault using its IAM execution role identity
# (no static credentials required).
#
# Flow: Lambda → Vault AWS auth (iam subtype) → bound_iam_principal_arn check
#       → token with lambda policy → database/creds/lambda-mongo-role
#
# SECURITY DESIGN — principal binding approach
# -------------------------------------------------------
# bound_iam_principal_arns uses the IAM role ARN format (arn:aws:iam::...):
#
#   Why NOT the STS assumed-role ARN (arn:aws:sts::...)?
#   Vault's AWS IAM auth resolves all principals to their underlying IAM entity.
#   STS session ARNs cannot be stored as bound principals when resolve_aws_unique_ids
#   is true, and direct STS ARN matching (resolve_aws_unique_ids = false) also does
#   not work — Vault still attempts to resolve the ARN and rejects it with
#   "does not belong to the role". The IAM role ARN is the correct format.
#
#   Effective scope: vault-mongo-demo-lambda-role is a dedicated execution role
#   created exclusively for this Lambda function. No other principal in this
#   account assumes it, so the binding is effectively single-function scoped.
#   → To enforce this architecturally: ensure no other Lambda function (or human)
#     has a trust policy allowing it to assume vault-mongo-demo-lambda-role.
#
#   resolve_aws_unique_ids = true:
#   Vault stores the role's opaque unique ID (AROA...) rather than the ARN.
#   If the IAM role is deleted and re-created with the same name, the unique ID
#   changes and the binding breaks — intentional protection against role-shadowing.
# =============================================================================

# Enable the AWS auth method at the default path "aws".
resource "vault_auth_backend" "aws" {
  type        = "aws"
  description = "AWS IAM authentication for Lambda and other AWS workloads."
}

# Point the AWS auth backend at the correct region so it can call the AWS
# STS and IAM APIs to validate incoming authentication requests.
resource "vault_aws_auth_backend_client" "this" {
  backend = vault_auth_backend.aws.path
}

# Auth role bound to the Lambda's dedicated IAM execution role.
# Only a caller whose IAM identity resolves to this role ARN can log in.
# The Vault Lambda Extension presents the Lambda's role credentials automatically.
resource "vault_aws_auth_backend_role" "lambda" {
  backend   = vault_auth_backend.aws.path
  role      = "${var.project_name}-lambda-role"
  auth_type = "iam"

  # Lambda IAM execution role ARN. Must use IAM ARN format (arn:aws:iam::...:role/...) —
  # Vault resolves it to the immutable unique ID (AROA...) stored as the binding.
  # STS assumed-role ARNs are not supported as bound_iam_principal_arns values.
  bound_iam_principal_arns = [data.aws_ssm_parameter.lambda_role_arn.value]

  # Restricts logins to tokens originating from this specific AWS account.
  # Prevents cross-account escalation even if a principal ARN is somehow spoofed.
  # → To relax: remove this attribute entirely.
  bound_account_ids = [data.aws_caller_identity.current.account_id]

  # Tells Vault to resolve the IAM role ARN to its immutable unique ID (AROA...).
  # If the IAM role is ever deleted and re-created with the same name, the unique
  # ID changes, breaking the binding — intentional protection against role-shadowing.
  # NOTE: resolve_aws_unique_ids requires an IAM ARN (not a STS ARN) in
  #       bound_iam_principal_arns — the two are interdependent.
  # → To relax: set to false (ARN string matching; role recreation preserves access).
  resolve_aws_unique_ids = true

  token_policies = [vault_policy.lambda.name]
  token_ttl      = 3600   # 1 hour — sufficient for Lambda max timeout (15 min) plus buffer
  token_max_ttl  = 14400  # 4 hours — caps token renewal; reauthentication required after
}
