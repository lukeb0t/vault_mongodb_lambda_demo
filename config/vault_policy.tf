# =============================================================================
# vault_policy.tf — ACL policy for the Lambda function
#
# Grants the Lambda token (issued via AWS auth) the minimum permissions it
# needs: read dynamic MongoDB credentials and manage its own token lifecycle.
# =============================================================================

resource "vault_policy" "lambda" {
  name = "${var.project_name}-lambda-policy"

  # Least-privilege: only the specific credential path and token self-management.
  policy = <<-EOT
    # Read dynamic MongoDB credentials for the lambda role.
    path "database/creds/lambda-mongo-role" {
      capabilities = ["read"]
    }

    # Allow the Lambda to renew its own token before it expires.
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }

    # Allow the Lambda to look up its own token (used by the Vault extension
    # for health checks and lease tracking).
    path "auth/token/lookup-self" {
      capabilities = ["read"]
    }
  EOT
}
