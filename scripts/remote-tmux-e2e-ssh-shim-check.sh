#!/bin/bash
# Exercises scripts/remote-tmux-e2e-ssh-shim.sh through every ssh invocation
# shape cmux's remote-tmux transport makes (RemoteTmuxSSHTransport /
# RemoteTmuxHost), against a throwaway local tmux server — so shim regressions
# surface here in seconds instead of inside a full UI-test cycle.
#
#   bash scripts/remote-tmux-e2e-ssh-shim-check.sh
#
# Exit code = number of failed checks.
set -u

SHIM="$(cd "$(dirname "$0")" && pwd)/remote-tmux-e2e-ssh-shim.sh"
TMUX_BIN=""
for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
  [ -x "$c" ] && TMUX_BIN="$c" && break
done
if [ -z "$TMUX_BIN" ]; then echo "SKIP: no tmux binary"; exit 0; fi

LAB="$(mktemp -d /tmp/shimchk.XXXXXX)"
export TMUX_TMPDIR="$LAB"
unset TMUX
cleanup() {
  "$TMUX_BIN" kill-server 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT

"$TMUX_BIN" new-session -d -s sizing -x 100 -y 30 || { echo "FATAL: lab server"; exit 1; }

FAIL=0
note() { printf '%-58s %s\n' "$1" "$2"; }
check() { # name expected_exit actual_exit extra_ok(0/1)
  if [ "$2" = "$3" ] && [ "${4:-0}" = 0 ]; then note "$1" "ok"
  else note "$1" "FAIL (exit want=$2 got=$3 extra=${4:-0})"; FAIL=$((FAIL + 1)); fi
}

# The exact remote-command string cmux builds (RemoteTmuxHost.tmuxRemoteCommand):
# every token single-quoted, resolver script as $0-style /bin/sh -c payload.
RESOLVER='cmux_tmux=""; if command -v tmux >/dev/null 2>&1; then cmux_tmux="$(command -v tmux)"; else for cmux_dir in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /snap/bin /usr/bin /bin; do if [ -x "$cmux_dir/tmux" ]; then cmux_tmux="$cmux_dir/tmux"; break; fi; done; if [ -z "$cmux_tmux" ] && [ -x /usr/libexec/path_helper ]; then eval "$(/usr/libexec/path_helper -s 2>/dev/null)"; if command -v tmux >/dev/null 2>&1; then cmux_tmux="$(command -v tmux)"; fi; fi; fi; if [ -n "$cmux_tmux" ]; then exec "$cmux_tmux" "$@"; fi; exec tmux "$@"'
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
tmux_remote() { # args... -> the single remote-command string
  local out; out="$(sq /bin/sh) $(sq -c) $(sq "$RESOLVER") $(sq cmux-remote-tmux)"
  for a in "$@"; do out="$out $(sq "$a")"; done
  printf '%s' "$out"
}
CTL=(-o ControlMaster=auto -o "ControlPath=$LAB/ctl.sock" -o ControlPersist=180 \
     -o ConnectTimeout=10 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o BatchMode=yes)

# 1. ControlMaster ops succeed trivially (gate for mirrorHost readiness).
"$SHIM" -O check -o "ControlPath=$LAB/ctl.sock" -- fakehost </dev/null >/dev/null 2>&1
check "1  -O check" 0 $?
"$SHIM" -O exit -o "ControlPath=$LAB/ctl.sock" -- fakehost </dev/null >/dev/null 2>&1
check "2  -O exit" 0 $?

# 3. Master warmup: run(["true"]).
"$SHIM" "${CTL[@]}" -- fakehost "'true'" </dev/null >/dev/null 2>&1
check "3  warm ('true')" 0 $?

# 4. list-sessions through the resolver; format string carries tabs.
OUT="$("$SHIM" "${CTL[@]}" -- fakehost "$(tmux_remote list-sessions -F '#{session_name}	#{session_windows}')" </dev/null 2>/tmp/shimchk-err)"
RC=$?; EXTRA=1
[ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "^sizing	1$" && [ ! -s /tmp/shimchk-err ] && EXTRA=0
check "4  list-sessions -F (tabs, stdout only)" 0 "$RC" "$EXTRA"

# 5. tmux -V through the resolver.
OUT="$("$SHIM" "${CTL[@]}" -- fakehost "$(tmux_remote -V)" </dev/null 2>/dev/null)"
RC=$?; EXTRA=1; printf '%s' "$OUT" | grep -q '^tmux ' && EXTRA=0
check "5  tmux -V" 0 "$RC" "$EXTRA"

# 6. display-message #{version} (server version probe).
"$SHIM" "${CTL[@]}" -- fakehost "$(tmux_remote display-message -p '#{version}')" </dev/null >/dev/null 2>&1
check "6  display-message -p" 0 $?

# 7. refresh-client -B probe MUST fail with classifiable stderr ("no current
#    client") on stderr, nothing on stdout — pty would merge/blank these.
OUT="$("$SHIM" "${CTL[@]}" -- fakehost "$(tmux_remote refresh-client -B 'cmux_probe::#{version}')" </dev/null 2>/tmp/shimchk-err)"
RC=$?; EXTRA=1
[ "$RC" != 0 ] && grep -q "current client" /tmp/shimchk-err && [ -z "$OUT" ] && EXTRA=0
check "7  refresh-client -B fails w/ stderr text" 1 "$([ "$RC" != 0 ] && echo 1 || echo 0)" "$EXTRA"

# 8. "no server running" classification (fresh empty TMUX_TMPDIR).
EMPTY="$(mktemp -d /tmp/shimchk-empty.XXXXXX)"
OUT="$(TMUX_TMPDIR="$EMPTY" "$SHIM" "${CTL[@]}" -- fakehost "$(tmux_remote list-sessions -F 'x')" </dev/null 2>/tmp/shimchk-err)"
RC=$?; EXTRA=1
[ "$RC" != 0 ] && grep -Eq "no server running|error connecting" /tmp/shimchk-err && EXTRA=0
rm -rf "$EMPTY"
check "8  no-server stderr classification" 1 "$([ "$RC" != 0 ] && echo 1 || echo 0)" "$EXTRA"

# 9. exit-status propagation through the pty path.
"$SHIM" -tt "${CTL[@]}" -- fakehost "'/bin/sh' '-c' 'exit 7'" </dev/null >/dev/null 2>&1
check "9  -tt exit propagation" 7 $?

# 10. The control stream: -tt attach must emit %begin, then answer a command
#     WRITTEN TO STDIN (the app's actual dialogue), then detach cleanly. The
#     app feeds the shim a PIPE (Foundation Pipe), so the harness must too —
#     script(1) dies probing termios on a fifo (ENOTSUP) but tolerates pipes.
CMDS="$LAB/cc.cmds"; OUTF="$LAB/cc.out"
: > "$CMDS"
tail -f "$CMDS" | "$SHIM" -tt "${CTL[@]}" -- fakehost "$(tmux_remote -CC attach-session -t sizing)" >"$OUTF" 2>&1 &
CCPID=$!
TAILPID="$(pgrep -f "tail -f $CMDS" | head -1)"
DEADLINE=$((SECONDS + 5)); EXTRA=1
while [ $SECONDS -lt $DEADLINE ]; do
  grep -q '%begin' "$OUTF" 2>/dev/null && { EXTRA=0; break; }
  sleep 0.2
done
check "10 -CC attach streams %begin" 0 0 "$EXTRA"
if [ "$EXTRA" = 0 ]; then
  printf 'list-windows -F "#{window_id}"\n' >> "$CMDS"
  DEADLINE=$((SECONDS + 5)); EXTRA=1
  while [ $SECONDS -lt $DEADLINE ]; do
    grep -q '@0' "$OUTF" 2>/dev/null && { EXTRA=0; break; }
    sleep 0.2
  done
  check "11 stdin command answered on control stream" 0 0 "$EXTRA"
  printf 'detach-client\n' >> "$CMDS"
fi
DEADLINE=$((SECONDS + 5))
while kill -0 "$CCPID" 2>/dev/null && [ $SECONDS -lt $DEADLINE ]; do sleep 0.2; done
kill -0 "$CCPID" 2>/dev/null && { kill "$CCPID" 2>/dev/null; note "12 control client exits after detach" "FAIL (still running)"; FAIL=$((FAIL + 1)); } \
  || note "12 control client exits after detach" "ok"
[ -n "${TAILPID:-}" ] && kill "$TAILPID" 2>/dev/null

# 13. SIGTERM to the shim (Process.terminate) must not leave an attached
#     client wedging the server: after kill, the server still answers.
"$SHIM" -tt "${CTL[@]}" -- fakehost "$(tmux_remote -CC attach-session -t sizing)" </dev/zero >/dev/null 2>&1 &
KPID=$!
disown "$KPID"  # suppress bash's "Terminated" job notice for the intentional kill
sleep 1
kill "$KPID" 2>/dev/null
sleep 0.5
"$TMUX_BIN" list-sessions >/dev/null 2>&1
check "13 server healthy after SIGTERM'd attach" 0 $?

echo "----"
echo "failures: $FAIL"
exit "$FAIL"
