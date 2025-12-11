#!/usr/bin/env bash

# EC2 Cross-Account Transfer Script - Interactive Version
# Transfers EC2 instances between AWS accounts via AMI
# Requires bash 4.0+ for associative arrays

set -e

# Check bash version
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: This script requires bash 4.0 or higher"
    echo "Current version: $BASH_VERSION"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

configure_aws_profile() {
    local profile_name="$1"
    local access_key="$2"
    local secret_key="$3"
    local region="$4"
    
    aws configure set aws_access_key_id "$access_key" --profile "$profile_name"
    aws configure set aws_secret_access_key "$secret_key" --profile "$profile_name"
    aws configure set region "$region" --profile "$profile_name"
    aws configure set output json --profile "$profile_name"
}

cleanup() {
    aws configure --profile source-account set aws_access_key_id "" 2>/dev/null || true
    aws configure --profile target-account set aws_access_key_id "" 2>/dev/null || true
}
trap cleanup EXIT

echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   EC2 Cross-Account Transfer Tool             ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo

# Step 1: Configure Source Account
echo -e "${BLUE}Step 1: Source Account Credentials${NC}"
while true; do
    read -p "Source AWS Access Key: " SOURCE_ACCESS_KEY
    read -s -p "Source AWS Secret Key: " SOURCE_SECRET_KEY
    echo
    read -p "Source Region [us-east-1]: " SOURCE_REGION
    SOURCE_REGION=${SOURCE_REGION:-us-east-1}
    
    configure_aws_profile "source-account" "$SOURCE_ACCESS_KEY" "$SOURCE_SECRET_KEY" "$SOURCE_REGION"
    
    SOURCE_ACCOUNT_ID=$(aws sts get-caller-identity --profile source-account --query Account --output text 2>&1)
    if [ $? -eq 0 ] && [[ "$SOURCE_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        echo -e "${GREEN}✓ Source Account: $SOURCE_ACCOUNT_ID${NC}"
        break
    fi
    echo -e "${RED}Invalid credentials or unable to authenticate. Please try again.${NC}"
    echo
done
echo

# Step 2: List and Select Source Instance
echo -e "${BLUE}Step 2: Select Source EC2 Instance${NC}"
echo "Scanning for EC2 instances..."

INSTANCES=$(aws ec2 describe-instances --profile source-account --region $SOURCE_REGION \
    --filters "Name=instance-state-name,Values=running,stopped" \
    --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,InstanceType,Platform]' \
    --output text)

if [ -z "$INSTANCES" ]; then
    echo -e "${RED}No EC2 instances found in source account${NC}"
    exit 1
fi

echo
echo "Available EC2 Instances:"
echo "─────────────────────────────────────────────────"
i=1
declare -A INSTANCE_MAP
while IFS=$'\t' read -r id name state type platform; do
    name=${name:-"(no name)"}
    platform=${platform:-"Linux"}
    echo "$i) $id - $name - $state - $type - $platform"
    INSTANCE_MAP[$i]=$id
    ((i++))
done <<< "$INSTANCES"

echo
while true; do
    read -p "Select instance number: " INSTANCE_NUM
    SOURCE_INSTANCE_ID=${INSTANCE_MAP[$INSTANCE_NUM]}
    
    if [ -n "$SOURCE_INSTANCE_ID" ]; then
        break
    fi
    echo -e "${RED}Invalid selection. Please try again.${NC}"
done

echo -e "${GREEN}✓ Selected: $SOURCE_INSTANCE_ID${NC}"

# Get instance details
INSTANCE_DETAILS=$(aws ec2 describe-instances --profile source-account --region $SOURCE_REGION \
    --instance-ids $SOURCE_INSTANCE_ID \
    --query 'Reservations[0].Instances[0]' \
    --output json)

INSTANCE_STATE=$(echo "$INSTANCE_DETAILS" | jq -r '.State.Name')
ROOT_DEVICE=$(echo "$INSTANCE_DETAILS" | jq -r '.RootDeviceName')

echo "Instance state: $INSTANCE_STATE"
echo "Root device: $ROOT_DEVICE"

# Get volume information
echo "Storage volumes:"
VOLUME_IDS=$(echo "$INSTANCE_DETAILS" | jq -r '.BlockDeviceMappings[].Ebs.VolumeId' | tr '\n' ' ')
for VOL_ID in $VOLUME_IDS; do
    VOL_INFO=$(aws ec2 describe-volumes --profile source-account --region $SOURCE_REGION \
        --volume-ids $VOL_ID \
        --query 'Volumes[0].[Size,VolumeType,Iops]' \
        --output text)
    echo "  $VOL_ID: $VOL_INFO GB"
done

# Stop instance if running
if [ "$INSTANCE_STATE" = "running" ]; then
    echo
    echo -e "${YELLOW}Instance must be stopped to create AMI (recommended for consistency)${NC}"
    read -p "Stop instance now? (yes/no): " STOP_CONFIRM
    if [ "$STOP_CONFIRM" = "yes" ]; then
        echo "Stopping instance..."
        aws ec2 stop-instances --profile source-account --region $SOURCE_REGION \
            --instance-ids $SOURCE_INSTANCE_ID > /dev/null
        
        echo "Waiting for instance to stop..."
        while true; do
            STATE=$(aws ec2 describe-instances --profile source-account --region $SOURCE_REGION \
                --instance-ids $SOURCE_INSTANCE_ID \
                --query 'Reservations[0].Instances[0].State.Name' \
                --output text)
            [ "$STATE" = "stopped" ] && break
            echo "  Status: $STATE..."
            sleep 10
        done
        echo -e "${GREEN}✓ Instance stopped${NC}"
    else
        echo -e "${YELLOW}Creating AMI without stopping (may have inconsistent data)${NC}"
    fi
fi

echo

# Step 3: Configure Target Account
echo -e "${BLUE}Step 3: Target Account Credentials${NC}"
while true; do
    read -p "Target AWS Access Key: " TARGET_ACCESS_KEY
    read -s -p "Target AWS Secret Key: " TARGET_SECRET_KEY
    echo
    read -p "Target Region [$SOURCE_REGION]: " TARGET_REGION
    TARGET_REGION=${TARGET_REGION:-$SOURCE_REGION}
    
    configure_aws_profile "target-account" "$TARGET_ACCESS_KEY" "$TARGET_SECRET_KEY" "$TARGET_REGION"
    
    TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --profile target-account --query Account --output text 2>&1)
    if [ $? -eq 0 ] && [[ "$TARGET_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
        echo -e "${GREEN}✓ Target Account: $TARGET_ACCOUNT_ID${NC}"
        break
    fi
    echo -e "${RED}Invalid credentials or unable to authenticate. Please try again.${NC}"
    echo
done
echo

# Step 4: Select Target VPC
echo -e "${BLUE}Step 4: Select Target VPC${NC}"
echo "Scanning VPCs in target account..."

VPCS=$(aws ec2 describe-vpcs --profile target-account --region $TARGET_REGION \
    --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output text)

echo
echo "Available VPCs:"
echo "─────────────────────────────────────────────────"
i=1
declare -A VPC_MAP
while IFS=$'\t' read -r vpc_id cidr name; do
    name=${name:-"(no name)"}
    echo "$i) $vpc_id - $cidr - $name"
    VPC_MAP[$i]=$vpc_id
    ((i++))
done <<< "$VPCS"

echo
while true; do
    read -p "Select VPC number: " VPC_NUM
    TARGET_VPC_ID=${VPC_MAP[$VPC_NUM]}
    
    if [ -n "$TARGET_VPC_ID" ]; then
        break
    fi
    echo -e "${RED}Invalid selection. Please try again.${NC}"
done

echo -e "${GREEN}✓ Selected VPC: $TARGET_VPC_ID${NC}"
echo

# Step 5: Select Subnet
echo -e "${BLUE}Step 5: Select Target Subnet${NC}"
echo "Scanning subnets..."

SUBNETS=$(aws ec2 describe-subnets --profile target-account --region $TARGET_REGION \
    --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
    --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output text)

echo
echo "Available Subnets:"
echo "─────────────────────────────────────────────────"
i=1
declare -A SUBNET_MAP
while IFS=$'\t' read -r subnet_id az cidr name; do
    name=${name:-"(no name)"}
    echo "$i) $subnet_id - $az - $cidr - $name"
    SUBNET_MAP[$i]=$subnet_id
    ((i++))
done <<< "$SUBNETS"

echo
while true; do
    read -p "Select subnet number: " SUBNET_NUM
    TARGET_SUBNET_ID=${SUBNET_MAP[$SUBNET_NUM]}
    
    if [ -n "$TARGET_SUBNET_ID" ]; then
        break
    fi
    echo -e "${RED}Invalid selection. Please enter a single number.${NC}"
done

echo -e "${GREEN}✓ Selected Subnet: $TARGET_SUBNET_ID${NC}"
echo

# Step 6: Security Groups - Recreate from Source
echo -e "${BLUE}Step 6: Security Groups${NC}"
echo "Getting source instance security groups..."

SOURCE_SGS=$(aws ec2 describe-instances --profile source-account --region $SOURCE_REGION \
    --instance-ids $SOURCE_INSTANCE_ID \
    --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' \
    --output text)

echo "Source security groups: $SOURCE_SGS"
echo
read -p "Recreate source security groups in target VPC? (yes/no): " RECREATE_SG

if [ "$RECREATE_SG" = "yes" ]; then
    echo "Recreating security groups..."
    SELECTED_SGS=""
    
    for SG_ID in $SOURCE_SGS; do
        SG_INFO=$(aws ec2 describe-security-groups --profile source-account --region $SOURCE_REGION \
            --group-ids $SG_ID \
            --query 'SecurityGroups[0].[GroupName,Description,IpPermissions,IpPermissionsEgress]' \
            --output json)
        
        SG_NAME=$(echo "$SG_INFO" | jq -r '.[0]')
        SG_DESC=$(echo "$SG_INFO" | jq -r '.[1]')
        INGRESS=$(echo "$SG_INFO" | jq -r '.[2]')
        EGRESS=$(echo "$SG_INFO" | jq -r '.[3]')
        
        NEW_SG_NAME="${SG_NAME}-migrated-$(date +%s)"
        
        NEW_SG_ID=$(aws ec2 create-security-group \
            --group-name "$NEW_SG_NAME" \
            --description "$SG_DESC (migrated)" \
            --vpc-id $TARGET_VPC_ID \
            --profile target-account \
            --region $TARGET_REGION \
            --query 'GroupId' \
            --output text)
        
        echo "  Created: $NEW_SG_ID ($NEW_SG_NAME)"
        
        # Filter ingress rules - remove SG references, keep IP-based rules
        INGRESS_FILTERED=$(echo "$INGRESS" | jq '[.[] | del(.UserIdGroupPairs) | select(.IpRanges != [] or .Ipv6Ranges != [] or .PrefixListIds != [])]')
        
        if [ "$INGRESS_FILTERED" != "[]" ] && [ "$INGRESS_FILTERED" != "null" ]; then
            echo "  Adding ingress rules (IP-based only)..."
            aws ec2 authorize-security-group-ingress \
                --group-id $NEW_SG_ID \
                --ip-permissions "$INGRESS_FILTERED" \
                --profile target-account \
                --region $TARGET_REGION 2>/dev/null && echo "    ✓ Ingress rules added" || echo "    ⚠ Some ingress rules failed"
        else
            echo "    ℹ No IP-based ingress rules to migrate"
        fi
        
        # Filter egress rules - remove SG references, keep IP-based rules
        EGRESS_FILTERED=$(echo "$EGRESS" | jq '[.[] | del(.UserIdGroupPairs) | select(.IpRanges != [] or .Ipv6Ranges != [] or .PrefixListIds != [])]')
        
        # Remove default egress rule first if we have custom rules
        if [ "$EGRESS_FILTERED" != "[]" ] && [ "$EGRESS_FILTERED" != "null" ]; then
            echo "  Removing default egress rule..."
            aws ec2 revoke-security-group-egress \
                --group-id $NEW_SG_ID \
                --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
                --profile target-account \
                --region $TARGET_REGION 2>/dev/null
            
            echo "  Adding egress rules (IP-based only)..."
            aws ec2 authorize-security-group-egress \
                --group-id $NEW_SG_ID \
                --ip-permissions "$EGRESS_FILTERED" \
                --profile target-account \
                --region $TARGET_REGION 2>/dev/null && echo "    ✓ Egress rules added" || echo "    ⚠ Some egress rules failed"
        else
            echo "    ℹ Keeping default egress rule (allow all)"
        fi
        
        SELECTED_SGS="$SELECTED_SGS $NEW_SG_ID"
    done
    
    SELECTED_SGS=$(echo $SELECTED_SGS | xargs)
    echo -e "${GREEN}✓ Security groups recreated with IP-based rules${NC}"
else
    echo "Scanning existing security groups..."
    SECURITY_GROUPS=$(aws ec2 describe-security-groups --profile target-account --region $TARGET_REGION \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
        --query 'SecurityGroups[*].[GroupId,GroupName,Description]' --output text)
    
    echo
    echo "Available Security Groups:"
    echo "─────────────────────────────────────────────────"
    i=1
    declare -A SG_MAP
    while IFS=$'\t' read -r sg_id sg_name sg_desc; do
        echo "$i) $sg_id - $sg_name - $sg_desc"
        SG_MAP[$i]=$sg_id
        ((i++))
    done <<< "$SECURITY_GROUPS"
    
    echo
    while true; do
        read -p "Enter security group numbers (comma-separated): " SG_NUMS
        
        SELECTED_SGS=""
        IFS=',' read -ra NUMS <<< "$SG_NUMS"
        for num in "${NUMS[@]}"; do
            num=$(echo $num | xargs)
            if [ -n "${SG_MAP[$num]}" ]; then
                SELECTED_SGS="$SELECTED_SGS ${SG_MAP[$num]}"
            fi
        done
        SELECTED_SGS=$(echo $SELECTED_SGS | xargs)
        
        if [ -n "$SELECTED_SGS" ]; then
            break
        fi
        echo -e "${RED}Invalid selection. Please try again.${NC}"
    done
    echo -e "${GREEN}✓ Selected security groups${NC}"
fi

echo "Security groups: $SELECTED_SGS"
echo

# Step 7: Transfer Configuration
echo -e "${BLUE}Step 7: Transfer Configuration${NC}"
read -p "Target Instance Name: " TARGET_INSTANCE_NAME
read -p "Target Instance Type [same as source]: " TARGET_INSTANCE_TYPE

if [ -z "$TARGET_INSTANCE_TYPE" ]; then
    TARGET_INSTANCE_TYPE=$(aws ec2 describe-instances --profile source-account --region $SOURCE_REGION \
        --instance-ids $SOURCE_INSTANCE_ID \
        --query 'Reservations[0].Instances[0].InstanceType' \
        --output text)
fi

AMI_NAME="ec2-transfer-$(date +%Y%m%d-%H%M%S)"

echo
echo -e "${YELLOW}Transfer Summary:${NC}"
echo "─────────────────────────────────────────────────"
echo "Source Instance: $SOURCE_INSTANCE_ID ($SOURCE_ACCOUNT_ID)"
echo "Target Instance: $TARGET_INSTANCE_NAME ($TARGET_ACCOUNT_ID)"
echo "Target VPC: $TARGET_VPC_ID"
echo "Target Subnet: $TARGET_SUBNET_ID"
echo "Security Groups: $SELECTED_SGS"
echo "Instance Type: $TARGET_INSTANCE_TYPE"
echo "─────────────────────────────────────────────────"
echo
read -p "Proceed with transfer? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Transfer cancelled"
    exit 0
fi

echo
echo -e "${GREEN}Starting transfer...${NC}"
echo

# Create AMI
echo "Creating AMI from source instance..."
AMI_ID=$(aws ec2 create-image \
    --instance-id $SOURCE_INSTANCE_ID \
    --name "$AMI_NAME" \
    --description "Cross-account transfer AMI" \
    --profile source-account \
    --region $SOURCE_REGION \
    --query ImageId \
    --output text)

echo "AMI ID: $AMI_ID"

# Wait for AMI
echo "Waiting for AMI to be available..."
while true; do
    STATE=$(aws ec2 describe-images \
        --image-ids $AMI_ID \
        --profile source-account \
        --region $SOURCE_REGION \
        --query 'Images[0].State' \
        --output text 2>/dev/null || echo "pending")
    
    if [ "$STATE" = "available" ]; then
        break
    elif [ "$STATE" = "failed" ]; then
        echo -e "${RED}AMI creation failed${NC}"
        exit 1
    fi
    
    echo "  Status: $STATE..."
    sleep 30
done

echo -e "${GREEN}✓ AMI created${NC}"

# Get snapshot IDs
SNAPSHOT_IDS=$(aws ec2 describe-images \
    --image-ids $AMI_ID \
    --profile source-account \
    --region $SOURCE_REGION \
    --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' \
    --output text)

echo "Snapshots: $SNAPSHOT_IDS"

# Share AMI with target account
echo "Sharing AMI with target account..."
aws ec2 modify-image-attribute \
    --image-id $AMI_ID \
    --launch-permission "Add=[{UserId=$TARGET_ACCOUNT_ID}]" \
    --profile source-account \
    --region $SOURCE_REGION

echo -e "${GREEN}✓ AMI shared${NC}"

# Share snapshots
echo "Sharing snapshots with target account..."
for SNAPSHOT_ID in $SNAPSHOT_IDS; do
    aws ec2 modify-snapshot-attribute \
        --snapshot-id $SNAPSHOT_ID \
        --create-volume-permission "Add=[{UserId=$TARGET_ACCOUNT_ID}]" \
        --profile source-account \
        --region $SOURCE_REGION
done

echo -e "${GREEN}✓ Snapshots shared${NC}"

# Copy AMI to target account (if cross-region)
if [ "$SOURCE_REGION" != "$TARGET_REGION" ]; then
    echo "Copying AMI to target region..."
    TARGET_AMI_ID=$(aws ec2 copy-image \
        --source-region $SOURCE_REGION \
        --source-image-id $AMI_ID \
        --name "$AMI_NAME-target" \
        --description "Copied from source account" \
        --profile target-account \
        --region $TARGET_REGION \
        --query ImageId \
        --output text)
    
    echo "Target AMI ID: $TARGET_AMI_ID"
    
    echo "Waiting for AMI copy..."
    while true; do
        STATE=$(aws ec2 describe-images \
            --image-ids $TARGET_AMI_ID \
            --profile target-account \
            --region $TARGET_REGION \
            --query 'Images[0].State' \
            --output text 2>/dev/null || echo "pending")
        
        [ "$STATE" = "available" ] && break
        [ "$STATE" = "failed" ] && echo -e "${RED}AMI copy failed${NC}" && exit 1
        echo "  Status: $STATE..."
        sleep 30
    done
    
    echo -e "${GREEN}✓ AMI copied to target region${NC}"
else
    TARGET_AMI_ID=$AMI_ID
fi

# Launch instance in target account
echo "Launching instance in target account..."

# Get key pair (optional)
read -p "Key pair name (leave empty for none): " KEY_PAIR

# Get AMI block device mappings to preserve volume sizes
AMI_BLOCK_DEVICES=$(aws ec2 describe-images \
    --image-ids $TARGET_AMI_ID \
    --profile target-account \
    --region $TARGET_REGION \
    --query 'Images[0].BlockDeviceMappings' \
    --output json)

echo "Preserving volume configuration from AMI"

# Build tag specifications properly
TAG_SPEC=$(cat <<EOF
[
  {
    "ResourceType": "instance",
    "Tags": [
      {
        "Key": "Name",
        "Value": "$TARGET_INSTANCE_NAME"
      }
    ]
  }
]
EOF
)

# Try to launch instance with retry logic for AZ issues
MAX_RETRIES=3
RETRY_COUNT=0
TARGET_INSTANCE_ID=""

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ -z "$TARGET_INSTANCE_ID" ]; do
    if [ -n "$KEY_PAIR" ]; then
        LAUNCH_OUTPUT=$(aws ec2 run-instances \
            --image-id $TARGET_AMI_ID \
            --instance-type $TARGET_INSTANCE_TYPE \
            --subnet-id $TARGET_SUBNET_ID \
            --security-group-ids $SELECTED_SGS \
            --key-name "$KEY_PAIR" \
            --block-device-mappings "$AMI_BLOCK_DEVICES" \
            --tag-specifications "$TAG_SPEC" \
            --profile target-account \
            --region $TARGET_REGION 2>&1)
    else
        LAUNCH_OUTPUT=$(aws ec2 run-instances \
            --image-id $TARGET_AMI_ID \
            --instance-type $TARGET_INSTANCE_TYPE \
            --subnet-id $TARGET_SUBNET_ID \
            --security-group-ids $SELECTED_SGS \
            --block-device-mappings "$AMI_BLOCK_DEVICES" \
            --tag-specifications "$TAG_SPEC" \
            --profile target-account \
            --region $TARGET_REGION 2>&1)
    fi
    
    if echo "$LAUNCH_OUTPUT" | grep -q "Unsupported"; then
        echo -e "${YELLOW}Instance type not available in selected subnet's AZ${NC}"
        echo "Please select a different subnet:"
        
        # Show subnets again
        i=1
        declare -A SUBNET_MAP_RETRY
        while IFS=$'\t' read -r subnet_id az cidr name; do
            name=${name:-"(no name)"}
            echo "$i) $subnet_id - $az - $cidr - $name"
            SUBNET_MAP_RETRY[$i]=$subnet_id
            ((i++))
        done <<< "$SUBNETS"
        
        read -p "Select subnet number: " SUBNET_NUM_RETRY
        TARGET_SUBNET_ID=${SUBNET_MAP_RETRY[$SUBNET_NUM_RETRY]}
        
        if [ -z "$TARGET_SUBNET_ID" ]; then
            echo -e "${RED}Invalid selection${NC}"
            ((RETRY_COUNT++))
            continue
        fi
        
        ((RETRY_COUNT++))
    else
        TARGET_INSTANCE_ID=$(echo "$LAUNCH_OUTPUT" | jq -r '.Instances[0].InstanceId' 2>/dev/null)
        if [ -z "$TARGET_INSTANCE_ID" ] || [ "$TARGET_INSTANCE_ID" = "null" ]; then
            echo -e "${RED}Launch failed: $LAUNCH_OUTPUT${NC}"
            ((RETRY_COUNT++))
        fi
    fi
done

if [ -z "$TARGET_INSTANCE_ID" ] || [ "$TARGET_INSTANCE_ID" = "None" ]; then
    echo -e "${RED}Failed to launch instance. Check error above.${NC}"
    exit 1
fi

echo "Target Instance ID: $TARGET_INSTANCE_ID"

# Wait for instance
echo "Waiting for instance to be running..."
while true; do
    STATE=$(aws ec2 describe-instances \
        --instance-ids $TARGET_INSTANCE_ID \
        --profile target-account \
        --region $TARGET_REGION \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "pending")
    
    if [ "$STATE" = "running" ]; then
        break
    elif [ "$STATE" = "terminated" ] || [ "$STATE" = "shutting-down" ]; then
        echo -e "${RED}Instance launch failed${NC}"
        exit 1
    fi
    
    echo "  Status: $STATE..."
    sleep 15
done

echo -e "${GREEN}✓ Instance running${NC}"

# Get instance details
INSTANCE_IP=$(aws ec2 describe-instances \
    --instance-ids $TARGET_INSTANCE_ID \
    --profile target-account \
    --region $TARGET_REGION \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text)

PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $TARGET_INSTANCE_ID \
    --profile target-account \
    --region $TARGET_REGION \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "N/A")

echo
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Transfer Completed Successfully!         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo
echo "Source Instance: $SOURCE_INSTANCE_ID"
echo "Target Instance: $TARGET_INSTANCE_ID"
echo "Target AMI: $TARGET_AMI_ID"
echo "Private IP: $INSTANCE_IP"
echo "Public IP: $PUBLIC_IP"
echo "Region: $TARGET_REGION"
echo
echo -e "${YELLOW}IMPORTANT: Rotate the AWS credentials used in this transfer${NC}"
echo
