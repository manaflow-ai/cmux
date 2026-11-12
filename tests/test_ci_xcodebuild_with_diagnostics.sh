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
if [[ -n "${FAKE_XCODEBUILD_DELAY:-}" ]]; then
  python3 -c 'import os, time; time.sleep(float(os.environ["FAKE_XCODEBUILD_DELAY"]))'
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

for invalid_interval in 0 0.0 00; do
  if CMUX_XCODEBUILD_HEARTBEAT_SECONDS="$invalid_interval" \
    "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/invalid.log" 2>&1; then
    echo "FAIL: heartbeat interval $invalid_interval must be rejected" >&2
    exit 1
  fi
done

: >"$TMP_DIR/heartbeat.log"
FAKE_XCODEBUILD_DELAY=0.3 \
  CMUX_XCODEBUILD_HEARTBEAT_SECONDS=0.05 \
  "$WRAPPER" -- "$TMP_DIR/fake-xcodebuild.sh" -scheme cmux >"$TMP_DIR/heartbeat.log" 2>&1 &
wrapper_pid=$!
for _ in {1..500}; do
  if grep -Fq 'xcodebuild heartbeat:' "$TMP_DIR/heartbeat.log"; then
    break
  fi
  sleep 0.02
done
if ! grep -Fq 'xcodebuild heartbeat:' "$TMP_DIR/heartbeat.log"; then
  kill "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true
  echo "FAIL: wrapper must emit a heartbeat while xcodebuild is quiet" >&2
  exit 1
fi
if ! wait "$wrapper_pid"; then
  echo "FAIL: heartbeat test command should complete successfully" >&2
  exit 1
fi

cat >"$TMP_DIR/fake-descendant.sh" <<'EOF'
#!/usr/bin/env bash
descendant_marker="${FAKE_DESCENDANT_MARKER:?}"
(
  trap '' INT TERM
  while :; do sleep 1; done
) &
printf '%s\n' "$!" >"$descendant_marker"
trap 'exit 0' INT TERM
while :; do sleep 1; done
EOF
chmod +x "$TMP_DIR/fake-descendant.sh"
: >"$TMP_DIR/descendant.log"
FAKE_DESCENDANT_MARKER="$TMP_DIR/descendant.pid" \
  CMUX_XCODEBUILD_HEARTBEAT_SECONDS=0.05 \
  "$WRAPPER" -- "$TMP_DIR/fake-descendant.sh" >"$TMP_DIR/descendant.log" 2>&1 &
wrapper_pid=$!
for _ in {1..500}; do
  if [[ -s "$TMP_DIR/descendant.pid" ]]; then
    break
  fi
  sleep 0.02
done
if [[ ! -s "$TMP_DIR/descendant.pid" ]]; then
  kill -TERM "$wrapper_pid" 2>/dev/null || true
  wait "$wrapper_pid" 2>/dev/null || true
  echo "FAIL: cancellation fixture did not start its descendant" >&2
  exit 1
fi
descendant_pid="$(cat "$TMP_DIR/descendant.pid")"
kill -TERM "$wrapper_pid"
wait "$wrapper_pid" 2>/dev/null || true
if kill -0 "$descendant_pid" 2>/dev/null \
  && ! ps -p "$descendant_pid" -o state= 2>/dev/null | grep -q 'Z'; then
  kill -KILL "$descendant_pid" 2>/dev/null || true
  echo "FAIL: cancellation must reap descendants that ignore SIGTERM" >&2
  exit 1
fi

echo "PASS: xcodebuild failures retain diagnostics and quiet builds emit heartbeats"
