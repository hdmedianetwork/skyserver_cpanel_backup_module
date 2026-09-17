#!/bin/bash
# Cron entrypoint: backs up every cPanel account on this server and then
# applies the S3 retention policy. Meant to run as root once a day.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/skyserver-backup.log"

echo "===== Backup run started: $(date) =====" >> "$LOG"

ACCOUNTS="$(whmapi1 listaccts --output=jsonpretty | grep -oP '"user"\s*:\s*"\K[^"]+')"

if [ -z "$ACCOUNTS" ]; then
  echo "[!] No accounts returned by whmapi1 listaccts — aborting run." >> "$LOG"
  exit 1
fi

FAILED=0
for USER in $ACCOUNTS; do
  if "$SCRIPT_DIR/backup-user.sh" "$USER" >> "$LOG" 2>&1; then
    echo "[OK] $USER" >> "$LOG"
  else
    echo "[FAIL] $USER" >> "$LOG"
    FAILED=1
  fi
done

"$SCRIPT_DIR/retention-cleanup.sh" >> "$LOG" 2>&1 || true

echo "===== Backup run finished: $(date) =====" >> "$LOG"
exit "$FAILED"
