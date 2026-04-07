#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/cmux-pty-cli.XXXXXX)"
DAEMON_SOCKET="$TMP_DIR/daemon.sock"
APP_SOCKET="$TMP_DIR/app.sock"
DAEMON_LOG="$TMP_DIR/daemon.log"
FAKE_APP_LOG="$TMP_DIR/fake-app.log"

cleanup() {
  if [[ -n "${FAKE_APP_PID:-}" ]]; then
    kill "$FAKE_APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DAEMON_PID:-}" ]]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

CLI_BIN="${CMUX_CLI_BIN:-}"
if [[ -z "$CLI_BIN" ]]; then
  CLI_BIN="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/cmux" -exec stat -f '%m %N' {} \; \
      | sort -nr \
      | head -1 \
      | cut -d' ' -f2-
  )"
fi

if [[ -z "$CLI_BIN" || ! -x "$CLI_BIN" ]]; then
  echo "cmux CLI binary not found; set CMUX_CLI_BIN" >&2
  exit 1
fi

GHOSTTY_SOURCE_DIR="$ROOT/ghostty" cargo build --manifest-path "$ROOT/daemon/remote/rust/Cargo.toml" >/dev/null
DAEMON_BIN="$ROOT/daemon/remote/rust/target/debug/cmuxd-remote"

"$DAEMON_BIN" serve --unix --socket "$DAEMON_SOCKET" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

python3 - <<'PY' "$DAEMON_SOCKET"
import socket, sys, time
path = sys.argv[1]
deadline = time.time() + 10
while time.time() < deadline:
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        sock.close()
        raise SystemExit(0)
    except OSError:
        time.sleep(0.05)
raise SystemExit("daemon socket did not become ready")
PY

"$DAEMON_BIN" session new pty-cli --socket "$DAEMON_SOCKET" --quiet --detached -- /bin/sh "$ROOT/daemon/remote/compat/testdata/ready_cat.sh" >/dev/null

python3 - <<'PY' "$APP_SOCKET" "$DAEMON_SOCKET" >"$FAKE_APP_LOG" 2>&1 &
import json, os, socket, sys
app_socket, daemon_socket = sys.argv[1], sys.argv[2]
try:
    os.unlink(app_socket)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(app_socket)
server.listen(4)
while True:
    conn, _ = server.accept()
    with conn:
        file = conn.makefile("rwb")
        while True:
            line = file.readline()
            if not line:
                break
            req = json.loads(line.decode("utf-8"))
            method = req.get("method")
            if method == "surface.daemon_info":
                resp = {
                    "id": req.get("id"),
                    "ok": True,
                    "result": {
                        "socket_path": daemon_socket,
                        "session_id": "pty-cli",
                        "workspace_id": "workspace:1",
                        "surface_id": "surface:1",
                    },
                }
            else:
                resp = {
                    "id": req.get("id"),
                    "ok": False,
                    "error": {"code": "method_not_found", "message": method or ""},
                }
            file.write((json.dumps(resp) + "\n").encode("utf-8"))
            file.flush()
PY
FAKE_APP_PID=$!

python3 - <<'PY' "$CLI_BIN" "$APP_SOCKET" "$DAEMON_BIN" "$DAEMON_SOCKET"
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time

cli_bin, app_socket, daemon_bin, daemon_socket = sys.argv[1:5]
env = os.environ.copy()
env["CMUX_SOCKET_PATH"] = app_socket

def daemon_history():
    return subprocess.run(
        [daemon_bin, "session", "history", "pty-cli", "--socket", daemon_socket],
        text=True,
        capture_output=True,
        check=True,
    ).stdout

def daemon_status():
    return subprocess.run(
        [daemon_bin, "session", "status", "pty-cli", "--socket", daemon_socket],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()

pid, fd = pty.fork()
if pid == 0:
    os.execve(
        cli_bin,
        [cli_bin, "pty", "--workspace", "workspace:1", "--surface", "surface:1"],
        env,
    )

capture = bytearray()

def pump(timeout=0.2):
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        return b""
    chunk = os.read(fd, 65536)
    capture.extend(chunk)
    return chunk

deadline = time.time() + 10
while time.time() < deadline:
    pump()
    if b"READY" in capture:
        break
else:
    raise SystemExit(f"cmux pty never showed READY: {capture.decode('utf-8', 'replace')}")

os.write(fd, b"bridge-ok\n")
deadline = time.time() + 5
while time.time() < deadline:
    if "bridge-ok" in daemon_history():
        break
    time.sleep(0.05)
else:
    raise SystemExit("cmux pty write never reached daemon history")

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 91, 0, 0))
deadline = time.time() + 5
while time.time() < deadline:
    if daemon_status().endswith("91x31"):
        break
    time.sleep(0.05)
else:
    raise SystemExit(f"cmux pty resize never reached daemon status: {daemon_status()}")

subprocess.run([daemon_bin, "session", "kill", "pty-cli", "--socket", daemon_socket], check=True, capture_output=True)
_, status = os.waitpid(pid, 0)
if status != 0:
    raise SystemExit(f"cmux pty exited with status {status}")

print({"history_contains_bridge_ok": True, "status": "91x31", "exit_status": status})
PY
