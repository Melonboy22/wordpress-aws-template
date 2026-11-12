#!/usr/bin/env bash
# =============================================================================
# 01-deploy-wordpress.sh
#
# Deploys a single-server WordPress site for the domain set in config.env:
#   EC2 (Amazon Linux 2023) running Apache + PHP + MariaDB + WordPress,
#   with a static Elastic IP and Route 53 A records for the apex and www names.
#
# Usage:   ./01-deploy-wordpress.sh            # HTTP only
#          ./01-deploy-wordpress.sh --https    # also get a Let's Encrypt certificate
#
# IDEMPOTENT: every resource is looked up (by name or Project tag) before it is
# created, so running the script twice reuses what exists - no duplicates.
# Shared settings (AWS_REGION, DOMAIN, PROJECT tag, resource names) are at the
# top of lib/common.sh; YOUR values (domain, email...) go in config.env.
# =============================================================================
set -euo pipefail

# ================================ CONFIG =====================================
INSTANCE_TYPE="t3.micro"        # Free Tier eligible, 2 vCPU burstable, 1 GiB RAM
AMI_SSM_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
ROOT_VOLUME_GB=10               # gp3; Free Tier covers up to 30 GB of EBS
DNS_TTL=60                      # short TTL so DNS changes show up within a minute
HTTP_WAIT_SECONDS=600           # give up waiting for WordPress after ~10 minutes
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENABLE_HTTPS=false
for arg in "$@"; do
  case "$arg" in
    --https) ENABLE_HTTPS=true ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "Unknown option: $arg (use --https or --help)" ;;
  esac
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# -----------------------------------------------------------------------------
step "Pre-flight checks: credentials, default VPC, Route 53 hosted zone"
why "fail fast, before creating anything, if a prerequisite is missing"
preflight
VPC_ID="$(default_vpc_id)"
[[ -n "$VPC_ID" ]] || die "No default VPC in ${AWS_REGION}. This project expects the default VPC - stopping. (You can recreate it with: aws ec2 create-default-vpc)"
ok "default VPC: ${VPC_ID}"
HOSTED_ZONE_ID="$(lookup_hosted_zone)"
[[ -n "$HOSTED_ZONE_ID" ]] || die "No public Route 53 hosted zone for ${DOMAIN} - stopping."
ok "hosted zone for ${DOMAIN}: ${HOSTED_ZONE_ID}"
state_set VPC_ID "$VPC_ID"
state_set HOSTED_ZONE_ID "$HOSTED_ZONE_ID"

# -----------------------------------------------------------------------------
step "EC2 key pair (${KEY_NAME})"
why "SSH needs a key pair; AWS keeps the public half, we keep the private .pem"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  if [[ -f "$KEY_FILE" ]]; then
    ok "reusing key pair ${KEY_NAME} (private key: ${KEY_FILE})"
  else
    warn "Key pair ${KEY_NAME} exists in AWS but ${KEY_FILE} is missing. AWS shows a private key only once, so SSH with it is impossible from here; SSM Session Manager still works."
  fi
else
  rm -f "$KEY_FILE"
  # umask 077 in a subshell: the .pem is created private (owner-only) from the first byte.
  ( umask 077
    aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 --key-format pem \
      --tag-specifications "$(tag_spec key-pair "$KEY_NAME")" \
      --query KeyMaterial --output text > "$KEY_FILE" )
  chmod 400 "$KEY_FILE"   # ssh refuses keys that other users could read
  ok "created key pair ${KEY_NAME}; private key saved to ${KEY_FILE} (chmod 400)"
fi
state_set KEY_NAME "$KEY_NAME"

# -----------------------------------------------------------------------------
step "Security group ${WEB_SG_NAME} (the web server's firewall)"
why "only HTTP/HTTPS are public; SSH is limited to your current IP address"
WEB_SG_ID="$(find_sg_id "$WEB_SG_NAME" "$VPC_ID")"
if [[ -z "$WEB_SG_ID" ]]; then
  WEB_SG_ID="$(aws ec2 create-security-group --group-name "$WEB_SG_NAME" --vpc-id "$VPC_ID" \
    --description "${PROJECT} web tier: HTTP/HTTPS public, SSH from admin IP" \
    --tag-specifications "$(tag_spec security-group "$WEB_SG_NAME")" \
    --query GroupId --output text)"
  ok "created ${WEB_SG_NAME}: ${WEB_SG_ID}"
else
  ok "reusing ${WEB_SG_NAME}: ${WEB_SG_ID}"
fi
sg_allow_cidr "$WEB_SG_ID" 80  "0.0.0.0/0" "HTTP from anywhere"
sg_allow_cidr "$WEB_SG_ID" 443 "0.0.0.0/0" "HTTPS from anywhere"

