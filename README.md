# Vault + MongoDB + Lambda Demo

Terraform modules that deploy a complete, self-contained demonstration of HashiCorp Vault's MongoDB dynamic database credentials and AWS Lambda Layers in proxy mode.

An AWS Lambda function authenticates to Vault using the **Vault Lambda Extension** (AWS IAM auth), retrieves short-lived MongoDB credentials from Vault's **database secrets engine**, and uses those credentials to read/write documents in a MongoDB collection — proving the full dynamic-secrets pipeline with no hardcoded passwords anywhere.

---

## Architecture

```
                          ┌──────────────────────────────────────┐
                          │          AWS Cloud (us-east-1)       │
                          │                                      │
  Browser ─────── HTTPS ──► EC2 (public subnet)                  │
  SSH (EICE) ─────────────►  ├─ Vault 1.17 (Docker, :8200)      │
                          │  ├─ MongoDB 7   (Docker, :27017)     │
                          │  └─ mongo-express (Docker, :8081)    │
                          │                  ▲                   │
                          │  Lambda ─────────┘ (VPC-local)      │
                          │  (private subnet)                    │
                          │       │                              │
                          │       └── EventBridge (every 5 min) │
                          └──────────────────────────────────────┘
```

**Key design decisions:**

| Decision | Rationale |
|---|---|
| EC2 Instance Connect Endpoint (EICE) | Keypair-free SSH using IAM credentials. No bastion host needed. |
| Vault Lambda Extension — proxy mode | Extension handles all auth + token lifecycle. Lambda code calls `localhost:8200` as if it were Vault directly. |
| KMS auto-unseal | Vault unseals itself on restart without operator intervention. |
| Dynamic MongoDB credentials | Vault creates a temporary MongoDB user per Lambda invocation. Credentials expire automatically (TTL: 1h). No shared passwords. |

---

## Prerequisites

- Terraform >= 1.5
- AWS CLI v2 with credentials configured (`aws sts get-caller-identity` should succeed)
- Docker (for the Lambda `npm install` packaging step — runs locally via `null_resource`)
- Node.js / npm (for Lambda dependency packaging)

The AWS identity running Terraform needs permissions to create: VPC, EC2, IAM roles, Lambda, KMS, SSM parameters, CloudWatch, EventBridge, and EC2 Instance Connect Endpoint resources.

---

## Quick Start

Deployment is a **two-step process**: `init/` creates infrastructure and bootstraps Vault; `config/` applies Vault configuration using Terraform's native Vault provider.

### Step 1 — Setup Variables (`init/` and `config/`)

Review `terraform.tfvars` in both `init/` and `config/` before deploying. If modifying defaults, ensure values that appear in both (e.g. `project_name`, `aws_region`) match.

### Step 2 — Infrastructure (`init/`)

```bash
git clone https://github.com/lukeb0t/vault_mongodb_lambda_demo.git
cd vault_mongodb_lambda_demo/init

# Deploy infrastructure (~7 minutes; EC2 bootstrap runs in the background)
terraform init
terraform apply

# The bootstrap will take 3-5 minutes to complete.
# When this returns a value (hvs.xxx...) the bootstrap is done:
aws ssm get-parameter \
  --name '/vault-mongo-demo/root-token' \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value --output text
```

### Step 3 — Vault Configuration (`config/`)

The `config/` run uses the Vault provider to configure auth, the database secrets engine, and policies. It reads the Vault address and root token from environment variables you must export before running terraform init/apply.

```bash
cd ../config

# Fetch Vault address + root token from SSM and export for the Vault provider
export VAULT_ADDR=$(aws ssm get-parameter \
  --name '/vault-mongo-demo/vault-addr' \
  --region us-east-1 \
  --query Parameter.Value --output text)

export VAULT_TOKEN=$(aws ssm get-parameter \
  --name '/vault-mongo-demo/root-token' \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value --output text)

# Run the config init and apply
terraform init
terraform apply
```

### Verify the Demo

```bash
# Manually trigger the Lambda (it also runs automatically every 5 minutes):
aws lambda invoke \
  --function-name vault-mongo-demo-demo \
  --region us-east-1 \
  /tmp/vault-demo-result.json && cat /tmp/vault-demo-result.json

# Expected output:
# {"success":true,"readBackVerified":true,"vaultDynamicUser":"v-aws-vault-mongo-lambda-mongo-ro-..."}
```

### Accessing Demo Resources

```bash
# Open the Vault UI (sign in with root token from SSM):
cd init && echo "$(terraform output -raw vault_ui_url)"

# Open mongo-express:
echo "$(terraform output -raw mongo_express_url)"

# SSH into EC2 (no keypair needed — uses EICE):
$(terraform output -raw ssh_command)

# Retrieve Vault root token:
$(terraform output -raw retrieve_vault_token_cmd)
```

