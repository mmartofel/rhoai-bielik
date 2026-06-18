#!/usr/bin/env bash
set -euo pipefail
# Jednorazowy setup EFS dla cache modeli Bielik.
# Uruchom raz przed deploy.sh na nowym klastrze.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/config/config.env"

REGION="us-east-2"
CLUSTER_NAME="${CLUSTER_NAME:-zenek-hqxqx}"
EFS_TAG="bielik-models"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# 1. Sprawdź czy EFS już istnieje
EXISTING=$(aws efs describe-file-systems \
  --query "FileSystems[?Tags[?Key=='Name'&&Value=='${EFS_TAG}']].FileSystemId" \
  --output text --region "$REGION" 2>/dev/null)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  log "EFS już istnieje: $EXISTING"
  EFS_ID="$EXISTING"
else
  log "Tworzę EFS file system..."
  EFS_ID=$(aws efs create-file-system \
    --region "$REGION" \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value="$EFS_TAG" "Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned" \
    --query 'FileSystemId' --output text)
  log "EFS ID: $EFS_ID"
  aws efs wait file-system-available --file-system-id "$EFS_ID" --region "$REGION"
fi

# 2. VPC i subnety
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")
log "VPC: $VPC_ID"

NODE_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${CLUSTER_NAME}-node" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")
log "Node SG: $NODE_SG"

# 3. EFS Security Group (port 2049)
EFS_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${CLUSTER_NAME}-efs" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")

if [ -z "$EFS_SG" ] || [ "$EFS_SG" = "None" ]; then
  EFS_SG=$(aws ec2 create-security-group \
    --group-name "${CLUSTER_NAME}-efs" \
    --description "EFS NFS dla bielik model cache" \
    --vpc-id "$VPC_ID" --region "$REGION" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress \
    --group-id "$EFS_SG" --protocol tcp --port 2049 \
    --source-group "$NODE_SG" --region "$REGION" > /dev/null
  log "EFS SG: $EFS_SG (nowa)"
else
  log "EFS SG: $EFS_SG (istniejąca)"
fi

# 4. Mount Targets (jedna na AZ)
SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[*].SubnetId' --output text --region "$REGION")

for SUBNET in $SUBNETS; do
  EXISTING_MT=$(aws efs describe-mount-targets \
    --file-system-id "$EFS_ID" \
    --query "MountTargets[?SubnetId=='$SUBNET'].MountTargetId" \
    --output text --region "$REGION" 2>/dev/null)
  if [ -z "$EXISTING_MT" ] || [ "$EXISTING_MT" = "None" ]; then
    MT=$(aws efs create-mount-target \
      --file-system-id "$EFS_ID" \
      --subnet-id "$SUBNET" \
      --security-groups "$EFS_SG" \
      --region "$REGION" \
      --query 'MountTargetId' --output text)
    log "Mount target: $MT ($SUBNET)"
  else
    log "Mount target już istnieje: $EXISTING_MT ($SUBNET)"
  fi
done

# 5. IMDSv2 hop limit = 2 (wymagane dla EFS CSI na OpenShift)
log "Ustawiam IMDSv2 hop limit = 2 na węzłach klastra..."
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
             "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text --region "$REGION")
for ID in $INSTANCES; do
  aws ec2 modify-instance-metadata-options \
    --instance-id "$ID" --http-put-response-hop-limit 2 \
    --http-endpoint enabled --region "$REGION" \
    --output text --query 'InstanceMetadataOptions.HttpPutResponseHopLimit' > /dev/null
  echo "  $ID → hop limit 2"
done

# 6. EFS CSI Driver (Helm)
log "Instaluję AWS EFS CSI Driver..."
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/ 2>/dev/null || true
helm repo update aws-efs-csi-driver 2>/dev/null
helm upgrade --install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
  --namespace kube-system \
  --set image.repository=public.ecr.aws/efs-csi-driver/amazon/aws-efs-csi-driver \
  --wait 2>/dev/null && log "EFS CSI Driver zainstalowany"

# 7. IAM permissions dla węzłów
log "Dodaję EFS permissions do IAM worker role..."
ROLE_NAME=$(aws iam get-instance-profile \
  --instance-profile-name "${CLUSTER_NAME}-worker-profile" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null || echo "")

if [ -n "$ROLE_NAME" ]; then
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name efs-csi-policy \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Action":[
        "elasticfilesystem:DescribeAccessPoints","elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets","elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:DeleteAccessPoint","elasticfilesystem:TagResource",
        "ec2:DescribeAvailabilityZones"],"Resource":"*"}]}' 2>/dev/null && \
    log "IAM policy dodana do $ROLE_NAME"
fi

# 8. EFS Access Point z UID dla OpenShift (1000950000)
EXISTING_AP=$(aws efs describe-access-points \
  --file-system-id "$EFS_ID" \
  --query "AccessPoints[?Tags[?Key=='Name'&&Value=='bielik-model-ap']].AccessPointId" \
  --output text --region "$REGION" 2>/dev/null)

if [ -z "$EXISTING_AP" ] || [ "$EXISTING_AP" = "None" ]; then
  AP_ID=$(aws efs create-access-point \
    --file-system-id "$EFS_ID" \
    --region "$REGION" \
    --posix-user Uid=1000950000,Gid=1000950000 \
    --root-directory "Path=/bielik-models,CreationInfo={OwnerUid=1000950000,OwnerGid=1000950000,Permissions=0775}" \
    --tags Key=Name,Value=bielik-model-ap \
    --query 'AccessPointId' --output text)
  log "Access Point: $AP_ID"
else
  AP_ID="$EXISTING_AP"
  log "Access Point już istnieje: $AP_ID"
fi

log ""
log "======================================================="
log " GOTOWE. Skopiuj te wartości do manifests/04-efs-storage.yaml:"
log "  EFS File System ID: $EFS_ID"
log "  EFS Access Point ID: $AP_ID"
log "  volumeHandle: ${EFS_ID}::${AP_ID}"
log "======================================================="
