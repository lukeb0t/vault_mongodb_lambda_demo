# =============================================================================
# vpc.tf — Networking layer
#
# Architecture overview:
#
#   ┌─────────────────────────────── VPC (10.0.0.0/16) ───────────────────────┐
#   │                                                                           │
#   │  ┌── public subnet (10.0.0.0/24, AZ[0]) ───────────────────────────┐    │
#   │  │  EC2 (Vault + MongoDB + mongo-express)  ← public IP via IGW      │    │
#   │  │  EC2 Instance Connect Endpoint (EICE)   ← keypair-free SSH       │    │
#   │  └──────────────────────────────────────────────────────────────────┘    │
#   │                                                                           │
#   │  ┌── private subnet A (10.0.1.0/24, AZ[0]) ────────────────────────┐    │
#   │  │  Lambda ENI (AZ[0])                                               │    │
#   │  └──────────────────────────────────────────────────────────────────┘    │
#   │                                                                           │
#   │  ┌── private subnet B (10.0.2.0/24, AZ[1]) ────────────────────────┐    │
#   │  │  Lambda ENI (AZ[1])  ← AWS requires ≥2 AZs for Lambda in VPC    │    │
#   │  └──────────────────────────────────────────────────────────────────┘    │
#   │                                                                           │
#   │  Internet Gateway — provides EC2 with internet access (Docker Hub,       │
#   │  AWS APIs).  Lambda communicates only within the VPC via local routing   │
#   │  and does not need a NAT gateway or VPC endpoints.                       │
#   └───────────────────────────────────────────────────────────────────────────┘
#
# Cost note: This design intentionally avoids NAT Gateways (~$32/mo + data
# transfer).  Lambda only talks to EC2 (internal VPC routing, free) and does
# not need internet access.  EC2 gets direct internet access via the IGW.
# =============================================================================

# ── VPC ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  # DNS support is required for EC2 Instance Connect and for internal DNS
  # resolution between Docker containers on the EC2 host.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  tags = { Name = "${var.project_name}-igw" }
}

# ── Public subnet (EC2 lives here — internet access via IGW, no NAT needed) ──

resource "aws_subnet" "public" {
  count = local.create_vpc ? 1 : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)   # e.g. 10.0.0.0/24
  availability_zone = data.aws_availability_zones.available.names[0]
  # Instances launched in this subnet automatically receive a public IP,
  # which is how the Vault UI and mongo-express become reachable from a browser.
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-${data.aws_availability_zones.available.names[0]}" }
}

# ── Private subnets (Lambda only — no internet access needed; Lambda reaches EC2 via VPC-local routing) ──

# AZ[0] — primary Lambda subnet.
resource "aws_subnet" "private_a" {
  count = local.create_vpc ? 1 : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 1)   # e.g. 10.0.1.0/24
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "${var.project_name}-private-${data.aws_availability_zones.available.names[0]}" }
}

# AZ[1] — secondary Lambda subnet.
# AWS Lambda requires VPC functions to be associated with subnets in at least
# two distinct Availability Zones so that Lambda can place ENIs for failover.
resource "aws_subnet" "private_b" {
  count = local.create_vpc ? 1 : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 2)   # e.g. 10.0.2.0/24
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = { Name = "${var.project_name}-private-${data.aws_availability_zones.available.names[1]}" }
}

# ── EC2 Instance Connect Endpoint (EICE) ─────────────────────────────────────
# Enables keypair-free SSH to the EC2 instance via IAM credentials.
# Works from the AWS console "Connect" button or the AWS CLI v2:
#   aws ec2-instance-connect ssh --instance-id <ID> --os-user ec2-user
#
# EICE is free — there are no hourly charges unlike a NAT Gateway or Bastion.
# It works by establishing an encrypted tunnel from the AWS control plane to the
# target instance using the caller's IAM identity; no SSH key pair is needed on
# the instance side.

resource "aws_ec2_instance_connect_endpoint" "main" {
  count     = local.create_vpc ? 1 : 0
  subnet_id = aws_subnet.public[0].id

  security_group_ids = [aws_security_group.eice.id]

  tags = { Name = "${var.project_name}-eice" }
}

# ── Route Tables ──────────────────────────────────────────────────────────────

# Public route table — sends all non-VPC traffic out through the Internet Gateway.
resource "aws_route_table" "public" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = local.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.public[0].id
  route_table_id = aws_route_table.public[0].id
}

# Private route table — VPC-local routes only (auto-added by AWS).
# Lambda only needs to reach EC2 via the VPC's internal routing fabric, so no
# internet default route (and therefore no NAT Gateway) is required here.
resource "aws_route_table" "private" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.main[0].id

  # No internet route — Lambda only communicates with EC2 via VPC-local routing.

  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private_a" {
  count          = local.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.private_a[0].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_route_table_association" "private_b" {
  count          = local.create_vpc ? 1 : 0
  subnet_id      = aws_subnet.private_b[0].id
  route_table_id = aws_route_table.private[0].id
}
