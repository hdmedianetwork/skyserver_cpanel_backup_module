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

# The cPanel end-user plugin runs as the logged-in account, not as root, so
# every directory on the way to that account's manifest has to be
# traversable by it. 0750 here is what made the end-user page read "No
# backups yet" on servers whose backups were running perfectly well: the
# account could not even reach manifests/. 0751 grants traversal without
# granting a listing, so an account can open its own manifest by name and
# still cannot discover anyone else's — the manifests themselves stay
# 0640 root:<user>.
chmod 751 "$SPOOL_DIR" "$SPOOL_DIR/manifests" "$SPOOL_DIR/restore-status" "$SPOOL_DIR/downloads"

# The restore queue is a drop box: accounts have to be able to create a
# request file in it, and the sticky bit stops them removing or replacing
# anyone else's.
chmod 1733 "$SPOOL_DIR/restore-requests"

# Re-publish the manifests of accounts backed up before the modes above
# were right, so an update fixes the end-user page now instead of at the
# next nightly run.
for MANIFEST in "$SPOOL_DIR"/manifests/*.json; do
  [ -e "$MANIFEST" ] || continue
  "$INSTALL_DIR/bin/publish-manifest.sh" "$(basename "$MANIFEST" .json)" || true
done

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

# The menu tile should carry the real logo rather than a stand-in. ImageKit
# will hand us a square version of it, so fetch that here and fall back to
# the bundled icon on a server with no outbound access.
ICON_SRC="$INSTALL_DIR/plugin/skyserver_backup.png"
ICON_TMP="$(mktemp)"
if curl -fsS --max-time 15 -o "$ICON_TMP" \
     "https://ik.imagekit.io/hdmn/skybackupmanager.png?tr=w-96,h-96,cm-pad_resize" \
   && head -c 8 "$ICON_TMP" | grep -qa PNG; then
  ICON_SRC="$ICON_TMP"
  log "  Menu icon taken from the SkyServer logo."
else
  log "  Could not fetch the logo — using the bundled menu icon."
fi

for THEME_DIR in "$FRONTEND_BASE"/*/; do
  [ -d "$THEME_DIR" ] || continue
  PLUGIN_DEST="${THEME_DIR}skyserver_backup"
  mkdir -p "$PLUGIN_DEST"
  cp "$INSTALL_DIR"/plugin/*.php "$PLUGIN_DEST/"
  chmod 644 "$PLUGIN_DEST"/*.php

  # The theme reads a menu item's icon from its own application_icons
  # directory, named after the descriptor's file=> key — the same place
  # letsencrypt-cpanel.png and lvephpsel.svg sit. Not the plugin's own
  # directory, which is where this landed before and was ignored.
  ICON_DIR="${THEME_DIR}assets/application_icons"
  mkdir -p "$ICON_DIR"
  cp "$ICON_SRC" "$ICON_DIR/skyserver_backup.png"

  # Almost every icon in that directory is .svg, so ship the same logo under
  # both extensions and let the theme pick. The PNG is embedded rather than
  # linked: an SVG used as an <img> cannot fetch anything of its own, so a
  # reference to the logo's URL would render as nothing.
  printf '%s' \
    '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 96 96" width="96" height="96"><image width="96" height="96" xlink:href="data:image/png;base64,' \
    > "$ICON_DIR/skyserver_backup.svg"
  base64 -w0 "$ICON_SRC" >> "$ICON_DIR/skyserver_backup.svg"
  printf '%s' '"/></svg>' >> "$ICON_DIR/skyserver_backup.svg"

  chmod 644 "$ICON_DIR/skyserver_backup.png" "$ICON_DIR/skyserver_backup.svg"
  rm -f "$PLUGIN_DEST/skyserver_backup.png"

  # The icon entry belongs in the theme's own dynamicui directory — that is
  # where cPanel reads menu items from. Without it the pages are served but
  # nothing links to them, which is exactly how this looked: installed, and
  # invisible.
  mkdir -p "${THEME_DIR}dynamicui"
  cp "$INSTALL_DIR/plugin/skyserver_backup.conf" \
     "${THEME_DIR}dynamicui/dynamicui_skyserver_backup.conf"
  chmod 644 "${THEME_DIR}dynamicui/dynamicui_skyserver_backup.conf"
done
rm -f "$ICON_TMP"

mkdir -p "$DYNAMICUI_DIR"
cp "$INSTALL_DIR/plugin/skyserver_backup.conf" "$DYNAMICUI_DIR/dynamicui_skyserver_backup.conf"
chmod 644 "$DYNAMICUI_DIR/dynamicui_skyserver_backup.conf"

log "Installing WHM admin dashboard..."
PHP_BIN="$(command -v php || true)"
[ -z "$PHP_BIN" ] && [ -x /usr/local/cpanel/3rdparty/bin/php ] && PHP_BIN="/usr/local/cpanel/3rdparty/bin/php"
[ -n "$PHP_BIN" ] || die "No PHP binary found — required for the WHM admin dashboard."

mkdir -p "$WHM_CGI_DIR"
sed "1s|.*|#!${PHP_BIN}|" "$INSTALL_DIR/whm-plugin/index.cgi" > "$WHM_CGI_DIR/index.cgi"
chmod 750 "$WHM_CGI_DIR/index.cgi"

# Print whatever register_appconfig says rather than swallowing it — a
# silent failure here means the WHM menu entry never appears, and the
# reason is the only way to fix it.
if [ -x /usr/local/cpanel/bin/register_appconfig ]; then
  # Drop any previous registration first, so a changed descriptor (a fixed
  # entryurl, say) actually takes effect instead of leaving the old menu
  # entry in place.
  /usr/local/cpanel/bin/unregister_appconfig skyserver_backup >/dev/null 2>&1 || true

  if REG_OUT="$(/usr/local/cpanel/bin/register_appconfig "$INSTALL_DIR/whm-plugin/skyserver_backup.appconfig" 2>&1)"; then
    log "  WHM plugin registered."
  else
    log "  WARNING: register_appconfig failed. Its output was:"
    printf '    %s\n' "$REG_OUT"
    log "  The WHM menu entry will be missing until this is resolved."
  fi
else
  log "  WARNING: /usr/local/cpanel/bin/register_appconfig not found on this server."
fi

log "Rebuilding cPanel UI caches..."
# rebuildnavigations is gone as of cPanel 134, and sprites live under either
# scripts/ or bin/ depending on the version.
if [ -x /usr/local/cpanel/scripts/rebuild_sprites ]; then
  /usr/local/cpanel/scripts/rebuild_sprites >/dev/null 2>&1 || true
elif [ -x /usr/local/cpanel/bin/rebuild_sprites ]; then
  /usr/local/cpanel/bin/rebuild_sprites >/dev/null 2>&1 || true
fi

log "Deploy complete (version $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo unknown))."
