#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUMBER="${DISPLAY_NUMBER:-1}"
DISPLAY_SIZE="${DISPLAY_SIZE:-1280x800x24}"
SESSION_TITLE="${SESSION_TITLE:-cmux Docker VNC}"
VNC_PASSWORD="${VNC_PASSWORD:-cmuxvnc}"

mkdir -p "$HOME/.vnc"
x11vnc -storepasswd "$VNC_PASSWORD" "$HOME/.vnc/passwd" >/dev/null

Xvfb ":$DISPLAY_NUMBER" -screen 0 "$DISPLAY_SIZE" &
XVFB_PID=$!
export DISPLAY=":$DISPLAY_NUMBER"

fluxbox >/tmp/fluxbox.log 2>&1 &
xsetroot -solid "#1f2937" || true
xclock -geometry 120x120+24+24 >/tmp/xclock.log 2>&1 &
xterm \
  -geometry 92x24+180+80 \
  -title "$SESSION_TITLE" \
  -fa Monospace \
  -fs 12 \
  -e bash -lc "printf '%s\n\n' '$SESSION_TITLE'; printf 'Real Docker VNC session served by x11vnc on %s\n' \"\$(hostname)\"; exec bash" &

cleanup() {
  kill "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

exec x11vnc \
  -display "$DISPLAY" \
  -forever \
  -shared \
  -rfbport 5900 \
  -rfbauth "$HOME/.vnc/passwd" \
  -listen 0.0.0.0 \
  -noxdamage \
  -repeat
