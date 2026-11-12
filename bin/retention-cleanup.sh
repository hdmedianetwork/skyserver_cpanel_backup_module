#!/bin/bash
# Deletes S3 backup objects older than RETENTION_DAYS (set in
# /etc/skyserver-backup.conf) to keep storage cost under control, and drops
# the same days from every account's manifest.
#
# Terminated accounts are handled first and differently. A terminated
# account never gets another backup, so under the ordinary rule its last one
# would be gone RETENTION_DAYS after termination — usually before anyone
# asks for it back. bin/archive-terminated.sh moves such backups out of
# backups/ into terminated/<user>/<stamp>/, and those are kept for
# TERMINATED_RETENTION_DAYS from the day of termination (0 keeps them until
# you delete them).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

TERMINATED_DIR="/var/spool/skyserver-backup/terminated"

echo "[*] Archiving backups of accounts that are no longer on this server..."
"$SCRIPT_DIR/archive-terminated.sh" --scan || echo "  [!] Archiving did not finish — see above."

# Which accounts exist. A key under backups/ whose account is not on this
# server is one the archive step above could not move yet; it is kept, not
# expired, until the next run moves it. When WHM cannot say which accounts
# exist, nothing under backups/ is expired at all this run.
LIVE=""
if OUT="$(whmapi1 listaccts --output=jsonpretty 2>/dev/null)" \
   && [ "$(printf '%s' "$OUT" | jq -r '.metadata.result // empty' 2>/dev/null)" = "1" ]; then
  LIVE="$(printf '%s' "$OUT" | jq -r '.data.acct[]?.user' 2>/dev/null || true)"
fi

CUTOFF_EPOCH="$(date -d "-${RETENTION_DAYS} days" +%s)"
if [ -z "$LIVE" ]; then
  echo "[!] Could not get the account list from WHM — no backups expired this run, so a" \
       "terminated account's cannot be lost by mistake."
else
  echo "[*] Applying retention policy: keep last ${RETENTION_DAYS} days"
  s3_list "backups/" | while read -r _DATE_STR _TIME_STR _SIZE KEY; do
    [ -z "$KEY" ] && continue
    KEY_USER="$(echo "$KEY" | cut -d/ -f2)"
    FOLDER_DATE="$(echo "$KEY" | grep -oP '(?<=backups/)[^/]+/\K\d{4}-\d{2}-\d{2}' || true)"
    [ -z "$FOLDER_DATE" ] && continue
    if [ -n "$KEY_USER" ] && ! printf '%s\n' "$LIVE" | grep -qxF "$KEY_USER"; then
      continue   # not on this server: kept for the archive step
    fi
    FOLDER_EPOCH="$(date -d "$FOLDER_DATE" +%s 2>/dev/null || echo 0)"
    if [ "$FOLDER_EPOCH" -ne 0 ] && [ "$FOLDER_EPOCH" -lt "$CUTOFF_EPOCH" ]; then
      echo "  [-] Deleting expired: $KEY"
      # One object that will not delete must not stop the rest from expiring.
      s3_rm "$KEY" || echo "  [!] Could not delete $KEY — it will be retried next run"
    fi
  done
fi

# Archives of terminated accounts, by the day they were archived.
if [ "$TERMINATED_RETENTION_DAYS" -gt 0 ]; then
  echo "[*] Terminated accounts: keep archives for ${TERMINATED_RETENTION_DAYS} days after termination"
  T_CUTOFF="$(date -u -d "-${TERMINATED_RETENTION_DAYS} days" +%Y%m%dT%H%M%S)"
  while read -r _D _T _S KEY; do
    [ -n "$KEY" ] || continue
    STAMP="$(echo "$KEY" | grep -oP '^terminated/[^/]+/\K\d{8}T\d{6}(?=/)' || true)"
    [ -n "$STAMP" ] || continue
    # Same-length timestamps compare as strings.
    if [[ "$STAMP" < "$T_CUTOFF" ]]; then
      echo "  [-] Deleting expired: $KEY"
      s3_rm "$KEY" || echo "  [!] Could not delete $KEY — it will be retried next run"
    fi
  done < <(s3_list "terminated/" 2>/dev/null || true)

  for R in "$TERMINATED_DIR"/*--*.json; do
    [ -f "$R" ] || continue
    STAMP="$(jq -r '.stamp // ""' "$R" 2>/dev/null || true)"
    [ -n "$STAMP" ] || continue
    if [[ "$STAMP" < "$T_CUTOFF" ]] && [ "$(jq -r '.status // ""' "$R")" != "archiving" ]; then
      rm -f "$R"
      echo "  [-] Dropped the record of $(basename "$R" .json): its archive has expired"
    fi
  done
else
  echo "[*] Terminated accounts: archives are kept until deleted by hand (TERMINATED_RETENTION_DAYS=0)"
fi

# The same days come out of every account's manifest, so the dashboard and
# the restore lists stop offering what was just deleted.
"$SCRIPT_DIR/prune-manifests.sh"