---

## How It Works

### Cold Start Flow

```
Lambda invoked
    │
    ├─► Vault Lambda Extension (runs before handler)
    │       ├─ Reads Lambda's built-in IAM credentials
    │       ├─ Signs a GetCallerIdentity HTTP request
    │       ├─ POSTs signed request to Vault /v1/auth/aws/login
    │       ├─ Vault calls AWS STS to verify the signature
    │       ├─ Vault matches caller's IAM role ARN against the auth role binding
    │       ├─ Vault issues a token scoped to the lambda policy
    │       └─ Extension starts local proxy on localhost:8200
    │
    └─► Lambda handler (index.js)
            ├─ GET localhost:8200/v1/database/creds/lambda-mongo-role
            │       └─ Extension proxies + injects token → real Vault
            │               └─ Vault calls MongoDB → creates temp user
            │                       └─ Returns username + password (TTL: 1h)
            │
            ├─ MongoClient connects to EC2:27017 with dynamic credentials
            ├─ Inserts document into mongoDB_demo.events
            ├─ Reads document back to verify
            └─ Returns { success: true, vaultDynamicUser: "v-...", readBackVerified: true }
```

### Why `iam:GetRole` is Required

When creating a Vault AWS auth role with `bound_iam_principal_arn`, Vault resolves the role ARN to its unique **Role ID** (an immutable identifier that changes if the role is deleted and recreated with the same name). This is a security feature that prevents role-substitution attacks. The EC2 instance running Vault must have `iam:GetRole` permission on the Lambda role for this lookup to succeed.

---

## Security Design Decisions

### Principal Binding — IAM Role ARN (not STS Assumed-Role ARN)

The Vault auth role uses the **IAM role ARN** as the principal binding:

```
arn:aws:iam::<account_id>:role/<role-name>
```

**Effective scope with the IAM role ARN:** The `vault-mongo-demo-lambda-role` is a dedicated execution role created exclusively for this Lambda function. No other principal in the account has a trust policy allowing it to assume this role, so the binding is effectively single-function scoped in practice.

→ To enforce this architecturally: ensure no other Lambda (or human) can assume `vault-mongo-demo-lambda-role` by auditing the role's trust policy.

### `bound_account_ids`

An explicit AWS account ID restriction adds defense-in-depth. Even if a principal ARN were somehow spoofed or a cross-account trust policy were accidentally added, Vault rejects any request not originating from this specific account.

**How to relax:** Remove the `bound_account_ids` attribute entirely.

### `resolve_aws_unique_ids = true`

Vault resolves the IAM role ARN to its opaque internal unique ID (`AROA…`) and stores that ID — not the human-readable ARN — as the binding. If the IAM role is deleted and re-created with the same name, it gets a new unique ID and the binding breaks automatically. This prevents role-shadowing attacks.

**How to relax:** Set `resolve_aws_unique_ids = false` for ARN string matching (role recreation preserves access).

### Summary Table

| Control | What it restricts |
|---|---|
| IAM role ARN binding | Scopes to callers assuming `vault-mongo-demo-lambda-role` |
| `bound_account_ids` | Prevents cross-account authentication |
| `resolve_aws_unique_ids = true` | Breaks binding if IAM role is deleted + recreated |

---

## SSH Access (Keypair-Free)

This module uses [EC2 Instance Connect Endpoint (EICE)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-using-eice.html) — a free AWS service that tunnels SSH over the AWS control plane using your IAM credentials. No key pair is stored on the instance.

```bash
# From terraform output:
aws ec2-instance-connect ssh \
  --instance-id <INSTANCE_ID> \
  --os-user ec2-user \
  --region us-east-1
```

**Required IAM permissions for the caller:**
- `ec2-instance-connect:OpenTunnel` on the EICE resource
- `ec2:DescribeInstances`

---

## Web UIs

| Service | URL | Credentials |
|---|---|---|
| Vault UI | `http://<PUBLIC_IP>:8200/ui` | Root token from SSM (see below) |
| mongo-express | `http://<PUBLIC_IP>:8081` | `terraform output mongo_express_username` / `terraform output -raw mongo_express_password` |

Access is controlled by the `vault_ui_cidr` variable (default: `0.0.0.0/0`). Restrict to your IP for security.

Retrieve the Vault root token:
```bash
aws ssm get-parameter \
  --name '/vault-mongo-demo/root-token' \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value \
  --output text
```

Retrieve the mongo-express password:
```bash
terraform output -raw mongo_express_password
```

---

## Variables

### `init/` Variables

These control the infrastructure deployment.

