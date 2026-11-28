#!/usr/bin/env bash
# Smoke test for CI: launch the app, send a command, verify it stays alive for 15 seconds.
set -euo pipefail

SOCKET_PATH="/tmp/cmux-debug.sock"
STABILITY_WAIT=15

echo "=== Smoke Test ==="

# --- Find the built app ---
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/cmux DEV.app" -print -quit 2>/dev/null || true)
if [ -z "$APP" ]; then
  echo "ERROR: Built app not found in DerivedData"
  exit 1
fi
echo "App: $APP"
BINARY="$APP/Contents/MacOS/cmux DEV"
if [ ! -x "$BINARY" ]; then
  echo "ERROR: App binary not found or not executable: $BINARY"
  exit 1
fi

# --- Clean up stale socket and any existing instances ---
rm -f "$SOCKET_PATH"
pkill -x "cmux DEV" 2>/dev/null || true
sleep 1

# --- Launch the app directly (not via `open`, which can silently fail on CI) ---
echo "Launching app..."
CMUX_SOCKET_MODE=allowAll CMUX_UI_TEST_MODE=1 "$BINARY" > /tmp/cmux-smoke-stdout.log 2>&1 &
APP_PID=$!
echo "App PID: $APP_PID"

# --- Verify process is alive after 2s ---
sleep 2
if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App exited immediately after launch"
  echo "--- stdout/stderr ---"
  cat /tmp/cmux-smoke-stdout.log 2>/dev/null | tail -50 || true
  echo "--- debug log ---"
  tail -50 /tmp/cmux-debug.log 2>/dev/null || true
  echo "--- crash reports ---"
  ls -lt ~/Library/Logs/DiagnosticReports/*cmux* 2>/dev/null | head -5 || echo "(none)"
  exit 1
fi

# --- Wait for socket (up to 30s) ---
echo "Waiting for socket at $SOCKET_PATH..."
SOCKET_READY=false
for i in $(seq 1 60); do
  if [ -S "$SOCKET_PATH" ]; then
    echo "Socket ready after $((i / 2))s"
    SOCKET_READY=true
    break
  fi
  # Check if process died while waiting
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "ERROR: App crashed while waiting for socket"
    echo "--- stdout/stderr ---"
    cat /tmp/cmux-smoke-stdout.log 2>/dev/null | tail -50 || true
    echo "--- debug log ---"
    tail -50 /tmp/cmux-debug.log 2>/dev/null || true
    exit 1
  fi
  sleep 0.5
done
if [ "$SOCKET_READY" != "true" ]; then
  echo "ERROR: Socket not ready after 30s"
  echo "--- stdout/stderr ---"
  cat /tmp/cmux-smoke-stdout.log 2>/dev/null | tail -30 || true
  echo "--- debug log ---"
  tail -30 /tmp/cmux-debug.log 2>/dev/null || true
  ls -la /tmp/cmux-debug* 2>/dev/null || true
  pgrep -la "cmux" || echo "No cmux processes found"
  exit 1
fi

# --- Ping the socket ---
echo "Pinging socket..."
PING_RESPONSE=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'ping\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Ping response: $PING_RESPONSE"
if [ "$PING_RESPONSE" != "PONG" ]; then
  echo "ERROR: Expected PONG, got: $PING_RESPONSE"
  exit 1
fi

# --- Send a command to the terminal ---
echo "Sending 'time' command to terminal..."
SEND_RESPONSE=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'send time\\\n\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Send response: $SEND_RESPONSE"

# --- Wait and verify stability ---
echo "Waiting ${STABILITY_WAIT}s to verify stability..."
sleep "$STABILITY_WAIT"

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App crashed during ${STABILITY_WAIT}s stability check"
  echo "--- stdout/stderr ---"
  cat /tmp/cmux-smoke-stdout.log 2>/dev/null | tail -30 || true
  echo "--- debug log ---"
  tail -30 /tmp/cmux-debug.log 2>/dev/null || true
  exit 1
fi

# --- Final ping ---
FINAL_PING=$(python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$SOCKET_PATH')
s.settimeout(5.0)
s.sendall(b'ping\n')
data = s.recv(1024).decode().strip()
s.close()
print(data)
")
echo "Final ping: $FINAL_PING"
if [ "$FINAL_PING" != "PONG" ]; then
  echo "ERROR: App not responsive after ${STABILITY_WAIT}s"
  exit 1
fi

echo "=== Smoke test passed ==="

# --- Cleanup ---
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
