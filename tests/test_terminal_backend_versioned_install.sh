#!/usr/bin/env bash

set -euo pipefail

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-versioned-backend.XXXXXX")"
BACKEND_PID=""
WORKER_PID_FILE="$TEST_ROOT/worker.pid"
RENDER_LOG="$TEST_ROOT/render.log"
BUILD_V1="1111111111111111111111111111111111111111111111111111111111111111"
BUILD_V2="2222222222222222222222222222222222222222222222222222222222222222"
VERSIONS="$TEST_ROOT/Application Support/cmux/terminal-backend/com.cmuxterm.test/versions"
LAUNCH_PLIST="$TEST_ROOT/Library/LaunchAgents/com.cmuxterm.test.terminal-backend.plist"

stop_backend() {
  [[ -n "$BACKEND_PID" ]] || return 0
  kill -TERM "$BACKEND_PID" 2>/dev/null || true
  wait "$BACKEND_PID" 2>/dev/null || true
  BACKEND_PID=""
}

cleanup() {
  stop_backend
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

make_pair() {
  local build_id="$1"
  local version="$2"
  local directory="$VERSIONS/$build_id"
  mkdir -p "$directory"
  cat > "$directory/cmux-terminal-backend" <<'BACKEND'
#!/usr/bin/env bash
set -u
directory="$(cd "$(dirname "$0")" && pwd)"
worker=""
stop() {
  [[ -n "$worker" ]] && kill -TERM "$worker" 2>/dev/null || true
  exit 0
}
trap stop TERM INT
while true; do
  "$directory/cmux-terminal-renderer" "$CMUX_TEST_RENDER_LOG" &
  worker=$!
  printf '%s\n' "$worker" > "$CMUX_TEST_WORKER_PID_FILE"
  wait "$worker" 2>/dev/null || true
done
BACKEND
  cat > "$directory/cmux-terminal-renderer" <<RENDERER
#!/usr/bin/env bash
printf '%s\n' '$version' >> "\$1"
exec /usr/bin/tail -f /dev/null
RENDERER
  printf '%s\n' "$build_id" > "$directory/cmux-terminal-backend.build-id"
  printf '%s\n' "$build_id" > "$directory/cmux-terminal-renderer.build-id"
  chmod 0500 "$directory/cmux-terminal-backend" "$directory/cmux-terminal-renderer"
  chmod 0400 "$directory/cmux-terminal-backend.build-id" "$directory/cmux-terminal-renderer.build-id"
  chmod 0700 "$directory"
}

write_launch_descriptor() {
  local build_id="$1"
  local program="$VERSIONS/$build_id/cmux-terminal-backend"
  mkdir -p "$(dirname "$LAUNCH_PLIST")"
  cat > "$LAUNCH_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.cmuxterm.test.terminal-backend</string>
  <key>Program</key><string>$program</string>
  <key>ProgramArguments</key><array><string>$program</string></array>
</dict></plist>
PLIST
  chmod 0600 "$LAUNCH_PLIST"
}

start_descriptor() {
  local program
  program="$(/usr/libexec/PlistBuddy -c 'Print :Program' "$LAUNCH_PLIST")"
  CMUX_TEST_RENDER_LOG="$RENDER_LOG" \
    CMUX_TEST_WORKER_PID_FILE="$WORKER_PID_FILE" \
    "$program" &
  BACKEND_PID=$!
}

wait_for_render_count() {
  local expected="$1"
  local count=0
  for _ in {1..250}; do
    count="$(wc -l < "$RENDER_LOG" 2>/dev/null || true)"
    [[ "$count" -ge "$expected" ]] && return 0
    kill -0 "$BACKEND_PID" 2>/dev/null || return 1
    sleep 0.02
  done
  return 1
}

mkdir -p "$VERSIONS"
: > "$RENDER_LOG"
chmod 0700 "$TEST_ROOT/Application Support" "$TEST_ROOT/Application Support/cmux" \
  "$TEST_ROOT/Application Support/cmux/terminal-backend" \
  "$TEST_ROOT/Application Support/cmux/terminal-backend/com.cmuxterm.test" \
  "$VERSIONS"
make_pair "$BUILD_V1" v1
write_launch_descriptor "$BUILD_V1"
start_descriptor
wait_for_render_count 1

# Stage an incompatible app/helper update without replacing the loaded descriptor.
make_pair "$BUILD_V2" v2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Program' "$LAUNCH_PLIST")" \
  == "$VERSIONS/$BUILD_V1/cmux-terminal-backend" ]]

# Killing vN's renderer proves the live vN daemon resolves its immutable vN sibling.
worker_pid="$(cat "$WORKER_PID_FILE")"
kill -KILL "$worker_pid"
wait_for_render_count 2
[[ "$(sed -n '1p' "$RENDER_LOG")" == v1 ]]
[[ "$(sed -n '2p' "$RENDER_LOG")" == v1 ]]

# An explicit stopped handoff is the only point where the descriptor moves to vN+1.
stop_backend
write_launch_descriptor "$BUILD_V2"
start_descriptor
wait_for_render_count 3
[[ "$(sed -n '3p' "$RENDER_LOG")" == v2 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Program' "$LAUNCH_PLIST")" \
  == "$VERSIONS/$BUILD_V2/cmux-terminal-backend" ]]

echo "version-pinned terminal backend lifecycle verified"