| Name | Type | Default | Description |
|---|---|---|---|
| `aws_region` | `string` | `"us-east-1"` | AWS region to deploy into |
| `project_name` | `string` | `"vault-mongo-demo"` | Prefix for all resource names and tags |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR block for the new VPC |
| `vpc_id` | `string` | `""` | Bring-your-own VPC ID. Leave empty to create a new VPC |
| `public_subnet_ids` | `list(string)` | `[]` | Bring-your-own public subnet for the EC2 instance |
| `private_subnet_ids` | `list(string)` | `[]` | Bring-your-own private subnets for Lambda |
| `ec2_instance_type` | `string` | `"t3.medium"` | EC2 instance type for the Vault + MongoDB server |
| `vault_ui_cidr` | `string` | `"0.0.0.0/0"` | CIDR allowed to access Vault UI (:8200) and mongo-express (:8081) |
| `mongo_express_username` | `string` | `"mongo_demo_admin"` | mongo-express basic auth username |
| `lambda_schedule_expression` | `string` | `"rate(5 minutes)"` | EventBridge schedule for the demo Lambda |
| `vault_lambda_extension_layer_arn` | `string` | `""` | Override the Vault Lambda Extension layer ARN. Leave empty to use the regional default |

### `config/` Variables

These control Vault configuration. In most cases the defaults are correct; only override if you changed `project_name` or `ssm_param_prefix` in `init/`.

| Name | Type | Default | Description |
|---|---|---|---|
| `aws_region` | `string` | `"us-east-1"` | AWS region (must match `init/`) |
| `project_name` | `string` | `"vault-mongo-demo"` | Project name prefix (must match `init/`) |
| `ssm_param_prefix` | `string` | `""` | SSM path prefix. Defaults to `/<project_name>` |
| `vault_addr` | `string` | `""` | Vault address. Defaults to `$VAULT_ADDR` env var — export before apply (see Step 3) |
| `vault_token` | `string` | `""` | Vault root token. Defaults to `$VAULT_TOKEN` env var — export before apply (see Step 3) |
| `mongo_db_name` | `string` | `"mongoDB_demo"` | MongoDB database name (must match `init/`) |

---

## Outputs

### `init/` Outputs

| Name | Description |
|---|---|
| `vpc_id` | VPC ID |
| `ec2_public_ip` | Public IP of the Vault + MongoDB EC2 instance |
| `ec2_private_ip` | Private IP (used by Lambda internally) |
| `vault_ui_url` | Vault web UI URL |
| `mongo_express_url` | mongo-express web UI URL (basic auth enabled) |
| `mongo_express_username` | mongo-express login username |
| `mongo_express_password` | mongo-express login password (sensitive — `terraform output -raw mongo_express_password`) |
| `mongo_admin_password` | MongoDB root admin password (sensitive — `terraform output -raw mongo_admin_password`) |
| `mongo_vault_password` | MongoDB vault_admin service account password (sensitive — `terraform output -raw mongo_vault_password`) |
| `ssh_command` | Full `aws ec2-instance-connect ssh` command |
| `vault_address` | Vault API address (VPC-internal) |
| `vault_root_token_ssm_path` | SSM path for the Vault root token |
| `vault_init_output_ssm_path` | SSM path for full init output (recovery keys) |
| `retrieve_vault_token_cmd` | AWS CLI command to print the root token |
| `lambda_function_name` | Lambda function name |
| `lambda_function_arn` | Lambda function ARN |
| `lambda_log_group` | CloudWatch Log Group name |
| `kms_key_arn` | KMS key ARN (do not delete — required for Vault unseal) |

### `config/` Outputs

| Name | Description |
|---|---|
| `vault_auth_backend_path` | Vault AWS auth backend mount path |
| `vault_auth_role_name` | Vault AWS auth role name |
| `vault_database_mount_path` | Vault database secrets engine mount path |
| `vault_database_role_name` | Vault database role name |
| `vault_policy_name` | Vault policy name attached to Lambda tokens |
| `vault_db_creds_path` | Vault API path for dynamic MongoDB credentials |
| `lambda_invoke_test_cmd` | AWS CLI command to invoke the Lambda for a quick test |

---

## Monitoring & Troubleshooting

### Check Lambda logs

```bash
aws logs tail /aws/lambda/vault-mongo-demo-demo \
  --follow \
  --region us-east-1
```

A successful run produces a log line like:
```
[INFO] Demo complete — {"success":true,"vaultDynamicUser":"v-root-lambda-mongo-role-...","readBackVerified":true,...}
```

### Check EC2 bootstrap status

SSH in via EICE and run:
```bash
# View bootstrap log
sudo cat /var/log/user-data.log

# Check sentinel file (written when bootstrap completes)
ls -la /opt/vault/bootstrap_complete

# Check Vault status
docker exec vault vault status

# Check all containers
docker ps
```
