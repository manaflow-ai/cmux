#!/bin/sh
# Start (or attach to) the demo's tmux session: dev server on top, size
# monitor below. Run inside the left cmux terminal.
#   tmux-up.sh SESSION STATE_DIR SITE_DIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
session="$1"
state="$2"
site="$3"
mkdir -p "$state" "$site"
[ -f "$site/index.md" ] || printf 'Edit any file in %s and the browser reloads.\n' "$site" > "$site/index.md"
rm -f "$state/port"
if ! tmux has-session -t "=$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -c "$site" -x "$(tput cols 2>/dev/null || echo 80)" -y "$(tput lines 2>/dev/null || echo 24)" \
    "python3 -I '$here/devserver.py' --root '$site' --size-file '$state/size.txt' --port-file '$state/port'; exec \$SHELL"
  tmux split-window -v -l 30% -t "$session:" -c "$site" "sh '$here/sizemon.sh' '$state/size.txt'; exec \$SHELL"
  tmux set-option -t "$session" status-right '#{client_width}x#{client_height}' >/dev/null
  # A size that follows the latest client, not the smallest: one cmux
  # terminal is the only client, and stale sizes are a bug we want to see.
  tmux set-option -t "$session" window-size latest >/dev/null
  # tmux takes rows from the last pane when the window shrinks, so the
  # monitor would end up 1 or 2 rows tall after the first cmux resize. Keep
  # it at 30% after every window resize. (client-resized fires before the
  # window takes the new size, so a shrink still collapsed the monitor:
  # sizebench.py "shrink 80x24" failed with it.)
  tmux set-hook -w -t "$session:" window-resized "resize-pane -t '$session:.1' -y 30%" >/dev/null
  tmux select-pane -t "$session:.0"
fi
# Only has-session takes the "=" exact-match prefix: with tmux 3.6a,
# split-window and attach-session answered "no such session: =NAME" for a
# session has-session had just found. The session name is unique per demo.
[ -n "${CMUX_DEMO_NO_ATTACH:-}" ] && exit 0
exec tmux attach-session -t "$session"
