#!/bin/bash
# =============================================================================
# user_data.sh.tpl — EC2 bootstrap script (Terraform templatefile)
#
# Runs once as root on first boot via EC2 user_data.  Sets up a complete
# single-node Vault + MongoDB demo environment using Docker containers.
#
# Terraform template variables (replaced before the script runs on EC2):
#   ${aws_region}           — AWS region (e.g. us-east-1)
#   ${kms_key_id}           — KMS key ID for Vault auto-unseal
#   ${mongo_admin_password} — MongoDB root 'admin' user password
#   ${mongo_vault_password} — MongoDB 'vault_admin' user password
#   ${lambda_role_arn}      — Lambda execution role ARN (bound in Vault AWS auth)
#   ${ssm_param_prefix}     — SSM path prefix (e.g. /vault-mongo-demo)
#   ${project_name}         — Resource name prefix (e.g. vault-mongo-demo)
#
# Terraform escaping rules used in this file:
#   $${var}   → produces literal ${var} in bash (needed for bash variable refs)
#   $(cmd)    → passed through as-is (bash command substitution, no escaping)
#   %%{       → produces literal %{ (needed for curl --write-out %%{http_code})
#   ${var}    → replaced by Terraform before the script reaches EC2
#
# Bootstrap sequence:
#   1. Install Docker + jq
#   2. Create shared Docker network
#   3. Start MongoDB (mongo:7) — root user, demo database
#   4. Configure MongoDB — create vault_admin user, seed events collection
#   5. Start mongo-express (web UI on port 8081)
#   6. Start Vault (hashicorp/vault:1.17) with KMS auto-unseal config
#   7. Initialize Vault — stores root token + init output in SSM
#   8. Wait for Vault to auto-unseal via KMS
#   9. Enable Vault AWS auth method + configure for this region
#  10. Create Vault AWS auth role bound to Lambda's IAM role ARN
#  11. Enable Vault database secrets engine
#  12. Configure Vault MongoDB connection (using vault_admin credentials)
#  13. Create Vault database role (generates readWrite users on mongoDB_demo)
#  14. Write Vault ACL policy for Lambda
#  15. Verify end-to-end by generating a test credential
#
# Log output is tee'd to /var/log/user-data.log and the system journal.
# On completion, writes /opt/vault/bootstrap_complete as a sentinel file.
# =============================================================================
set -euo pipefail

# Redirect all output (stdout + stderr) to the log file and system journal.
# The console device makes messages visible in the EC2 "Get System Log" view.
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

log() { echo "[$(date '+%Y-%m-%d %T')] $*"; }
die() { log "ERROR: $*"; exit 1; }

log "=== Starting Vault + MongoDB bootstrap ==="
log "Region: ${aws_region}"

# =============================================================================
# Step 1 — Install Docker + jq
# =============================================================================
log "--- Installing docker and jq ---"
dnf update -y
dnf install -y docker jq

systemctl enable --now docker
# Add ec2-user to the docker group so SSM/EICE sessions can run docker commands
# without sudo.
usermod -aG docker ec2-user

# =============================================================================
# Step 2 — Create shared Docker network
# =============================================================================
# All three containers (MongoDB, Vault, mongo-express) join this bridge network.
# Docker's embedded DNS resolves container names (e.g. "mongodb", "vault") to
# their internal IPs, so containers can address each other by name.
docker network create vault-demo-net

# =============================================================================
# Step 3 — Start MongoDB
# =============================================================================
log "--- Starting MongoDB container ---"

docker run -d \
  --name mongodb \
  --network vault-demo-net \
  --restart unless-stopped \
  -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD="${mongo_admin_password}" \
  mongo:7

