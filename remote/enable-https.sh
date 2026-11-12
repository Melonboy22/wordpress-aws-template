#!/bin/bash
# =============================================================================
# remote/enable-https.sh - runs ON the EC2 instance (as root) via SSM Run Command
# when 01-deploy-wordpress.sh is called with --https.
#
# Gets a free Let's Encrypt certificate for both names with certbot, lets
# certbot configure Apache (port 443 + redirect 80 -> 443), switches WordPress
# URLs to https:// and schedules automatic renewal (certs live 90 days).
# Prerequisite: DNS for both names already points at this instance, because
# Let's Encrypt verifies ownership by fetching a file over plain HTTP (port 80).
# =============================================================================
set -euo pipefail
: "${DOMAIN:?}" "${WWW_DOMAIN:?}" "${CERT_EMAIL:?}"
WP_DIR=/var/www/html
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
wp_cli() { runuser -u apache -- env HOME=/tmp /usr/local/bin/wp --path="$WP_DIR" "$@"; }

log "1/4 Install mod_ssl and certbot"
# Amazon Linux 2023 has no certbot package, so we use the method recommended by
# the certbot project: an isolated Python virtual environment in /opt/certbot.
dnf install -y mod_ssl python3 augeas-libs
if [[ ! -x /opt/certbot/bin/certbot ]]; then
  python3 -m venv /opt/certbot
  /opt/certbot/bin/pip install --quiet --upgrade pip
  /opt/certbot/bin/pip install --quiet certbot certbot-apache
fi
ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot

log "2/4 Request the certificate and configure Apache"
# --redirect: plain-HTTP visitors are sent to HTTPS.
# --keep-until-expiring: re-running does not request a new cert needlessly
# (Let's Encrypt has rate limits).
/opt/certbot/bin/certbot --apache --non-interactive --agree-tos -m "$CERT_EMAIL" \
  -d "$DOMAIN" -d "$WWW_DOMAIN" --redirect --keep-until-expiring

log "3/4 Switch WordPress URLs to https://"
wp_cli option update home "https://${DOMAIN}"
wp_cli option update siteurl "https://${DOMAIN}"

log "4/4 Schedule automatic renewal (systemd timer, twice a day)"
cat > /etc/systemd/system/certbot-renew.service <<'EOF'
[Unit]
Description=Renew Let's Encrypt certificates
[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --quiet --deploy-hook "systemctl reload httpd"
EOF
cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Twice-daily certbot renewal check
[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now certbot-renew.timer
log "HTTPS enabled for ${DOMAIN} and ${WWW_DOMAIN}"
