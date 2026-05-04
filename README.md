# Vault + MongoDB + Lambda Demo

A Terraform module that deploys a complete, self-contained demonstration of HashiCorp Vault's dynamic database credentials workflow on AWS.

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
| EC2 in public subnet | Eliminates expensive NAT Gateway (~$32/month). Lambda only needs VPC-local routing to reach EC2. |
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
- `gh` CLI (optional — only needed to create the GitHub repo)

The AWS identity running Terraform needs permissions to create: VPC, EC2, IAM roles, Lambda, KMS, SSM parameters, CloudWatch, EventBridge, and EC2 Instance Connect Endpoint resources.

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/lukeb0t/vault_mongodb_lambda_demo.git
cd vault_mongodb_lambda_demo

# Create a terraform.tfvars file (see Variables section below)
cat > terraform.tfvars <<VARS
aws_region = "us-east-1"
VARS

# Deploy (takes ~5 minutes — EC2 bootstrap runs in the background)
terraform init
terraform apply

# After apply completes, wait ~5 minutes for the EC2 bootstrap to finish.
# Then retrieve the Vault root token:
$(terraform output -raw retrieve_vault_token_cmd)

# Open the Vault UI:
echo "Vault UI: $(terraform output -raw vault_ui_url)"

# Open mongo-express:
echo "mongo-express: $(terraform output -raw mongo_express_url)"

# SSH into EC2 (no keypair needed):
$(terraform output -raw ssh_command)

# Manually trigger the Lambda to run the demo:
aws lambda invoke \
  --function-name $(terraform output -raw lambda_function_name) \
  --region us-east-1 \
  /tmp/vault-demo-result.json && cat /tmp/vault-demo-result.json
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

When creating a Vault AWS auth role with `bound_iam_principal_arn`, Vault resolves the role ARN to its unique **Role ID** (a stable identifier that persists even if the role is deleted and recreated with the same name). This is a security feature that prevents role-substitution attacks. The EC2 instance running Vault must have `iam:GetRole` permission on the Lambda role for this lookup to succeed.

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

| Service | URL | Notes |
|---|---|---|
| Vault UI | `http://<PUBLIC_IP>:8200/ui` | Sign in with root token from SSM |
| mongo-express | `http://<PUBLIC_IP>:8081` | No credentials required (demo mode) |

Access is controlled by the `vault_ui_cidr` variable (default: `0.0.0.0/0`). Restrict to your IP for security.

Retrieve the root token:
```bash
aws ssm get-parameter \
  --name '/vault-mongo-demo/root-token' \
  --with-decryption \
  --region us-east-1 \
  --query Parameter.Value \
  --output text
```

---

## Variables

| Name | Type | Default | Description |
|---|---|---|---|
| `aws_region` | `string` | `"us-east-1"` | AWS region to deploy into |
| `project_name` | `string` | `"vault-mongo-demo"` | Prefix for all resource names and tags |
| `environment` | `string` | `"demo"` | Environment tag applied to all resources |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | CIDR block for the new VPC |
| `vpc_id` | `string` | `""` | Bring-your-own VPC ID. Leave empty to create a new VPC |
| `public_subnet_id` | `string` | `""` | Bring-your-own public subnet for the EC2 instance |
| `private_subnet_ids` | `list(string)` | `[]` | Bring-your-own private subnets for Lambda |
| `ec2_instance_type` | `string` | `"t3.medium"` | EC2 instance type for the Vault + MongoDB server |
| `ec2_ami_id` | `string` | `""` | Custom AMI ID. Leave empty to use the latest Amazon Linux 2023 |
| `vault_ui_cidr` | `string` | `"0.0.0.0/0"` | CIDR allowed to access Vault UI (:8200) and mongo-express (:8081) |
| `mongo_admin_password` | `string` | `"Admin1234!"` | MongoDB root password (**change in production**) |
| `mongo_vault_password` | `string` | `"Vault1234!"` | MongoDB vault_admin service account password |
| `lambda_schedule_expression` | `string` | `"rate(5 minutes)"` | EventBridge schedule for the demo Lambda |
| `kms_deletion_window_days` | `number` | `7` | KMS key pending-deletion window (7–30 days) |
| `tags` | `map(string)` | `{}` | Additional tags to apply to all resources |

---

## Outputs

| Name | Description |
|---|---|
| `vpc_id` | VPC ID |
| `ec2_public_ip` | Public IP of the Vault + MongoDB EC2 instance |
| `ec2_private_ip` | Private IP (used by Lambda internally) |
| `vault_ui_url` | Vault web UI URL |
| `mongo_express_url` | mongo-express web UI URL |
| `ssh_command` | Full `aws ec2-instance-connect ssh` command |
| `vault_address` | Vault API address (VPC-internal) |
| `vault_root_token_ssm_path` | SSM path for the Vault root token |
| `vault_init_output_ssm_path` | SSM path for full init output (recovery keys) |
| `retrieve_vault_token_cmd` | AWS CLI command to print the root token |
| `lambda_function_name` | Lambda function name |
| `lambda_function_arn` | Lambda function ARN |
| `lambda_log_group` | CloudWatch Log Group name |
| `kms_key_arn` | KMS key ARN (do not delete — required for Vault unseal) |

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

### Common issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Lambda times out with no logs | Extension can't reach Vault | Check EC2 security group allows :8200 from Lambda SG |
| `403 permission denied` on Vault login | AWS auth role not created / wrong ARN | Check bootstrap log for errors on Step 10 |
| MongoDB connection refused | MongoDB container not running | SSH in, run `docker ps` and `docker logs mongodb` |
| Vault sealed after EC2 restart | KMS key deleted or IAM permissions revoked | Restore `kms:Decrypt` on the EC2 role |
| Bootstrap log ends early | `set -euo pipefail` caught an error | Check the last line of `/var/log/user-data.log` |

### Useful SSM commands

```bash
# Get Vault root token
aws ssm get-parameter --name '/vault-mongo-demo/root-token' \
  --with-decryption --region us-east-1 --query Parameter.Value --output text

# Get full Vault init output (recovery keys)
aws ssm get-parameter --name '/vault-mongo-demo/init-output' \
  --with-decryption --region us-east-1 --query Parameter.Value --output text | jq .
```

---

## Bring Your Own VPC

To deploy into an existing VPC instead of creating a new one:

```hcl
module "vault_demo" {
  source = "./path/to/module"

  vpc_id             = "vpc-0abc123"
  public_subnet_id   = "subnet-0abc123"   # EC2 goes here — needs internet route
  private_subnet_ids = ["subnet-0def456", "subnet-0ghi789"]  # Lambda subnets

  # ... other variables
}
```

---

## Cleanup

```bash
terraform destroy
```

> **Note:** The KMS key has a `deletion_window_in_days` (default 7). If you re-deploy within that window, the key may still be pending deletion. Either wait for it to expire or use the KMS console to cancel deletion.

---

## Security Considerations

This module is designed for **demonstration purposes**. Before using in a shared or production environment:

- Set `vault_ui_cidr` to your specific IP range — the default `0.0.0.0/0` exposes ports 8200 and 8081 to the internet.
- Replace `mongo_admin_password` and `mongo_vault_password` with strong, unique values managed by a secrets manager.
- Enable TLS on Vault (`tls_disable = 0` in `vault.hcl`) and use a valid certificate.
- Enable mongo-express basic authentication.
- Rotate or revoke the Vault root token after initial setup.
- Consider enabling Vault audit logging.
- The EC2 instance does not use a key pair — access is via EICE only. Ensure EICE access is restricted to authorized IAM identities.