MY_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not detect your public IP (got '${MY_IP}')."
info "your public IP: ${MY_IP}"
# If your IP changed since the last run (home vs. campus Wi-Fi), remove the old
# SSH rule so port 22 is only ever open to ONE address: the current one.
# shellcheck disable=SC2016  # backticks are a JMESPath literal, not shell
OLD_SSH_CIDRS="$(aws_text ec2 describe-security-groups --group-ids "$WEB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp')"
for cidr in $OLD_SSH_CIDRS; do
  if [[ "$cidr" != "${MY_IP}/32" ]]; then
    aws ec2 revoke-security-group-ingress --group-id "$WEB_SG_ID" --protocol tcp --port 22 --cidr "$cidr" >/dev/null
    ok "removed old SSH rule for ${cidr}"
  fi
done
sg_allow_cidr "$WEB_SG_ID" 22 "${MY_IP}/32" "SSH from admin IP only"
state_set WEB_SG_ID "$WEB_SG_ID"

# -----------------------------------------------------------------------------
step "IAM role + instance profile (${ROLE_NAME})"
why "gives the instance temporary AWS credentials (no access keys on the server) so it can register with Systems Manager and read its secrets"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  ok "reusing role ${ROLE_NAME}"
else
  # Trust policy: WHO may assume the role -> only the EC2 service.
  aws iam create-role --role-name "$ROLE_NAME" \
    --description "EC2 role for ${PROJECT} (SSM + read own parameters)" \
    --tags "Key=Project,Value=${PROJECT}" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  ok "created role ${ROLE_NAME}"
fi
# AWS-managed policy for the SSM Agent: lets script 2 use Run Command
# instead of SSH. Attaching an already-attached policy is a no-op.
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
ok "AmazonSSMManagedInstanceCore attached"
# Explicit least-privilege statement: read ONLY parameters under /<PROJECT>/.
# (The managed policy above also allows ssm:GetParameter, but stating it here
# documents exactly which secrets this server is meant to read.)
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "read-${PROJECT}-parameters" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ssm:GetParameter\",\"ssm:GetParameters\"],\"Resource\":\"arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${SSM_PREFIX}/*\"}]}"
ok "inline policy read-${PROJECT}-parameters set"
# EC2 attaches roles through an "instance profile" container.
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  ok "reusing instance profile ${INSTANCE_PROFILE_NAME}"
else
  aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" \
    --tags "Key=Project,Value=${PROJECT}" >/dev/null
  ok "created instance profile ${INSTANCE_PROFILE_NAME}"
fi
PROFILE_ROLES="$(aws_text iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --query 'InstanceProfile.Roles[].RoleName')"
if [[ " ${PROFILE_ROLES} " != *" ${ROLE_NAME} "* ]]; then
  aws iam add-role-to-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$ROLE_NAME"
  ok "role added to instance profile"
fi
state_set ROLE_NAME "$ROLE_NAME"
state_set INSTANCE_PROFILE_NAME "$INSTANCE_PROFILE_NAME"

# -----------------------------------------------------------------------------
step "WordPress admin password in SSM Parameter Store"
why "the password is generated here and stored encrypted (SecureString, KMS); it is never printed, never in the scripts, never in user-data"
ensure_random_secret "$WP_ADMIN_PW_PARAM" "${PROJECT} admin password (user ${WP_ADMIN_USER})"

# -----------------------------------------------------------------------------
step "EC2 instance (${INSTANCE_NAME})"
why "the web server itself; reused if one with our tags already exists"
INSTANCE_ID="$(find_instance_id)"
if [[ -n "$INSTANCE_ID" ]]; then
  STATE="$(aws_text ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name')"
  ok "reusing instance ${INSTANCE_ID} (state: ${STATE})"
  if [[ "$STATE" == "stopping" ]]; then aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"; STATE=stopped; fi
  if [[ "$STATE" == "stopped" ]]; then
    aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    ok "start requested"
  fi
