#!/bin/bash
# =============================================================================
# remote/wordpress-user-data.sh - EC2 USER-DATA (first-boot bootstrap)
#
# 01-deploy-wordpress.sh replaces the __PLACEHOLDERS__ below and passes this
# file as user-data. cloud-init runs it ONCE, as root, on the very first boot.
# Log on the instance: /var/log/wordpress-bootstrap.log
#
# SECURITY NOTE: user-data is NOT secret - anyone with ec2:DescribeInstanceAttribute
# can read it back. So this file contains no passwords:
#   * the local DB password is generated here, on the instance;
#   * the WordPress admin password is read from SSM Parameter Store (SecureString)
#     using the instance's IAM role.
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/wordpress-bootstrap.log) 2>&1

# ---- values injected by 01-deploy-wordpress.sh ----
REGION="__REGION__"
DOMAIN="__DOMAIN__"
WWW_DOMAIN="__WWW_DOMAIN__"
WP_TITLE="__WP_TITLE__"
WP_ADMIN_USER="__WP_ADMIN_USER__"
WP_ADMIN_EMAIL="__WP_ADMIN_EMAIL__"
WP_ADMIN_PW_PARAM="__WP_ADMIN_PW_PARAM__"
# ---------------------------------------------------
WP_DIR=/var/www/html
DB_NAME=wordpress
DB_USER=wpuser

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
# Run WP-CLI as the apache user, so files it touches stay owned by the web server.
wp_cli() { runuser -u apache -- env HOME=/tmp /usr/local/bin/wp --path="$WP_DIR" "$@"; }

log "1/9 Add a 1 GiB swap file"
# why: t3.micro has only 1 GiB RAM. Apache + PHP-FPM + MariaDB (+ dnf during
# installs) can exceed it, and the kernel would then kill MariaDB (OOM killer).
if [[ ! -f /swapfile ]]; then
  dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

log "2/9 Install Apache, PHP (with mysqlnd driver) and MariaDB"
# why: WordPress is PHP; php-mysqlnd is the driver PHP uses to talk to MySQL/MariaDB.
dnf install -y httpd php php-cli php-fpm php-mysqlnd php-gd php-mbstring php-xml php-opcache
# Newer AL2023 releases ship MariaDB 10.11; fall back to 10.5 on older images.
dnf install -y mariadb1011-server || dnf install -y mariadb105-server

log "3/9 Start MariaDB (localhost only) and create the WordPress database + user"
# why bind to 127.0.0.1: the database must never be reachable from the network,
# even if someone opens port 3306 in the security group by mistake (defense in depth).
printf '[mysqld]\nbind-address=127.0.0.1\n' > /etc/my.cnf.d/zz-local-only.cnf
systemctl enable --now mariadb
DB_PASS="$(openssl rand -hex 20)"     # random, generated here, never leaves the instance
mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

log "4/9 Download the latest WordPress"
curl -fsSL https://wordpress.org/latest.tar.gz -o /tmp/wordpress.tar.gz
tar -xzf /tmp/wordpress.tar.gz -C /tmp
cp -a /tmp/wordpress/. "$WP_DIR"/
rm -rf /tmp/wordpress /tmp/wordpress.tar.gz

log "5/9 Write wp-config.php with fresh secret keys/salts"
# why: the salts sign WordPress login cookies. Every site must have its own
# unique, random values - the sample file only contains placeholders.
SALTS_FILE="$(mktemp)"
curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/ -o "$SALTS_FILE"
[[ "$(grep -c "define(" "$SALTS_FILE")" -eq 8 ]] || { log "salt download looks wrong"; exit 1; }
# Replace the 8 placeholder salt lines with the downloaded ones (awk: print the
# salts file once at the first placeholder, skip the other placeholder lines).
awk -v salts="$SALTS_FILE" '
  /put your unique phrase here/ { if (!done) { while ((getline line < salts) > 0) print line; done = 1 }; next }
  { print }' "$WP_DIR/wp-config-sample.php" > "$WP_DIR/wp-config.php"
rm -f "$SALTS_FILE"
sed -i -e "s/database_name_here/${DB_NAME}/" -e "s/username_here/${DB_USER}/" \
       -e "s/password_here/${DB_PASS}/" "$WP_DIR/wp-config.php"
# FS_METHOD=direct lets WordPress install plugins/updates without asking for FTP credentials.
sed -i "/That's all, stop editing/i define( 'FS_METHOD', 'direct' );" "$WP_DIR/wp-config.php"
unset DB_PASS

log "6/9 Set ownership and permissions"
# why: Apache/PHP run as user 'apache' and must own the files to handle uploads
# and updates; directories 755 / files 644 is the standard WordPress hardening.
# wp-config.php holds the DB password, so 640 = not world-readable.
chown -R apache:apache "$WP_DIR"
find "$WP_DIR" -type d -exec chmod 755 {} +
find "$WP_DIR" -type f -exec chmod 644 {} +
chmod 640 "$WP_DIR/wp-config.php"

log "7/9 Apache virtual host for ${DOMAIN}"
# why: a named VirtualHost lets Apache answer for both names, enables .htaccess
# (AllowOverride All) for WordPress permalinks, and gives certbot (--https) a
# vhost to attach the certificate to.
cat > /etc/httpd/conf.d/wordpress.conf <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias ${WWW_DOMAIN}
    DocumentRoot ${WP_DIR}
    <Directory "${WP_DIR}">
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

log "8/9 Install WP-CLI and run the WordPress installer"
# why: without this, WordPress stops at its browser setup wizard and has NO
# tables yet - script 2 would then migrate an empty database.
curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod 755 /usr/local/bin/wp
if ! wp_cli core is-installed 2>/dev/null; then
  # The IAM role's credentials can take a few seconds to appear after boot: retry.
  ADMIN_PW=""
  for _ in 1 2 3 4 5 6; do
    ADMIN_PW="$(aws ssm get-parameter --region "$REGION" --name "$WP_ADMIN_PW_PARAM" \
                  --with-decryption --query Parameter.Value --output text 2>/dev/null)" && break
    sleep 10
  done
  [[ -n "$ADMIN_PW" ]] || { log "could not read $WP_ADMIN_PW_PARAM from Parameter Store"; exit 1; }
  # Install with a random throw-away password, then set the real one through an
  # ENVIRONMENT variable read inside PHP. Why: command-line arguments are visible
  # in `ps`, and WP-CLI's --prompt option echoes the full command (password
  # included) into this log - so the real password must never be an argument.
  wp_cli core install --url="http://${DOMAIN}" --title="$WP_TITLE" --admin_user="$WP_ADMIN_USER" \
    --admin_email="$WP_ADMIN_EMAIL" --admin_password="$(openssl rand -hex 32)" --skip-email
  # shellcheck disable=SC2016  # PHP code, not shell
  WP_NEW_PW="$ADMIN_PW" wp_cli eval 'wp_set_password(getenv("WP_NEW_PW"), get_user_by("login", "'"$WP_ADMIN_USER"'")->ID); echo "admin password set from Parameter Store\n";'
  unset ADMIN_PW
fi

log "9/9 Enable and start PHP-FPM and Apache"
# Started LAST on purpose: the moment the site answers HTTP 200, it is fully
# installed - which is exactly what 01-deploy-wordpress.sh polls for.
systemctl enable --now php-fpm
systemctl enable --now httpd
touch /var/lib/wordpress-bootstrap.done
log "Bootstrap complete"
