# =============================================================================
# vault_database.tf — Dynamic MongoDB credential engine
#
# Mounts the database secrets engine and connects it to the MongoDB instance
# running on the same EC2 host as Vault (reachable via the Docker network
# hostname "mongodb"). Vault manages credential lifecycle: on each request it
# creates a short-lived MongoDB user, issues credentials to the caller, and
# revokes the user when the lease expires.
# =============================================================================

# Mount the database secrets engine at the conventional "database/" path.
resource "vault_mount" "database" {
  path        = "database"
  type        = "database"
  description = "Dynamic credential engine for MongoDB."
}

# Configure the MongoDB connection.
# {{username}} and {{password}} are Vault template placeholders — Vault
# substitutes the vault_admin credentials at connection time. These are NOT
# Terraform interpolations.
resource "vault_database_secret_backend_connection" "mongodb" {
  backend       = vault_mount.database.path
  name          = "mongodb"
  allowed_roles = ["lambda-mongo-role"]

  mongodb {
    # "mongodb" resolves inside the Docker network on the EC2 host.
    # Vault makes this connection itself; Terraform only calls the Vault API.
    connection_url = "mongodb://{{username}}:{{password}}@mongodb:27017/admin"
    username       = "vault_admin"
    password       = data.aws_ssm_parameter.mongo_vault_password.value
  }
}

# Database role — defines the MongoDB user template Vault creates on each
# credential request. Users get readWrite on the demo database and expire
# automatically when the lease ends.
resource "vault_database_secret_backend_role" "lambda" {
  backend = vault_mount.database.path
  name    = "lambda-mongo-role"
  db_name = vault_database_secret_backend_connection.mongodb.name

  # MongoDB creation statement: JSON object describing the new user's roles.
  # The role is scoped to readWrite on mongoDB_demo only.
  creation_statements = [
    jsonencode({
      db    = "admin"
      roles = [{ role = "readWrite", db = var.mongo_db_name }]
    })
  ]

  default_ttl = 3600   # 1 hour in seconds
  max_ttl     = 86400  # 24 hours in seconds
}
