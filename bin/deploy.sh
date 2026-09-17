#!/bin/bash
# Deploys whatever is currently in INSTALL_DIR onto this server: spool
# dirs, config, cron, logrotate, the cPanel end-user plugin and the WHM
# admin plugin. Idempotent — safe to re-run, which is what both the
# installer and the in-place updater rely on.
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_FILE="/etc/skyserver-backup.conf"
DYNAMICUI_DIR="/var/cpanel/dynamicui"
FRONTEND_BASE="/usr/local/cpanel/base/frontend"
CRON_FILE="/etc/cron.d/skyserver-backup"
SPOOL_DIR="/var/spool/skyserver-backup"
WHM_CGI_DIR="/usr/local/cpanel/whostmgr/docroot/cgi/skyserver_backup"

log() { echo "[skyserver-backup] $*"; }
die() { echo "[skyserver-backup] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]     || die "deploy.sh must run as root."
[ -d /usr/local/cpanel ] || die "cPanel/WHM not found at /usr/local/cpanel."

chmod +x "$INSTALL_DIR"/bin/*.sh "$INSTALL_DIR"/scripts/*.sh 2>/dev/null || true

log "Setting up spool directories..."
mkdir -p "$SPOOL_DIR"/manifests "$SPOOL_DIR"/restore-requests "$SPOOL_DIR"/restore-status "$SPOOL_DIR"/downloads
chmod 750 "$SPOOL_DIR"

if [ ! -f "$CONF_FILE" ]; then
  cp "$INSTALL_DIR/etc/skyserver-backup.conf.example" "$CONF_FILE"
  chmod 600 "$CONF_FILE"
  log "Config file created at $CONF_FILE (S3 bucket + AWS keys are still placeholders)."
else
  log "Existing config found at $CONF_FILE — leaving it untouched."
fi

log "Installing cron jobs..."
sed "s#__INSTALL_DIR__#$INSTALL_DIR#g" "$INSTALL_DIR/etc/cron/skyserver-backup" > "$CRON_FILE"
chmod 644 "$CRON_FILE"

log "Installing log rotation..."
cp "$INSTALL_DIR/etc/logrotate/skyserver-backup" /etc/logrotate.d/skyserver-backup
chmod 644 /etc/logrotate.d/skyserver-backup

log "Installing cPanel end-user plugin into every theme..."
for THEME_DIR in "$FRONTEND_BASE"/*/; do
  [ -d "$THEME_DIR" ] || continue
  PLUGIN_DEST="${THEME_DIR}skyserver_backup"
  mkdir -p "$PLUGIN_DEST"
  cp "$INSTALL_DIR"/plugin/*.live.php "$PLUGIN_DEST/"
done
mkdir -p "$DYNAMICUI_DIR"
cp "$INSTALL_DIR/plugin/skyserver_backup.conf" "$DYNAMICUI_DIR/dynamicui_skyserver_backup.conf"

log "Installing WHM admin dashboard..."
PHP_BIN="$(command -v php || true)"
[ -z "$PHP_BIN" ] && [ -x /usr/local/cpanel/3rdparty/bin/php ] && PHP_BIN="/usr/local/cpanel/3rdparty/bin/php"
[ -n "$PHP_BIN" ] || die "No PHP binary found — required for the WHM admin dashboard."

mkdir -p "$WHM_CGI_DIR"
sed "1s|.*|#!${PHP_BIN}|" "$INSTALL_DIR/whm-plugin/index.cgi" > "$WHM_CGI_DIR/index.cgi"
chmod 750 "$WHM_CGI_DIR/index.cgi"
/usr/local/cpanel/bin/register_appconfig "$INSTALL_DIR/whm-plugin/skyserver_backup.appconfig" >/dev/null 2>&1 \
  || log "  (register_appconfig failed or is unavailable — add the WHM entry manually, see README)"

log "Rebuilding cPanel UI caches..."
/usr/local/cpanel/scripts/rebuild_sprites >/dev/null 2>&1 || true
/usr/local/cpanel/scripts/rebuildnavigations >/dev/null 2>&1 || true

log "Deploy complete (version $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown))."
