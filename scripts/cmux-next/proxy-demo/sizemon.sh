#!/bin/sh
# Size monitor for the proxy demo's tmux pane.
#
# Prints one line per size change (on SIGWINCH and every second as a
# fallback) with three numbers that must agree after every resize:
#   tty      what the kernel tells this pane (stty size: rows cols)
#   pane     what tmux thinks this pane is (#{pane_width}x#{pane_height})
#   client   what tmux thinks the cmux terminal is (#{client_width}x#{client_height})
# and writes "client WxH, pane WxH" to $1 (the dev server shows it on the page).
#
# A tmux client whose size never follows the cmux terminal is a resize bug
# in the cmux terminal (no TIOCSWINSZ or no SIGWINCH), not in tmux.
out="${1:-/tmp/cmux-proxy-demo/size.txt}"
last=""
print_size() {
  tty=$(stty size 2>/dev/null)
  pane=$(tmux display -p -t "${TMUX_PANE:-}" '#{pane_width}x#{pane_height}' 2>/dev/null)
  client=$(tmux display -p -t "${TMUX_PANE:-}" '#{client_width}x#{client_height}' 2>/dev/null)
  line="client ${client}, pane ${pane}, tty ${tty}"
  if [ "$line" != "$last" ]; then
    last="$line"
    printf '%s %s\n' "$(date +%H:%M:%S)" "$line"
    printf 'terminal %s\n' "$line" > "$out.tmp" && mv "$out.tmp" "$out"
  fi
}
trap print_size WINCH
print_size
while :; do
  sleep 1 &
  wait $!
  print_size
done
