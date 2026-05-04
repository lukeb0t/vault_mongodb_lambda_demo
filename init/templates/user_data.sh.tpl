#!/bin/bash
# Bootstrap: installs Docker, starts MongoDB + Vault + mongo-express,
# initialises Vault with KMS auto-unseal, configures AWS auth and dynamic
# MongoDB credentials, and stores the root token in SSM.
set -euo pipefail

# Write to both the log file and the console (visible in get-console-output).
exec > >(tee /var/log/user-data.log) 2>&1

log() { echo "[$(date '+%Y-%m-%d %T')] $*"; }
die() { log "ERROR: $*"; exit 1; }

log "=== Bootstrap start ==="

# ── Step 1: System packages + Docker ─────────────────────────────────────────
log "Installing packages..."
dnf update -y && dnf install -y docker jq ec2-instance-connect
systemctl enable --now docker
usermod -aG docker ec2-user

# Restart sshd to pick up the ec2-instance-connect AuthorizedKeysCommand.
systemctl restart sshd
log "sshd restarted with ec2-instance-connect"

# ── Step 2: Docker network ────────────────────────────────────────────────────
docker network create vault-demo-net

# ── Step 3: MongoDB ───────────────────────────────────────────────────────────
docker run -d \
  --name mongodb --network vault-demo-net --restart unless-stopped \
  -p 27017:27017 \
  -e MONGO_INITDB_ROOT_USERNAME=admin \
  -e MONGO_INITDB_ROOT_PASSWORD="${mongo_admin_password}" \
  mongo:7

log "Waiting for MongoDB..."
for i in $(seq 1 60); do
  docker exec mongodb mongosh \
    --username admin --password "${mongo_admin_password}" \
    --authenticationDatabase admin \
    --eval "db.runCommand({ping:1})" --quiet 2>/dev/null | grep -q '"ok": 1\|ok: 1' \
    && log "MongoDB ready (attempt $i)" && break
  [ "$i" -eq 60 ] && die "MongoDB timeout"
  sleep 5
done

# ── Step 4: Configure MongoDB ─────────────────────────────────────────────────
# vault_admin needs userAdmin to create/drop dynamic users, readWrite and
# clusterMonitor for Vault's MongoDB plugin health checks.
docker exec mongodb mongosh \
  --username admin --password "${mongo_admin_password}" \
  --authenticationDatabase admin --eval "
    db.getSiblingDB('admin').createUser({
      user: 'vault_admin', pwd: '${mongo_vault_password}',
      roles: [
        {role:'userAdminAnyDatabase', db:'admin'},
        {role:'readWriteAnyDatabase', db:'admin'},
        {role:'clusterMonitor',       db:'admin'}
      ]
    });
    const demo = db.getSiblingDB('mongoDB_demo');
    demo.createCollection('events');
    demo.events.insertOne({
      timestamp: new Date().toISOString(),
      message: 'Database initialized by bootstrap',
      source: 'ec2-user-data'
    });
    print('MongoDB configured');
  "

# ── Step 5: mongo-express (web UI on :8081) ───────────────────────────────────
docker run -d \
  --name mongo-express --network vault-demo-net --restart unless-stopped \
  -p 8081:8081 \
  -e ME_CONFIG_MONGODB_ADMINUSERNAME=admin \
  -e ME_CONFIG_MONGODB_ADMINPASSWORD="${mongo_admin_password}" \
  -e ME_CONFIG_MONGODB_URL="mongodb://admin:${mongo_admin_password}@mongodb:27017/" \
  -e ME_CONFIG_BASICAUTH=false \
  mongo-express:latest

# ── Step 6: Vault config + start ──────────────────────────────────────────────
mkdir -p /opt/vault/data /opt/vault/config
# uid=100 (vault user in the Docker image) must own the host directories.
chown -R 100:1000 /opt/vault/data /opt/vault/config
chmod 750 /opt/vault/data && chmod 755 /opt/vault/config

# Write vault.hcl.  Use multi-line block format for reliable HCL v1 parsing.
# Terraform replaces ${aws_region} and ${kms_key_id} before bash runs this.
cat > /opt/vault/config/vault.hcl << 'VAULTCONFIG'
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

seal "awskms" {
  region     = "${aws_region}"
  kms_key_id = "${kms_key_id}"
}

api_addr     = "http://0.0.0.0:8200"
cluster_addr = "http://0.0.0.0:8201"
ui           = true
VAULTCONFIG

log "vault.hcl written:"
cat /opt/vault/config/vault.hcl

docker run -d \
  --name vault --network vault-demo-net --restart unless-stopped \
  -p 8200:8200 -p 8201:8201 \
  -v /opt/vault/config:/vault/config \
  -v /opt/vault/data:/vault/data \
  --cap-add=IPC_LOCK \
  hashicorp/vault:1.17 vault server -config=/vault/config/vault.hcl

VAULT_ADDR="http://localhost:8200"
export VAULT_ADDR

log "Waiting for Vault API..."
for i in $(seq 1 60); do
  STATUS=$(curl -s -o /dev/null -w "%%{http_code}" "$VAULT_ADDR/v1/sys/health" || true)
  [[ "$STATUS" =~ ^(200|429|501|503)$ ]] && log "Vault API up (HTTP $STATUS)" && break
  if [ "$i" -eq 60 ]; then
    log "Vault container logs:"
    docker logs vault --tail 50 2>&1 || true
    die "Vault API timeout"
  fi
  sleep 5
done

# ── Step 7: Initialise Vault ──────────────────────────────────────────────────
# KMS auto-unseal uses recovery-shares/threshold (not key-shares/threshold).
INIT_RESPONSE=$(curl -s -X PUT "$VAULT_ADDR/v1/sys/init" \
  -H "Content-Type: application/json" \
  -d '{"secret_shares":0,"secret_threshold":0,"recovery_shares":5,"recovery_threshold":3}')

ROOT_TOKEN=$(echo "$INIT_RESPONSE" | jq -r '.root_token')
if [ -z "$ROOT_TOKEN" ] || [ "$ROOT_TOKEN" = "null" ]; then
  die "Vault init failed: $INIT_RESPONSE"
fi

aws ssm put-parameter --region "${aws_region}" \
  --name "${ssm_param_prefix}/root-token" --value "$ROOT_TOKEN" \
  --type SecureString --overwrite

aws ssm put-parameter --region "${aws_region}" \
  --name "${ssm_param_prefix}/init-output" --value "$INIT_RESPONSE" \
  --type SecureString --overwrite

log "Vault initialised; waiting for KMS unseal (up to 10 min)..."
for i in $(seq 1 120); do
  SEALED=$(curl -s "$VAULT_ADDR/v1/sys/health" | jq -r '.sealed // true')
  [ "$SEALED" = "false" ] && log "Vault unsealed after $((i*5))s" && break
  [ "$i" -eq 120 ] && die "Vault unseal timeout"
  sleep 5
done

log "Vault ready — run 'terraform apply' in config/ to complete setup"

log "=== Bootstrap complete ==="
echo "BOOTSTRAP_COMPLETE" > /opt/vault/bootstrap_complete
