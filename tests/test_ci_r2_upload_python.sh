#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

printf '<rss>ok</rss>' >"$TMP_DIR/appcast.xml"

python3 -m py_compile "$ROOT_DIR/scripts/ci/upload-r2-object.py"

AWS_ACCESS_KEY_ID=AKIDEXAMPLE \
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY \
AWS_DEFAULT_REGION=auto \
CMUX_R2_UPLOAD_AMZ_DATE=20260102T030405Z \
python3 "$ROOT_DIR/scripts/ci/upload-r2-object.py" \
  --file "$TMP_DIR/appcast.xml" \
  --endpoint-url "https://example-account.r2.cloudflarestorage.com" \
  --bucket cmux-binaries \
  --key nightly/appcast.xml \
  --cache-control "no-cache, no-store, must-revalidate" \
  --dry-run-json >"$TMP_DIR/request.json"

python3 - "$TMP_DIR/request.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as file:
    request = json.load(file)

headers = {key.lower(): value for key, value in request["headers"].items()}
authorization = headers.get("authorization", "")

assert request["method"] == "PUT", request
assert request["url"] == "https://example-account.r2.cloudflarestorage.com/cmux-binaries/nightly/appcast.xml", request
assert headers["cache-control"] == "no-cache, no-store, must-revalidate", headers
assert headers["x-amz-date"] == "20260102T030405Z", headers
assert "Credential=AKIDEXAMPLE/20260102/auto/s3/aws4_request" in authorization, authorization
assert "SignedHeaders=cache-control;host;x-amz-content-sha256;x-amz-date" in authorization, authorization
assert len(headers["x-amz-content-sha256"]) == 64, headers
PY

if grep -R "resolve-aws-cli.sh" "$ROOT_DIR/.github/workflows/nightly.yml" "$ROOT_DIR/.github/workflows/release.yml"; then
  echo "FAIL: appcast R2 uploads must not depend on an AWS CLI resolver"
  exit 1
fi

if ! grep -Fq "scripts/ci/upload-r2-object.py" "$ROOT_DIR/.github/workflows/nightly.yml"; then
  echo "FAIL: nightly workflow must use the Python R2 uploader"
  exit 1
fi
if ! grep -Fq "scripts/ci/upload-r2-object.py" "$ROOT_DIR/.github/workflows/release.yml"; then
  echo "FAIL: release workflow must use the Python R2 uploader"
  exit 1
fi

echo "PASS: Python R2 uploader signs appcast uploads without awscli"
