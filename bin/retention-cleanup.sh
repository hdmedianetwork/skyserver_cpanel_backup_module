#!/bin/bash
# Deletes S3 backup objects older than RETENTION_DAYS (set in
# /etc/skyserver-backup.conf) to keep storage cost under control, and drops
# the same days from every account's manifest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

MANIFEST_DIR="/var/spool/skyserver-backup/manifests"
CUTOFF_EPOCH="$(date -d "-${RETENTION_DAYS} days" +%s)"
# The oldest day that survives the S3 pass below, which deletes a day once
# its midnight falls before the cutoff. The manifests must keep exactly the
# same days, or they list backups that are already gone.
KEEP_FROM="$(date -d "@$CUTOFF_EPOCH" +%F)"
if [ "$(date -d "$KEEP_FROM" +%s)" -lt "$CUTOFF_EPOCH" ]; then
  KEEP_FROM="$(date -d "$KEEP_FROM +1 day" +%F)"
fi

echo "[*] Applying retention policy: keep last ${RETENTION_DAYS} days"

s3_list "backups/" | while read -r _DATE_STR _TIME_STR _SIZE KEY; do
  [ -z "$KEY" ] && continue
  FOLDER_DATE="$(echo "$KEY" | grep -oP '(?<=backups/)[^/]+/\K\d{4}-\d{2}-\d{2}' || true)"
  [ -z "$FOLDER_DATE" ] && continue
  FOLDER_EPOCH="$(date -d "$FOLDER_DATE" +%s 2>/dev/null || echo 0)"
  if [ "$FOLDER_EPOCH" -ne 0 ] && [ "$FOLDER_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
    echo "  [-] Deleting expired: $KEY"
    # One object that will not delete must not stop the rest from expiring.
    s3_rm "$KEY" || echo "  [!] Could not delete $KEY — it will be retried next run"
  fi
done

# The manifests are what the dashboard counts as "Kept" and what both
# plugins offer to restore. Left alone they grow by one entry a night
# forever, listing backups the bucket no longer has — and a restore of one
# of those fails only after the customer has asked for it.
[ -d "$MANIFEST_DIR" ] || exit 0
for MANIFEST_FILE in "$MANIFEST_DIR"/*.json; do
  [ -f "$MANIFEST_FILE" ] || continue
  USER="$(basename "$MANIFEST_FILE" .json)"
  BEFORE="$(jq 'length' "$MANIFEST_FILE" 2>/dev/null || echo 0)"
  if ! jq --arg from "$KEEP_FROM" '[.[] | select(.date >= $from)]' \
       "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp"; then
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
