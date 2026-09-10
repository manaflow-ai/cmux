#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FAKE_R2_PID=""
stop_fake_r2() {
  if [ -n "${FAKE_R2_PID:-}" ]; then
    kill "$FAKE_R2_PID" 2>/dev/null || true
    wait "$FAKE_R2_PID" 2>/dev/null || true
    FAKE_R2_PID=""
  fi
}
trap 'stop_fake_r2; rm -rf "$TMP_DIR"' EXIT

# Starts tests/fixtures/fake_r2_server.py and waits for its port file.
start_fake_r2() {
  local state="$1"
  shift
  mkdir -p "$state"
  python3 "$ROOT_DIR/tests/fixtures/fake_r2_server.py" --state-dir "$state" "$@" &
  FAKE_R2_PID=$!
  for _ in $(seq 1 200); do
    [ -s "$state/port" ] && return 0
    sleep 0.05
  done
  echo "FAIL: fake R2 server did not start" >&2
  exit 1
}

upload_to_fake_r2() {
  local port="$1"
  local out="$2"
  local err="$3"
  shift 3
  AWS_ACCESS_KEY_ID=AKIDEXAMPLE \
  AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY \
  AWS_DEFAULT_REGION=auto \
  CMUX_R2_UPLOAD_RETRY_DELAY_SECONDS=0 \
  "$@" \
  python3 "$ROOT_DIR/scripts/ci/upload-r2-object.py" \
    --file "$TMP_DIR/appcast.xml" \
    --endpoint-url "http://127.0.0.1:$port" \
    --bucket cmux-binaries \
    --key nightly/appcast.xml \
    --cache-control "no-cache, no-store, must-revalidate" >"$out" 2>"$err"
}

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

# On 2026-09-06 R2 answered the first appcast PutObject with an instant
# HTTP 500 InternalError twice, 49 minutes apart, and each time the whole
# nightly publish died after the DMGs were already on the GitHub release.
# One transient 5xx must be retried, not fatal.
STATE="$TMP_DIR/transient"
start_fake_r2 "$STATE" --fail-first 2
PORT="$(cat "$STATE/port")"
set +e
upload_to_fake_r2 "$PORT" "$TMP_DIR/transient.out" "$TMP_DIR/transient.err" env
rc=$?
set -e
stop_fake_r2
if [ "$rc" -ne 0 ]; then
  echo "FAIL: uploader gave up on a transient R2 InternalError (exit $rc)" >&2
  cat "$TMP_DIR/transient.err" >&2
  exit 1
fi
PUTS="$(cat "$STATE/put-count")"
if [ "$PUTS" != "3" ]; then
  echo "FAIL: expected 3 PUT attempts (two InternalErrors, then success), saw $PUTS" >&2
  exit 1
fi
if ! grep -q "Uploaded" "$TMP_DIR/transient.out"; then
  echo "FAIL: the successful retry was not reported" >&2
  exit 1
fi

# A persistent outage still fails, after a bounded number of attempts, with
# R2's own error body in the output so the workflow log says what happened.
STATE="$TMP_DIR/persistent"
start_fake_r2 "$STATE" --always-fail
PORT="$(cat "$STATE/port")"
set +e
upload_to_fake_r2 "$PORT" "$TMP_DIR/persistent.out" "$TMP_DIR/persistent.err" env CMUX_R2_UPLOAD_MAX_ATTEMPTS=3
rc=$?
set -e
stop_fake_r2
if [ "$rc" -eq 0 ]; then
  echo "FAIL: uploader must fail when R2 keeps returning InternalError" >&2
  exit 1
fi
PUTS="$(cat "$STATE/put-count")"
if [ "$PUTS" != "3" ]; then
  echo "FAIL: expected exactly 3 bounded attempts, saw $PUTS" >&2
  exit 1
fi
if ! grep -q "InternalError" "$TMP_DIR/persistent.err"; then
  echo "FAIL: R2's error body must be surfaced on the final failure" >&2
  cat "$TMP_DIR/persistent.err" >&2
  exit 1
fi
echo "PASS: Python R2 uploader retries transient InternalError and bounds a persistent one"

