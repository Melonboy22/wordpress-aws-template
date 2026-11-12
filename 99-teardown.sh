#!/usr/bin/env bash
# =============================================================================
# 99-teardown.sh
#
# Deletes EVERYTHING created by 01-deploy-wordpress.sh and 02-attach-rds.sh,
# so the account stops costing money. Asks for confirmation first.
#
# Order matters because of dependencies (AWS refuses to delete something that
# is still in use):
#   1. Route 53 A records  - first, so DNS never points at an IP we no longer
#                            own (a released IP can be given to someone else:
#                            "dangling DNS" / subdomain takeover)
#   2. RDS instance        - its network interface lives in db-sg
#   3. Elastic IP          - disassociate + release
#   4. EC2 instance        - its network interface lives in web-sg
#   5. Security groups     - db-sg first (its rule references web-sg), then web-sg
#   6. DB subnet group     - only deletable once the RDS instance is gone
#   7. Key pair            - in AWS and the local .pem
#   8. SSM parameters      - everything under /<PROJECT>/
#   9. IAM role + instance profile
#  10. local state.env
# The hosted zone itself is NOT deleted - it belongs to the domain.
#
# Usage:   ./99-teardown.sh
# Safe to re-run: anything already gone is skipped.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

has_project_tag() { # $1 = "Key=Value" list -> true if Project matches
  # `aws --output text` separates list items with TABs, so turn all whitespace
  # into single spaces before matching the whole word " Project=<name> ".
  local tags
  tags=" $(printf '%s' "$1" | tr -s '[:space:]' ' ') "
  [[ "$tags" == *" Project=${PROJECT} "* ]]
}

step "Pre-flight"
preflight
VPC_ID="$(default_vpc_id)"
HOSTED_ZONE_ID="$(lookup_hosted_zone)"

printf '\n%sThis permanently deletes all %s resources in account %s (%s):%s\n' "$C_RED" "$PROJECT" "$ACCOUNT_ID" "$AWS_REGION" "$C_RESET"
info "Route 53 A records for ${DOMAIN} / ${WWW_DOMAIN}, RDS ${DB_INSTANCE_ID} (no final snapshot),"
info "Elastic IP, EC2 instance, ${DB_SG_NAME} + ${WEB_SG_NAME}, DB subnet group, key pair, ${SSM_PREFIX}/* parameters, IAM role."
printf '\nType the project name (%s) to continue: ' "$PROJECT"
read -r answer
[[ "$answer" == "$PROJECT" ]] || die "Aborted - nothing was deleted."

# -----------------------------------------------------------------------------
step "Route 53 A records"
# Only delete a record if it points at OUR Elastic IP - never someone else's.
EIP_ALLOC_ID="$(aws_text ec2 describe-addresses --filters "Name=tag:Project,Values=${PROJECT}" --query 'Addresses[0].AllocationId')"
OUR_IP=""
[[ -n "$EIP_ALLOC_ID" ]] && OUR_IP="$(aws_text ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].PublicIp')"
OUR_IP="${OUR_IP:-$(state_get EIP_PUBLIC_IP)}"
if [[ -z "$HOSTED_ZONE_ID" ]]; then
  warn "hosted zone for ${DOMAIN} not found - skipping DNS"
else
  for name in "$DOMAIN" "$WWW_DOMAIN"; do
    # DELETE must quote the record exactly as it is, so fetch its current JSON.
    RRSET="$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${name}.' && Type=='A'] | [0]" --output json)"
    if [[ "$RRSET" == "null" ]]; then ok "no A record for ${name}"; continue; fi
    VALUE="$(aws_text route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${name}.' && Type=='A'] | [0].ResourceRecords[0].Value")"
    if [[ -n "$OUR_IP" && "$VALUE" == "$OUR_IP" ]]; then
      printf '{"Changes":[{"Action":"DELETE","ResourceRecordSet":%s}]}' "$RRSET" > "${TMP_DIR}/del.json"
      CHANGE_ID="$(aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
                     --change-batch "file://${TMP_DIR}/del.json" --query ChangeInfo.Id --output text)"
      aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"
      ok "deleted A record ${name} -> ${VALUE}"
    else
      warn "A record ${name} -> ${VALUE} does not point at our Elastic IP (${OUR_IP:-unknown}); left untouched"
    fi
  done
fi

# -----------------------------------------------------------------------------
step "RDS instance ${DB_INSTANCE_ID}"
DB_ARN="$(aws_text rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query 'DBInstances[0].DBInstanceArn' 2>/dev/null || true)"
if [[ -z "$DB_ARN" ]]; then
  ok "not found (already deleted)"
else
  DB_TAGS="$(aws_text rds list-tags-for-resource --resource-name "$DB_ARN" --query "TagList[].join('=', [Key, Value])")"
  has_project_tag "$DB_TAGS" || die "${DB_INSTANCE_ID} exists but is not tagged Project=${PROJECT}; refusing to delete it."
  DB_STATUS="$(aws_text rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query 'DBInstances[0].DBInstanceStatus')"
  if [[ "$DB_STATUS" != "deleting" ]]; then
    # --skip-final-snapshot: demo setup, no data to keep. In production you
    # would take a final snapshot instead.
    aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_ID" \
      --skip-final-snapshot --delete-automated-backups >/dev/null
    ok "deletion started"
  fi
  info "waiting for RDS deletion (usually 5-10 minutes)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID"
  ok "RDS instance deleted"
