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
# mktemp, not a predictable /tmp name: the remote may be multi-user, and a
# fixed path could be pre-created (or symlinked) by someone else. Deleting on
# exit is safe: the builder confirms every probe is RUNNING (each pane's bash
# holds an open fd on the script) before this shell exits.
PROBE="$(mktemp "${TMPDIR:-/tmp}/remote-tmux-width-probe.XXXXXX")"
trap 'rm -f "$PROBE"' EXIT
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

# Refuse to clobber an existing session of this name: it may be real work,
# and a partial build left by a prior interrupted run must not be silently
# reused. Fail loudly with the fix instead of guessing.
if T has-session -t "$SESSION" 2>/dev/null; then
  echo "session '$SESSION' already exists on the remote." >&2
  echo "kill it first ('$TMUX_BIN kill-session -t $SESSION' on the host) or run with a different name:" >&2
  echo "  remote-tmux-shape-zoo.sh <host> <other-name>" >&2
  exit 2
fi

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
T split-window -h -t "$SESSION:6.1"
T select-layout -t "$SESSION:6" main-horizontal

T new-window -t "$SESSION" -n plain

T select-window -t "$SESSION:0"

# Wait for each pane's shell to be at a prompt before typing the probe
# command, then confirm the probe took — polling the real readiness signal
# (#{pane_current_command}) instead of a fixed grace period. Interactive
# shells report as one of these; the probe reports as bash.
is_shell() { # $1 = pane_current_command; a login/interactive shell?
  [ "$1" = bash ] || [ "$1" = zsh ] || [ "$1" = sh ] || [ "$1" = fish ] \
    || [ "$1" = -bash ] || [ "$1" = -zsh ] || [ "$1" = dash ] || [ "$1" = ash ]
}
shell_ready() {
  local p c
  while read -r p c; do
    is_shell "$c" || return 1
  done < <(T list-panes -s -t "$SESSION" -F '#{pane_id} #{pane_current_command}')
  return 0
}
for _ in $(seq 1 30); do shell_ready && break; sleep 0.5; done

PANES="$(T list-panes -s -t "$SESSION" -F '#{pane_id}')"
# The probe announces itself by setting the @probe_alive pane option as its
# first act (see remote-tmux-width-probe.sh). Confirming on that marker —
# not on foreground-command names or a grace period — means a loaded box can
# only DELAY the confirm, never falsify it: no measuring before the probe is
# actually running.
pending_panes() {
  T list-panes -s -t "$SESSION" -F '#{pane_id} #{@probe_alive}' \
    | while read -r pane alive; do
        [ "$alive" = 1 ] || printf '%s\n' "$pane"
      done
}
launch_and_confirm() {
  for pane in $1; do
    T send-keys -t "$pane" "PROBE_TICK=$TICK bash $PROBE" Enter
  done
  for _ in $(seq 1 20); do
    [ -z "$(pending_panes)" ] && return 0
    sleep 0.5
  done
  return 1
}
# One re-launch pass covers a pane that never left its prompt on the first
# try — re-sent ONLY to the panes still missing their marker, so a pane whose
# probe is already running never gets stray keystrokes typed into it.
launch_and_confirm "$PANES" || launch_and_confirm "$(pending_panes)" || {
  echo "warning: some panes never started the probe:" >&2
  T list-panes -s -t "$SESSION" -F '  #{window_name}.#{pane_id} alive=#{@probe_alive} cmd=#{pane_current_command}' \
    | grep -v 'alive=1' >&2 || true
}

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
