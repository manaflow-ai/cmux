"""The environment for `/usr/bin/open` when a script launches a cmux NEXT app on its own socket.

`open` hands the launched app the caller's environment as well as what `--env` names. A script's
CLI environment sets CMUX_SOCKET_PATH (so its `cmux` calls reach the run's socket), and that variable
is one of LaunchIdentity.otherCmuxMarkers: an app that inherits it believes another cmux started it
and strips CMUX_NEXT_SOCKET_PATH with the other state-root knobs, so it binds its default socket and
the run's CLI never reaches it ("launched app ready: exit 3", app.unreachable). The daily Cloud chat
proof failed that way from 11-17 after its launcher began passing the CLI environment (#41027).

Launch with `launch_env(cli_env)`, never the CLI environment itself.
"""

from __future__ import annotations

from collections.abc import Mapping

# LaunchIdentity.otherCmuxMarkers, plus the caller context a cmux terminal exports
# (scripts/cmux-next/media/tour.py SCRUBBED_ENV).
OTHER_CMUX_MARKERS = ("CMUX_SOCKET_PATH", "CMUX_BUNDLE_ID", "CMUX_TAG", "MUX_AGENT_TOKEN_FILE")
CALLER_CONTEXT = ("CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_SOCKET_PASSWORD",
                  "CMUX_TUI_SOCKET", "CMUX_SOCKET")


def launch_env(env: Mapping[str, str]) -> dict[str, str]:
    """`env` without any variable that makes the launched app take itself for another cmux's child."""
    dropped = set(OTHER_CMUX_MARKERS) | set(CALLER_CONTEXT)
    return {key: value for key, value in env.items() if key not in dropped}
