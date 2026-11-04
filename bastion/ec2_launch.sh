#!/bin/bash
# /opt/ec2_launch.sh <name tag>        e.g. /opt/ec2_launch.sh wsi-api-3
#
# Launches a new API instance with the same settings as the EC2 section (AMI, instance type,
# security groups, IAM role wsi-api, tag wsi:deploy:group=dev-api), copied from wsi-api-1.
# The instance is fully private:
#   - subnet wsi-private-a, which has no route to the internet (no NAT, no IGW), no public IP
#   - no key pair: access only through AWS Systems Manager, with the credentials of the
#     AWS CLI that runs the command:   aws ssm start-session --target <instance-id>
#   - SSM, CodeDeploy and S3 (yum repos, CodeDeploy agent, build artifacts) are reached
#     through the VPC endpoints of infra/wsi-module-b.yaml
#
# Optional overrides: REF_NAME (instance to copy, default wsi-api-1), SUBNET_NAME (default
# wsi-private-a), SUBNET_ID, AMI_ID, INSTANCE_TYPE, SG_IDS (comma separated), PROFILE_NAME,
# SSM_WAIT (seconds to wait for SSM, 0 = do not wait).
set -uo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "Usage: $0 <name tag>   (e.g. $0 wsi-api-3)" >&2; exit 1; }

export AWS_DEFAULT_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
export AWS_PAGER=""
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: do not rewrite /paths inside arguments
REGION="$AWS_DEFAULT_REGION"

REF_NAME="${REF_NAME:-wsi-api-1}"
SUBNET_NAME="${SUBNET_NAME:-wsi-private-a}"
DEPLOY_TAG_KEY="wsi:deploy:group"
DEPLOY_TAG_VALUE="dev-api"
SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
SSM_WAIT="${SSM_WAIT:-180}"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- settings of the reference instance (same as the EC2 section)
ref_settings() {   # describe-instances filter
  aws ec2 describe-instances --filters "$1" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[] | [0].[InstanceId,ImageId,InstanceType,SubnetId,IamInstanceProfile.Arn,join(`","`,SecurityGroups[].GroupId)]' \
    --output text 2>/dev/null
}
REF=$(ref_settings "Name=tag:Name,Values=$REF_NAME")
case "$REF" in ""|None*) REF=$(ref_settings "Name=tag:$DEPLOY_TAG_KEY,Values=$DEPLOY_TAG_VALUE") ;; esac
read -r REF_ID AMI TYPE REF_SUBNET PROFILE_ARN SGS <<<"$REF"
[ "${PROFILE_ARN:-None}" = None ] && PROFILE_ARN=""

# ---- private subnet (no NAT): wsi-private-a, or the reference instance's subnet
SUBNET="${SUBNET_ID:-$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$SUBNET_NAME" \
                         --query 'Subnets[0].SubnetId' --output text 2>/dev/null)}"
[ "${SUBNET:-None}" = None ] && SUBNET="$REF_SUBNET"

AMI="${AMI_ID:-$AMI}"
TYPE="${INSTANCE_TYPE:-$TYPE}"
SGS="${SG_IDS:-$SGS}"
PROFILE_NAME="${PROFILE_NAME:-${PROFILE_ARN##*/}}"
PROFILE_NAME="${PROFILE_NAME:-wsi-api}"
[ -n "$AMI" ] && [ -n "$TYPE" ] && [ -n "$SUBNET" ] && [ -n "$SGS" ] \
  || die "reference instance $REF_NAME not found - set AMI_ID, INSTANCE_TYPE, SUBNET_ID and SG_IDS"

# ---- the subnet's route table must not have a default route (NAT / internet gateway)
INET=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$SUBNET" \
         --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`][].[NatGatewayId||GatewayId]' \
         --output text 2>/dev/null)
if [ -z "$INET" ] || [ "$INET" = None ]; then
  NET="no route to the internet"
else
  NET="internet via $INET"
  echo "WARNING: subnet $SUBNET has a 0.0.0.0/0 route to $INET - the instance will not be fully private" >&2
fi

