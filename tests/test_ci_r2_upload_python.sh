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

# Transient R2 failures (HTTP 5xx, 429, connection errors) must be retried
# with backoff. R2 documents InternalError as "please try again"; nightly runs
# 34020074283, 34022099394, and 34023000234 all died on one such PUT.
cat >"$TMP_DIR/fake_r2.py" <<'FAKE'
import http.server
import sys

PORT = int(sys.argv[1])
FAIL_FIRST = int(sys.argv[2])
COUNT_FILE = sys.argv[3]
seen = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_PUT(self):
        global seen
        seen += 1
        with open(COUNT_FILE, "w", encoding="utf-8") as file:
            file.write(str(seen))
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if seen <= FAIL_FIRST:
            payload = b'<?xml version="1.0"?><Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>'
            self.send_response(500)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        assert body == b"<rss>ok</rss>", body
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
server.serve_forever()
FAKE

start_fake_r2() {
  local fail_first="$1" count_file="$2"
  FAKE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  python3 "$TMP_DIR/fake_r2.py" "$FAKE_PORT" "$fail_first" "$count_file" &
  FAKE_PID=$!
  for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',$FAKE_PORT))==0 else 1)"; then
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: fake R2 server did not start" >&2
  exit 1
}

stop_fake_r2() {
  kill "$FAKE_PID" 2>/dev/null || true
  wait "$FAKE_PID" 2>/dev/null || true
}

run_upload() {
  AWS_ACCESS_KEY_ID=AKIDEXAMPLE \
  AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY \
  AWS_DEFAULT_REGION=auto \
  CMUX_R2_UPLOAD_MAX_ATTEMPTS=4 \
  CMUX_R2_UPLOAD_RETRY_BASE_SECONDS=0.01 \
  python3 "$ROOT_DIR/scripts/ci/upload-r2-object.py" \
    --file "$TMP_DIR/appcast.xml" \
    --endpoint-url "http://127.0.0.1:$FAKE_PORT" \
    --bucket cmux-binaries \
    --key nightly/appcast.xml \
    --cache-control "no-cache, no-store, must-revalidate"
}

# Two InternalErrors, then success: the upload must succeed on the third PUT.
start_fake_r2 2 "$TMP_DIR/count-recover"
if ! run_upload >"$TMP_DIR/recover.log" 2>&1; then
  cat "$TMP_DIR/recover.log"
  stop_fake_r2
  echo "FAIL: uploader gave up on a transient HTTP 500"
  exit 1
fi
stop_fake_r2
[ "$(cat "$TMP_DIR/count-recover")" = "3" ] || { echo "FAIL: expected 3 PUT attempts, got $(cat "$TMP_DIR/count-recover")"; exit 1; }
grep -q "retrying" "$TMP_DIR/recover.log" || { cat "$TMP_DIR/recover.log"; echo "FAIL: retries must be logged"; exit 1; }

# Persistent InternalError: the upload must stop after the attempt budget.
start_fake_r2 1000 "$TMP_DIR/count-giveup"
if run_upload >"$TMP_DIR/giveup.log" 2>&1; then
  stop_fake_r2
  echo "FAIL: uploader reported success while R2 kept failing"
  exit 1
fi
stop_fake_r2
[ "$(cat "$TMP_DIR/count-giveup")" = "4" ] || { echo "FAIL: expected 4 PUT attempts, got $(cat "$TMP_DIR/count-giveup")"; exit 1; }
grep -q "HTTP 500" "$TMP_DIR/giveup.log" || { cat "$TMP_DIR/giveup.log"; echo "FAIL: final error must name the HTTP status"; exit 1; }

echo "PASS: Python R2 uploader retries transient failures and gives up after the attempt budget"
echo "PASS: Python R2 uploader signs appcast uploads without awscli"
