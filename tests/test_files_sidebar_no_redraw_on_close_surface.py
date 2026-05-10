#!/usr/bin/env python3
"""
Regression: closing a split while the Files right sidebar is open must not make
the Files AppKit tree relayout/repaint when no Files-owned state changed.

The old screenshot check missed the flicker because the window settled before
the screenshot. This test uses debug counters inside the Files NSView tree and
fails on the transient redraw source itself.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


def _wait_until(predicate, timeout_s: float = 5.0, interval_s: float = 0.05) -> bool:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def main() -> int:
    socket_path = os.environ.get("CMUX_SOCKET_PATH") or cmux.default_socket_path()
    if not os.path.exists(socket_path):
        print(f"SKIP: Socket not found at {socket_path}")
        print("Tip: start a tagged Debug app first, or set CMUX_TAG / CMUX_SOCKET_PATH.")
        return 0

    with cmux(socket_path) as client:
        workspace_id = None
        try:
            client.activate_app()
            time.sleep(0.2)

            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            time.sleep(0.4)

            response = client._send_command("debug_right_sidebar_focus files")
            if not response.startswith("OK"):
                raise cmuxError(f"Failed to reveal Files sidebar: {response}")
            time.sleep(0.5)

            client.new_split("right")
            if not _wait_until(lambda: len(client.list_surfaces()) == 2, timeout_s=4.0):
                raise cmuxError(f"Expected 2 surfaces before close, got {client.list_surfaces()}")
            time.sleep(0.4)

            client.reset_file_explorer_debug_counts()
            client.close_surface(1)
            if not _wait_until(lambda: len(client.list_surfaces()) == 1, timeout_s=4.0):
                raise cmuxError(f"Expected 1 surface after close, got {client.list_surfaces()}")
            time.sleep(0.35)

            counts = client.file_explorer_debug_counts()
            failures = []
            if counts.get("searchLayoutInvalidations", 0) != 0:
                failures.append(
                    "Files invalidated AppKit layout during split close: "
                    f"{counts.get('searchLayoutInvalidations')}"
                )
            if counts.get("outlineReloads", 0) != 0 or counts.get("outlineRefreshes", 0) != 0:
                failures.append(
                    "Files outline data refreshed during split close: "
                    f"reloads={counts.get('outlineReloads')} refreshes={counts.get('outlineRefreshes')}"
                )

            if failures:
                raise cmuxError(
                    "Files sidebar redraw regression reproduced.\n"
                    f"workspace={workspace_id}\n"
                    f"counts={counts}\n"
                    + "\n".join(f"failure={failure}" for failure in failures)
                )

            print(f"PASS: split close did not dirty Files sidebar AppKit layout ({counts})")
            return 0
        finally:
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except cmuxError as exc:
        print(f"FAIL: {exc}")
        raise SystemExit(1) from exc
