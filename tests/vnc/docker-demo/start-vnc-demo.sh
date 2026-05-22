#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUMBER="${DISPLAY_NUMBER:-1}"
DISPLAY_SIZE="${DISPLAY_SIZE:-1280x800x24}"
SESSION_TITLE="${SESSION_TITLE:-cmux Docker VNC}"
VNC_PASSWORD="${VNC_PASSWORD:-cmuxvnc}"
READY_FILE="/tmp/cmux-vnc-desktop-ready"

mkdir -p "$HOME/.vnc"
x11vnc -storepasswd "$VNC_PASSWORD" "$HOME/.vnc/passwd" >/dev/null
rm -f "$READY_FILE"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-root}"
export NO_AT_BRIDGE=1
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

Xvfb ":$DISPLAY_NUMBER" -screen 0 "$DISPLAY_SIZE" &
XVFB_PID=$!
export DISPLAY=":$DISPLAY_NUMBER"

for _ in $(seq 1 50); do
  if xset q >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

if ! xset q >/dev/null 2>&1; then
  echo "error: Xvfb did not become ready on $DISPLAY" >&2
  exit 1
fi

mkdir -p "$HOME/Desktop"
cat >"$HOME/Desktop/cmux-vnc-demo.txt" <<EOF
$SESSION_TITLE

This is a real XFCE desktop session served through x11vnc.
Host: $(hostname)
EOF

dbus-launch --exit-with-session startxfce4 >/tmp/xfce.log 2>&1 &
XFCE_PID=$!

for _ in $(seq 1 120); do
  if pgrep -x xfce4-panel >/dev/null 2>&1 && pgrep -x xfwm4 >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! pgrep -x xfce4-panel >/dev/null 2>&1 || ! pgrep -x xfwm4 >/dev/null 2>&1; then
  echo "error: XFCE desktop did not become ready on $DISPLAY" >&2
  cat /tmp/xfce.log >&2 || true
  exit 1
fi

touch "$READY_FILE"

TERMINAL_SCRIPT="/tmp/cmux-vnc-terminal.sh"
cat >"$TERMINAL_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n\n' "$SESSION_TITLE"
printf 'Real Docker XFCE VNC desktop served by x11vnc on %s\n' "$(hostname)"
exec bash
EOF
chmod +x "$TERMINAL_SCRIPT"
export SESSION_TITLE

xfce4-terminal \
  --disable-server \
  --geometry 92x24+180+100 \
  --title "$SESSION_TITLE" \
  --command "$TERMINAL_SCRIPT" \
  >/tmp/xfce4-terminal.log 2>&1 || \
xterm \
  -geometry 92x24+180+100 \
  -title "$SESSION_TITLE" \
  -fa Monospace \
  -fs 12 \
  -e "$TERMINAL_SCRIPT" &

cleanup() {
  kill "$XVFB_PID" 2>/dev/null || true
  kill "$XFCE_PID" 2>/dev/null || true
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