log "Waiting for MongoDB to accept connections..."
for i in $(seq 1 60); do
  if docker exec mongodb mongosh \
      --username admin \
      --password "${mongo_admin_password}" \
      --authenticationDatabase admin \
      --eval "db.runCommand({ ping: 1 })" --quiet 2>/dev/null | grep -q '"ok": 1\|ok: 1'; then
    log "MongoDB is ready (attempt $i)"
    break
  fi
  [ "$i" -eq 60 ] && die "MongoDB did not become ready in time"
  log "  MongoDB not ready yet (attempt $i/60), waiting 5s..."
  sleep 5
done

# =============================================================================
# Step 4 — Configure MongoDB
# =============================================================================
log "--- Configuring MongoDB ---"

docker exec mongodb mongosh \
  --username admin \
  --password "${mongo_admin_password}" \
  --authenticationDatabase admin \
  --eval "
    // vault_admin is the service account Vault uses to manage dynamic users.
    // It needs userAdminAnyDatabase to CREATE/DROP dynamic users on behalf of
    // requestors, readWriteAnyDatabase to verify connectivity, and
    // clusterMonitor to satisfy Vault's MongoDB plugin health checks.
    db.getSiblingDB('admin').createUser({
      user: 'vault_admin',
      pwd:  '${mongo_vault_password}',
      roles: [
        { role: 'userAdminAnyDatabase',  db: 'admin' },
        { role: 'readWriteAnyDatabase',  db: 'admin' },
        { role: 'clusterMonitor',        db: 'admin' }
      ]
    });

    // Pre-create the demo database and seed it so the Lambda has something to
    // read on its first invocation.
    const demo = db.getSiblingDB('mongoDB_demo');
    demo.createCollection('events');
    demo.events.insertOne({
      timestamp: new Date().toISOString(),
      message:   'Database initialized by bootstrap',
      source:    'ec2-user-data'
    });
    print('MongoDB configured successfully');
  "

# =============================================================================
# Step 5 — Start mongo-express (MongoDB web UI)
# =============================================================================
log "--- Starting mongo-express web UI ---"

# mongo-express provides a browser-based MongoDB client on port 8081.
# ME_CONFIG_BASICAUTH=false disables the HTTP basic-auth gate for demo simplicity.
# In a production environment, enable basic auth and use strong credentials.
docker run -d \
  --name mongo-express \
  --network vault-demo-net \
  --restart unless-stopped \
  -p 8081:8081 \
  -e ME_CONFIG_MONGODB_ADMINUSERNAME=admin \
  -e ME_CONFIG_MONGODB_ADMINPASSWORD="${mongo_admin_password}" \
  -e ME_CONFIG_MONGODB_URL="mongodb://admin:${mongo_admin_password}@mongodb:27017/" \
  -e ME_CONFIG_BASICAUTH=false \
  mongo-express:latest

log "mongo-express started on port 8081"

# =============================================================================
# Step 6 — Configure and start Vault
# =============================================================================
log "--- Configuring Vault ---"

mkdir -p /opt/vault/data /opt/vault/config

# The Vault Docker image runs as uid=100 (vault user), gid=1000.
# The host directories must be pre-owned before the container starts or Vault
# will fail to write its storage backend files (permission denied on /vault/data).
chown -R 100:1000 /opt/vault/data /opt/vault/config
chmod 750 /opt/vault/data
chmod 755 /opt/vault/config

# Write the Vault server configuration file.
# NOTE: ${aws_region} and ${kms_key_id} are replaced by Terraform templatefile
# before this script reaches EC2 — they are literal strings by the time bash
# evaluates this heredoc.
cat > /opt/vault/config/vault.hcl << 'VAULTCONFIG'
# File storage backend — suitable for a single-node demo.
# For production, use Raft integrated storage or a cloud backend.
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1   # TLS is disabled for demo simplicity; enable in production.
}

# AWS KMS auto-unseal — Vault encrypts its master key with this KMS key and
# stores the ciphertext.  On startup, Vault calls KMS to decrypt and unseal
# itself automatically, no operator intervention required.
seal "awskms" {
  region     = "${aws_region}"
  kms_key_id = "${kms_key_id}"
}

api_addr     = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"
ui           = true   # Enable the Vault web UI (served at /ui)
VAULTCONFIG

