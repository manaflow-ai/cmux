#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/cmux-pty-tmux-parity.XXXXXX)"
DAEMON_SOCKET="$TMP_DIR/daemon.sock"
APP_SOCKET="$TMP_DIR/app.sock"
DAEMON_LOG="$TMP_DIR/daemon.log"
FAKE_APP_LOG="$TMP_DIR/fake-app.log"
TMUX_SOCKET="cmux-pty-parity-$$"
TMUX_TMPDIR="$TMP_DIR/tmux"
READY_CAT="$ROOT/daemon/remote/compat/testdata/ready_cat.sh"

cleanup() {
  if [[ -n "${FAKE_APP_PID:-}" ]]; then
    kill "$FAKE_APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DAEMON_PID:-}" ]]; then
    kill "$DAEMON_PID" >/dev/null 2>&1 || true
  fi
  if command -v tmux >/dev/null 2>&1; then
    TMUX_TMPDIR="$TMUX_TMPDIR" tmux -f /dev/null -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found in PATH" >&2
  exit 1
fi

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

mkdir -p "$TMUX_TMPDIR"

DAEMON_BIN="${CMUX_DAEMON_BIN:-$ROOT/daemon/remote/rust/target/debug/cmuxd-remote}"
if [[ -z "${CMUX_DAEMON_BIN:-}" ]]; then
  GHOSTTY_SOURCE_DIR="$ROOT/ghostty" cargo build --manifest-path "$ROOT/daemon/remote/rust/Cargo.toml" >/dev/null
fi
if [[ ! -x "$DAEMON_BIN" ]]; then
  echo "cmuxd-remote binary not found; set CMUX_DAEMON_BIN or build daemon/remote/rust" >&2
  exit 1
fi

"$DAEMON_BIN" serve --unix --socket "$DAEMON_SOCKET" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

python3 - <<'PY' "$DAEMON_SOCKET"
import socket
import sys
import time

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

"$DAEMON_BIN" session new pty-cli --socket "$DAEMON_SOCKET" --quiet --detached -- /bin/sh "$READY_CAT" >/dev/null

python3 - <<'PY' "$APP_SOCKET" "$DAEMON_SOCKET" >"$FAKE_APP_LOG" 2>&1 &
import json
import os
import socket
import sys

app_socket, daemon_socket = sys.argv[1], sys.argv[2]
try:
    os.unlink(app_socket)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(app_socket)
server.listen(8)
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

python3 - <<'PY' "$CLI_BIN" "$APP_SOCKET" "$DAEMON_BIN" "$DAEMON_SOCKET" "$TMUX_SOCKET" "$TMUX_TMPDIR" "$READY_CAT"
import fcntl
import os
import pty
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

cli_bin, app_socket, daemon_bin, daemon_socket, tmux_socket, tmux_tmpdir, ready_cat = sys.argv[1:8]

cmux_env = os.environ.copy()
cmux_env["CMUX_SOCKET_PATH"] = app_socket

tmux_env = os.environ.copy()
tmux_env["TMUX_TMPDIR"] = tmux_tmpdir
# Use a conservative TERM value so the tmux side works on minimal test hosts.
tmux_env["TERM"] = "vt100"

tmux_bin = shutil.which("tmux")
if not tmux_bin:
    raise SystemExit("tmux not found in PATH")
tmux_base = [tmux_bin, "-f", "/dev/null", "-L", tmux_socket]


