# cmux Cloud devbox desktop shell env (/etc/cmux/desktop-env.sh), desktop
# images only. Sourced from /etc/profile.d/cmux-desktop.sh (login and exec
# shells) and the bashrc chain (interactive shells, the panes the cmux-tui
# daemon opens).
#
# Points a shell that has no DISPLAY at the machine's VNC desktop while it is
# up, so browser automation (agent-browser, Chrome), xdotool and computer-use
# (cua-driver mcp/call) act on the screen a person can watch in the Displays
# pane, and hands them the desktop's accessibility bus (AT_SPI_BUS_ADDRESS
# for AT-SPI clients, AT_SPI_BUS for cua-driver's doctor) so window trees
# resolve. The session's own user also gets its D-Bus session bus (apps it
# launches from a terminal join the desktop's bus); other accounts do not,
# since the bus admits only its owner.
#
# Never overrides a DISPLAY the shell already has (ssh -X, a nested session),
# and does nothing while the desktop is down: /run/cmux-desktop/env is written
# by start-vnc.sh (web/services/vms/images/desktop.ts) and the display socket
# is the liveness check. Cheap: two stats and a small source.
if [ -z "${DISPLAY-}" ] && [ -r /run/cmux-desktop/env ] && [ -S /tmp/.X11-unix/X1 ]; then
  . /run/cmux-desktop/env
  if [ -n "${CMUX_DESKTOP_SESSION_BUS-}" ] && [ -z "${DBUS_SESSION_BUS_ADDRESS-}" ] \
    && [ "${CMUX_DESKTOP_UID-}" = "$(id -u)" ]; then
    DBUS_SESSION_BUS_ADDRESS="$CMUX_DESKTOP_SESSION_BUS"
    export DBUS_SESSION_BUS_ADDRESS
  fi
  unset CMUX_DESKTOP_UID CMUX_DESKTOP_SESSION_BUS
fi