else
  # Always the newest patched Amazon Linux 2023 image: AWS publishes its ID in
  # a public SSM parameter, so we never hard-code an AMI ID that goes stale.
  AMI_ID="$(aws ssm get-parameter --name "$AMI_SSM_PARAM" --query Parameter.Value --output text)"
  info "latest Amazon Linux 2023 AMI: ${AMI_ID}"

  # Not every AZ offers every instance type (us-east-1e has no t3), so choose a
  # default subnet in an AZ where ${INSTANCE_TYPE} is actually available.
  OFFERED_AZS=" $(aws_text ec2 describe-instance-type-offerings --location-type availability-zone \
      --filters "Name=instance-type,Values=${INSTANCE_TYPE}" --query 'InstanceTypeOfferings[].Location') "
  SUBNET_ID=""
  while read -r sid az; do
    if [[ -n "$sid" && "$OFFERED_AZS" == *[[:space:]]"$az"[[:space:]]* ]]; then SUBNET_ID="$sid"; SUBNET_AZ="$az"; break; fi
  done <<< "$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
               --query 'sort_by(Subnets, &AvailabilityZone)[].[SubnetId,AvailabilityZone]' --output text)"
  [[ -n "$SUBNET_ID" ]] || die "No default subnet in an AZ that offers ${INSTANCE_TYPE}."
  info "subnet: ${SUBNET_ID} (${SUBNET_AZ})"

  # Fill the placeholders in the user-data template (values contain no '|').
  USER_DATA="${TMP_DIR}/user-data.sh"
  sed -e "s|__REGION__|${AWS_REGION}|g" -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__WWW_DOMAIN__|${WWW_DOMAIN}|g" \
      -e "s|__WP_TITLE__|${WP_TITLE}|g" -e "s|__WP_ADMIN_USER__|${WP_ADMIN_USER}|g" \
      -e "s|__WP_ADMIN_EMAIL__|${WP_ADMIN_EMAIL}|g" -e "s|__WP_ADMIN_PW_PARAM__|${WP_ADMIN_PW_PARAM}|g" \
      "${SCRIPT_DIR}/remote/wordpress-user-data.sh" > "$USER_DATA"

  # A brand-new instance profile takes a few seconds to propagate inside IAM;
  # run-instances fails with "Invalid IAM Instance Profile" until then -> retry.
  for attempt in 1 2 3 4 5 6 7 8; do
    if INSTANCE_ID="$(aws ec2 run-instances \
          --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" --count 1 \
          --key-name "$KEY_NAME" --subnet-id "$SUBNET_ID" --security-group-ids "$WEB_SG_ID" \
          --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
          --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2" \
          --credit-specification CpuCredits=standard \
          --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=${ROOT_VOLUME_GB},VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
          --tag-specifications "$(tag_spec instance "$INSTANCE_NAME")" "$(tag_spec volume "${INSTANCE_NAME}-root")" \
          --user-data "file://${USER_DATA}" \
          --query 'Instances[0].InstanceId' --output text 2>"${TMP_DIR}/run.err")"; then
      break
    fi
    if grep -qi 'instance profile' "${TMP_DIR}/run.err" && (( attempt < 8 )); then
      info "instance profile not propagated yet, retrying in 10 s (attempt ${attempt})"; sleep 10
    else
      die "run-instances failed: $(cat "${TMP_DIR}/run.err")"
    fi
  done
  # Flags explained:
  #   HttpTokens=required          -> IMDSv2 only (blocks SSRF attacks on instance metadata)
  #   CpuCredits=standard          -> t3 defaults to "unlimited", which can bill extra; standard can't
  #   Encrypted=true               -> EBS encryption at rest with the AWS-managed key (free)
  ok "launched ${INSTANCE_ID}"
  state_set AMI_ID "$AMI_ID"
fi
info "waiting for the instance to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
ok "instance ${INSTANCE_ID} is running"
state_set INSTANCE_ID "$INSTANCE_ID"

# -----------------------------------------------------------------------------
step "Elastic IP"
why "a normal public IP changes on every stop/start; DNS needs an address that never changes"
EIP_ALLOC_ID="$(aws_text ec2 describe-addresses --filters "Name=tag:Project,Values=${PROJECT}" --query 'Addresses[0].AllocationId')"
if [[ -z "$EIP_ALLOC_ID" ]]; then
  EIP_ALLOC_ID="$(aws ec2 allocate-address --domain vpc --tag-specifications "$(tag_spec elastic-ip "$EIP_NAME")" \
                    --query AllocationId --output text)"
  ok "allocated ${EIP_ALLOC_ID}"
else
  ok "reusing ${EIP_ALLOC_ID}"
fi
EIP_INSTANCE="$(aws_text ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].InstanceId')"
if [[ "$EIP_INSTANCE" != "$INSTANCE_ID" ]]; then
  aws ec2 associate-address --allocation-id "$EIP_ALLOC_ID" --instance-id "$INSTANCE_ID" --allow-reassociation >/dev/null
  ok "associated with ${INSTANCE_ID}"
else
  ok "already associated with ${INSTANCE_ID}"
fi
EIP_PUBLIC_IP="$(aws ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)"
info "Elastic IP: ${EIP_PUBLIC_IP}"
state_set EIP_ALLOC_ID "$EIP_ALLOC_ID"
state_set EIP_PUBLIC_IP "$EIP_PUBLIC_IP"

