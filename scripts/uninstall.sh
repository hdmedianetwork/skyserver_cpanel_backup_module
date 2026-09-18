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
WHM_CGI_DIR="/usr/local/cpanel/whostmgr/docroot/cgi/skyserver_backup"

echo "[skyserver-backup] Removing cron job..."
rm -f "$CRON_FILE"

echo "[skyserver-backup] Removing cPanel end-user plugin..."
rm -f "$DYNAMICUI_DIR/dynamicui_skyserver_backup.conf"
for THEME_DIR in "$FRONTEND_BASE"/*/; do
  rm -rf "${THEME_DIR}skyserver_backup"
done
/usr/local/cpanel/scripts/rebuildnavigations >/dev/null 2>&1 || true

echo "[skyserver-backup] Removing WHM admin dashboard..."
/usr/local/cpanel/bin/unregister_appconfig "$INSTALL_DIR/whm-plugin/skyserver_backup.appconfig" >/dev/null 2>&1 || true
rm -rf "$WHM_CGI_DIR"

echo "[skyserver-backup] Removing the manifest copies from account homes..."
# bin/publish-manifest.sh drops a copy of each account's manifest into its
# own home so the plugin can read it on a jailed filesystem. The plugin is
# gone now, so these would just sit in every customer's home forever.
for MANIFEST in /var/spool/skyserver-backup/manifests/*.json; do
  [ -e "$MANIFEST" ] || continue
  HOME_DIR="$(getent passwd "$(basename "$MANIFEST" .json)" | cut -d: -f6)"
  [ -n "$HOME_DIR" ] && [ -d "$HOME_DIR/.skyserver-backup" ] || continue
  rm -rf "$HOME_DIR/.skyserver-backup"
done

echo "[skyserver-backup] Removing installed scripts at $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"

echo "[skyserver-backup] Done. Config (/etc/skyserver-backup.conf) and S3 backups were left in place."
