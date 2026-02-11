#!/usr/bin/env python3
"""
Regression test: creating a new terminal surface (nested tab) inside an existing split
must become interactive and render output immediately, without requiring a focus toggle.

Bug: after many splits, creating a new tab could show only initial output (e.g. "Last login")
and then appear "frozen" until the user alt-tabs or changes pane focus. Input would be
buffered and only appear after refocus.

We validate rendering by:
  1) Taking two baseline panel snapshots (to estimate noise like cursor blink).
  2) Typing a command that prints many lines.
  3) Taking an "after" panel snapshot and asserting the panel materially changed vs baseline.

Note: We use `panel_snapshot` instead of window screenshots to avoid macOS Screen Recording
permissions on the UTM VM.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _wait_for_terminal_focus(c: cmux, panel_id: str, timeout_s: float = 2.0) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if c.is_terminal_focused(panel_id):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for terminal focus: {panel_id}")


def _panel_snapshot_retry(c: cmux, panel_id: str, label: str, timeout_s: float = 3.0) -> dict:
    start = time.time()
    last_err: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            return dict(c.panel_snapshot(panel_id, label=label) or {})
        except Exception as e:
            last_err = e
            if "Failed to capture panel image" not in str(e):
                raise
            time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for panel_snapshot: panel_id={panel_id} label={label}: {last_err!r}")


def _ratio(changed_pixels: int, width: int, height: int) -> float:
    denom = max(1, int(width) * int(height))
    return float(max(0, int(changed_pixels))) / float(denom)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        c.new_workspace()
        time.sleep(0.3)

        # Create a dense layout (similar to "4 splits") to exercise attach/focus races.
        for _ in range(4):
            c.new_split("right")
            time.sleep(0.25)

        panes = c.list_panes()
        if len(panes) < 2:
            raise cmuxError(f"expected multiple panes, got: {panes}")

        mid = len(panes) // 2
        c.focus_pane(mid)
        time.sleep(0.2)

        # Create a new nested tab in the focused pane.
        new_id = c.new_surface(panel_type="terminal")
        time.sleep(0.35)

        # Ensure the app/key window is active before asserting first-responder focus.
        c.activate_app()
        time.sleep(0.2)

        # The new surface should be focused and interactive immediately.
        _wait_for_terminal_focus(c, new_id, timeout_s=6.0)

        # Reset any prior snapshot state for this panel so our diffs are deterministic.
        c.panel_snapshot_reset(new_id)

        # Baseline snapshots to estimate noise (cursor blink, etc).
        s0 = _panel_snapshot_retry(c, new_id, "newtab_baseline0")
        time.sleep(0.25)
        s1 = _panel_snapshot_retry(c, new_id, "newtab_baseline1")

        # Type a command that prints many lines (large visual delta).
        c.simulate_type("for i in {1..40}; do echo CMUX_DRAW_$i; done")
        c.simulate_shortcut("enter")
        time.sleep(0.45)

        s2 = _panel_snapshot_retry(c, new_id, "newtab_after")

        w1 = int(s1.get("width") or 0)
        h1 = int(s1.get("height") or 0)
        w2 = int(s2.get("width") or 0)
        h2 = int(s2.get("height") or 0)
        if w1 <= 0 or h1 <= 0 or (w1, h1) != (w2, h2):
            raise cmuxError(f"panel_snapshot dims differ: {(w1,h1)} {(w2,h2)}; paths: {s1.get('path')} {s2.get('path')}")

        noise_px = int(s1.get("changed_pixels") or 0)
        change_px = int(s2.get("changed_pixels") or 0)
        # -1 means "no previous snapshot" or size mismatch; treat as a hard failure for this test.
        if noise_px < 0 or change_px < 0:
            raise cmuxError(
                "panel_snapshot diff unavailable (size mismatch or missing previous).\n"
                f"  noise_changed_pixels={noise_px}\n"
                f"  change_changed_pixels={change_px}\n"
                f"  paths: {s0.get('path')} {s1.get('path')} {s2.get('path')}"
            )

        noise = _ratio(noise_px, w1, h1)
        change = _ratio(change_px, w1, h1)

        # Require a material visual change relative to baseline noise.
        threshold = max(0.01, noise * 4.0)
        if change <= threshold:
            # Diagnostics: try a focus toggle and capture evidence; in the bug, this "unfreezes".
            try:
                other = 0 if mid != 0 else min(1, len(panes) - 1)
                c.focus_pane(other)
                time.sleep(0.25)
                c.focus_pane(mid)
                time.sleep(0.35)
                s3 = _panel_snapshot_retry(c, new_id, "newtab_after_refocus")
                refocus_px = int(s3.get("changed_pixels") or 0)
                refocus_change = _ratio(refocus_px, w1, h1) if refocus_px >= 0 else -1.0
            except Exception:
                refocus_change = -1.0

            raise cmuxError(
                "New tab did not render output immediately after typing.\n"
                f"  noise_ratio={noise:.5f}\n"
                f"  change_ratio={change:.5f} (threshold={threshold:.5f})\n"
                f"  refocus_change_ratio={refocus_change:.5f}\n"
                f"  snapshots: {s0.get('path')} {s1.get('path')} {s2.get('path')}"
            )

    print("PASS: new tab renders immediately after many splits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
