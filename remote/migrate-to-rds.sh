#!/bin/bash
# =============================================================================
# remote/migrate-to-rds.sh - runs ON the EC2 instance (as root) through SSM
# Run Command, sent by 02-attach-rds.sh.
#
# Moves the WordPress database from the local MariaDB to Amazon RDS:
#   1. back up wp-config.php            4. point wp-config.php at RDS
#   2. mysqldump the local database     5. stop + disable local MariaDB
#   3. import the dump into RDS         6. restart Apache / PHP-FPM
# then verifies by querying RDS directly.
#
# SAFETY: if ANY step fails before the migration is complete, the EXIT trap
# restores the wp-config.php backup and restarts MariaDB, so the site keeps
# running on the local database.
#
# Inputs (exported by 02-attach-rds.sh; none of them are secret):
#   REGION, DOMAIN, DB_ENDPOINT, SSM_DB_PREFIX
# Secrets are read here from SSM Parameter Store with the instance's IAM role.
# =============================================================================
set -euo pipefail
: "${REGION:?}" "${DOMAIN:?}" "${DB_ENDPOINT:?}" "${SSM_DB_PREFIX:?}"

WP_DIR=/var/www/html
WP_CONFIG="${WP_DIR}/wp-config.php"
BACKUP=/root/wp-config.php.before-rds
DUMP=/root/wordpress-local-dump.sql
CA_BUNDLE=/etc/pki/rds/global-bundle.pem
MASTER_CNF=/root/.rds-master.cnf     # mysql client option files (mode 600):
APP_CNF=/root/.rds-app.cnf           # keep passwords off the command line

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
wp_cli() { runuser -u apache -- env HOME=/tmp /usr/local/bin/wp --path="$WP_DIR" "$@"; }
getp() { aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption --query Parameter.Value --output text; }

ROLLBACK_ARMED=false   # becomes true once we start changing things
SUCCESS=false
on_exit() {
  local rc=$?
  rm -f "$MASTER_CNF" "$APP_CNF"
  if [[ "$SUCCESS" != "true" && "$ROLLBACK_ARMED" == "true" ]]; then
    log "!! migration failed (exit ${rc}) - ROLLING BACK to the local MariaDB database"
    [[ -f "$BACKUP" ]] && cp -p "$BACKUP" "$WP_CONFIG" && log "restored wp-config.php from ${BACKUP}"
    systemctl enable --now mariadb || true
    systemctl restart php-fpm httpd || true
    log "ROLLBACK COMPLETE - the site runs on the local database again"
  fi
  exit "$rc"
}
trap on_exit EXIT

log "0/6 Read DB settings from Parameter Store and prepare TLS"
DB_NAME="$(getp "${SSM_DB_PREFIX}/name")"
MASTER_USER="$(getp "${SSM_DB_PREFIX}/master-username")"
MASTER_PW="$(getp "${SSM_DB_PREFIX}/master-password")"
APP_USER="$(getp "${SSM_DB_PREFIX}/app-username")"
APP_PW="$(getp "${SSM_DB_PREFIX}/app-password")"
# why TLS: traffic between EC2 and RDS should be encrypted even inside the VPC.
# The RDS certificate is signed by Amazon's RDS CA, so we download that CA and
# add it to the system trust store - then both the mysql client and PHP can
# VERIFY they are really talking to RDS.
mkdir -p "$(dirname "$CA_BUNDLE")"
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o "$CA_BUNDLE"
cp "$CA_BUNDLE" /etc/pki/ca-trust/source/anchors/rds-global-bundle.pem
update-ca-trust extract
write_cnf() { # $1 file, $2 user, $3 password
  ( umask 077
    printf '[client]\nhost=%s\nuser=%s\npassword=%s\nssl-ca=%s\nssl-verify-server-cert\n' \
      "$DB_ENDPOINT" "$2" "$3" "$CA_BUNDLE" > "$1" )
}
write_cnf "$MASTER_CNF" "$MASTER_USER" "$MASTER_PW"
write_cnf "$APP_CNF" "$APP_USER" "$APP_PW"
unset MASTER_PW
mysql --defaults-extra-file="$MASTER_CNF" -e "SELECT 1" >/dev/null
log "RDS is reachable from this instance over TLS (db-sg allows web-sg on 3306)"

CURRENT_HOST="$(wp_cli config get DB_HOST)"
if [[ "$CURRENT_HOST" == "$DB_ENDPOINT" ]]; then
  log "wp-config.php already points at RDS - migration was done earlier, only verifying"
