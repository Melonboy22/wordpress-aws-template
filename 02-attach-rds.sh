#!/usr/bin/env bash
# =============================================================================
# 02-attach-rds.sh
#
# Moves the WordPress database from the EC2 instance's local MariaDB to a
# managed Amazon RDS for MySQL instance - ON TOP OF the deployment made by
# 01-deploy-wordpress.sh (the instance is found by its tags, never recreated).
#
#   EC2 (web-sg) --3306--> RDS MySQL (db-sg, private, not publicly accessible)
#
# Usage:   ./02-attach-rds.sh
# IDEMPOTENT: re-running reuses the SG, subnet group, secrets and RDS instance,
# and the remote step detects an already-finished migration and only verifies.
# Your values (domain, email, region) go in config.env; derived names are in lib/common.sh.
# =============================================================================
set -euo pipefail

# ================================ CONFIG =====================================
DB_ENGINE="mysql"
DB_ENGINE_MAJOR="8.4"           # 8.4 = current LTS; 8.0 is in paid Extended Support
DB_INSTANCE_CLASS="db.t3.micro" # Free Tier eligible
DB_STORAGE_GB=20                # Free Tier: 20 GB
DB_STORAGE_TYPE="gp3"
DB_BACKUP_RETENTION_DAYS=1      # keep automated backups 1 day (demo setting; raise for production)
DB_NAME="wordpress"
DB_MASTER_USER="dbadmin"        # RDS admin account (used only for setup/import)
DB_APP_USER="wp_app"            # what WordPress uses: rights on its own DB only
MIGRATION_TIMEOUT=900           # seconds allowed for the remote migration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
[[ $# -eq 0 ]] || { sed -n '2,16p' "$0"; exit 0; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# -----------------------------------------------------------------------------
step "Pre-flight: credentials and the existing WordPress instance"
why "this script builds on script 1, so it must find that instance first"
preflight
INSTANCE_ID="$(find_instance_id)"
[[ -n "$INSTANCE_ID" ]] || die "No instance tagged Project=${PROJECT}, Name=${INSTANCE_NAME}. Run ./01-deploy-wordpress.sh first."
read -r STATE VPC_ID INSTANCE_AZ <<< "$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].[State.Name,VpcId,Placement.AvailabilityZone]' --output text)"
[[ "$STATE" == "running" ]] || die "Instance ${INSTANCE_ID} is '${STATE}', it must be running."
ok "found instance ${INSTANCE_ID} (${INSTANCE_AZ}, ${VPC_ID})"
WEB_SG_ID="$(find_sg_id "$WEB_SG_NAME" "$VPC_ID")"
[[ -n "$WEB_SG_ID" ]] || die "Security group ${WEB_SG_NAME} not found - run ./01-deploy-wordpress.sh first."
ok "web tier security group: ${WEB_SG_ID}"
why "Run Command needs the SSM Agent on the instance to be registered and Online"
wait_ssm_online "$INSTANCE_ID" 300

# -----------------------------------------------------------------------------
step "Security group ${DB_SG_NAME} (the database's firewall)"
why "MySQL (3306) is allowed ONLY from members of web-sg - a security-group reference, not an IP range - so only our web server can connect, even if its IP changes"
DB_SG_ID="$(find_sg_id "$DB_SG_NAME" "$VPC_ID")"
if [[ -z "$DB_SG_ID" ]]; then
  DB_SG_ID="$(aws ec2 create-security-group --group-name "$DB_SG_NAME" --vpc-id "$VPC_ID" \
    --description "${PROJECT} DB tier: MySQL only from web-sg" \
    --tag-specifications "$(tag_spec security-group "$DB_SG_NAME")" \
    --query GroupId --output text)"
  ok "created ${DB_SG_NAME}: ${DB_SG_ID}"
else
  ok "reusing ${DB_SG_NAME}: ${DB_SG_ID}"
fi
sg_allow_sg "$DB_SG_ID" 3306 "$WEB_SG_ID" "MySQL from web-sg only"
state_set DB_SG_ID "$DB_SG_ID"

# -----------------------------------------------------------------------------
step "DB subnet group ${DB_SUBNET_GROUP}"
why "RDS must know which subnets it may place the database in; AWS requires subnets in at least 2 Availability Zones (so a standby could be added later)"
read -r -a SUBNET_IDS <<< "$(aws_text ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" --query 'Subnets[].SubnetId')"
AZ_COUNT="$(aws_text ec2 describe-subnets --subnet-ids "${SUBNET_IDS[@]}" --query 'length(Subnets[].AvailabilityZone)')"
[[ "${AZ_COUNT:-0}" -ge 2 ]] || die "Need default subnets in at least 2 AZs, found ${AZ_COUNT:-0}."
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP" >/dev/null 2>&1; then
  ok "reusing ${DB_SUBNET_GROUP}"
else
  aws rds create-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --db-subnet-group-description "${PROJECT}: default VPC subnets" \
    --subnet-ids "${SUBNET_IDS[@]}" \
    --tags "Key=Project,Value=${PROJECT}" "Key=Name,Value=${DB_SUBNET_GROUP}" >/dev/null
  ok "created ${DB_SUBNET_GROUP} with ${#SUBNET_IDS[@]} subnets in ${AZ_COUNT} AZs"
fi
state_set DB_SUBNET_GROUP "$DB_SUBNET_GROUP"

# -----------------------------------------------------------------------------
step "Database credentials in SSM Parameter Store (${SSM_DB_PREFIX}/*)"
why "passwords are random, stored encrypted (SecureString), and read by the instance at run time - they never appear in the scripts, the terminal or git"
put_plain_param "${SSM_DB_PREFIX}/name" "$DB_NAME" "${PROJECT} database name"
put_plain_param "${SSM_DB_PREFIX}/master-username" "$DB_MASTER_USER" "${PROJECT} RDS master username" SecureString
put_plain_param "${SSM_DB_PREFIX}/app-username" "$DB_APP_USER" "${PROJECT} DB username" SecureString
ensure_random_secret "${SSM_DB_PREFIX}/master-password" "${PROJECT} RDS master password"
MASTER_PW_IS_NEW="$SECRET_CREATED"
ensure_random_secret "${SSM_DB_PREFIX}/app-password" "${PROJECT} DB user password"
ok "credentials stored (values not shown)"

# The master password must be handed to RDS once. We pass it in a private temp
# JSON file (--cli-input-json), never as a command-line argument.
master_pw_json() {
  local f="${TMP_DIR}/master-pw.json"
  ( umask 077
    printf '{"MasterUserPassword":"%s"}' \
      "$(aws ssm get-parameter --name "${SSM_DB_PREFIX}/master-password" --with-decryption --query Parameter.Value --output text)" > "$f" )
  printf '%s' "$f"
}

# -----------------------------------------------------------------------------
step "RDS for MySQL instance ${DB_INSTANCE_ID}"
why "a managed database: AWS handles backups, patching and storage; it is private (no public IP) and only reachable from web-sg"
DB_STATUS="$(aws_text rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
               --query 'DBInstances[0].DBInstanceStatus' 2>/dev/null || true)"
