#!/usr/bin/env bash
# Desktop starter for the cmux devbox image (/usr/local/bin/start-vnc.sh).
# CONTRACT FILE (web/services/vms/images/desktop.ts; tests/vm-devbox-desktop.test.ts
# pins it): the desktop is reached on two fixed ports, and the Mac app
# (CmuxTuiSnapshotParser.desktopPort), the CLI (cloudVMDesktopPort) and the
# Freestyle driver's port-open heal depend on them:
#   - RFB on 5901, loopback only, no VNC-level auth (the only ingress is the
#     owner's private network; a VNC password would be a second prompt
#     noVNC's autoconnect cannot answer).
#   - noVNC web client via websockify on 6901, at `/`.
# It runs as the work user `ubuntu` with HOME=/home/ubuntu and DISPLAY=:1
# (cmux-desktop-boot under the cmux-desktop systemd unit on Freestyle, or
# under cmux-devbox-boot in a container; a driver heal runs exactly the same
# invocation), so the desktop session is the same account terminals and SSH
# land in. This path, user, display, and ports must not change without a
# matching driver change.
#
# The session: TigerVNC's Xvnc, one D-Bus session bus shared by everything
# below, the accessibility bus (computer-use agents read window trees over
# it), openbox, the wallpaper, the tint2 dock, TigerVNC's clipboard helper
# (copy/paste between the noVNC pane and the apps), a resize watcher, and
# websockify. It publishes DISPLAY and the accessibility bus address at
# $CMUX_DESKTOP_RUNTIME_DIR/env (/run/cmux-desktop/env) for
# /etc/cmux/desktop-env.sh, which every login and pane shell sources.
#
# Readiness is signalled by its owners, never inferred from elapsed time:
#   - Xvnc reports its display on -displayfd once it accepts connections;
#   - the accessibility bus is waited for by its bus name (gdbus wait);
#   - the resize watcher reacts to RandR screen-change events (xev);
#   - the whole desktop reports READY to systemd (sd_notify; the cmux-desktop
#     unit is Type=notify) once the display, noVNC and the published env are
#     up, so `systemctl start cmux-desktop` (the driver's heal, the bake)
#     returns exactly when the screen is usable.
# The one third-party listener with no readiness signal, websockify, is
# waited for through wait_listening, a bounded connect probe.
#
# Idempotent: every component is guarded by a liveness probe, so re-running
# against a healthy desktop starts nothing. Starts everything in the background
# and exits; the supervisor loop re-invokes it.
set -u

# The systemd notification socket is for this script's READY at the very end
# and for nothing else: dbus-daemon (and anything else sd_notify-aware)
# would otherwise report READY=1 for the whole unit the moment it starts.
CMUX_NOTIFY_SOCKET="${NOTIFY_SOCKET:-}"
unset NOTIFY_SOCKET

