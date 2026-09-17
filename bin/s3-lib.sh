#!/bin/bash
# Shared S3 helper functions. Source this file from other scripts:
#   source "$(dirname "$0")/s3-lib.sh"
set -euo pipefail

: "${SKYSERVER_CONF:=/etc/skyserver-backup.conf}"

if [ ! -f "$SKYSERVER_CONF" ]; then
  echo "[skyserver-backup] Config file not found: $SKYSERVER_CONF" >&2
  echo "[skyserver-backup] Copy etc/skyserver-backup.conf.example to $SKYSERVER_CONF and edit it." >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$SKYSERVER_CONF"

: "${S3_BUCKET:?S3_BUCKET not set in $SKYSERVER_CONF}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${RETENTION_DAYS:=7}"
# Defaults keep configs written before these options existed working.
: "${BACKUP_WORK_DIR:=/root}"
: "${DISK_SAFETY_MARGIN_MB:=2048}"
: "${ENABLE_USER_RESTORE:=0}"
: "${ALERT_EMAIL:=}"
# Empty means real AWS S3. Set it for any S3-compatible provider
# (Wasabi, Backblaze B2, IDrive e2, DigitalOcean Spaces, MinIO, Contabo…).
: "${S3_ENDPOINT_URL:=}"
: "${S3_ADDRESSING_STYLE:=}"
export AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

# The AWS CLI rejects an endpoint without a scheme outright, and typing
# the bare hostname is the obvious mistake to make.
if [ -n "$S3_ENDPOINT_URL" ]; then
  case "$S3_ENDPOINT_URL" in
    http://*|https://*) ;;
    *) S3_ENDPOINT_URL="https://${S3_ENDPOINT_URL}" ;;
  esac
fi

# With virtual-host addressing the bucket becomes a subdomain of the
# endpoint, so a bucket whose name contains a dot breaks TLS: a wildcard
# cert matches one label only, and "my.bucket.host" is two. Path-style
# avoids that and every S3-compatible provider accepts it, so it is the
# default whenever a custom endpoint is in play.
if [ -n "$S3_ENDPOINT_URL" ]; then
  : "${S3_ADDRESSING_STYLE:=path}"
  AWS_CFG_DIR="/var/spool/skyserver-backup/aws"
  mkdir -p "$AWS_CFG_DIR"
  chmod 700 "$AWS_CFG_DIR"
  cat > "$AWS_CFG_DIR/config" <<AWSCFG
[default]
s3 =
    addressing_style = ${S3_ADDRESSING_STYLE}
AWSCFG
  export AWS_CONFIG_FILE="$AWS_CFG_DIR/config"
fi

USER_RESTORE_MARKER="/var/spool/skyserver-backup/user-restore-enabled"

# Every aws call goes through here so the custom endpoint is never
# forgotten on one of them — and is omitted entirely for real AWS, where
# passing --endpoint-url would be wrong.
aws_s3() {
  if [ -n "$S3_ENDPOINT_URL" ]; then
    aws --endpoint-url "$S3_ENDPOINT_URL" "$@"
  else
    aws "$@"
  fi
}

s3_upload() { # <local_path> <s3_key>
  aws_s3 s3 cp "$1" "s3://${S3_BUCKET}/$2" --only-show-errors
}

s3_download() { # <s3_key> <local_path>
  aws_s3 s3 cp "s3://${S3_BUCKET}/$1" "$2" --only-show-errors
}

s3_list() { # <prefix>
  aws_s3 s3 ls "s3://${S3_BUCKET}/$1" --recursive
}

s3_rm() { # <s3_key>
  aws_s3 s3 rm "s3://${S3_BUCKET}/$1" --only-show-errors
}