if [[ -z "$DB_STATUS" ]]; then
  ENGINE_VERSION="$(aws_text rds describe-db-engine-versions --engine "$DB_ENGINE" --engine-version "$DB_ENGINE_MAJOR" \
                      --default-only --query 'DBEngineVersions[0].EngineVersion')"
  [[ -n "$ENGINE_VERSION" ]] || die "Could not find a default MySQL ${DB_ENGINE_MAJOR}.x version."
  info "engine: MySQL ${ENGINE_VERSION}, class ${DB_INSTANCE_CLASS}, ${DB_STORAGE_GB} GB ${DB_STORAGE_TYPE}, AZ ${INSTANCE_AZ}"
  PW_FILE="$(master_pw_json)"
  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --engine "$DB_ENGINE" --engine-version "$ENGINE_VERSION" \
    --db-instance-class "$DB_INSTANCE_CLASS" \
    --allocated-storage "$DB_STORAGE_GB" --storage-type "$DB_STORAGE_TYPE" --storage-encrypted \
    --db-name "$DB_NAME" --master-username "$DB_MASTER_USER" --cli-input-json "file://${PW_FILE}" \
    --vpc-security-group-ids "$DB_SG_ID" --db-subnet-group-name "$DB_SUBNET_GROUP" \
    --availability-zone "$INSTANCE_AZ" \
    --no-multi-az --no-publicly-accessible \
    --backup-retention-period "$DB_BACKUP_RETENTION_DAYS" \
    --no-deletion-protection --copy-tags-to-snapshot \
    --tags "Key=Project,Value=${PROJECT}" "Key=Name,Value=${DB_INSTANCE_ID}" >/dev/null
  rm -f "$PW_FILE"
  # Flags explained:
  #   --no-publicly-accessible  -> no public IP; reachable only inside the VPC
  #   --no-multi-az             -> single AZ (Free Tier); production would use Multi-AZ
  #   --availability-zone       -> same AZ as the web server: lower latency and
  #                                no cross-AZ data-transfer charges
  #   --storage-encrypted       -> encryption at rest with the AWS-managed KMS key
  #   --no-deletion-protection  -> lets 99-teardown.sh delete it (demo setting; raise for production)
  ok "creation started"