log "--- Starting Vault container ---"

docker run -d \
  --name vault \
  --network vault-demo-net \
  --restart unless-stopped \
  -p 8200:8200 \
  -p 8201:8201 \
  -v /opt/vault/config:/vault/config \
  -v /opt/vault/data:/vault/data \
  --cap-add=IPC_LOCK \
  hashicorp/vault:1.17 \
  vault server -config=/vault/config/vault.hcl

VAULT_ADDR="http://localhost:8200"
export VAULT_ADDR

log "Waiting for Vault to be reachable..."
for i in $(seq 1 60); do
  STATUS=$(curl -s -o /dev/null -w "%%{http_code}" "$VAULT_ADDR/v1/sys/health" || true)
  # HTTP status meanings from the Vault health endpoint:
  #   200 = initialized, unsealed, active
  #   429 = unsealed, standby
  #   501 = not initialized  ← we want this at this stage, API is up
  #   503 = sealed
  if [[ "$STATUS" =~ ^(200|429|501|503)$ ]]; then
    log "Vault API is reachable (HTTP $STATUS, attempt $i)"
    break
  fi
  [ "$i" -eq 60 ] && die "Vault API did not become reachable in time"
  log "  Vault not reachable yet (attempt $i/60, status $STATUS), waiting 5s..."
  sleep 5
done

# =============================================================================
# Step 7 — Initialize Vault
# =============================================================================
log "--- Initializing Vault ---"

# With KMS auto-unseal, use -recovery-shares/-recovery-threshold (not
# -key-shares/-key-threshold, which are for Shamir unseal).
# Recovery keys can be used to regenerate the root token if it is lost.
INIT_RESPONSE=$(curl -s -X PUT "$VAULT_ADDR/v1/sys/init" \
  -H "Content-Type: application/json" \
  -d '{"secret_shares":0,"secret_threshold":0,"recovery_shares":5,"recovery_threshold":3}')

ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')

if [ -z "$ROOT_TOKEN" ] || [ "$ROOT_TOKEN" = "null" ]; then
  die "Vault init failed — root_token not found in response: $INIT_RESPONSE"
fi

log "Vault initialized. Storing credentials in SSM..."

# Store the root token as a SecureString so it is encrypted at rest and
# retrievable by operators with the appropriate IAM permissions.
aws ssm put-parameter \
  --region "${aws_region}" \
  --name "${ssm_param_prefix}/root-token" \
  --value "$ROOT_TOKEN" \
  --type "SecureString" \
  --overwrite

# Store the full init response (contains recovery keys) for emergency use.
aws ssm put-parameter \
  --region "${aws_region}" \
  --name "${ssm_param_prefix}/init-output" \
  --value "$INIT_RESPONSE" \
  --type "SecureString" \
  --overwrite

# =============================================================================
# Step 8 — Wait for Vault to auto-unseal via KMS
# =============================================================================
log "Waiting for Vault to auto-unseal via KMS..."
for i in $(seq 1 30); do
  SEALED=$(curl -s "$VAULT_ADDR/v1/sys/health" | jq -r '.sealed // true')
  if [ "$SEALED" = "false" ]; then
    log "Vault is unsealed (attempt $i)"
    break
  fi
  [ "$i" -eq 30 ] && die "Vault did not unseal in time"
  log "  Still sealed (attempt $i/30), waiting 5s..."
  sleep 5
done

# =============================================================================
# Step 9 — Enable and configure the Vault AWS auth method
# =============================================================================
log "--- Enabling Vault AWS auth method ---"

# Enable the AWS auth method at the default path (auth/aws/).
curl -sf -X POST "$VAULT_ADDR/v1/sys/auth/aws" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"aws"}'

# Tell Vault which AWS region to use when calling STS to verify Lambda's identity.
curl -sf -X POST "$VAULT_ADDR/v1/auth/aws/config/client" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg region "${aws_region}" '{"region": $region}')"

