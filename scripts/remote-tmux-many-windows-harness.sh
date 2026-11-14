#!/bin/bash
# ============================================================================
# Remote-tmux MANY-WINDOWS harness.
#
# Mirrors a loopback tmux server holding about 48 windows through a slow link and
# checks that the control connection stays up: one connect, then no
# `stdin-write-backpressure` and no stream reset for the watch period.
#
# Everything past the link is real. The app runs its own `cmux ssh-tmux` attach
# against a real tmux server; the only thing injected is the link itself. A stand-in
# `ssh` (the app runs it in place of /usr/bin/ssh when started with
# CMUX_REMOTE_TMUX_SSH_FOR_TESTING) adds a ProxyCommand that relays the TCP stream
# through a rate limiter, so both directions crawl the way a proxied connection does.
#
# PREREQUISITES
#   - A loopback ssh alias whose forced command pins TMUX_TMPDIR (default cmux-srvA,
#     whose server lives in /tmp/cmux-srvA). Override with CMUX_MW_HOST and
#     CMUX_MW_TMUX_DIR.
#   - A tagged Debug app started WITH the stand-in ssh in its environment:
#       scripts/remote-tmux-many-windows-harness.sh --print-ssh   # prints the path
#       open -g --env CMUX_REMOTE_TMUX_SSH_FOR_TESTING=<path> "<tagged app>"
#   - Both remote tmux betas on for that bundle id:
#       defaults write com.cmuxterm.app.debug.<tag> remoteTmux.beta.enabled -bool true
#       defaults write com.cmuxterm.app.debug.<tag> remoteTmux.multiplexer.beta.enabled -bool true
#
# Usage:
#   CMUX_TAG=<tag> scripts/remote-tmux-many-windows-harness.sh populate
#   CMUX_TAG=<tag> scripts/remote-tmux-many-windows-harness.sh run [seconds]
#
# `populate` rebuilds the loopback tmux server (it only ever kills the server under
# CMUX_MW_TMUX_DIR, after checking the socket path). `run` connects and watches the
# tag's debug log. Link speed is CMUX_MW_RATE bytes per second in each direction
# (default 65536) plus CMUX_MW_DELAY_MS of one-way delay (default 40). Exit code 0 means
# the connection stayed up.
# ============================================================================
set -uo pipefail

HOST="${CMUX_MW_HOST:-cmux-srvA}"
TMUX_DIR="${CMUX_MW_TMUX_DIR:-/tmp/cmux-srvA}"
SESSIONS="${CMUX_MW_SESSIONS:-16}"
WINDOWS_PER_SESSION="${CMUX_MW_WINDOWS:-3}"
RATE="${CMUX_MW_RATE:-65536}"
DELAY_MS="${CMUX_MW_DELAY_MS:-40}"
STATE="${CMUX_MW_STATE_DIR:-$HOME/Library/Caches/cmux/remote-tmux-many-windows}"
FAKE_SSH="$STATE/ssh"
THROTTLE="$STATE/throttle.py"
LINK_FILE="$STATE/link"

write_throttle() {
  mkdir -p "$STATE"
  cat > "$THROTTLE" <<'EOF'
#!/usr/bin/env python3
"""ProxyCommand relay that limits each direction to RATE bytes/s plus a fixed delay."""
import os, select, socket, sys, time

host, port, rate, delay = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]) / 1000.0
sock = socket.create_connection((host, port))
sock.setblocking(False)
stdin, stdout = sys.stdin.fileno(), sys.stdout.fileno()
os.set_blocking(stdin, False)
os.set_blocking(stdout, False)

class Lane:
    def __init__(self):
        self.queue = []        # (release_time, bytes)
        self.out = b""
        self.allowance = 0.0
        self.last = time.monotonic()
    def take(self, now):
        self.allowance = min(rate, self.allowance + (now - self.last) * rate)
        self.last = now
        while self.queue and self.queue[0][0] <= now and self.allowance >= 1:
            ready, data = self.queue[0]
            n = int(min(len(data), self.allowance))
            self.out += data[:n]
            self.allowance -= n
            if n == len(data):
                self.queue.pop(0)
            else:
                self.queue[0] = (ready, data[n:])

