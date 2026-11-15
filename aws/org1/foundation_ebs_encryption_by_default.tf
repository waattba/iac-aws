# Enable default EBS encryption by default across all governed regions
# Uses aws cli via local-exec to avoid terraform provider timeout issues
# when multiple AWS provider aliases are configured.

locals {
  ebs_encryption_regions = [
    "ca-central-1",
    "ca-west-1",
    "us-east-1",
    "us-east-2",
    "us-west-2",
  ]
}

# Use null_resource with local-exec to enable EBS encryption via AWS CLI
# This avoids the terraform provider timeout issue with multiple regions
resource "null_resource" "ebs_encryption_by_default" {
  for_each = toset(local.ebs_encryption_regions)

  provisioner "local-exec" {
    command = "aws ec2 enable-ebs-encryption-by-default --region ${each.value}"
  }

  # Trigger on every apply to ensure encryption is enabled
  triggers = {
    always_run = timestamp()
  }
}
