#!/bin/bash
# Builds the sizing shape zoo on a REMOTE host's tmux server — the same
# window geometry RemoteTmuxSizingUITests builds in its hermetic lab — so the
# mirror can be exercised manually against a real server over real ssh:
#
#   scripts/remote-tmux-shape-zoo.sh <ssh-host> [session-name]
#   cmux ssh-tmux <ssh-host>          # then put the mirror through its paces
#
# Windows: even3, nested, rows3, grid4, deep, sixcol, mainh, plain. Every
# pane runs scripts/remote-tmux-width-probe.sh (shipped inline), whose
# PTY-wide ruler, bottom-row sentinel, and two-axis check make sizing bugs
# visible at a glance: a wrapped ruler = surface narrower than the PTY, a
# clipped sentinel = shorter, ✗ at rest = mismatch. PROBE_TICK (seconds,
# default 1) throttles the redraw rate.
#
# ONE ssh connection, invoked exactly like an interactive `ssh <host>` (-tt,
# no injected multiplexing options, no scp side channel), so security-key
# touches, PINs, and 2FA prompts behave the same as your everyday login.
# The probe script and the builder ride along base64-encoded in the remote
# command; nothing else is transferred.
#
# Touches only the named session (kill-session, never kill-server); the
# remote server and any other sessions are left alone.
set -euo pipefail

HOST="${1:?usage: remote-tmux-shape-zoo.sh <ssh-host> [session-name]}"
SESSION="${2:-zoo}"
TICK="${PROBE_TICK:-1}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROBE_LOCAL="$REPO_DIR/scripts/remote-tmux-width-probe.sh"
[ -f "$PROBE_LOCAL" ] || { echo "missing $PROBE_LOCAL" >&2; exit 1; }

# The script that runs on the remote. SESSION/TICK/PROBE_B64 are prepended
# as assignments when the payload is packed below.
REMOTE_BODY=$(cat <<'REMOTE'
set -euo pipefail
PROBE="/tmp/remote-tmux-width-probe-$(id -un).sh"
printf '%s' "$PROBE_B64" | base64 -d > "$PROBE"

# Resolve tmux the way the app's ssh transport does: PATH first, then the
# usual install locations (non-login remote shells often have a minimal PATH).
TMUX_BIN="$(command -v tmux || true)"
if [ -z "$TMUX_BIN" ]; then
  for dir in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin /opt/local/bin /usr/pkg/bin /snap/bin /usr/bin /bin; do
    [ -x "$dir/tmux" ] && TMUX_BIN="$dir/tmux" && break
  done
fi
[ -n "$TMUX_BIN" ] || { echo "tmux not installed on remote" >&2; exit 1; }
T() { "$TMUX_BIN" "$@"; }

T kill-session -t "$SESSION" 2>/dev/null || true

# The same shapes, in the same order, as the e2e suite's buildShapeZoo.
T new-session -d -s "$SESSION" -x 180 -y 45 -n even3
T split-window -h -t "$SESSION:0"
T split-window -h -t "$SESSION:0"
T select-layout -t "$SESSION:0" even-horizontal

T new-window -t "$SESSION" -n nested
T split-window -h -t "$SESSION:1"
T split-window -v -t "$SESSION:1.1"

T new-window -t "$SESSION" -n rows3
T split-window -v -t "$SESSION:2"
T split-window -v -t "$SESSION:2"
T select-layout -t "$SESSION:2" even-vertical

T new-window -t "$SESSION" -n grid4
T split-window -h -t "$SESSION:3"
T split-window -v -t "$SESSION:3.0"
T split-window -v -t "$SESSION:3.2"
T select-layout -t "$SESSION:3" tiled

T new-window -t "$SESSION" -n deep
T split-window -h -t "$SESSION:4"
T split-window -v -t "$SESSION:4.1"
T split-window -h -t "$SESSION:4.2"

T new-window -t "$SESSION" -n sixcol
for _ in 1 2 3 4 5; do T split-window -h -t "$SESSION:5"; done
T select-layout -t "$SESSION:5" even-horizontal

T new-window -t "$SESSION" -n mainh
T split-window -v -t "$SESSION:6"
T split-window -h -t "$SESSION:6.1"

T new-window -t "$SESSION" -n plain

T select-window -t "$SESSION:0"

# Let the pane shells finish starting before typing into them.
sleep 2
for pane in $(T list-panes -s -t "$SESSION" -F '#{pane_id}'); do
  T send-keys -t "$pane" "PROBE_TICK=$TICK bash $PROBE" Enter
done
# Slow shell init (dotfiles, motd) can swallow the Enter: re-nudge any pane
# whose foreground command isn't the probe yet.
for _ in 1 2 3 4 5; do
  pending=0
  while read -r pane cmd; do
    if [ "$cmd" != bash ]; then
      pending=1
      T send-keys -t "$pane" "" Enter
    fi
  done < <(T list-panes -s -t "$SESSION" -F '#{pane_id} #{pane_current_command}')
  [ "$pending" = 0 ] && break
  sleep 2
done

echo "session '$SESSION' ready: $(T list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
REMOTE
)

b64() { base64 | tr -d '\n'; }
PAYLOAD=$(
  {
    printf 'SESSION=%q\nTICK=%q\nPROBE_B64=%q\n' \
      "$SESSION" "$TICK" "$(b64 < "$PROBE_LOCAL")"
    printf '%s\n' "$REMOTE_BODY"
  } | b64
)

echo ">> connecting to $HOST — answer your usual login prompts (key touch / PIN / 2FA)..."
# -tt: a real tty end to end, so every interactive auth mechanism works; the
# payload decodes and runs in one shot on the far side.
ssh -tt -- "$HOST" "echo $PAYLOAD | base64 -d | bash"

echo "mirror it with: cmux ssh-tmux $HOST   (session: $SESSION)"