fi

# -----------------------------------------------------------------------------
step "Elastic IP"
if [[ -z "$EIP_ALLOC_ID" ]]; then
  ok "none found"
else
  ASSOC_ID="$(aws_text ec2 describe-addresses --allocation-ids "$EIP_ALLOC_ID" --query 'Addresses[0].AssociationId')"
  [[ -n "$ASSOC_ID" ]] && aws ec2 disassociate-address --association-id "$ASSOC_ID" && ok "disassociated"
  aws ec2 release-address --allocation-id "$EIP_ALLOC_ID"
  ok "released ${EIP_ALLOC_ID}"
fi

# -----------------------------------------------------------------------------
step "EC2 instance(s)"
INSTANCE_IDS="$(aws_text ec2 describe-instances --filters "Name=tag:Project,Values=${PROJECT}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --query 'Reservations[].Instances[].InstanceId')"
if [[ -z "$INSTANCE_IDS" ]]; then
  ok "none found"
else
  # shellcheck disable=SC2086  # intentional word splitting: one argument per instance ID
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS >/dev/null
  info "terminating ${INSTANCE_IDS}; waiting..."
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
  ok "terminated (the encrypted root volume is deleted with it)"
fi

# -----------------------------------------------------------------------------
step "Security groups (${DB_SG_NAME}, then ${WEB_SG_NAME})"
for sg_name in "$DB_SG_NAME" "$WEB_SG_NAME"; do
  [[ -n "$VPC_ID" ]] || break
  SG_ID="$(find_sg_id "$sg_name" "$VPC_ID")"
  if [[ -z "$SG_ID" ]]; then ok "${sg_name}: not found"; continue; fi
  SG_TAGS="$(aws_text ec2 describe-security-groups --group-ids "$SG_ID" --query "SecurityGroups[0].Tags[].join('=', [Key, Value])")"
  if ! has_project_tag "$SG_TAGS"; then warn "${sg_name} (${SG_ID}) is not tagged Project=${PROJECT}; left untouched"; continue; fi
  # Network interfaces of deleted RDS/EC2 can take a minute to disappear, and
  # until then AWS answers DependencyViolation -> retry for up to 5 minutes.
  for attempt in $(seq 1 30); do
    if aws ec2 delete-security-group --group-id "$SG_ID" >/dev/null 2>"${TMP_DIR}/sg.err"; then
      ok "deleted ${sg_name} (${SG_ID})"; break
    fi
    grep -q DependencyViolation "${TMP_DIR}/sg.err" || die "$(cat "${TMP_DIR}/sg.err")"
    (( attempt == 30 )) && die "${sg_name} still in use after 5 minutes: $(cat "${TMP_DIR}/sg.err")"
    info "${sg_name} still in use (ENIs detaching), retrying in 10 s..."; sleep 10
  done
done

# -----------------------------------------------------------------------------
step "DB subnet group ${DB_SUBNET_GROUP}"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP"
  ok "deleted"
else
  ok "not found"
fi

# -----------------------------------------------------------------------------
step "Key pair ${KEY_NAME}"
if aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null
  ok "deleted in AWS"
else
  ok "not found in AWS"
fi
if [[ -f "$KEY_FILE" ]]; then rm -f "$KEY_FILE"; ok "removed local ${KEY_FILE}"; fi

# -----------------------------------------------------------------------------
step "SSM parameters under ${SSM_PREFIX}/"
PARAMS="$(aws_text ssm get-parameters-by-path --path "$SSM_PREFIX" --recursive --query 'Parameters[].Name')"
if [[ -z "$PARAMS" ]]; then
  ok "none found"
else
  # delete-parameters accepts at most 10 names per call.
  # shellcheck disable=SC2086
  printf '%s\n' $PARAMS | xargs -n 10 aws ssm delete-parameters --query 'DeletedParameters' --output text --names \
    | tr '\t' '\n' | sed 's/^/    [ok] deleted /'
fi

# -----------------------------------------------------------------------------
step "IAM role ${ROLE_NAME} + instance profile ${INSTANCE_PROFILE_NAME}"
if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  for role in $(aws_text iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --query 'InstanceProfile.Roles[].RoleName'); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$role"
  done
  aws iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME"
  ok "deleted instance profile"
fi
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  # A role can only be deleted once no policies are attached to it.
  for arn in $(aws_text iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyArn'); do
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$arn"
  done
  for pol in $(aws_text iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames'); do
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$pol"
  done
  aws iam delete-role --role-name "$ROLE_NAME"
  ok "deleted role"
else
  ok "role not found"
fi

# -----------------------------------------------------------------------------
step "Local state file"
rm -f "$STATE_FILE"
ok "removed ${STATE_FILE}"

# Final check: anything still tagged with our project? (Terminated instances
# and just-deleted resources can linger in this API for a while - that's normal.)
LEFT="$(aws_text resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=${PROJECT}" \
          --query 'ResourceTagMappingList[].ResourceARN' || true)"
printf '\n%s==> Teardown complete%s\n' "$C_GREEN" "$C_RESET"
[[ -n "$LEFT" ]] && info "Still listed by the tagging API (may just be propagation delay): ${LEFT}"
info "The Route 53 hosted zone ${HOSTED_ZONE_ID:-?} was kept (it belongs to the domain)."
