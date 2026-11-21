#!/usr/bin/env bash
# dev-slot.sh up, run the way an agent's one-shot shell runs it, in a hostile environment:
#   1. the slot folder is 700 under a umask of 002;
#   2. no acpmux the script runs sees an inherited ACPMUX_* variable, the daemon serves the
#      slot's own socket, and nothing connects to the caller's ACPMUX_SOCKET;
#   3. the daemon and Vite outlive the caller's shell and a signal to its process group;
#   4. the slot's daemon answers the agent pane's WebSocket handshake with the slot's token.
# The acpmux is $DEV_SLOT_TEST_ACPMUX (`stub` for the stub), else `acpmux` on PATH, else a stub that speaks the
# handshake; `bun` is a stub that serves the Vite port. Everything lives in one mktemp folder,
# and only the processes this test started are stopped, by pid.
#
#   webviews/scripts/agent-pane/dev-slot.test.sh
# shellcheck disable=SC2016 # the checks are single-quoted expressions check() evaluates
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/dev-slot.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dev-slot-test.XXXXXX")"
# Short: the slot's socket path must fit sun_path.
root="$(mktemp -d /tmp/dst.XXXXXX)"
pids=()
slot=""

# shellcheck disable=SC2317,SC2329 # run by the trap below
cleanup() {
  if [[ -n "$slot" ]]; then
    CMUX_DEV_SLOT_ROOT="$root" ACPMUX_BIN="$tmp/bin/acpmux" PATH="$tmp/bin:$PATH" \
      "$script" down "$slot" >/dev/null 2>&1 || true
  fi
  for file in "$root/acpdev-$slot/daemon.pid" "$root/acpdev-$slot/vite.pid"; do
    [[ -f "$file" ]] && pids+=("$(cat "$file")")
  done
  for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$tmp" "$root"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
port_free() { ! nc -z 127.0.0.1 "$1" 2>/dev/null; }

for n in $(seq 91 99); do
  if port_free $((47900 + n)) && port_free $((4180 + n)); then slot="$n"; break; fi
done
[[ -n "$slot" ]] || fail "no slot 91-99 has both ports free"
home="$root/acpdev-$slot"

mkdir -p "$tmp/bin"
real="${DEV_SLOT_TEST_ACPMUX:-$(command -v acpmux || true)}"
if [[ -z "$real" || "$real" == stub ]]; then
  # No acpmux here: a stub daemon that binds $ACPMUX_SOCKET and answers the browser handshake
  # (ws_auth.rs: subprotocols acpmux.v1 and acpmux.token.<token>) with 101 only for its token.
  real="$tmp/stub-acpmux"
  cat >"$real" <<'PY'
#!/usr/bin/env python3
import os, socket, sys, threading
args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("acpmux 0.0.0-stub"); sys.exit(0)
if args[:2] != ["daemon", "run"] or "--help" in args:
    sys.exit(0)
listen, token = args[args.index("--listen") + 1], args[args.index("--token") + 1]
unix = socket.socket(socket.AF_UNIX); unix.bind(os.environ["ACPMUX_SOCKET"]); unix.listen()
host, port = listen.rsplit(":", 1)
tcp = socket.socket(); tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
tcp.bind((host, int(port))); tcp.listen()
threading.Thread(target=lambda: [unix.accept()[0].close() for _ in iter(int, 1)], daemon=True).start()
while True:
    conn, _ = tcp.accept()
    request = conn.recv(4096).decode(errors="replace")
    ok = f"acpmux.token.{token}" in request and "acpmux.v1" in request
    conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Protocol: acpmux.v1\r\n\r\n" if ok
                 else b"HTTP/1.1 401 Unauthorized\r\n\r\n")
    conn.close()
PY
  chmod +x "$real"
fi
# Every acpmux the script runs records its ACPMUX_* environment, then runs the real one.
cat >"$tmp/bin/acpmux" <<SH
#!/usr/bin/env bash
{ echo "argv: \$*"; env | grep '^ACPMUX_' || true; echo; } >>"$tmp/acpmux-env.log"
exec "$real" "\$@"
SH
cat >"$tmp/bin/bun" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == run ]] || exit 0
exec python3 -I -m http.server "$CMUX_WEBVIEWS_DEV_PORT" --bind 127.0.0.1
SH
chmod +x "$tmp/bin/acpmux" "$tmp/bin/bun"