up, down = Lane(), Lane()   # up: stdin -> socket, down: socket -> stdout
open_in, open_sock = True, True
while open_in or open_sock or up.queue or up.out or down.queue or down.out:
    now = time.monotonic()
    up.take(now); down.take(now)
    r, w = [], []
    # Stop reading a side while its lane holds more than a second of data, so the
    # limit pushes back on the sender the way a full link does.
    if open_in and sum(len(d) for _, d in up.queue) < rate: r.append(stdin)
    if open_sock and sum(len(d) for _, d in down.queue) < rate: r.append(sock)
    if up.out: w.append(sock)
    if down.out: w.append(stdout)
    if not (open_in or open_sock) and not (up.out or down.out) and not (up.queue or down.queue):
        break
    rr, ww, _ = select.select(r, w, [], 0.01)
    now = time.monotonic()
    if stdin in rr:
        data = os.read(stdin, 65536)
        if data: up.queue.append((now + delay, data))
        else: open_in = False
    if sock in rr:
        try: data = sock.recv(65536)
        except BlockingIOError: data = None
        if data: down.queue.append((now + delay, data))
        elif data == b"": open_sock = False
    if sock in ww and up.out:
        try: up.out = up.out[sock.send(up.out):]
        except BlockingIOError: pass
    if stdout in ww and down.out:
        try: down.out = down.out[os.write(stdout, down.out):]
        except BlockingIOError: pass
    if not open_sock and not down.queue and not down.out:
        break
EOF
  chmod 755 "$THROTTLE"
}

write_fake_ssh() {
  write_throttle
  cat > "$FAKE_SSH" <<EOF
#!/bin/sh
# Stand-in ssh for scripts/remote-tmux-many-windows-harness.sh: the real ssh, carried
# over a rate-limited relay. Reads the link settings on every call.
link="\$(cat "$LINK_FILE" 2>/dev/null)"
rate="\${link%% *}"; delay="\${link##* }"
[ -n "\$rate" ] || rate=$RATE
[ -n "\$delay" ] || delay=$DELAY_MS
for arg in "\$@"; do
  # Control operations on a shared master are not connections.
  [ "\$arg" = "-O" ] && exec /usr/bin/ssh "\$@"
done
exec /usr/bin/ssh -o "ProxyCommand=/usr/bin/env python3 $THROTTLE %h %p \$rate \$delay" "\$@"
EOF
  chmod 755 "$FAKE_SSH"
}

if [ "${1:-}" = "--print-ssh" ]; then
  write_fake_ssh
  echo "$FAKE_SSH"
  exit 0
fi

: "${CMUX_TAG:?CMUX_TAG is required}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI() { CMUX_TAG="$CMUX_TAG" "$REPO/scripts/cmux-debug-cli.sh" "$@"; }
LOG="/tmp/cmux-debug-$CMUX_TAG.log"

