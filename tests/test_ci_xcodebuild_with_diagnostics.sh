#!/usr/bin/env bash
# Exercise the xcodebuild diagnostic wrapper with deterministic fake commands.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$ROOT_DIR/scripts/ci/run-xcodebuild-with-diagnostics.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/fake-xcodebuild.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fake xcodebuild args: %s\n' "$*"
if [[ -n "${FAKE_XCODEBUILD_FIFO:-}" ]]; then
  read -r _ <"$FAKE_XCODEBUILD_FIFO"
fi
exit "${FAKE_XCODEBUILD_STATUS:-0}"
EOF
chmod +x "$TMP_DIR/fake-xcodebuild.sh"

if ! "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/success.log" 2>&1; then
  echo "FAIL: wrapper must preserve a successful xcodebuild exit" >&2
  exit 1
fi
grep -Fq 'xcodebuild exit status: 0' "$TMP_DIR/success.log"
grep -Fq 'fake xcodebuild args: -scheme cmux' "$TMP_DIR/success.log"

set +e
FAKE_XCODEBUILD_STATUS=137 "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/failure.log" 2>&1
status=$?
set -e
if [[ "$status" -ne 137 ]]; then
  echo "FAIL: wrapper must return the xcodebuild status, got $status" >&2
  exit 1
fi
grep -Fq 'xcodebuild exit status: 137' "$TMP_DIR/failure.log"
grep -Fq 'xcodebuild termination: signal=9' "$TMP_DIR/failure.log"
grep -Fq 'resource diagnostics follow' "$TMP_DIR/failure.log"
grep -Fq -- '--- top processes by resident memory ---' "$TMP_DIR/failure.log"

mkfifo "$TMP_DIR/release.fifo"
: >"$TMP_DIR/heartbeat.log"
FAKE_XCODEBUILD_FIFO="$TMP_DIR/release.fifo" \
  CMUX_XCODEBUILD_HEARTBEAT_SECONDS=0.05 \
  "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/heartbeat.log" 2>&1 &
wrapper_pid=$!
for _ in {1..100}; do
  if grep -Fq 'xcodebuild heartbeat:' "$TMP_DIR/heartbeat.log"; then
    break
  fi
  sleep 0.01
done
if ! grep -Fq 'xcodebuild heartbeat:' "$TMP_DIR/heartbeat.log"; then
  kill "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true
  echo "FAIL: wrapper must emit a heartbeat while xcodebuild is quiet" >&2
  exit 1
fi
printf 'release\n' >"$TMP_DIR/release.fifo"
if ! wait "$wrapper_pid"; then
  echo "FAIL: heartbeat test command should complete successfully" >&2
  exit 1
fi

echo "PASS: xcodebuild failures retain diagnostics and quiet builds emit heartbeats"
