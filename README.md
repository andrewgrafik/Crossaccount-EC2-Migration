EC2 Cross-Account Transfer Tool
================================

Automated bash script for transferring EC2 instances across AWS accounts using AMI sharing.


Purpose
-------

Automates EC2 instance migration between AWS accounts by:

  • Creating AMI from source instance
  • Sharing AMI and EBS snapshots cross-account
  • Launching new instance in target account with all storage
  • Supporting cross-region transfers


Transfer Flow
-------------

  1. Stop source instance (optional but recommended)
  2. Create AMI in source account
  3. Share AMI with target account
  4. Share all EBS snapshots with target account
  5. Copy AMI to target region (if cross-region)
  6. Launch instance in target account
  7. Verify instance is running


Prerequisites
-------------

  • Bash 4.0 or higher
  • AWS CLI installed and configured
  • IAM credentials for both source and target accounts


Required IAM Permissions
------------------------

Source Account:

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeImages",
        "ec2:DescribeSnapshots",
        "ec2:CreateImage",
        "ec2:ModifyImageAttribute",
        "ec2:ModifySnapshotAttribute",
        "ec2:StopInstances",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}

Target Account:

{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:CopyImage",
        "ec2:RunInstances",
        "ec2:CreateTags",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}


Usage
-----

    chmod +x ec2-cross-account-transfer.sh
    ./ec2-cross-account-transfer.sh


Interactive Steps:

  1. Source Account Credentials - Enter AWS access key, secret key, and region
  2. Select Source Instance - Choose from list of running/stopped instances
  3. Stop Instance - Optionally stop instance for consistent AMI
  4. Target Account Credentials - Enter target AWS credentials
  5. Select Target VPC - Choose destination VPC
  6. Select Target Subnet - Choose subnet for new instance
  7. Select Security Groups - Choose one or more security groups
  8. Transfer Configuration - Set instance name, type, and key pair
  9. Confirm and Execute - Review summary and proceed


Example Output
--------------


 EC2 Cross-Account Transfer Tool          


Step 1: Source Account Credentials
✓ Source Account: 123456789012

Step 2: Select Source EC2 Instance
Available EC2 Instances:
─────────────────────────────────────────────────
1) i-0abc123 - web-server - running - t3.medium - Linux
2) i-0def456 - app-server - stopped - t3.large - Linux

Select instance number: 1
✓ Selected: i-0abc123

Step 3: Target Account Credentials
✓ Target Account: 987654321098

Step 4: Select Target VPC
✓ Selected VPC: vpc-0xyz789

Step 5: Select Target Subnet
✓ Selected Subnet: subnet-0abc123

Step 6: Select Security Groups
✓ Selected security groups: sg-0def456 sg-0ghi789

Step 7: Transfer Configuration
Transfer Summary:
─────────────────────────────────────────────────
Source Instance: i-0abc123 (123456789012)
Target Instance: web-server-migrated (987654321098)
Target VPC: vpc-0xyz789
Target Subnet: subnet-0abc123
Security Groups: sg-0def456 sg-0ghi789
Instance Type: t3.medium
─────────────────────────────────────────────────

Proceed with transfer? (yes/no): yes

Starting transfer...

Creating AMI from source instance...
✓ AMI created
✓ AMI shared
✓ Snapshots shared
✓ Instance running


     Transfer Completed Successfully!       


Source Instance: i-0abc123
Target Instance: i-0xyz789
Target AMI: ami-0abc123def
Private IP: 10.0.1.50
Public IP: 54.123.45.67
Region: us-east-1


Important Notes
---------------

Storage Transfer:

  • All EBS volumes attached to source instance are included in AMI
  • Root volume and all data volumes are transferred
  • Volume types, sizes, and IOPS settings are preserved
  • Snapshots are shared automatically with target account

Encryption:

  • Unencrypted volumes transfer seamlessly
  • Encrypted volumes require KMS key access (not handled by this script)
  • For encrypted volumes, use AWS managed keys or ensure KMS grants are configured

Downtime:

  • Stopping instance recommended for data consistency
  • Can create AMI from running instance (may have inconsistent data)
  • Downtime duration depends on instance size and EBS volume sizes

Network Configuration:

  • Instance launched in target VPC/subnet of your choice
  • Security groups must exist in target account
  • Elastic IPs not transferred (must be reassigned manually)
  • ENI configurations not preserved

What is NOT Transferred:

  • IAM instance profiles/roles (must be recreated)
  • Elastic IPs (must be reassigned)
  • CloudWatch alarms (must be recreated)
  • Tags on volumes (only instance tags transferred)
  • Instance metadata options


Troubleshooting
---------------

Bash Version Error:

    bash --version
    
    # macOS - upgrade bash
    brew install bash
    
    # Update shell
    sudo bash -c 'echo /usr/local/bin/bash >> /etc/shells'
    chsh -s /usr/local/bin/bash

AMI Not Visible in Target Account:

    # Verify AMI sharing
    aws ec2 describe-images --image-ids ami-xxxxx --region us-east-1
    
    # Check snapshot permissions
    aws ec2 describe-snapshots --snapshot-ids snap-xxxxx --region us-east-1

Instance Launch Fails:

  • Verify subnet has available IP addresses
  • Check security group rules allow necessary traffic
  • Ensure instance type is available in target AZ
  • Verify IAM permissions for RunInstances

Cross-Region Transfer Issues:

  • AMI copy can take 20-60 minutes depending on size
  • Ensure target region supports the instance type
  • Check regional service quotas


Post-Transfer Checklist
------------------------

  • Verify instance is running
  • Test application functionality
  • Reassign Elastic IP (if needed)
  • Recreate IAM instance profile
  • Update DNS records
  • Configure monitoring/alarms
  • Update backup policies
  • Test security group rules
  • Verify all EBS volumes attached
  • Clean up source AMI/snapshots (after verification)
  • Remove cross-account sharing permissions
  • Rotate AWS credentials used in transfer


Security Best Practices
------------------------

  • Use temporary IAM credentials with minimum required permissions
  • Rotate credentials immediately after transfer
  • Delete shared AMIs/snapshots after successful transfer
  • Review and tighten security group rules in target account
  • Enable encryption at rest for new volumes
  • Enable CloudTrail logging for audit trail


Tips
----

  • Test in non-production environment first
  • Document instance dependencies before transfer
  • Plan for DNS cutover timing
  • Consider using AWS Systems Manager for post-launch configuration
  • Use tags to track transferred resources
  • Keep source instance stopped until verification complete


License
-------

MIT License


Disclaimer
----------

This tool is provided as-is. Always test in non-production environment first. Ensure proper backups before migration. Review AWS costs for data transfer and storage.
