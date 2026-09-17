#!/bin/bash
# SkyServer cPanel Backup Module — remote installer.
#
# Run as root on the WHM/cPanel server you want to protect:
#
#   curl -sSL https://raw.githubusercontent.com/hdmedianetwork/skyserver_cpanel_backup_module/main/install.sh | bash
#
# This installs: the backup engine (bin/), a config file at
# /etc/skyserver-backup.conf, a daily cron job, and a "SkyServer Backup
# Manager" entry inside every cPanel user's dashboard.
set -euo pipefail

REPO_URL="https://github.com/hdmedianetwork/skyserver_cpanel_backup_module.git"
REPO_BRANCH="${SKYSERVER_BRANCH:-main}"
INSTALL_DIR="/opt/skyserver-backup-module"
CONF_FILE="/etc/skyserver-backup.conf"
DYNAMICUI_DIR="/var/cpanel/dynamicui"
FRONTEND_BASE="/usr/local/cpanel/base/frontend"
CRON_FILE="/etc/cron.d/skyserver-backup"
SPOOL_DIR="/var/spool/skyserver-backup"
WHM_CGI_DIR="/usr/local/cpanel/whostmgr/docroot/cgi/skyserver_backup"

log()  { echo "[skyserver-backup] $*"; }
die()  { echo "[skyserver-backup] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]        || die "This installer must be run as root."
[ -d /usr/local/cpanel ]    || die "cPanel/WHM installation not found at /usr/local/cpanel."

log "Installing dependencies (git, jq, awscli)..."
if command -v yum >/dev/null 2>&1; then
  yum install -y git jq awscli >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y git jq awscli >/dev/null 2>&1 || true
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 && apt-get install -y git jq awscli >/dev/null 2>&1 || true
fi
command -v git >/dev/null 2>&1 || die "git is required but could not be installed automatically."
command -v jq  >/dev/null 2>&1 || die "jq is required but could not be installed automatically."
command -v aws >/dev/null 2>&1 || die "AWS CLI is required but could not be installed automatically. Install it manually and re-run this script."

log "Fetching module source (branch: $REPO_BRANCH)..."
if [ -d "$INSTALL_DIR/.git" ]; then
  git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH"
  git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR"/bin/*.sh

log "Setting up spool directories..."
mkdir -p "$SPOOL_DIR"/manifests "$SPOOL_DIR"/restore-requests "$SPOOL_DIR"/restore-status
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

echo
log "Install complete."
log "Next steps:"
log "  1) Edit $CONF_FILE — set S3_BUCKET, AWS_DEFAULT_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
log "     (or use the WHM admin dashboard's config form instead)."
log "  2) Test a manual backup run:  $INSTALL_DIR/bin/backup-all.sh"
log "  3) Daily backups then run automatically at 02:00 via /etc/cron.d/skyserver-backup."
log "  4) Admin: WHM → Plugins → SkyServer Backup Manager."
log "  5) Each cPanel user will see 'SkyServer Backup Manager' under the Files section."
