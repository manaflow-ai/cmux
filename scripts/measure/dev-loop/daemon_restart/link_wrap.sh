#!/bin/sh
# The cmux-tui binary's linker during the daemon_restart measurement: rustc_wrap.py times the link
# and runs the linker cargo configured (DLC_REAL_LINKER, else cc).
exec python3 "$(dirname "$0")/rustc_wrap.py" --link "$@"