populate() {
  # The remote side runs under the alias's forced command, which exports TMUX_TMPDIR.
  # Still refuse to touch any server whose socket is not under that directory: a
  # missing directory makes tmux fall back to the default socket silently.
  ssh "$HOST" "/bin/sh -s" <<EOF
set -eu
unset TMUX TMUX_PANE
export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
[ "\${TMUX_TMPDIR:-}" = "$TMUX_DIR" ] || { echo "TMUX_TMPDIR is '\${TMUX_TMPDIR:-}', want $TMUX_DIR" >&2; exit 3; }
mkdir -p "$TMUX_DIR"
if tmux list-sessions >/dev/null 2>&1; then
  sock="\$(tmux display-message -p '#{socket_path}' 2>/dev/null || true)"
  case "\$sock" in
    "$TMUX_DIR"/*|/private"$TMUX_DIR"/*) tmux kill-server ;;
    *) echo "refusing to kill server at '\$sock'" >&2; exit 3 ;;
  esac
  # kill-server returns before the server is gone, and a new-session that reaches the
  # exiting server fails with "server exited unexpectedly". Wait for it to stop answering.
  n=0
  while tmux list-sessions >/dev/null 2>&1; do
    n=\$((n+1)); [ \$n -lt 100 ] || { echo "old server did not exit" >&2; exit 3; }
    sleep 0.1
  done
fi
printf 'import itertools, time\nfor i in itertools.count():\n    print("tick", i, flush=True)\n    time.sleep(0.5)\n' > "$TMUX_DIR/ticker.py"
fill='i=0; while [ \$i -lt 2000 ]; do echo "line \$i of scrollback, padded to look like real terminal output from a busy pane"; i=\$((i+1)); done'
s=1
while [ \$s -le $SESSIONS ]; do
  name=\$(printf 'mw-%02d' \$s)
  tmux new-session -d -s "\$name" -x 200 -y 50
  w=1
  while [ \$w -lt $WINDOWS_PER_SESSION ]; do tmux new-window -d -t "\$name"; w=\$((w+1)); done
  for win in \$(tmux list-windows -t "\$name" -F '#{window_id}'); do
    tmux send-keys -t "\$win" "\$fill; clear" Enter
    # Every third window is split and keeps printing, like an agent pane.
    case \$((\${win#@} % 3)) in
      0) tmux split-window -d -t "\$win" "python3 $TMUX_DIR/ticker.py" ;;
    esac
  done
  s=\$((s+1))
done
echo "windows=\$(tmux list-windows -a | wc -l | tr -d ' ') panes=\$(tmux list-panes -a | wc -l | tr -d ' ')"
EOF
}

run() {
  local seconds="${1:-120}"
  write_fake_ssh
  echo "$RATE $DELAY_MS" > "$LINK_FILE"
  [ -f "$LOG" ] || { echo "no debug log at $LOG; is the tagged app running?" >&2; exit 2; }
  local start; start=$(wc -l < "$LOG" | tr -d ' ')
  echo "connecting $HOST at ${RATE} B/s, ${DELAY_MS} ms delay; watching for ${seconds}s"
  CLI ssh-tmux "$HOST" || { echo "FAIL: ssh-tmux did not attach" >&2; exit 1; }
  sleep "$seconds"   # the watch window itself; the verdict reads the log below
  local slice; slice="$(tail -n +"$((start + 1))" "$LOG")"
  # The mirror must actually be up: one workspace per populated session. Without this a
  # server that failed to populate, or a stream that never published, would read as a pass.
  local mirrored
  mirrored=$(CMUX_QUIET=1 CLI workspace list 2>/dev/null | grep -cE ' mw-[0-9]+( |$)' || true)
  echo "mirrored workspaces: $mirrored of $SESSIONS"
  local resets backpressure enters
  resets=$(printf '%s\n' "$slice" | grep -cE 'remote.stream.reset .*mode=attach( |$)' || true)
  backpressure=$(printf '%s\n' "$slice" | grep -c 'stdin-write-backpressure' || true)
  enters=$(printf '%s\n' "$slice" | grep -cE 'remote\.event enter$' || true)
  echo "stream resets after the first connect: $resets"
  echo "stdin-write-backpressure: $backpressure"
  echo "control-mode enters: $enters"
  if [ "$enters" -lt 1 ]; then
    echo "VOID: the stream never reached control mode, so nothing was measured" >&2
    exit 2
  fi
  if [ "$mirrored" -ne "$SESSIONS" ]; then
    echo "VOID: expected $SESSIONS mirrored workspaces, saw $mirrored" >&2
    exit 2
  fi
  if [ "$resets" -gt 0 ] || [ "$backpressure" -gt 0 ]; then
    echo "FAIL: the connection reset under load"
    exit 1
  fi
  echo "PASS"
}

case "${1:-}" in
  populate) populate ;;
  run) shift; run "$@" ;;
  *) echo "usage: $0 --print-ssh | populate | run [seconds]" >&2; exit 2 ;;
esac
