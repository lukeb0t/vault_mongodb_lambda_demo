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
# SECURITY DESIGN — intentionally tight role binding
# -------------------------------------------------------
# The bound_iam_principal_arns value uses an STS *assumed-role* ARN format:
#   arn:aws:sts::<account>:assumed-role/<role-name>/<session-name>
# rather than the IAM role ARN format:
#   arn:aws:iam::<account>:role/<role-name>
#
# This is intentional and tighter than strictly required. Here's why each
# constraint was added:
#
#  1. STS assumed-role ARN (includes function name as session name)
#     When Lambda assumes an IAM role the STS session name equals the function
#     name. By including the function name in bound_iam_principal_arns we scope
#     this Vault role to exactly ONE Lambda function. Any other Lambda that
#     shares the same IAM execution role cannot log in with this Vault role —
#     it would need its own Vault role.
#     → To relax: replace with the IAM role ARN from data.aws_ssm_parameter.lambda_role_arn.value
#
#  2. bound_account_ids
#     Defense-in-depth: even if someone crafted a spoofed request that passed
#     the principal check, the account ID constraint rejects cross-account calls.
#     → To relax: remove the attribute entirely (Vault allows any account by default)
#
#  3. resolve_aws_unique_ids = true
#     Vault resolves the IAM principal to its opaque internal unique ID (AIDA…
#     for roles) and stores that ID — not the human-readable ARN — as the
#     binding. This means that if the IAM role is deleted and re-created with
#     the same name the binding is broken (new role = new unique ID). This
#     prevents role-shadowing attacks where an attacker deletes the original
#     role and creates an identically-named one under their control.
#     → To relax: set resolve_aws_unique_ids = false (ARN-based matching)
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

# Auth role bound to the specific Lambda function via its STS assumed-role ARN.
#
# When Lambda invokes a function it calls sts:AssumeRole on the execution role
# and the resulting session name equals the Lambda function name. The ARN of
# that session follows this pattern:
#   arn:aws:sts::<account_id>:assumed-role/<role_name>/<function_name>
#
# This is more restrictive than binding to the IAM role ARN (which would allow
# ANY principal — human or machine — that assumes the same role to authenticate
# with Vault). See the header comment block for full rationale.
resource "vault_aws_auth_backend_role" "lambda" {
  backend   = vault_auth_backend.aws.path
  role      = "${var.project_name}-lambda-role"
  auth_type = "iam"

  # Scoped to the exact STS session produced by this Lambda function.
  # Role name segment: "${var.project_name}-lambda-role" (matches init/iam.tf)
  # Session name segment: "${var.project_name}-demo"    (matches Lambda function name)
  # → To widen to any caller using this IAM role, replace with:
  #     [data.aws_ssm_parameter.lambda_role_arn.value]
  bound_iam_principal_arns = [
    "arn:aws:sts::${data.aws_caller_identity.current.account_id}:assumed-role/${var.project_name}-lambda-role/${var.project_name}-demo"
  ]

  # Restricts logins to tokens originating from this specific AWS account.
  # Prevents cross-account escalation even if a principal ARN is somehow spoofed.
  # → To relax: remove this attribute entirely.
  bound_account_ids = [data.aws_caller_identity.current.account_id]

  # NOTE: resolve_aws_unique_ids must be false when using STS assumed-role ARNs.
  # Vault can only resolve IAM ARNs (arn:aws:iam::...) to internal unique IDs —
  # STS session ARNs (arn:aws:sts::...) are not resolvable to a stable unique ID
  # because they represent ephemeral sessions, not persistent IAM entities.
  #
  # The trade-off: we gain tight function-name scoping (STS ARN) but lose the
  # role-deletion protection that resolve_aws_unique_ids provides.
  # → If you switch back to an IAM role ARN, set this to true for both benefits.
  resolve_aws_unique_ids = false

  token_policies = [vault_policy.lambda.name]
  token_ttl      = 3600   # 1 hour — sufficient for Lambda max timeout (15 min) plus buffer
  token_max_ttl  = 14400  # 4 hours — caps token renewal; reauthentication required after
}
