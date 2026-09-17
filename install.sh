#!/bin/bash
# SkyServer cPanel Backup Module — installer.
#
# Run as root on the WHM/cPanel server you want to protect:
#
#   curl -sSL https://backup.gosecureserver.in/install.sh | bash
#
# Clones the module into /opt/skyserver-backup-module and hands off to
# bin/deploy.sh, which does the actual wiring (config, cron, logrotate,
# cPanel plugin, WHM plugin). The same deploy step runs on every update,
# so there is only one copy of that logic.
set -euo pipefail

REPO_URL="https://github.com/hdmedianetwork/skyserver_cpanel_backup_module.git"
REPO_BRANCH="${SKYSERVER_BRANCH:-main}"
INSTALL_DIR="/opt/skyserver-backup-module"

log()  { echo "[skyserver-backup] $*"; }
die()  { echo "[skyserver-backup] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ]     || die "This installer must be run as root."
[ -d /usr/local/cpanel ] || die "cPanel/WHM installation not found at /usr/local/cpanel."

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
  git -C "$INSTALL_DIR" checkout -qB "$REPO_BRANCH" "origin/$REPO_BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH"
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR"/bin/*.sh
"$INSTALL_DIR/bin/deploy.sh"

echo
log "Install complete."
log "Next steps:"
log "  1) Edit /etc/skyserver-backup.conf — set S3_BUCKET, AWS_DEFAULT_REGION,"
log "     AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (or use the WHM config form)."
log "  2) In WHM → Plugins → SkyServer Backup Manager, hit 'Test S3 Connection'."
log "  3) Back up a single account from the dashboard and check the result."
log "  4) Daily backups then run automatically at 02:00."
log ""
log "Self-service restore is DISABLED by default. Verify a restore yourself on a"
log "throwaway account first, then enable it from the WHM dashboard's config form."
