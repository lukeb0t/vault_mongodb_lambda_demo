# =============================================================================
# terraform.tfvars — Default variable overrides for init/
#
# All variables have sensible defaults in variables.tf. Uncomment and edit
# any value you want to change before running `terraform apply`.
# =============================================================================

aws_region   = "us-east-1"
project_name = "vault-mongo-demo"

# Restrict UI access to your IP for security (default: open to internet)
# vault_ui_cidr = "YOUR_IP/32"

# Use an existing VPC instead of creating one
# vpc_id             = "vpc-xxxxxxxxxxxxxxxxx"
# private_subnet_ids = ["subnet-xxxxxxxxxxxxxxxxx", "subnet-xxxxxxxxxxxxxxxxx"]
# public_subnet_ids  = ["subnet-xxxxxxxxxxxxxxxxx"]

# Upsize for sustained load (default: t3.medium)
# ec2_instance_type = "t3.large"

# Change the mongo-express login username (default: mongo_demo_admin)
# mongo_express_username = "mongo_demo_admin"

# Run the demo Lambda more or less frequently (default: every 5 minutes)
# lambda_schedule_expression = "rate(5 minutes)"