DISPLAY="${DISPLAY:-:1}"
export DISPLAY
GEOMETRY="${CMUX_VNC_GEOMETRY:-1440x900}"
RUNTIME_DIR="${CMUX_DESKTOP_RUNTIME_DIR:-/run/cmux-desktop}"
# Never let an unwritable HOME keep the desktop down: fall back to a per-user
# tmp dir for logs and session state.
STATE_DIR="$HOME/.cmux"
mkdir -p "$STATE_DIR/desktop-logs" 2>/dev/null || { STATE_DIR="/tmp/cmux-desktop-$(id -u)"; mkdir -p "$STATE_DIR/desktop-logs"; }
LOG_DIR="$STATE_DIR/desktop-logs"

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
mine() { pgrep -u "$(id -u)" "$@" >/dev/null 2>&1; }
# Bounded wait for a listener that has no readiness signal of its own
# (websockify): probes the socket table until the port is bound or the
# deadline (seconds) passes. Returns the port's state at the deadline.
wait_listening() {
  port=$1; deadline=$(( $(date +%s) + $2 ))
  until listening "$port"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# TigerVNC on :1, RFB on 5901, loopback only. -displayfd is the X server's
# own readiness signal: it writes the display number to that descriptor the
# moment it accepts connections, so nothing below talks to X too early. The
# descriptor is a FIFO opened read/write here (so neither side blocks on the
# open) and read with a deadline.
if ! listening 5901; then
  ready_fifo="$STATE_DIR/xvnc-ready.fifo"
  rm -f "$ready_fifo"
  if mkfifo -m 600 "$ready_fifo" 2>/dev/null && exec {ready_fd}<>"$ready_fifo"; then
    "$VNC_BIN" "$DISPLAY" \
      -geometry "$GEOMETRY" \
      -depth 24 \
      -rfbport 5901 \
      -localhost \
      -SecurityTypes None \
      -AlwaysShared \
      -displayfd 3 3>"$ready_fifo" \
      >>"$LOG_DIR/xvnc.log" 2>&1 &
    read -r -t 20 -u "$ready_fd" _ || echo "Xvnc did not report readiness on -displayfd within 20 s" >>"$LOG_DIR/xvnc.log"
    exec {ready_fd}>&-
    rm -f "$ready_fifo"
  else
    "$VNC_BIN" "$DISPLAY" \
      -geometry "$GEOMETRY" \
      -depth 24 \
      -rfbport 5901 \
      -localhost \
      -SecurityTypes None \
      -AlwaysShared \
      >>"$LOG_DIR/xvnc.log" 2>&1 &
    wait_listening 5901 20 || true
  fi
fi

# One D-Bus session bus for the whole desktop: openbox, the dock and every app
# it launches, and the accessibility bus. Its address is persisted so the next
# supervisor pass reuses the live bus instead of launching another. Launched
# with the display up so dbus-launch also publishes it on the X root window
# (what --autolaunch clients find).
SESSION_ENV="$STATE_DIR/desktop-session.env"
[ -f "$SESSION_ENV" ] && . "$SESSION_ENV"
if [ -z "${DBUS_SESSION_BUS_PID:-}" ] || ! kill -0 "$DBUS_SESSION_BUS_PID" 2>/dev/null; then
  unset DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
  eval "$(dbus-launch --sh-syntax 2>>"$LOG_DIR/dbus.log")"
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    {
      echo "DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'"
      echo "DBUS_SESSION_BUS_PID=$DBUS_SESSION_BUS_PID"
    } > "$SESSION_ENV"
  fi
fi
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then export DBUS_SESSION_BUS_ADDRESS; else DBUS_SESSION_BUS_ADDRESS=""; fi

# The accessibility bus (at-spi2-core): cua-driver's get_window_state and any
# other AT-SPI client resolve window trees through it. --launch-immediately
# starts it now instead of on first use, and it registers on the session bus
# (org.a11y.Bus) and on the X root window (AT_SPI_BUS).
if ! mine -f at-spi-bus-launcher; then
  for launcher in /usr/libexec/at-spi-bus-launcher /usr/lib/at-spi2-core/at-spi-bus-launcher; do
    [ -x "$launcher" ] || continue
    "$launcher" --launch-immediately >>"$LOG_DIR/at-spi.log" 2>&1 &
    break
  done
fi

if ! mine -x openbox; then
  openbox >>"$LOG_DIR/openbox.log" 2>&1 &
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

if ! mine -x tint2; then
  tint2 -c /etc/cmux/tint2rc >>"$LOG_DIR/tint2.log" 2>&1 &
fi

# TigerVNC moves clipboard text between the viewer (the noVNC pane) and X
# selections only while its helper is attached to the display.
if command -v vncconfig >/dev/null 2>&1 && ! mine -x vncconfig; then
  vncconfig -nowin >>"$LOG_DIR/vncconfig.log" 2>&1 &
fi

# noVNC's remote resize grows the display live, but the root pixmap keeps its
# old size (X tiles it: the doubled-wallpaper bug) and tint2 keeps its old
# strut. Re-fill the wallpaper and nudge tint2 on every RandR screen change,
# delivered as events by xev; the watcher exits with the display and the next
# supervisor pass restarts it. `bash -c '…' cmux-desktop-resize-watch` puts
# the marker in $0 so the pgrep guard finds the loop on the next idempotent
# pass.
if ! mine -f cmux-desktop-resize-watch; then
  bash -c '
    xev -root -event randr 2>/dev/null | while read -r line; do
      case $line in
        *RRScreenChangeNotify*)
          feh --no-fehbg --bg-fill /usr/share/backgrounds/cmux/wallpaper.jpg >/dev/null 2>&1 || true
          pkill -USR1 -U "$(id -u)" -x tint2 >/dev/null 2>&1 || true
          ;;
      esac
    done
  ' cmux-desktop-resize-watch >>"$LOG_DIR/resize-watch.log" 2>&1 &