# The caller's own daemon: anything that connects here leaked out of the slot.
cat >"$tmp/caller-daemon.py" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen()
while True:
    c, _ = s.accept(); open(sys.argv[2], "a").write("connected\n"); c.close()
PY
python3 -I "$tmp/caller-daemon.py" "$tmp/caller.sock" "$tmp/caller-hits" &
pids+=($!)
for _ in $(seq 50); do [[ -S "$tmp/caller.sock" ]] && break; sleep 0.1; done

# The one-shot shell: a session and process group of its own, with the caller's acpmux env.
cat >"$tmp/one-shot.sh" <<SH
echo \$\$ >"$tmp/shell.pgid"
umask 002
export ACPMUX_HOME="$tmp/caller-home" ACPMUX_SOCKET="$tmp/caller.sock" ACPMUX_SESSION_TOKEN_SOCKET="$tmp/caller.sock" \
  ACPMUX_ENV=1 ACPMUX_SESSION_ID=caller-session ACPMUX_FROM=caller ACPMUX_SENDER_TOKEN=caller-token
CMUX_DEV_SLOT_ROOT="$root" ACPMUX_BIN="$tmp/bin/acpmux" PATH="$tmp/bin:\$PATH" "$script" up "$slot" --cwd "$tmp"
SH
python3 -I -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' bash "$tmp/one-shot.sh" \
  >"$tmp/up.log" 2>&1 </dev/null || { cat "$tmp/up.log" >&2; fail "dev-slot.sh up exited non-zero"; }
daemon_pid="$(cat "$home/daemon.pid")" vite_pid="$(cat "$home/vite.pid")"
pids+=("$daemon_pid" "$vite_pid")

status=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1" >&2; status=1; fi; }

# 1. Mode.
mode="$(stat -c %a "$home" 2>/dev/null || stat -f %Lp "$home")"
check "slot folder is 700 under umask 002 (got $mode)" '[[ "$mode" == 700 ]]'

# 2. Socket and environment.
leaked="$(grep -E '^ACPMUX_' "$tmp/acpmux-env.log" | grep -vE "^ACPMUX_(HOME=$home|SOCKET=$home/acpmux\.sock)\$" | cut -d= -f1 | sort -u || true)"
check "no acpmux run saw a caller's ACPMUX_* variable${leaked:+: ${leaked//$'\n'/ }}" '[[ -z "$leaked" ]]'
check "the daemon serves the slot's socket" '[[ -S "$home/acpmux.sock" ]]'

# 3. Parent exit: the shell is gone; signal what is left of its process group, as a harness does.
pgid="$(cat "$tmp/shell.pgid")"
kill -HUP -- "-$pgid" 2>/dev/null || true
kill -TERM -- "-$pgid" 2>/dev/null || true
sleep 1
check "the daemon outlives the caller's shell and its process group" 'kill -0 "$daemon_pid" 2>/dev/null'
check "Vite outlives the caller's shell and its process group" 'kill -0 "$vite_pid" 2>/dev/null'

# 4. Handshake: the agent pane's browser upgrade, with the slot's token and Vite origin.
handshake() {
  python3 -I - "$((47900 + slot))" "$1" "http://127.0.0.1:$((4180 + slot))" <<'PY'
import base64, os, socket, sys
port, token, origin = sys.argv[1:]
s = socket.create_connection(("127.0.0.1", int(port)), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nOrigin: {origin}\r\n"
           f"Sec-WebSocket-Protocol: acpmux.v1, acpmux.token.{token}\r\n\r\n").encode())
print(s.recv(4096).decode(errors="replace").split("\r\n", 1)[0])
PY
}
answer="$(handshake "$(cat "$home/token")" || true)"
check "the slot's token upgrades ($answer)" '[[ "$answer" == *" 101 "* ]]'
answer="$(handshake wrong-token || true)"
check "a wrong token is refused ($answer)" '[[ "$answer" != *" 101 "* ]]'

check "nothing connected to the caller's socket" '[[ ! -s "$tmp/caller-hits" ]]'
if [[ "$status" != 0 ]]; then
  for log in "$tmp/up.log" "$home/daemon.log" "$home/vite.log"; do echo "--- $log" >&2; tail -15 "$log" >&2 || true; done
fi
exit "$status"
