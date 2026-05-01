#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/zig-build-env.sh"
DAEMON_DIR="$ROOT/daemon/remote/zig"

if ! command -v expect >/dev/null 2>&1; then
  echo "ERROR: expect is required"
  exit 1
fi

if ! command -v nc >/dev/null 2>&1; then
  echo "ERROR: nc is required"
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/cmux-session-cli.XXXXXX)"
SOCKET_PATH="$TMP_DIR/cmuxd.sock"
DAEMON_LOG="$TMP_DIR/daemon.log"
EXPECT_SCRIPT="$TMP_DIR/attach.expect"
ATTACH_ONE_LOG="$TMP_DIR/attach1.log"
ATTACH_TWO_LOG="$TMP_DIR/attach2.log"

cleanup() {
  if [[ -n "${DAEMON_PID:-}" ]]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
    wait "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "=== Build Zig daemon ==="
(
  cd "$DAEMON_DIR"
  cmux_run_zig build -Doptimize=ReleaseFast >/dev/null
)

BIN="$DAEMON_DIR/zig-out/bin/cmuxd-remote"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: daemon binary missing at $BIN"
  exit 1
fi

echo "=== Start daemon ==="
"$BIN" serve --unix --socket "$SOCKET_PATH" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 100); do
  [[ -S "$SOCKET_PATH" ]] && break
  sleep 0.05
done
if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "ERROR: socket not ready at $SOCKET_PATH"
  cat "$DAEMON_LOG" || true
  exit 1
fi

echo "=== Create detached session ==="
NEW_OUTPUT="$("$BIN" session new dev --socket "$SOCKET_PATH" --detached -- cat)"
printf '%s\n' "$NEW_OUTPUT"
if [[ "$NEW_OUTPUT" != "dev" ]]; then
  echo "ERROR: expected session new to print dev"
  exit 1
fi

echo "=== List sessions ==="
LIST_OUTPUT="$("$BIN" session ls --socket "$SOCKET_PATH")"
printf '%s\n' "$LIST_OUTPUT"
if [[ "$LIST_OUTPUT" != *"dev"* ]]; then
  echo "ERROR: session ls missing dev"
  exit 1
fi

echo "=== Seed known output ==="
printf '%s\n' '{"id":"1","method":"terminal.write","params":{"session_id":"dev","data":"aGVsbG8K"}}' | nc -U "$SOCKET_PATH" >/dev/null
printf '%s\n' '{"id":"2","method":"terminal.read","params":{"session_id":"dev","offset":0,"max_bytes":1024,"timeout_ms":1000}}' | nc -U "$SOCKET_PATH" >/dev/null

cat >"$EXPECT_SCRIPT" <<'EOF'
log_user 0
set timeout 5
set bin [lindex $argv 0]
set sock [lindex $argv 1]
set attach_one_log [lindex $argv 2]
set attach_two_log [lindex $argv 3]

spawn -noecho $bin session attach dev --socket $sock
send -- "again\r"
expect {
  -re {again} {}
  timeout { exit 11 }
  eof { exit 12 }
}
send -- "\034"
expect eof
set f1 [open $attach_one_log w]
puts -nonewline $f1 $expect_out(buffer)
close $f1

spawn -noecho $bin session attach dev --socket $sock
expect {
  -re {hello} {}
  timeout { exit 21 }
  eof { exit 22 }
}
send -- "\034"
expect eof
set f2 [open $attach_two_log w]
puts -nonewline $f2 $expect_out(buffer)
close $f2
EOF

echo "=== Attach, type, detach, reattach ==="
expect "$EXPECT_SCRIPT" "$BIN" "$SOCKET_PATH" "$ATTACH_ONE_LOG" "$ATTACH_TWO_LOG"
echo "--- first attach ---"
cat "$ATTACH_ONE_LOG"
echo
echo "--- second attach ---"
cat "$ATTACH_TWO_LOG"
echo

echo "=== Session history ==="
HISTORY_OUTPUT="$("$BIN" session history dev --socket "$SOCKET_PATH")"
printf '%s\n' "$HISTORY_OUTPUT"
if [[ "$HISTORY_OUTPUT" != *"hello"* ]]; then
  echo "ERROR: session history missing hello"
  exit 1
fi

echo "=== Session status ==="
STATUS_OUTPUT="$("$BIN" session status dev --socket "$SOCKET_PATH")"
printf '%s\n' "$STATUS_OUTPUT"
if [[ "$STATUS_OUTPUT" != dev* ]]; then
  echo "ERROR: session status missing dev"
  exit 1
fi

echo "=== Kill session ==="
KILL_OUTPUT="$("$BIN" session kill dev --socket "$SOCKET_PATH")"
printf '%s\n' "$KILL_OUTPUT"
if [[ "$KILL_OUTPUT" != "dev" ]]; then
  echo "ERROR: session kill did not return dev"
  exit 1
fi

echo "=== Verify session removed ==="
LIST_AFTER_KILL="$("$BIN" session ls --socket "$SOCKET_PATH" || true)"
printf '%s\n' "$LIST_AFTER_KILL"
if [[ -n "$LIST_AFTER_KILL" ]]; then
  echo "ERROR: expected no sessions after kill"
  exit 1
fi

echo "=== verify-remote-session-cli passed ==="