fi

# noVNC web client + websocket proxy on 6901 (the app's desktop port).
if ! listening 6901; then
  websockify --web /usr/share/novnc --heartbeat 30 0.0.0.0:6901 127.0.0.1:5901 \
    >>"$LOG_DIR/websockify.log" 2>&1 &
fi

# Publish the session for other shells (/etc/cmux/desktop-env.sh): the
# display, and the accessibility bus once its name is owned on the session
# bus (gdbus wait is the owner's signal), under both names clients use
# (AT_SPI_BUS_ADDRESS is what the atspi library connects to; AT_SPI_BUS is
# the launcher's X property name, what cua-driver's doctor checks). Written
# atomically; a runtime dir that does not exist or is not ours (no systemd
# RuntimeDirectory=, no supervisor) simply gets no file.
published=0
if [ -d "$RUNTIME_DIR" ] && [ -w "$RUNTIME_DIR" ]; then
  a11y_bus=""
  if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
    if command -v gdbus >/dev/null 2>&1; then
      gdbus wait --session --timeout 10 org.a11y.Bus >>"$LOG_DIR/at-spi.log" 2>&1 || true
    fi
    a11y_bus=$(dbus-send --session --print-reply=literal --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress 2>/dev/null | tr -d ' \n')
  fi
  {
    echo "# generated by start-vnc.sh; the desktop session other shells attach to"
    echo "export DISPLAY='$DISPLAY'"
    [ -n "$a11y_bus" ] && echo "export AT_SPI_BUS_ADDRESS='$a11y_bus'"
    [ -n "$a11y_bus" ] && echo "export AT_SPI_BUS='$a11y_bus'"
    echo "CMUX_DESKTOP_UID=$(id -u)"
    [ -n "$DBUS_SESSION_BUS_ADDRESS" ] && echo "CMUX_DESKTOP_SESSION_BUS='$DBUS_SESSION_BUS_ADDRESS'"
  } > "$RUNTIME_DIR/env.tmp" 2>/dev/null && chmod 0644 "$RUNTIME_DIR/env.tmp" && mv -f "$RUNTIME_DIR/env.tmp" "$RUNTIME_DIR/env" && published=1
fi

# READY for systemd (cmux-desktop is Type=notify, NotifyAccess=all): the
# display accepts connections, noVNC is bound, and the env is published.
# Repeating it on later passes is harmless; a pass that finds something
# down leaves the unit's state to systemd (Restart=always) and this loop.
if [ -n "$CMUX_NOTIFY_SOCKET" ] && command -v systemd-notify >/dev/null 2>&1; then
  if listening 5901 && wait_listening 6901 10 && [ "$published" = 1 ]; then
    NOTIFY_SOCKET="$CMUX_NOTIFY_SOCKET" systemd-notify --ready --status="desktop up on $DISPLAY: RFB 5901 (loopback), noVNC 6901" 2>>"$LOG_DIR/notify.log" || true
  fi
fi

exit 0
