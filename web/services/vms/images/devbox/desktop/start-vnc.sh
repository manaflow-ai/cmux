#!/usr/bin/env bash
# Desktop starter for the cmux devbox image (/usr/local/bin/start-vnc.sh).
# CONTRACT FILE: the desktop is reached on two fixed ports, and the Mac CLI
# (cloudVMDesktopPort) plus any provider heal command depend on them:
#   - RFB on 5901, loopback only, no VNC-level auth (the only ingress is a
#     token-gated proxy in front of websockify; a VNC password would be a
#     second prompt noVNC's autoconnect cannot answer).
#   - noVNC web client via websockify on 6901, at `/`.
# It runs as the work user `ubuntu` with HOME=/home/ubuntu and DISPLAY=:1
# (cmux-desktop-boot under the cmux-desktop systemd unit on Freestyle; a
# provider driver's heal command runs exactly the same invocation), so the
# desktop session is the same account terminals and SSH land in. This
# path, user, display, and ports must not change without a matching driver
# change. tests/vm-devbox-desktop.test.ts pins the contract.
#
# Idempotent: every component is guarded by a liveness probe, so re-running
# against a healthy desktop starts nothing. Starts everything in the background
# and exits; the supervisor loop re-invokes it.
set -u

DISPLAY="${DISPLAY:-:1}"
export DISPLAY
GEOMETRY="${CMUX_VNC_GEOMETRY:-1440x900}"
# Never let an unwritable HOME keep the desktop down: fall back to a per-user
# tmp dir for logs.
LOG_DIR="$HOME/.cmux/desktop-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR="/tmp/cmux-desktop-logs-$(id -u)"; mkdir -p "$LOG_DIR"; }

# The supervisor re-runs this every 30 s, so cap each component log here: a
# crash-looping component must not grow its log without bound.
for log in "$LOG_DIR"/*.log; do
  [ -f "$log" ] || continue
  if [ "$(wc -c <"$log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -c 65536 "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log"
  fi
done

VNC_BIN="$(command -v Xvnc || command -v Xtigervnc)" || exit 0

listening() { ss -tln 2>/dev/null | grep -q ":$1 "; }

# TigerVNC on :1, RFB on 5901, loopback only.
if ! listening 5901; then
  "$VNC_BIN" "$DISPLAY" \
    -geometry "$GEOMETRY" \
    -depth 24 \
    -rfbport 5901 \
    -localhost \
    -SecurityTypes None \
    -AlwaysShared \
    >>"$LOG_DIR/xvnc.log" 2>&1 &
  for _ in $(seq 1 50); do listening 5901 && break; sleep 0.2; done
fi

if ! pgrep -u "$(id -u)" -x openbox >/dev/null 2>&1; then
  dbus-launch openbox >>"$LOG_DIR/openbox.log" 2>&1 &
fi

set_wallpaper() {
  if [ -f /usr/share/backgrounds/cmux/wallpaper.jpg ] && command -v feh >/dev/null 2>&1; then
    feh --no-fehbg --bg-fill /usr/share/backgrounds/cmux/wallpaper.jpg >/dev/null 2>&1 \
      || xsetroot -solid '#1f2430' >/dev/null 2>&1 || true
  else
    xsetroot -solid '#1f2430' >/dev/null 2>&1 || true
  fi
}
set_wallpaper

if ! pgrep -u "$(id -u)" -x tint2 >/dev/null 2>&1; then
  tint2 -c /etc/cmux/tint2rc >>"$LOG_DIR/tint2.log" 2>&1 &
fi

# noVNC's remote resize grows the display live, but the root pixmap keeps its
# old size (X tiles it: the doubled-wallpaper bug) and tint2 keeps its old
# strut. Re-fill the wallpaper and nudge tint2 whenever the geometry changes.
# `bash -c '…' cmux-desktop-resize-watch` puts the marker in $0 so the pgrep
# guard finds the loop on the next idempotent pass.
if ! pgrep -u "$(id -u)" -f cmux-desktop-resize-watch >/dev/null 2>&1; then
  bash -c '
    last=""
    while :; do
      now=$(xdpyinfo 2>/dev/null | awk "/dimensions:/ {print \$2}")
      if [ -n "$now" ] && [ "$now" != "$last" ]; then
        if [ -n "$last" ]; then
          feh --no-fehbg --bg-fill /usr/share/backgrounds/cmux/wallpaper.jpg >/dev/null 2>&1 || true
          pkill -USR1 -U "$(id -u)" -x tint2 >/dev/null 2>&1 || true
        fi
        last="$now"
      fi
      sleep 2
    done
  ' cmux-desktop-resize-watch >>"$LOG_DIR/resize-watch.log" 2>&1 &
fi

# noVNC web client + websocket proxy on 6901 (the CLI's cloudVMDesktopPort).
if ! listening 6901; then
  websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:6901 127.0.0.1:5901 \
    >>"$LOG_DIR/websockify.log" 2>&1 &
fi

exit 0
