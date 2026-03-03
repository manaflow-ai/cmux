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

# --- Check display availability ---
if system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Resolution"; then
  echo "Display: available"
else
  echo "WARNING: No display detected, app may fail to launch"
fi

# --- Clean up stale socket ---
rm -f "$SOCKET_PATH"

# --- Launch the app ---
echo "Launching app..."
open "$APP" --env CMUX_SOCKET_MODE=allowAll

# --- Wait for socket (up to 30s) ---
echo "Waiting for socket at $SOCKET_PATH..."
SOCKET_READY=false
for i in $(seq 1 60); do
  if [ -S "$SOCKET_PATH" ]; then
    echo "Socket ready after $((i / 2))s"
    SOCKET_READY=true
    break
  fi
  sleep 0.5
done
if [ "$SOCKET_READY" != "true" ]; then
  echo "ERROR: Socket not ready after 30s"
  # Dump any crash logs
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

# --- Get app PID ---
APP_PID=$(pgrep -x "cmux DEV" | head -1 || true)
if [ -z "$APP_PID" ]; then
  echo "ERROR: App process not found"
  exit 1
fi
echo "App PID: $APP_PID"

# --- Wait and verify stability ---
echo "Waiting ${STABILITY_WAIT}s to verify stability..."
sleep "$STABILITY_WAIT"

if ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: App crashed during ${STABILITY_WAIT}s stability check"
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
pkill -x "cmux DEV" 2>/dev/null || true