else
  ok "reusing ${DB_INSTANCE_ID} (status: ${DB_STATUS})"
  [[ "$DB_STATUS" == "deleting" ]] && die "The DB instance is being deleted; wait for that to finish, then re-run."
  if [[ "$MASTER_PW_IS_NEW" == "true" ]]; then
    # Parameter was missing but the DB exists: set RDS to the new stored password
    # so the two can never disagree.
    PW_FILE="$(master_pw_json)"
    aws rds modify-db-instance --db-instance-identifier "$DB_INSTANCE_ID" \
      --cli-input-json "file://${PW_FILE}" --apply-immediately >/dev/null
    rm -f "$PW_FILE"
    warn "master password parameter was re-created; RDS master password reset to match"
    sleep 30   # the modification takes a moment to start
  fi
fi
info "waiting for RDS to become 'available' (a new instance takes ~5-10 minutes)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"
DB_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
                 --query 'DBInstances[0].Endpoint.Address' --output text)"
ok "RDS available at ${DB_ENDPOINT}:3306"
PUBLIC="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --query 'DBInstances[0].PubliclyAccessible' --output text)"
info "PubliclyAccessible=${PUBLIC}"
put_plain_param "${SSM_DB_PREFIX}/endpoint" "$DB_ENDPOINT" "${PROJECT} RDS endpoint"
state_set DB_INSTANCE_ID "$DB_INSTANCE_ID"
state_set DB_ENDPOINT "$DB_ENDPOINT"

# -----------------------------------------------------------------------------
step "Migrate the WordPress database to RDS (SSM Run Command on ${INSTANCE_ID})"
why "Run Command executes the steps on the server without SSH or open ports; every run is logged in Systems Manager"
info "remote steps: backup wp-config -> mysqldump -> import into RDS -> update wp-config -> stop MariaDB -> restart Apache -> verify"
if ! run_remote_script "$INSTANCE_ID" "${SCRIPT_DIR}/remote/migrate-to-rds.sh" "${PROJECT}: migrate WordPress DB to RDS" \
       "$MIGRATION_TIMEOUT" \
       "REGION=${AWS_REGION}" "DOMAIN=${DOMAIN}" "DB_ENDPOINT=${DB_ENDPOINT}" "SSM_DB_PREFIX=${SSM_DB_PREFIX}"; then
  die "Migration failed (status ${REMOTE_STATUS}). The remote script restored wp-config.php and restarted MariaDB, so the site still runs on the local DB. See the output above."
fi
ok "remote migration finished successfully"

# -----------------------------------------------------------------------------
step "Verify from the internet: the site still loads"
why "the request goes from this Mac over the internet to the Elastic IP (pinned with --resolve, so it does not depend on DNS caches)"
SITE_URL="$(state_get SITE_URL)"; SITE_URL="${SITE_URL:-http://${DOMAIN}}"
PUBLIC_IP="$(aws_text ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress')"
for _ in 1 2 3 4 5 6; do
  wordpress_responds "${SITE_URL}/" "$PUBLIC_IP" && break
  sleep 10
done
if wordpress_responds "${SITE_URL}/" "$PUBLIC_IP"; then
  ok "${SITE_URL} (${PUBLIC_IP}) answers HTTP ${HTTP_CODE} - now served from RDS"
  if public_dns_ok "$DOMAIN" "$PUBLIC_IP"; then ok "public DNS for ${DOMAIN} -> ${PUBLIC_IP}"; else explain_dns_failure; fi
else
  warn "${SITE_URL} answers HTTP ${HTTP_CODE} - rolling back to the local database"
  run_remote_script "$INSTANCE_ID" "${SCRIPT_DIR}/remote/rollback-to-local-db.sh" "${PROJECT}: rollback to local DB" 300 || true
  die "Site check failed after the migration; rolled back to the local MariaDB."
fi

printf '\n%s==> RDS attached%s\n' "$C_GREEN" "$C_RESET"
info "Site:          ${SITE_URL}"
info "DB endpoint:   ${DB_ENDPOINT} (private; only reachable from ${WEB_SG_NAME})"
info "Credentials:   SSM Parameter Store ${SSM_DB_PREFIX}/* (SecureString)"
info "Backup on EC2: /root/wp-config.php.before-rds  (dump: /root/wordpress-local-dump.sql)"
