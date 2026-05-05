# =============================================================================
# security_groups.tf — EC2, Lambda, and EICE security groups
#
# Traffic flow summary:
#
#   Browser/CLI ──(443)──► EICE endpoint ──(22)──► EC2
#   Browser     ──(8200)──────────────────────────► EC2  (Vault UI)
#   Browser     ──(8081)──────────────────────────► EC2  (mongo-express)
#   Lambda      ──(8200)──────────────────────────► EC2  (Vault API)
#   Lambda      ──(27017)─────────────────────────► EC2  (MongoDB, dynamic creds)
#   EC2         ──(all)───────────────────────────► Internet (Docker Hub, AWS APIs)
#
# MongoDB (27017) is intentionally NOT exposed to the internet; it is only
# reachable from Lambda via the security-group rule.
# =============================================================================

# ── EC2 Instance Connect Endpoint Security Group ─────────────────────────────
# EICE needs outbound SSH to EC2; no inbound rules (AWS manages inbound).
# Using the VPC CIDR for the egress rather than a security-group reference
# avoids a Terraform cycle between the two SGs.

resource "aws_security_group" "eice" {
  name        = "${var.project_name}-eice-sg"
  description = "Allows EC2 Instance Connect Endpoint to reach EC2 over SSH."
  vpc_id      = local.vpc_id

  egress {
    description = "SSH to instances in VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.project_name}-eice-sg" }
}

# ── EC2 Security Group (Vault + MongoDB) ─────────────────────────────────────

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "Vault UI, mongo-express, SSH via EICE, and internal traffic from Lambda."
  vpc_id      = local.vpc_id

  # ── Inbound ──────────────────────────────────────────────────────────────

  # SSH via EC2 Instance Connect Endpoint (no keypair required — uses your IAM
  # credentials).  Traffic arrives from the EICE SG, not from the public internet.
  ingress {
    description     = "SSH via EICE"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice.id]
  }

  # Vault UI + API accessible from the internet (filtered by vault_ui_cidr).
  # Restrict var.vault_ui_cidr to your office/VPN CIDR for non-demo environments.
  ingress {
    description = "Vault API/UI from internet"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [var.vault_ui_cidr]
  }

  # Lambda also reaches Vault on 8200 — the SG reference is belt-and-suspenders
  # alongside the CIDR rule above (both rules are evaluated independently by AWS).
  ingress {
    description     = "Vault API from Lambda"
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # mongo-express web UI — a lightweight MongoDB browser client running on port
  # 8081 inside the Docker network on the EC2 instance.
  ingress {
    description = "mongo-express UI from internet"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.vault_ui_cidr]
  }

  # MongoDB wire protocol — internal only; never exposed to the internet.
  # Lambda connects here to use the dynamic credentials issued by Vault.
  ingress {
    description     = "MongoDB from Lambda"
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # ── Outbound ─────────────────────────────────────────────────────────────

  # EC2 needs full outbound access to:
  #   • Docker Hub (pull hashicorp/vault, mongo, mongo-express images)
  #   • AWS KMS   (Vault auto-unseal)
  #   • AWS STS   (Vault AWS auth — verifies Lambda's IAM identity)
  #   • AWS SSM   (write Vault root token to Parameter Store)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}

# ── Lambda Security Group ────────────────────────────────────────────────────

resource "aws_security_group" "lambda" {
  name        = "${var.project_name}-lambda-sg"
  description = "Allow outbound to Vault/MongoDB EC2 and to AWS APIs."
  vpc_id      = local.vpc_id

  # Lambda's outbound traffic stays entirely within the VPC.
  # No NAT Gateway is required — Lambda only reaches EC2 via VPC-local routing.
  egress {
    description = "All outbound (Vault + MongoDB via VPC-local routing)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-lambda-sg" }
}
