#!/bin/bash
# Cron entrypoint: backs up every cPanel account on this server and then
# applies the S3 retention policy. Meant to run as root once a day.
#
#   backup-all.sh              back up every account
#   backup-all.sh --resume     pick up where an interrupted run stopped
#
# A run over a couple of hundred accounts takes hours, and a server that
# reboots in the middle of one used to mean starting again from the first
# account — re-doing work that was already safely in S3. Every run records
# what it has finished in run-state.json, so --resume can carry on from
# there, and the WHM dashboard offers the button when there is something to
# carry on from.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

LOG="/var/log/skyserver-backup.log"
LOCK_FILE="/var/spool/skyserver-backup/backup.lock"
STATE_FILE="/var/spool/skyserver-backup/run-state.json"

RESUME=0
if [ "${1:-}" = "--resume" ]; then
  RESUME=1
fi

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

DATE="$(date +%F)"
STARTED_AT="$(date -Iseconds)"
ALL_ACCOUNTS=()
DONE_USERS=()
FAILED_USERS=()
TIMED_OUT=()
CURRENT_USER=""

json_array() { # items...
  if [ "$#" -eq 0 ]; then echo '[]'; return; fi
  printf '%s\n' "$@" | jq -R . | jq -s .
}

# Written after every account, so an interruption at any point leaves a
# complete picture of what is already in S3 and what is not.
write_run_state() { # <status>
  jq -n --arg date "$DATE" --arg status "$1" --arg current "$CURRENT_USER" \
        --arg started "$STARTED_AT" --arg ts "$(date -Iseconds)" \
        --argjson accounts "$(json_array ${ALL_ACCOUNTS[@]+"${ALL_ACCOUNTS[@]}"})" \
        --argjson done "$(json_array ${DONE_USERS[@]+"${DONE_USERS[@]}"})" \
        --argjson failed "$(json_array ${FAILED_USERS[@]+"${FAILED_USERS[@]}"})" \
    '{date:$date, status:$status, current:$current, started_at:$started,
      updated_at:$ts, accounts:$accounts, done:$done, failed:$failed}' \
    > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE" || return 0
  chmod 640 "$STATE_FILE" 2>/dev/null || true
}

trap 'if [ "$RUN_ENDED" = "0" ]; then
        echo "===== Backup run interrupted: $(date) =====" >> "$LOG"
        write_run_state interrupted
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
  write_run_state aborted
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

while IFS= read -r _acct; do
  if [ -n "$_acct" ]; then ALL_ACCOUNTS+=("$_acct"); fi
done <<< "$ACCOUNTS"

# Resuming keeps the earlier run's completed accounts — they are already in
# S3 under today's date and re-uploading them would be hours of work for
# nothing. Accounts that failed are retried: a run is usually resumed
# precisely because something went wrong.
if [ "$RESUME" = "1" ] && [ -f "$STATE_FILE" ]; then
  PREV_DATE="$(jq -r '.date // ""' "$STATE_FILE" 2>/dev/null || true)"
  PREV_STATUS="$(jq -r '.status // ""' "$STATE_FILE" 2>/dev/null || true)"

  if [ "$PREV_DATE" = "$DATE" ] && [ "$PREV_STATUS" != "finished" ]; then
    while IFS= read -r _acct; do
      if [ -n "$_acct" ]; then DONE_USERS+=("$_acct"); fi
    done < <(jq -r '.done[]? // empty' "$STATE_FILE" 2>/dev/null || true)

    REMAINING=()
    for _acct in ${ALL_ACCOUNTS[@]+"${ALL_ACCOUNTS[@]}"}; do
      _skip=0
      for _d in ${DONE_USERS[@]+"${DONE_USERS[@]}"}; do
        if [ "$_acct" = "$_d" ]; then _skip=1; break; fi
      done
      if [ "$_skip" = "0" ]; then REMAINING+=("$_acct"); fi
    done

    ACCOUNTS="$(printf '%s\n' ${REMAINING[@]+"${REMAINING[@]}"})"
    echo "[*] Resuming: ${#DONE_USERS[@]} of ${#ALL_ACCOUNTS[@]} accounts were already done today;" \
         "${#REMAINING[@]} left." >> "$LOG"

    if [ "${#REMAINING[@]}" -eq 0 ]; then
      RUN_ENDED=1
      write_run_state finished
      echo "[*] Nothing left to do — every account already has today's backup." >> "$LOG"
      echo "===== Backup run finished: $(date) =====" >> "$LOG"
      exit 0
    fi
  elif [ "$PREV_DATE" = "$DATE" ] && [ "$PREV_STATUS" = "finished" ]; then
    # Asking to resume something that already finished should not quietly
    # turn into hours of re-uploading everything.
    RUN_ENDED=1
    echo "[*] Today's run already finished — nothing to resume." >> "$LOG"
    echo "===== Backup run finished: $(date) =====" >> "$LOG"
    exit 0
  else
    echo "[*] No interrupted run from today to resume — starting a full run." >> "$LOG"
  fi
fi

write_run_state running

TOTAL="${#ALL_ACCOUNTS[@]}"
N="${#DONE_USERS[@]}"

for USER in $ACCOUNTS; do
  N=$(( N + 1 ))
  STARTED=$SECONDS
  CURRENT_USER="$USER"
  write_run_state running
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
    DONE_USERS+=("$USER")
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
  CURRENT_USER=""
  write_run_state running
done

"$SCRIPT_DIR/retention-cleanup.sh" >> "$LOG" 2>&1 200>&- || true

RUN_ENDED=1
write_run_state finished
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
