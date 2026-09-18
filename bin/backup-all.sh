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

# A run that is killed — the OOM killer, a reboot, a hand on the keyboard —
# left the log showing "started" and nothing else, which reads exactly like
# a run still in progress. It is not, and the difference matters: this is
# what a stalled nightly backup looked like for days.
RUN_ENDED=0
trap 'if [ "$RUN_ENDED" = "0" ]; then
        echo "===== Backup run interrupted: $(date) =====" >> "$LOG"
      fi' EXIT
trap 'exit 143' INT TERM

echo "===== Backup run started: $(date) =====" >> "$LOG"

# Give up loudly. Every abort below writes the reason and a matching
# "finished" line: a run that stops after "started" and says nothing looks
# identical to one still in progress, which is exactly how a nightly job
# that had not worked in days still read as healthy on the dashboard.
abort() { # <short reason> <detail>
  echo "[!] $1" >> "$LOG"
  if [ -n "${2:-}" ]; then echo "$2" >> "$LOG"; fi
  RUN_ENDED=1
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
TIMED_OUT=()
TOTAL=$(echo "$ACCOUNTS" | wc -w)
N=0

for USER in $ACCOUNTS; do
  N=$(( N + 1 ))
  STARTED=$SECONDS
  echo "[*] $(date '+%F %T') [$N/$TOTAL] starting $USER" >> "$LOG"

  # --foreground so the limit applies to the account being packaged rather
  # than to a process group cron already owns; backup-user.sh cleans up its
  # own pkgacct when it is told to stop.
  # 200>&- closes the lock file descriptor for the child. Bash hands every
  # open fd to everything it starts, so pkgacct — and anything it leaves
  # behind — inherited the run's lock. One orphaned child was then enough to
  # make every later run exit with "another backup run is already in
  # progress", for good.
  if timeout --foreground --kill-after=60s "${ACCOUNT_TIMEOUT_MIN}m" \
       "$SCRIPT_DIR/backup-user.sh" "$USER" >> "$LOG" 2>&1 200>&-; then
    echo "[OK] $USER (took $(( (SECONDS - STARTED) / 60 ))m)" >> "$LOG"
  else
    RC=$?
    if [ "$RC" = "124" ] || [ "$RC" = "137" ]; then
      echo "[FAIL] $USER — gave up after ${ACCOUNT_TIMEOUT_MIN} minutes" >> "$LOG"
      TIMED_OUT+=("$USER")
    else
      echo "[FAIL] $USER (after $(( (SECONDS - STARTED) / 60 ))m)" >> "$LOG"
    fi
    FAILED_USERS+=("$USER")
  fi
done

"$SCRIPT_DIR/retention-cleanup.sh" >> "$LOG" 2>&1 200>&- || true

RUN_ENDED=1
echo "===== Backup run finished: $(date) =====" >> "$LOG"

if [ "${#FAILED_USERS[@]}" -gt 0 ]; then
  alert "[SkyServer Backup] ${#FAILED_USERS[@]} account(s) failed on $(hostname)" \
"$(printf 'Backup run on %s finished with failures.\n\nFailed accounts:\n%s\n%s\nLast 40 log lines:\n%s\n' \
    "$(hostname)" \
    "$(printf '  - %s\n' "${FAILED_USERS[@]}")" \
    "$(if [ "${#TIMED_OUT[@]}" -gt 0 ]; then
         printf '\nGave up on these after %s minutes each — they may simply be too\nlarge for that limit, which is ACCOUNT_TIMEOUT_MIN in %s:\n%s\n' \
           "$ACCOUNT_TIMEOUT_MIN" "$SKYSERVER_CONF" "$(printf '  - %s\n' "${TIMED_OUT[@]}")"
       fi)" \
    "$(tail -n 40 "$LOG")")"
  exit 1
fi

exit 0
