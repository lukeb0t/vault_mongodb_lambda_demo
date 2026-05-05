# =============================================================================
# iam.tf — IAM roles, policies, and instance profiles
#
# Two principals are defined here:
#
#   1. EC2 instance role (vault-mongo-demo-ec2-role)
#      Grants the EC2 host running Vault + MongoDB the permissions it needs:
#        • KMS      — Vault auto-unseal (encrypt/decrypt the master key)
#        • STS      — Vault AWS auth method verifies Lambda's identity
#        • IAM      — Vault AWS auth method resolves role ARN → unique role ID
#        • SSM      — Bootstrap writes the Vault root token to Parameter Store
#        • SSM Core — Enables EC2 Instance Connect Endpoint (keypair-free SSH)
#
#   2. Lambda execution role (vault-mongo-demo-lambda-role)
#      Grants the Lambda function:
#        • VPC networking  — create/manage ENIs in the private subnets
#        • CloudWatch Logs — emit function logs
#        • SSM read        — read the Vault root token during debugging/ops
#
#      The Lambda role ARN is also the value bound in the Vault AWS auth role
#      (bound_iam_principal_arn), so Vault will only issue tokens to Lambdas
#      running under this specific role.
# =============================================================================

# ── EC2 Instance Role ─────────────────────────────────────────────────────────

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-ec2-role"

  # Only EC2 instances can assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ── Vault KMS auto-unseal ──────────────────────────────────────────
        # Vault calls these four KMS actions on startup to decrypt its master
        # key and unseal itself without human intervention.
        Sid    = "VaultAutoUnseal"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.vault_unseal.arn
      },
      {
        # ── Vault AWS auth — caller identity verification ──────────────────
        # Vault calls sts:GetCallerIdentity to verify the signed IAM request
        # sent by the Lambda Extension at login time.
        Sid      = "STSGetCallerIdentity"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
      {
        # ── Vault AWS auth — role ARN → unique ID resolution ──────────────
        # Vault calls iam:GetRole to resolve the Lambda role ARN to its
        # immutable unique ID (AROA...). Required when creating the Vault
        # AWS auth role; without it Vault returns HTTP 400.
        Sid    = "IAMGetRole"
        Effect = "Allow"
        Action = "iam:GetRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-lambda-role"
      },
      {
        # ── Bootstrap — Vault credential storage ──────────────────────────
        # The EC2 user_data script writes the Vault root token and init output
        # to SSM Parameter Store (as SecureString) so operators can retrieve
        # them later without logging into the instance.
        # NOT A BEST PRACTICE for production use (ANTI-PATTERN) — do NOT store secrets in SSM Parameter Store in production without proper access controls and auditing.
        Sid    = "SSMParameterStore"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:DeleteParameter",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_param_prefix}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── Lambda Execution Role ─────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda-role"

  # Only the Lambda service can assume this role.
  # The role ARN is also used in the Vault AWS auth role binding — Vault only
  # issues tokens to callers whose IAM identity resolves to this role ARN.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Grants the Lambda function permission to:
#   • Create and manage VPC ENIs in the private subnets (required for VPC access)
#   • Write logs to CloudWatch Logs
# This is the AWS-managed policy for VPC-connected Lambda functions.
resource "aws_iam_role_policy_attachment" "lambda_vpc_execution" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Enables EC2 Instance Connect Endpoint for keypair-free SSH on the EC2 instance.
# The managed policy grants SSM Agent the ability to register with the SSM service
# and receive session-manager commands — required for EICE to establish its tunnel.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allows the Lambda function (and operators) to retrieve the Vault root token
# from SSM Parameter Store for debugging and operational purposes.
# NOT A BEST PRACTICE for production use (ANTI-PATTERN)
resource "aws_iam_role_policy" "lambda" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMReadDebug"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_param_prefix}/*"
      },
    ]
  })
}
