#!/bin/bash
# cPanel standardized hook for Whostmgr Accounts::Remove, registered by
# bin/deploy.sh for both stages:
#
#   pre   takes a final backup of the account if it has none from today
#         (TERMINATION_FINAL_BACKUP=1, the default), and notes its domain,
#         owner and plan so the archive can say what it was;
#   post  archives that account's backups out of backups/<user>/ — in the
#         background, so terminating a large account does not sit waiting
#         on S3.
#
# cPanel passes the event as JSON on stdin. Nothing here may stop the
# termination: the hook is registered as non-blocking, and every path out of
# this script reports success to cPanel whatever happened to the backup.
set -uo pipefail

# Hooks are run with whatever PATH cpsrvd has, which need not include
# cPanel's own bin directories.
PATH="/usr/local/cpanel/bin:/usr/local/cpanel/scripts:/usr/local/bin:/usr/local/sbin:${PATH:-/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/skyserver-backup.log"
SPOOL_DIR="/var/spool/skyserver-backup"
TERMINATED_DIR="$SPOOL_DIR/terminated"

done_ok() { echo "1 ${1:-ok}"; exit 0; }
log() { echo "[terminate] $*" >> "$LOG"; }

INPUT="$(cat)"
STAGE="$(printf '%s' "$INPUT" | jq -r '.context.stage // empty' 2>/dev/null || true)"
USER="$(printf '%s' "$INPUT" | jq -r '.data.user // empty' 2>/dev/null || true)"

case "$USER" in
  ''|*[!a-zA-Z0-9_]*) done_ok "no usable account name in the hook data" ;;
esac

# The config is sourced through s3-lib.sh in the scripts this starts; only
# the two switches this hook needs are read here, so a broken S3 setup can
# never get in the way of terminating an account.
CONF_FILE="${SKYSERVER_CONF:-/etc/skyserver-backup.conf}"
conf_get() { # <key> <default>
  local v=""
  [ -r "$CONF_FILE" ] && v="$(sed -n "s/^[[:space:]]*$1=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$CONF_FILE" | tail -n1)"
  printf '%s' "${v:-$2}"
}

mkdir -p "$TERMINATED_DIR" 2>/dev/null || true
chmod 700 "$TERMINATED_DIR" 2>/dev/null || true

case "$STAGE" in
  pre)
    # What the account was, while WHM can still tell us.
    SUMMARY="$(whmapi1 accountsummary user="$USER" --output=json 2>/dev/null || true)"
    PENDING="$TERMINATED_DIR/pending-${USER}.json"
    printf '%s' "$SUMMARY" | jq --arg u "$USER" --arg ts "$(date -Iseconds)" '
        (.data.acct[0] // {}) as $a
        | {user: $u, terminated_at: $ts, domain: ($a.domain // null),
           owner: ($a.owner // null), plan: ($a.plan // null)}' > "$PENDING" 2>/dev/null || true
    if [ ! -s "$PENDING" ]; then
      jq -n --arg u "$USER" --arg ts "$(date -Iseconds)" '{user: $u, terminated_at: $ts}' > "$PENDING"
    fi
    chmod 600 "$PENDING" 2>/dev/null || true

    if [ "$(conf_get TERMINATION_FINAL_BACKUP 1)" != "1" ]; then
      log "$USER is being terminated — final backup is switched off"
      done_ok "final backup disabled"
    fi

    MANIFEST="$SPOOL_DIR/manifests/${USER}.json"
    if [ -r "$MANIFEST" ] && jq -e --arg d "$(date +%F)" 'map(select(.date == $d)) | length > 0' \
         "$MANIFEST" >/dev/null 2>&1; then
      log "$USER is being terminated — it already has today's backup, so that is the one kept"
      done_ok "already backed up today"
    fi

    TIMEOUT_MIN="$(conf_get ACCOUNT_TIMEOUT_MIN 90)"
    case "$TIMEOUT_MIN" in ''|*[!0-9]*) TIMEOUT_MIN=90 ;; esac
    log "$USER is being terminated — taking a final backup first (up to ${TIMEOUT_MIN}m)"
    if timeout "${TIMEOUT_MIN}m" "$SCRIPT_DIR/backup-user.sh" "$USER" >> "$LOG" 2>&1; then
      log "final backup of $USER done"
    else
      rc=$?
      if [ "$rc" = "2" ]; then
        log "final backup of $USER done, but some databases could not be dumped"
      else
        log "final backup of $USER FAILED (exit $rc) — its earlier backups are still archived"
      fi
    fi
    done_ok "final backup attempted"
    ;;

  post)
    log "$USER was terminated — archiving its backups"
    # Detached so WHM is not left waiting on the bucket. If this is cut
    # short, the nightly scan finishes it.
    setsid nohup "$SCRIPT_DIR/archive-terminated.sh" --user "$USER" >> "$LOG" 2>&1 < /dev/null &
    done_ok "archive started"
    ;;
esac

done_ok "nothing to do for stage ${STAGE:-unknown}"
