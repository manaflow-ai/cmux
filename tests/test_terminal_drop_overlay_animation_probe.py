#!/usr/bin/env python3
"""
Regression test: terminal drop-target overlay should animate on initial show.

This exercises the focused terminal's drop-overlay code path via debug socket
commands (no Accessibility/TCC/sudo required).
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = (
    os.environ.get("CMUX_SOCKET")
    or os.environ.get("CMUX_SOCKET_PATH")
    or "/tmp/cmux-debug.sock"
)


def _parse_probe_response(response: str) -> dict[str, str]:
    if not response.startswith("OK "):
        raise cmuxError(response)
    parsed: dict[str, str] = {}
    for token in response.split()[1:]:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        parsed[key] = value
    return parsed


def _parse_bounds(bounds: str) -> tuple[float, float]:
    parts = bounds.split("x", 1)
    if len(parts) != 2:
        raise cmuxError(f"Unexpected bounds format: {bounds}")
    return float(parts[0]), float(parts[1])


def main() -> int:
    with cmux(SOCKET_PATH) as client:
        client.activate_app()
        workspace_id = client.new_workspace()
        try:
            client.select_workspace(workspace_id)
            time.sleep(0.25)

            deferred_raw = client._send_command("terminal_drop_overlay_probe deferred")
            deferred = _parse_probe_response(deferred_raw)
            direct_raw = client._send_command("terminal_drop_overlay_probe direct")
            direct = _parse_probe_response(direct_raw)

            width, height = _parse_bounds(deferred.get("bounds", "0x0"))
            if width <= 2 or height <= 2:
                raise cmuxError(
                    f"Focused terminal bounds too small for overlay probe: {width}x{height}"
                )

            if deferred.get("animated") != "1":
                raise cmuxError(
                    "Deferred drop-overlay show did not animate. "
                    f"response={deferred_raw}"
                )
            if direct.get("animated") != "1":
                raise cmuxError(
                    "Direct drop-overlay show did not animate. "
                    f"response={direct_raw}"
                )
        finally:
            try:
                client.close_workspace(workspace_id)
            except Exception:
                # Keep the test focused on overlay behavior; cleanup best-effort.
                pass

    print("PASS: terminal drop overlay animates for deferred and direct show paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
