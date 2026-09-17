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
export AWS_DEFAULT_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

s3_upload() { # <local_path> <s3_key>
  aws s3 cp "$1" "s3://${S3_BUCKET}/$2" --only-show-errors
}

s3_download() { # <s3_key> <local_path>
  aws s3 cp "s3://${S3_BUCKET}/$1" "$2" --only-show-errors
}

s3_list() { # <prefix>
  aws s3 ls "s3://${S3_BUCKET}/$1" --recursive
}

s3_rm() { # <s3_key>
  aws s3 rm "s3://${S3_BUCKET}/$1" --only-show-errors
}