# -----------------------------------------------------------------------------
step "Route 53: A records ${DOMAIN} and ${WWW_DOMAIN} -> ${EIP_PUBLIC_IP}"
why "UPSERT = create the record or overwrite it, so re-runs never fail or duplicate"
CHANGE_BATCH="${TMP_DIR}/dns.json"
cat > "$CHANGE_BATCH" <<JSON
{
  "Comment": "${PROJECT} -> Elastic IP",
  "Changes": [
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "${DOMAIN}.", "Type": "A", "TTL": ${DNS_TTL},
      "ResourceRecords": [{"Value": "${EIP_PUBLIC_IP}"}]}},
    {"Action": "UPSERT", "ResourceRecordSet": {"Name": "${WWW_DOMAIN}.", "Type": "A", "TTL": ${DNS_TTL},
      "ResourceRecords": [{"Value": "${EIP_PUBLIC_IP}"}]}}
  ]
}
JSON
CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
               --change-batch "file://${CHANGE_BATCH}" --query ChangeInfo.Id --output text)"
info "waiting for Route 53 to sync the change to all its name servers..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
ok "DNS records are INSYNC"

# -----------------------------------------------------------------------------
step "Wait for EC2 status checks"
why "both the AWS hardware check and the OS reachability check must pass before the server is considered healthy"
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
ok "status checks passed"

# -----------------------------------------------------------------------------
step "Wait for WordPress to answer at http://${DOMAIN} (pinned to ${EIP_PUBLIC_IP})"
why "user-data installs everything on first boot (~3-5 min); Apache starts last, so an answer means the install finished"
deadline=$((SECONDS + HTTP_WAIT_SECONDS))
until wordpress_responds "http://${DOMAIN}/" "$EIP_PUBLIC_IP"; do
  (( SECONDS > deadline )) && die "WordPress did not answer within ${HTTP_WAIT_SECONDS} s (last HTTP code ${HTTP_CODE}). Check the log on the instance: sudo cat /var/log/wordpress-bootstrap.log"
  info "not ready yet (HTTP ${HTTP_CODE}), checking again in 15 s..."
  sleep 15
done
ok "WordPress answered with HTTP ${HTTP_CODE}"

# -----------------------------------------------------------------------------
step "Public DNS check: do visitors reach ${EIP_PUBLIC_IP}?"
why "Route 53 being correct is not enough - the domain registration must also delegate to it; we ask a public resolver what the internet sees"
DNS_PUBLIC=true
for name in "$DOMAIN" "$WWW_DOMAIN"; do
  if public_dns_ok "$name" "$EIP_PUBLIC_IP"; then ok "${name} -> ${EIP_PUBLIC_IP} (public DNS)"; else DNS_PUBLIC=false; fi
done
if [[ "$DNS_PUBLIC" == "true" ]]; then
  if wordpress_responds "http://${DOMAIN}/"; then ok "http://${DOMAIN} works through real DNS (HTTP ${HTTP_CODE})"
  else warn "public DNS is correct but this Mac still has an old DNS answer cached; try again in a minute"; fi
else
  explain_dns_failure
fi
state_set DNS_PUBLIC "$DNS_PUBLIC"

# -----------------------------------------------------------------------------
SITE_URL="http://${DOMAIN}"
if [[ "$ENABLE_HTTPS" == "true" ]]; then
  step "HTTPS with Let's Encrypt (--https)"
  why "encrypts traffic; certbot proves domain ownership over port 80, which is why DNS had to be ready first"
  [[ "$DNS_PUBLIC" == "true" ]] || die "Let's Encrypt can only validate the domain once public DNS works (see the warnings above). Re-run with --https after that; everything else is already deployed."
  wait_ssm_online "$INSTANCE_ID" 300
  run_remote_script "$INSTANCE_ID" "${SCRIPT_DIR}/remote/enable-https.sh" "${PROJECT}: enable HTTPS" 900 \
    "DOMAIN=${DOMAIN}" "WWW_DOMAIN=${WWW_DOMAIN}" "CERT_EMAIL=${WP_ADMIN_EMAIL}" \
    || die "Enabling HTTPS failed (see output above). The site is still available over HTTP."
  SITE_URL="https://${DOMAIN}"
  wordpress_responds "${SITE_URL}/" "$EIP_PUBLIC_IP" || die "HTTPS check failed (HTTP ${HTTP_CODE})."
  ok "HTTPS works (HTTP ${HTTP_CODE})"
fi
state_set SITE_URL "$SITE_URL"

# -----------------------------------------------------------------------------
printf '\n%s==> Deployment complete%s\n' "$C_GREEN" "$C_RESET"
info "Site:         ${SITE_URL}   (also ${SITE_URL/${DOMAIN}/${WWW_DOMAIN}})"
info "Admin:        ${SITE_URL}/wp-admin/   user: ${WP_ADMIN_USER}"
info "Admin pass:   aws ssm get-parameter --name ${WP_ADMIN_PW_PARAM} --with-decryption --query Parameter.Value --output text"
info "SSH:          ssh -i \"${KEY_FILE}\" ec2-user@${EIP_PUBLIC_IP}"
info "State file:   ${STATE_FILE}"
