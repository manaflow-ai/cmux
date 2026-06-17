#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

LOCK_DIR="$TMP_DIR/cmux-ci-app-host-xcodebuild.lock"
mkdir "$LOCK_DIR"
{
  printf 'created_at=%s\n' "$(date +%s)"
  printf 'token=preheld\n'
  printf 'host=test\n'
  printf 'run_id=test\n'
  printf 'job=test\n'
  printf 'pid=%s\n' "$$"
} > "$LOCK_DIR/metadata"
printf 'preheld\n' > "$LOCK_DIR/token"

cat > "$TMP_DIR/xcodebuild" <<'SH'
#!/usr/bin/env bash
echo "SocketControlServer: Listening on /tmp/cmux-debug-ci-lock-test.sock"
SH
chmod +x "$TMP_DIR/xcodebuild"

PATH="$TMP_DIR:$PATH" \
RUNNER_TEMP="$TMP_DIR" \
CMUX_APP_HOST_XCODEBUILD_LOCK_DIR="$LOCK_DIR" \
CMUX_APP_HOST_XCODEBUILD_LOCK_TIMEOUT_SECONDS=5 \
CMUX_APP_HOST_XCODEBUILD_LOCK_POLL_SECONDS=0.1 \
  bash "$ROOT_DIR/scripts/ci/run-app-host-xcodebuild.sh" test >"$TMP_DIR/output.log" 2>&1 &
wrapper_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -Fq "Waiting for app-host xcodebuild lock" "$TMP_DIR/output.log"; then
    break
  fi
  sleep 0.1
done

if ! grep -Fq "Waiting for app-host xcodebuild lock" "$TMP_DIR/output.log"; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper did not wait for a held app-host xcodebuild lock"
  exit 1
fi

rm -rf "$LOCK_DIR"
wait "$wrapper_pid"

if ! grep -Fq "Acquired app-host xcodebuild lock" "$TMP_DIR/output.log"; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper did not acquire the app-host xcodebuild lock after it was released"
  exit 1
fi

if [ -e "$LOCK_DIR" ]; then
  cat "$TMP_DIR/output.log"
  echo "FAIL: wrapper did not release the app-host xcodebuild lock"
  exit 1
fi

echo "PASS: app-host xcodebuild wrapper waits for and releases host lock"
