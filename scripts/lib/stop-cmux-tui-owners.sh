#!/bin/bash
# Stop the cmux-tui owner daemons of one app bundle, and end their terminals,
# without signaling a terminal host.
#
# cmux_stop_cmux_tui_owners BIN_DIR
#   BIN_DIR  the bundle's Contents/Resources/bin directory.
#
# Every terminal host runs the same bundled `cmux-tui` executable as its
# owner (`cmux-tui __terminal-host`), so `pkill -f "$BIN_DIR/cmux-tui"` or
# `pkill -f "$APP/"` also kills every host. A host is the only holder of its
# terminal's PTY: killing it hangs up the shell and leaves no exit record
# (the terminal shows "Terminal lost"). This helper finds only the owners
# (`<BIN_DIR>/cmux-tui --headless ... --socket S`) and asks each to stop with
# `server stop --end-terminals`, which ends every terminal through its host.
# Only if that request fails does it send SIGTERM to the exact owner PID; the
# owner then exits and leaves its hosts running for re-adoption (it never
# ends a host on SIGTERM).
cmux_stop_cmux_tui_owners() {
  local bin_dir="${1%/}"
  local exe="$bin_dir/cmux-tui"
  [[ -x "$exe" ]] || return 0
  local pid args socket
  while read -r pid args; do
    [[ -n "$pid" ]] || continue
    # Exact executable, owner mode only; hosts run `__terminal-host`.
    [[ "$args" == "$exe --headless "* ]] || continue
    socket="$(printf '%s\n' "$args" | sed -nE 's/.* --socket ([^ ]+).*/\1/p')"
    if [[ -n "$socket" ]] && "$exe" --socket "$socket" server stop --end-terminals >/dev/null 2>&1; then
      continue
    fi
    echo "cmux_stop_cmux_tui_owners: server stop failed for owner PID $pid; sending SIGTERM to that PID only (its terminal hosts keep running)" >&2
    kill -TERM "$pid" 2>/dev/null || true
  done < <(ps -axww -o pid= -o args= 2>/dev/null)
}
