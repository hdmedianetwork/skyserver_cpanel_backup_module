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

# Give up loudly. Every abort below writes the reason and a matching
# "finished" line: a run that stops after "started" and says nothing looks
# identical to one still in progress, which is exactly how a nightly job
# that had not worked in days still read as healthy on the dashboard.
abort() { # <short reason> <detail>
  echo "[!] $1" >> "$LOG"
  if [ -n "${2:-}" ]; then echo "$2" >> "$LOG"; fi
  echo "===== Backup run aborted: $(date) =====" >> "$LOG"
  alert "[SkyServer Backup] FAILED on $(hostname): $1" \
"$(printf 'The backup run on %s stopped before backing up anything.\n\n%s\n\n%s\n' \
    "$(hostname)" "$1" "${2:-}")"
  exit 1
}

# whmapi1 lives in /usr/local/cpanel/bin, which cron's PATH does not include.
# bin/s3-lib.sh puts it back; this catches the case where it genuinely isn't
# installed, instead of letting the account list come back empty.
if ! TOOL_ERR="$(sky_require_tools whmapi1 jq aws 2>&1)"; then
  abort "required commands are missing" "$TOOL_ERR"
fi

if ! ACCOUNTS_JSON="$(whmapi1 listaccts --output=jsonpretty 2>&1)"; then
  abort "whmapi1 listaccts failed" "$ACCOUNTS_JSON"
fi

ACCOUNTS="$(printf '%s' "$ACCOUNTS_JSON" | grep -oP '"user"\s*:\s*"\K[^"]+' || true)"

if [ -z "$ACCOUNTS" ]; then
  abort "whmapi1 listaccts returned no accounts" \
        "WHM answered, but the reply named no accounts. Check that WHM is healthy on $(hostname)."
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
