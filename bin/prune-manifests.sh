#!/bin/bash
# Drops the days older than RETENTION_DAYS from every account's manifest.
#
# The manifests are what the dashboard counts as "Kept" and what both
# plugins offer to restore. Left alone they grow by one entry a night
# forever, listing backups the bucket no longer has — and a restore of one
# of those fails only after the customer has asked for it.
#
# Run by bin/retention-cleanup.sh after it expires the same days in S3, and
# by bin/deploy.sh so an update corrects the counts straight away. Touches
# nothing in S3, so it is safe to run at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SKYSERVER_CONF:-/etc/skyserver-backup.conf}"
MANIFEST_DIR="/var/spool/skyserver-backup/manifests"

# Read on its own rather than through s3-lib.sh: deploy runs this, and an
# install whose S3 settings are still placeholders must not fail over it.
RETENTION_DAYS=""
if [ -r "$CONF_FILE" ]; then
  RETENTION_DAYS="$(sed -n 's/^[[:space:]]*RETENTION_DAYS=["'\'']\{0,1\}\([0-9]*\).*/\1/p' "$CONF_FILE" | tail -n1)"
fi
: "${RETENTION_DAYS:=7}"
# 0 would empty every manifest; nothing in S3 is expired at 0 either.
[ "$RETENTION_DAYS" -gt 0 ] || exit 0
[ -d "$MANIFEST_DIR" ] || exit 0
command -v jq >/dev/null 2>&1 || { echo "  [!] jq not found — manifests not pruned"; exit 0; }

# The oldest day that survives retention-cleanup.sh, which deletes a day
# from S3 once its midnight falls before the cutoff. The manifests must keep
# exactly the same days, or they list backups that are already gone.
CUTOFF_EPOCH="$(date -d "-${RETENTION_DAYS} days" +%s)"
KEEP_FROM="$(date -d "@$CUTOFF_EPOCH" +%F)"
if [ "$(date -d "$KEEP_FROM" +%s)" -lt "$CUTOFF_EPOCH" ]; then
  KEEP_FROM="$(date -d "$KEEP_FROM +1 day" +%F)"
fi

for MANIFEST_FILE in "$MANIFEST_DIR"/*.json; do
  [ -f "$MANIFEST_FILE" ] || continue
  USER="$(basename "$MANIFEST_FILE" .json)"
  BEFORE="$(jq 'length' "$MANIFEST_FILE" 2>/dev/null || echo 0)"
  if ! jq --arg from "$KEEP_FROM" '[.[] | select(.date >= $from)]' \
       "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" 2>/dev/null; then
    rm -f "$MANIFEST_FILE.tmp"
    echo "  [!] Could not read $MANIFEST_FILE — left as it is"
    continue
  fi
  AFTER="$(jq 'length' "$MANIFEST_FILE.tmp")"
  if [ "$AFTER" -eq "$BEFORE" ]; then
    rm -f "$MANIFEST_FILE.tmp"
    continue
  fi
  mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
  echo "  [-] $USER: dropped $(( BEFORE - AFTER )) expired backup(s) from the manifest"
  "$SCRIPT_DIR/publish-manifest.sh" "$USER" || true
done
