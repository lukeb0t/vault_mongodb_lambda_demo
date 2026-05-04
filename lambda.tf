# =============================================================================
# lambda.tf — Demo Lambda function, packaging, and EventBridge schedule
#
# The Lambda function demonstrates the full Vault + MongoDB dynamic credential
# flow on a schedule (default: every 5 minutes).
#
# How the Vault Lambda Extension works (proxy mode):
#
#   ┌─────────────────────────────────────────────┐
#   │ Lambda execution environment                │
#   │                                             │
#   │  ┌──────────────────┐                       │
#   │  │ vault-lambda-ext │  ← runs as an         │
#   │  │ (proxy mode)     │    extension process  │
#   │  │                  │                       │
#   │  │ 1. Reads Lambda's IAM creds from env     │
#   │  │ 2. Signs GetCallerIdentity request       │
#   │  │ 3. Sends signed req to Vault → gets token│
#   │  │ 4. Listens on localhost:8200             │
#   │  │ 5. Injects Vault token into every        │
#   │  │    proxied request from function code    │
#   │  └──────────────────┘                       │
#   │                                             │
#   │  ┌──────────────────┐                       │
#   │  │ index.js handler │  ← function code      │
#   │  │                  │                       │
#   │  │ GET localhost:8200/v1/database/creds/... │
#   │  │   → extension adds token, forwards to   │
#   │  │     real Vault, returns creds            │
#   │  │ connect MongoDB with dynamic creds       │
#   │  │ write + read document                   │
#   │  └──────────────────┘                       │
#   └─────────────────────────────────────────────┘
#
# Environment variable reference:
#   VLE_VAULT_ADDR      — real Vault server (used by extension internally)
#   VAULT_ADDR          — localhost proxy (used by function code)
#   VAULT_AUTH_PROVIDER — must be "aws" to activate AWS IAM auth
#   VAULT_AUTH_ROLE     — Vault role name the extension will request a token for
#   VAULT_RUN_MODE      — "proxy" enables the transparent proxy behaviour
# =============================================================================

# ── Lambda package ────────────────────────────────────────────────────────────

# Run `npm install --omit=dev` whenever package.json or the handler changes.
# This populates lambda_src/node_modules/ before the archive step zips it up.
resource "null_resource" "lambda_npm_install" {
  triggers = {
    package_json = filemd5("${path.module}/lambda_src/package.json")
    index_js     = filemd5("${path.module}/lambda_src/index.js")
  }

  provisioner "local-exec" {
    command = "cd ${path.module}/lambda_src && npm install --omit=dev"
  }
}

# Zip lambda_src/ (handler + node_modules) into a deployment package.
# The output_base64sha256 is used as source_code_hash so Lambda updates
# only when the code actually changes.
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/lambda_src.zip"

  depends_on = [null_resource.lambda_npm_install]
}

# ── Lambda Function ───────────────────────────────────────────────────────────

# Pre-create the log group so Terraform controls the retention policy.
# Without this, Lambda auto-creates it with no retention (logs accumulate forever).
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}-demo"
  retention_in_days = 7
}

resource "aws_lambda_function" "demo" {
  filename      = data.archive_file.lambda_zip.output_path
  function_name = "${var.project_name}-demo"
  role          = aws_iam_role.lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs22.x"
  timeout       = 60     # seconds — generous for cold starts + MongoDB round-trips
  memory_size   = 256    # MB — extension + MongoDB driver fit comfortably here

  # Lambda redeploys only when the zip hash changes, not on every apply.
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  # ── Vault Lambda Extension layer ──────────────────────────────────────────
  # Published by HashiCorp from account 634166935893.  The extension process
  # runs alongside the function and handles all Vault authentication and token
  # management transparently.
  layers = [local.vault_extension_layer_arn]

  # ── VPC placement ─────────────────────────────────────────────────────────
  # Lambda needs VPC access to reach Vault (port 8200) and MongoDB (port 27017)
  # on the EC2 instance via private IP.  It is placed in the private subnets
  # and communicates with EC2 via VPC-local routing — no NAT Gateway needed.
  vpc_config {
    subnet_ids         = local.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      # ── Vault Lambda Extension configuration ──────────────────────────────

      # VLE_VAULT_ADDR: the extension uses this to reach the real Vault server.
      # Takes precedence over VAULT_ADDR for the extension's own connections.
      VLE_VAULT_ADDR = "http://${aws_instance.vault_mongo.private_ip}:8200"

      # VAULT_ADDR: points at the extension's local proxy (localhost:8200).
      # Function code uses this address; the extension intercepts requests,
      # injects the Vault token, and forwards them to VLE_VAULT_ADDR.
      VAULT_ADDR = "http://127.0.0.1:8200"

      # VAULT_AUTH_PROVIDER: tells the extension to use AWS IAM authentication.
      # Must be "aws" — using the old "VAULT_AUTH_METHOD" name causes a fatal crash.
      VAULT_AUTH_PROVIDER = "aws"

      # VAULT_AUTH_ROLE: the Vault role the extension will authenticate as.
      # This role's bound_iam_principal_arn must match the Lambda execution role ARN.
      VAULT_AUTH_ROLE = "${var.project_name}-lambda-role"

      # VAULT_RUN_MODE: "proxy" makes the extension act as a transparent HTTP
      # proxy rather than just fetching a token and writing it to a file.
      VAULT_RUN_MODE = "proxy"

      # ── Application configuration ─────────────────────────────────────────

      # MongoDB host — private IP of the EC2 instance.
      # Lambda connects using dynamic credentials obtained from Vault.
      MONGODB_HOST = aws_instance.vault_mongo.private_ip
      MONGODB_PORT = "27017"

      # Database the Lambda reads/writes during the demo.
      MONGODB_DATABASE = "mongoDB_demo"

      # Vault path for dynamic MongoDB credentials (database secrets engine).
      VAULT_DB_CREDS_PATH = "database/creds/lambda-mongo-role"
    }
  }

  # Ensure the log group exists before Lambda tries to write to it.
  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = { Name = "${var.project_name}-demo" }
}

# ── EventBridge Schedule ──────────────────────────────────────────────────────

# Triggers the Lambda on the configured schedule (default: every 5 minutes).
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
  name                = "${var.project_name}-schedule"
  description         = "Triggers the Vault+MongoDB demo Lambda on a schedule."
  schedule_expression = var.lambda_schedule_expression

  tags = { Name = "${var.project_name}-schedule" }
}

resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.lambda_schedule.name
  target_id = "DemoLambdaTarget"
  arn       = aws_lambda_function.demo.arn
}

# Grants EventBridge permission to invoke the Lambda function.
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.demo.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}
