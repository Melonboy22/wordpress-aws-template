#!/bin/bash
# =============================================================================
# remote/rollback-to-local-db.sh - runs ON the EC2 instance via SSM Run Command.
# Used by 02-attach-rds.sh if the site check from the INTERNET fails after the
# migration script itself reported success. Puts back the original
# wp-config.php and restarts the local MariaDB, so the site is up again.
# =============================================================================
set -euo pipefail
BACKUP=/root/wp-config.php.before-rds
WP_CONFIG=/var/www/html/wp-config.php
[[ -f "$BACKUP" ]] || { echo "No backup at ${BACKUP} - nothing to roll back."; exit 1; }
cp -p "$BACKUP" "$WP_CONFIG"
systemctl enable --now mariadb
systemctl restart php-fpm httpd
echo "Rolled back: wp-config.php restored from ${BACKUP}, MariaDB running again."
