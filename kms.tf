# =============================================================================
# kms.tf — KMS key for Vault auto-unseal
#
# Vault's auto-unseal feature delegates the storage of its master key to AWS
# KMS.  On every restart, Vault calls KMS to decrypt the key material it needs
# to unseal itself — no human operator needs to provide unseal shards.
#
# Access model:
#   The key policy grants admin access to the account root only.  The EC2
#   instance role is granted usage access via an IAM policy (in iam.tf), not
#   via the key policy itself.  This avoids a circular dependency:
#     kms.tf → iam.tf would require iam.tf to be evaluated first, but
#     iam.tf → kms.tf is safe because the KMS ARN is an output of this file.
# =============================================================================

resource "aws_kms_key" "vault_unseal" {
  description = "Vault auto-unseal key for ${var.project_name}"

  # Safety window before permanent deletion — minimum is 7 days.
  # Destroying this key without first migrating Vault's key material will
  # leave Vault permanently sealed (data is not lost, but cannot be accessed).
  deletion_window_in_days = 7

  # Automatically rotate the key material every year.  Rotation does NOT
  # invalidate ciphertext encrypted with older key versions; AWS KMS retains
  # all previous key versions until the key is deleted.
  enable_key_rotation = true

  tags = { Name = "${var.project_name}-vault-unseal" }
}

# Human-readable alias used in the Vault HCL configuration file so that the
# kms_key_id config value is stable across key rotations.
resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.project_name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}
