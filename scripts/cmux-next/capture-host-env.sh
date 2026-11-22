# Sourced by the capture-slot scripts (restore-journey-slot.sh, perceived-speed-slot.sh): puts HQ's
# capture-host on PATH and, on a Mac without leo-workspace's fleet registry copy, the ssh routes to the
# capture minis that HQ's build-fleet/pr_capture/fleet_routes.py writes from mini-fleet.json, so this
# script's own ssh and scp reach the host capture-host leased.
#
# capture-host comes from PATH, else the installed copy of HQ main (`cmux-ci capture` keeps it current at
# ${CMUX_HQ_TOOLS_HOME:-~/.local/share/cmux/hq-tools}/current). Before 2026-10-28 neither was set up on
# Lawrence's Mac, so every slot run there failed before it leased.
capture_host_bin=$(command -v capture-host 2>/dev/null || true)
if [ -z "$capture_host_bin" ]; then
  candidate="${CMUX_HQ_TOOLS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/cmux/hq-tools}/current/build-fleet/capture-host"
  if [ -x "$candidate" ]; then
    capture_host_bin=$candidate
    PATH="$(dirname "$candidate"):$PATH"
    export PATH
  fi
fi
if [ -n "$capture_host_bin" ]; then
  capture_host_routes="$(cd "$(dirname "$capture_host_bin")" && pwd -P)/pr_capture/fleet_routes.py"
  if [ -f "$capture_host_routes" ]; then
    eval "$(python3 -I "$capture_host_routes" ensure)"
  fi
fi
unset capture_host_bin candidate capture_host_routes