# ---- SSM needs AmazonSSMManagedInstanceCore on the instance role (idempotent)
ensure_ssm_policy() {
  local role attached
  role=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
           --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null)
  case "$role" in ""|None) role="$PROFILE_NAME" ;; esac
  attached=$(aws iam list-attached-role-policies --role-name "$role" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)
  grep -qF "$SSM_POLICY_ARN" <<<"$attached" && return 0
  if aws iam attach-role-policy --role-name "$role" --policy-arn "$SSM_POLICY_ARN" 2>/dev/null; then
    echo "Attached AmazonSSMManagedInstanceCore to IAM role $role"
  else
    echo "WARNING: could not check/attach AmazonSSMManagedInstanceCore on IAM role $role - attach it, or SSM will not work" >&2
  fi
}
ensure_ssm_policy

# ---- boot script. No internet: the Amazon Linux repos and the CodeDeploy agent bucket come
# through the S3 gateway endpoint, SSM and CodeDeploy through interface endpoints.
# Python 3 / Flask and the application are installed by the deployment (appspec.yml hooks).
USER_DATA=$(cat <<EOF
#!/bin/bash
if ! rpm -q amazon-ssm-agent >/dev/null 2>&1; then
  for i in \$(seq 1 30); do yum install -y https://s3.${REGION}.amazonaws.com/amazon-ssm-${REGION}/latest/linux_amd64/amazon-ssm-agent.rpm && break; sleep 10; done
fi
systemctl enable --now amazon-ssm-agent
if ! rpm -q codedeploy-agent >/dev/null 2>&1; then
  for i in \$(seq 1 30); do yum install -y ruby && break; sleep 10; done
  cd /tmp
  for i in \$(seq 1 30); do curl -fsSL -o install https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install && break; sleep 10; done
  chmod +x ./install && ./install auto
fi
# The agent must use codedeploy-commands-secure, the CodeDeploy endpoint that exists in the VPC
conf=/etc/codedeploy-agent/conf/codedeployagent.yml
if grep -q '^:enable_auth_policy:' \$conf; then
  sed -i 's/^:enable_auth_policy:.*/:enable_auth_policy: true/' \$conf
else
  echo ':enable_auth_policy: true' >> \$conf
fi
systemctl enable codedeploy-agent
# The installer already started the agent with the public endpoint, which is unreachable here:
# a graceful stop would wait 90 s for its hung poll, so kill it and start it with the new setting
systemctl kill -s SIGKILL codedeploy-agent 2>/dev/null
systemctl restart codedeploy-agent
EOF
)

# ---- launch (no --key-name: no SSH key; no public IP)
# shellcheck disable=SC2086   # SGS is a comma separated list -> one argument per group
ID=$(aws ec2 run-instances \
       --image-id "$AMI" --instance-type "$TYPE" --subnet-id "$SUBNET" --no-associate-public-ip-address \
       --security-group-ids ${SGS//,/ } \
       --iam-instance-profile "Name=$PROFILE_NAME" \
       --user-data "$USER_DATA" \
       --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=$DEPLOY_TAG_KEY,Value=$DEPLOY_TAG_VALUE}]" \
       --count 1 --query 'Instances[0].InstanceId' --output text) || die "run-instances failed"
[ -n "$ID" ] && [ "$ID" != None ] || die "run-instances returned no instance id"
echo "Launched $ID (Name=$NAME) in $SUBNET ($NET) - no key pair, no public IP, access through SSM"

aws ec2 wait instance-running --instance-ids "$ID" || die "$ID did not reach the running state"
echo "$ID is running"

# ---- wait until the SSM agent registers the instance (through the ssm/ssmmessages endpoints)
if [ "$SSM_WAIT" -gt 0 ] 2>/dev/null; then
  start=$(date +%s); ping=""
  while [ $(( $(date +%s) - start )) -lt "$SSM_WAIT" ]; do
    ping=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$ID" \
             --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null) || { ping=""; break; }
    [ "$ping" = Online ] && break
    sleep 5
  done
  if [ "$ping" = Online ]; then echo "$ID is Online in SSM"
  else echo "$ID is not Online in SSM yet - it can take a few more minutes"; fi
fi
echo "Connect: aws ssm start-session --target $ID --region $REGION"