else
  log "1/6 Back up wp-config.php -> ${BACKUP}"
  # Never overwrite an existing backup: it is the known-good LOCAL config.
  [[ -f "$BACKUP" ]] || cp -p "$WP_CONFIG" "$BACKUP"
  ROLLBACK_ARMED=true

  log "2/6 Dump the local WordPress database"
  systemctl start mariadb
  LOCAL_DB="$(wp_cli config get DB_NAME)"
  # --single-transaction: consistent snapshot without locking the live site.
  # --no-tablespaces: avoids needing the PROCESS privilege.
  mysqldump --single-transaction --default-character-set=utf8mb4 --no-tablespaces \
            --routines --triggers "$LOCAL_DB" > "$DUMP"
  chmod 600 "$DUMP"
  # Newer MariaDB dumps start with a MariaDB-only "sandbox mode" line; drop it
  # so the dump is plain SQL that MySQL also understands.
  sed -i '1{/enable the sandbox mode/d}' "$DUMP"
  LOCAL_TABLES="$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${LOCAL_DB}'")"
  log "dumped ${LOCAL_TABLES} tables ($(du -h "$DUMP" | cut -f1)) from local database '${LOCAL_DB}'"

  log "3/6 Prepare RDS: database + least-privilege WordPress user"
  # WordPress gets its OWN user with rights on ITS database only - not the
  # RDS master user. REQUIRE SSL makes RDS refuse unencrypted logins for it.
  # SQL is sent on stdin, so the password is not visible in the process list.
  mysql --defaults-extra-file="$MASTER_CNF" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${APP_USER}'@'%' IDENTIFIED BY '${APP_PW}' REQUIRE SSL;
ALTER USER '${APP_USER}'@'%' IDENTIFIED BY '${APP_PW}' REQUIRE SSL;
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${APP_USER}'@'%';
SQL

  log "4/6 Import the dump into RDS"
  mysql --defaults-extra-file="$MASTER_CNF" "$DB_NAME" < "$DUMP"
  RDS_TABLES="$(mysql --defaults-extra-file="$MASTER_CNF" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
  log "RDS database '${DB_NAME}' now has ${RDS_TABLES} tables"
  [[ "$RDS_TABLES" -ge "$LOCAL_TABLES" ]] || { log "table count mismatch (local ${LOCAL_TABLES}, RDS ${RDS_TABLES})"; exit 1; }

  log "5/6 Point wp-config.php at RDS"
  wp_cli config set DB_HOST "$DB_ENDPOINT" --quiet
  wp_cli config set DB_NAME "$DB_NAME" --quiet
  wp_cli config set DB_USER "$APP_USER" --quiet
  wp_cli config set DB_PASSWORD "$APP_PW" --quiet
  # Tell PHP's MySQL driver to use TLS (required by REQUIRE SSL above).
  wp_cli config set MYSQL_CLIENT_FLAGS MYSQLI_CLIENT_SSL --raw --type=constant --quiet
  # Prove PHP -> RDS works BEFORE we turn the local database off.
  # shellcheck disable=SC2016  # $wpdb etc. are PHP variables, not shell
  PHP_CHECK="$(wp_cli eval 'global $wpdb; $s = $wpdb->get_row("SHOW SESSION STATUS LIKE \"Ssl_version\""); echo "php->rds ok, tls=", ($s ? $s->Value : "none"), ", wp_tables=", count($wpdb->get_col("SHOW TABLES LIKE \"wp\\_%\""));')"
  log "$PHP_CHECK"

  log "6/6 Stop + disable local MariaDB, restart PHP-FPM and Apache"
  # why disable: the local DB is no longer the source of truth; if it kept
  # running (or started on reboot) it would waste the t3.micro's 1 GiB RAM.
  systemctl disable --now mariadb
  systemctl restart php-fpm httpd
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN}" http://127.0.0.1/ || true)"
  [[ "$CODE" =~ ^(200|301|302)$ ]] || { log "local HTTP check after the switch failed (HTTP ${CODE})"; exit 1; }
  log "site answers HTTP ${CODE} on the instance with MariaDB stopped"
fi

log "VERIFY: query RDS directly as the WordPress app user"
mysql --defaults-extra-file="$APP_CNF" --table "$DB_NAME" -e "
  SELECT @@hostname AS rds_server, @@version AS mysql_version,
         (SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME='Ssl_version') AS connection_tls;
  SHOW TABLES LIKE 'wp\\_%';
  SELECT (SELECT COUNT(*) FROM wp_users) AS users, (SELECT COUNT(*) FROM wp_posts) AS posts,
         (SELECT COUNT(*) FROM wp_options) AS options;
  SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home','blogname');"
WP_TABLES="$(mysql --defaults-extra-file="$APP_CNF" -N "$DB_NAME" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND TABLE_NAME LIKE 'wp\\_%'")"
# A standard single-site WordPress has 12 core tables.
[[ "$WP_TABLES" -ge 12 ]] || { log "expected at least 12 wp_ tables on RDS, found ${WP_TABLES}"; exit 1; }
log "MariaDB service: $(systemctl is-active mariadb || true) / $(systemctl is-enabled mariadb 2>/dev/null || true)"
SUCCESS=true
log "MIGRATION OK: ${WP_TABLES} wp_ tables on RDS, wp-config.php -> ${DB_ENDPOINT}"
