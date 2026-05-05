# =============================================================================
# ec2.tf — EC2 instance running Vault + MongoDB + mongo-express (Docker)
#
# A single t3.medium instance hosts three Docker containers on a shared bridge
# network.  All setup is performed by the user_data bootstrap script at first
# boot (see templates/user_data.sh.tpl).
#
# Instance placement:
#   The instance is placed in the public subnet so it has direct internet
#   access via the Internet Gateway.  This allows the bootstrap script to pull
#   Docker images from Docker Hub and call AWS APIs without a NAT Gateway.
#   The instance receives an auto-assigned public IP for browser access to the
#   Vault UI (port 8200) and mongo-express (port 8081).
#
# SSH access:
#   SSH is available via EC2 Instance Connect Endpoint (keypair-free).
#   Run: aws ec2-instance-connect ssh --instance-id <ID> --os-user ec2-user
# =============================================================================

resource "aws_instance" "vault_mongo" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.ec2_instance_type

  # Public subnet — instance receives a public IP for browser access.
  subnet_id                   = local.public_subnet_ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 30      # GiB — enough for the two Docker image layers + Vault data
    encrypted   = true    # Encrypts with the account's default EBS KMS key
  }

  # Render the bootstrap script, substituting Terraform values for template
  # variables.  The rendered script runs once as root at first boot.
  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    aws_region                = var.aws_region
    kms_key_id                = aws_kms_key.vault_unseal.key_id
    mongo_admin_password      = random_password.mongo_admin.result
    mongo_vault_password      = random_password.mongo_vault.result
    mongo_express_username    = var.mongo_express_username
    mongo_express_password    = random_password.mongo_express.result
    # Lambda role ARN is bound in the Vault AWS auth role so only Lambdas
    # running under this specific IAM role can authenticate to Vault.
    lambda_role_arn           = aws_iam_role.lambda.arn
    ssm_param_prefix          = local.ssm_param_prefix
    project_name              = var.project_name
  })

  # Ensure the IGW and public route table are ready before this instance
  # starts so that user_data can reach Docker Hub and AWS APIs.
  depends_on = [
    aws_route_table_association.public,
  ]

  tags = { Name = "${var.project_name}-server" }
}
