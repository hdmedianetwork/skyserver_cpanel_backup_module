#!/bin/bash
# Cron entrypoint: backs up every cPanel account on this server and then
# applies the S3 retention policy. Meant to run as root once a day.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

LOG="/var/log/skyserver-backup.log"
LOCK_FILE="/var/spool/skyserver-backup/backup.lock"

mkdir -p "$(dirname "$LOCK_FILE")"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "[!] Another backup run is already in progress — skipping." >> "$LOG"; exit 1; }

alert() { # <subject> <body>
  [ -n "$ALERT_EMAIL" ] || return 0
  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$2" | mail -s "$1" "$ALERT_EMAIL"
  else
    echo "[!] ALERT_EMAIL is set but no 'mail' command is available to send alerts." >> "$LOG"
  fi
}

echo "===== Backup run started: $(date) =====" >> "$LOG"

ACCOUNTS="$(whmapi1 listaccts --output=jsonpretty | grep -oP '"user"\s*:\s*"\K[^"]+')"

if [ -z "$ACCOUNTS" ]; then
  echo "[!] No accounts returned by whmapi1 listaccts — aborting run." >> "$LOG"
  alert "[SkyServer Backup] FAILED on $(hostname): no accounts found" \
        "whmapi1 listaccts returned no accounts, so nothing was backed up. Check that WHM is healthy on $(hostname)."
  exit 1
fi

FAILED_USERS=()
for USER in $ACCOUNTS; do
  if "$SCRIPT_DIR/backup-user.sh" "$USER" >> "$LOG" 2>&1; then
    echo "[OK] $USER" >> "$LOG"
  else
    echo "[FAIL] $USER" >> "$LOG"
    FAILED_USERS+=("$USER")
  fi
done

"$SCRIPT_DIR/retention-cleanup.sh" >> "$LOG" 2>&1 || true

echo "===== Backup run finished: $(date) =====" >> "$LOG"

if [ "${#FAILED_USERS[@]}" -gt 0 ]; then
  alert "[SkyServer Backup] ${#FAILED_USERS[@]} account(s) failed on $(hostname)" \
"$(printf 'Backup run on %s finished with failures.\n\nFailed accounts:\n%s\n\nLast 40 log lines:\n%s\n' \
    "$(hostname)" \
    "$(printf '  - %s\n' "${FAILED_USERS[@]}")" \
    "$(tail -n 40 "$LOG")")"
  exit 1
fi

exit 0