def run_tmux(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(tmux_base + list(args), capture_output=True, text=True, env=tmux_env, check=True)


def daemon_history() -> str:
    return subprocess.run(
        [daemon_bin, "session", "history", "pty-cli", "--socket", daemon_socket],
        text=True,
        capture_output=True,
        check=True,
    ).stdout


def daemon_status() -> str:
    return subprocess.run(
        [daemon_bin, "session", "status", "pty-cli", "--socket", daemon_socket],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def tmux_pane_size() -> str:
    return run_tmux("display-message", "-p", "-t", "pty-parity:0.0", "#{pane_width}x#{pane_height}").stdout.strip()


def start_attach(argv, env):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    return pid, fd


def pump(fd: int, capture: bytearray, timeout: float = 0.2) -> bytes:
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        return b""
    chunk = os.read(fd, 65536)
    capture.extend(chunk)
    return chunk


def wait_for_capture(fd: int, capture: bytearray, token: bytes, timeout: float, label: str):
    deadline = time.time() + timeout
    while time.time() < deadline:
        pump(fd, capture)
        if token in capture:
            return
    raise SystemExit(f"{label} never showed {token!r}: {capture.decode('utf-8', 'replace')}")


def assert_contains(capture: bytearray, token: str, label: str):
    text = capture.decode("utf-8", "replace")
    if token not in text:
        raise SystemExit(f"{label} missing {token!r}: {text!r}")


def wait_for(pred, timeout: float, label: str):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.05)
    raise SystemExit(f"Timed out waiting for {label}")


def ensure_alive(pid: int, label: str, capture: bytearray):
    done, status = os.waitpid(pid, os.WNOHANG)
    if done == 0:
        return
    text = capture.decode("utf-8", "replace")
    if os.WIFSIGNALED(status):
        raise SystemExit(f"{label} exited by signal {os.WTERMSIG(status)}: {text!r}")
    code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else status
    raise SystemExit(f"{label} exited early with status {code}: {text!r}")


def write_one(fd: int, data: bytes, pid: int, label: str, capture: bytearray):
    try:
        os.write(fd, data)
    except OSError as exc:
        ensure_alive(pid, label, capture)
        raise SystemExit(f"{label} write failed: {exc}")


def write_both(data: bytes):
    write_one(cmux_fd, data, cmux_pid, "cmux pty", cmux_capture)
    write_one(tmux_fd, data, tmux_pid, "tmux attach", tmux_capture)


run_tmux("new-session", "-d", "-s", "pty-parity", "/bin/sh", ready_cat)
run_tmux("set-option", "-t", "pty-parity", "status", "off")
wait_for(
    lambda: "READY" in run_tmux("capture-pane", "-p", "-t", "pty-parity:0.0", "-S", "-20").stdout,
    5.0,
    "tmux READY in pane history",
)

cmux_pid, cmux_fd = start_attach([cli_bin, "pty", "--workspace", "workspace:1", "--surface", "surface:1"], cmux_env)
tmux_pid, tmux_fd = start_attach(tmux_base + ["attach", "-t", "pty-parity"], tmux_env)

cmux_capture = bytearray()
tmux_capture = bytearray()

deadline = time.time() + 10.0
while time.time() < deadline:
    pump(cmux_fd, cmux_capture, 0.05)
    pump(tmux_fd, tmux_capture, 0.05)
    ensure_alive(cmux_pid, "cmux pty", cmux_capture)
    ensure_alive(tmux_pid, "tmux attach", tmux_capture)
    if b"READY" in cmux_capture:
        break
else:
    raise SystemExit(f"cmux pty never showed b'READY': {cmux_capture.decode('utf-8', 'replace')}")

write_both(b"parity-hello\n")
wait_for_capture(cmux_fd, cmux_capture, b"parity-hello", 5.0, "cmux pty")
wait_for_capture(tmux_fd, tmux_capture, b"parity-hello", 5.0, "tmux attach")

# Fragmented OSC 11 query bytes. This reproduces the short-buffer path
# that previously caused a crash/infinite loop in cmux's terminal surface path.
for frag in (b"\x1b", b"]", b"1", b"1", b";", b"?", b"\x07"):
    write_both(frag)
    time.sleep(0.02)
write_both(b"frag-ok\n")

wait_for_capture(cmux_fd, cmux_capture, b"frag-ok", 5.0, "cmux pty after fragmented osc")
wait_for_capture(tmux_fd, tmux_capture, b"frag-ok", 5.0, "tmux attach after fragmented osc")

wait_for(lambda: "parity-hello" in daemon_history() and "frag-ok" in daemon_history(), 5.0, "daemon history tokens")

fcntl.ioctl(cmux_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 91, 0, 0))
fcntl.ioctl(tmux_fd, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 91, 0, 0))

wait_for(lambda: daemon_status().endswith("91x31"), 5.0, "cmux daemon resize")
wait_for(lambda: tmux_pane_size() == "91x31", 5.0, "tmux pane resize")

for token in ("parity-hello", "frag-ok"):
    assert_contains(cmux_capture, token, "cmux transcript")
    assert_contains(tmux_capture, token, "tmux transcript")

subprocess.run([daemon_bin, "session", "kill", "pty-cli", "--socket", daemon_socket], check=True, capture_output=True)
run_tmux("kill-session", "-t", "pty-parity")

def wait_for_exit(pid: int, label: str):
    deadline = time.time() + 5
    while time.time() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == 0:
            time.sleep(0.05)
            continue
        if os.WIFSIGNALED(status):
            raise SystemExit(f"{label} terminated by signal {os.WTERMSIG(status)}")
        return os.WEXITSTATUS(status) if os.WIFEXITED(status) else 0
    raise SystemExit(f"{label} did not exit")

cmux_exit = wait_for_exit(cmux_pid, "cmux pty")
tmux_exit = wait_for_exit(tmux_pid, "tmux attach")

if cmux_exit != 0:
    raise SystemExit(f"cmux pty exited with status {cmux_exit}")
if tmux_exit not in (0, 1):
    raise SystemExit(f"tmux attach exited with unexpected status {tmux_exit}")

print(
    {
        "cmux_exit": cmux_exit,
        "tmux_exit": tmux_exit,
        "daemon_status": "91x31",
        "tmux_status": "91x31",
        "tokens": ["parity-hello", "frag-ok"],
    }
)
PY