# =============================================================================
# Step 10 — Create Vault AWS auth role for Lambda
# =============================================================================
# This role restricts Vault token issuance to callers whose IAM identity
# resolves to exactly the Lambda execution role ARN.
#
# auth_type = "iam": the Lambda Extension signs a GetCallerIdentity HTTP request
# and sends it to Vault.  Vault calls AWS STS to verify the signature, then
# resolves the assumed-role ARN back to the underlying IAM role ARN and checks
# it against bound_iam_principal_arn.
#
# IMPORTANT: The EC2 instance role must have iam:GetRole on the Lambda role so
# Vault can resolve the ARN to a stable unique role ID.  This prevents a deleted-
# and-recreated role (same name, new ID) from silently bypassing the binding.
curl -sf -X POST "$VAULT_ADDR/v1/auth/aws/role/${project_name}-lambda-role" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg arn "${lambda_role_arn}" \
    --arg policy "${project_name}-lambda-policy" \
    '{
      auth_type:                 "iam",
      bound_iam_principal_arn:   [$arn],
      policies:                  [$policy],
      ttl:                       "1h",
      max_ttl:                   "4h"
    }')"

# =============================================================================
# Step 11 — Enable the Vault database secrets engine
# =============================================================================
log "--- Enabling Vault database secrets engine ---"

curl -sf -X POST "$VAULT_ADDR/v1/sys/mounts/database" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"type":"database"}'

# =============================================================================
# Step 12 — Configure Vault MongoDB connection
# =============================================================================
# {{username}} and {{password}} are Vault template placeholders — they are NOT
# Terraform or bash variables.  Vault substitutes vault_admin's credentials
# at runtime when connecting to MongoDB.
curl -sf -X POST "$VAULT_ADDR/v1/database/config/mongodb" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg password "${mongo_vault_password}" \
    '{
      plugin_name:    "mongodb-database-plugin",
      allowed_roles:  "lambda-mongo-role",
      connection_url: "mongodb://{{username}}:{{password}}@mongodb:27017/admin",
      username:       "vault_admin",
      password:       $password
    }')"

# =============================================================================
# Step 13 — Create Vault database role
# =============================================================================
# When Lambda requests credentials via this role, Vault creates a temporary
# MongoDB user in the 'admin' auth database with readWrite access on
# 'mongoDB_demo'.  The user is automatically dropped when its TTL expires.
curl -sf -X POST "$VAULT_ADDR/v1/database/roles/lambda-mongo-role" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n '{
    db_name:             "mongodb",
    creation_statements: ["{\"db\":\"admin\",\"roles\":[{\"role\":\"readWrite\",\"db\":\"mongoDB_demo\"}]}"],
    default_ttl:         "1h",
    max_ttl:             "24h"
  }')"

# =============================================================================
# Step 14 — Write Vault ACL policy for Lambda
# =============================================================================
log "--- Writing Vault policy ---"

# This policy grants the Lambda token the minimum permissions it needs:
#   • Read dynamic MongoDB credentials
#   • Renew and inspect its own token
POLICY='
path "database/creds/lambda-mongo-role" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
'

curl -sf -X PUT "$VAULT_ADDR/v1/sys/policies/acl/${project_name}-lambda-policy" \
  -H "X-Vault-Token: $ROOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg policy "$POLICY" '{"policy": $policy}')"

# =============================================================================
# Step 15 — Verify end-to-end credential generation
# =============================================================================
log "--- Verifying dynamic credential generation ---"

TEST_CREDS=$(curl -sf "$VAULT_ADDR/v1/database/creds/lambda-mongo-role" \
  -H "X-Vault-Token: $ROOT_TOKEN")

TEST_USER=$(echo "$TEST_CREDS" | jq -r '.data.username')
log "Test credential generated for user: $TEST_USER"

# =============================================================================
# Done
# =============================================================================
log "=== Bootstrap complete ==="
echo "BOOTSTRAP_COMPLETE" > /opt/vault/bootstrap_complete
