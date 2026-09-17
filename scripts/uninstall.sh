#!/bin/bash
# Removes the SkyServer Backup Module: cron job, cPanel plugin entries, and
# installed scripts. Leaves /etc/skyserver-backup.conf and existing S3
# backups untouched (delete those manually if you really want them gone).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }

INSTALL_DIR="/opt/skyserver-backup-module"
DYNAMICUI_DIR="/var/cpanel/dynamicui"
FRONTEND_BASE="/usr/local/cpanel/base/frontend"
CRON_FILE="/etc/cron.d/skyserver-backup"

echo "[skyserver-backup] Removing cron job..."
rm -f "$CRON_FILE"

echo "[skyserver-backup] Removing cPanel plugin..."
rm -f "$DYNAMICUI_DIR/dynamicui_skyserver_backup.conf"
for THEME_DIR in "$FRONTEND_BASE"/*/; do
  rm -rf "${THEME_DIR}skyserver_backup"
done
/usr/local/cpanel/scripts/rebuildnavigations >/dev/null 2>&1 || true

echo "[skyserver-backup] Removing installed scripts at $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"

echo "[skyserver-backup] Done. Config (/etc/skyserver-backup.conf) and S3 backups were left in place."
