#!/usr/bin/env bash
# Desktop starter for the cmux-devbox image. CONTRACT FILE: the Blaxel driver's
# DESKTOP_VNC_HEAL_COMMAND runs exactly `runuser -u cua -- env HOME=/home/cua
# USER=cua DISPLAY=:1 bash /usr/local/bin/start-vnc.sh` when no :5901 listener
# exists, so this path, user, display, and port must not change without a
# matching driver change (web/services/vms/drivers/blaxel.ts).
#
# Idempotent: every component is guarded by a liveness probe, so re-running
# against a healthy desktop starts nothing. Starts everything in the background
# and exits; the image entrypoint's supervisor loop re-invokes it.
set -u

DISPLAY="${DISPLAY:-:1}"
export DISPLAY
GEOMETRY="${CMUX_VNC_GEOMETRY:-1440x900}"
# The driver's heal can run this before anything recreated $HOME (Blaxel's
# rootfs transform drops /home/cua from the image), so never let an unwritable
# HOME keep the desktop down: fall back to a per-user tmp dir for logs.
LOG_DIR="$HOME/.cmux/desktop-logs"
mkdir -p "$LOG_DIR" 2>/dev/null || { LOG_DIR="/tmp/cmux-desktop-logs-$(id -u)"; mkdir -p "$LOG_DIR"; }

VNC_BIN="$(command -v Xvnc || command -v Xtigervnc)" || exit 0

listening() { ss -tln 2>/dev/null | grep -q ":$1 "; }

# TigerVNC on :1, RFB on 5901, loopback only: the sole ingress is Blaxel's
# tokened preview in front of websockify, so VNC-level auth would be a second
# password prompt noVNC's autoconnect cannot answer.
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

xsetroot -solid '#1f2430' >/dev/null 2>&1 || true

if ! pgrep -u "$(id -u)" -x tint2 >/dev/null 2>&1; then
  tint2 -c /etc/cmux/tint2rc >>"$LOG_DIR/tint2.log" 2>&1 &
fi

# noVNC web client + websocket proxy on 6901 (the CLI's cloudVMDesktopPort).
if ! listening 6901; then
  websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:6901 127.0.0.1:5901 \
    >>"$LOG_DIR/websockify.log" 2>&1 &
fi

exit 0
