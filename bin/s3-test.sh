#!/bin/bash
# Verifies the configured S3 (or S3-compatible) storage end to end:
# reachability, credentials, and the write + delete permissions the backup
# and retention jobs actually need. Listing alone would pass with
# read-only keys and then fail at 2am on the first upload.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/s3-lib.sh"

echo "Endpoint : ${S3_ENDPOINT_URL:-(default AWS S3)}"
echo "Bucket   : $S3_BUCKET"
echo "Region   : $AWS_DEFAULT_REGION"
echo "AWS CLI  : $(aws --version 2>&1)"
echo

if [ "$S3_BUCKET" = "your-bucket-name" ] || [ -z "$S3_BUCKET" ]; then
  echo "[FAIL] No bucket configured yet — fill in the configuration form first."
  exit 1
fi

FAILED=0

echo "1/3 Listing the bucket..."
if OUT="$(aws_s3 s3 ls "s3://${S3_BUCKET}/" 2>&1)"; then
  echo "    [OK] Bucket is reachable and the credentials are accepted."
else
  echo "    [FAIL] Could not list the bucket:"
  printf '         %s\n' "$OUT"
  echo
  echo "Common causes: wrong endpoint URL, wrong region, wrong keys, or the"
  echo "bucket name is misspelled / belongs to another account."
  exit 1
fi

echo "2/3 Writing a test object..."
TESTKEY="backups/.skyserver-write-test"
TMPF="$(mktemp)"
echo "skyserver-backup connectivity test $(date -Iseconds)" > "$TMPF"
if OUT="$(aws_s3 s3 cp "$TMPF" "s3://${S3_BUCKET}/${TESTKEY}" --only-show-errors 2>&1)"; then
  echo "    [OK] Write permission confirmed — backups can be uploaded."
else
  echo "    [FAIL] Could not write to the bucket:"
  printf '         %s\n' "$OUT"
  echo "    The keys can read but not write. Backups would fail."
  rm -f "$TMPF"
  exit 1
fi
rm -f "$TMPF"

echo "3/3 Deleting the test object..."
if OUT="$(aws_s3 s3 rm "s3://${S3_BUCKET}/${TESTKEY}" --only-show-errors 2>&1)"; then
  echo "    [OK] Delete permission confirmed — retention cleanup will work."
else
  echo "    [WARN] Could not delete the test object:"
  printf '         %s\n' "$OUT"
  echo "    Backups will still work, but old ones won't be cleaned up,"
  echo "    so storage will grow forever. Add s3:DeleteObject to the key."
  FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All checks passed — this server can store and rotate backups here."
else
  echo "Backups will work, but see the warning above."
fi
exit 0
