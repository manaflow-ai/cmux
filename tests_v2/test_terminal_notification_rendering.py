#!/usr/bin/env python3
"""
Regression test: an OSC 777 completion notification must not blank the focused
terminal surface.

The bug in issue 3026 was visible state loss, not terminal data loss: the
sidebar still showed the session needed input, but the portal-hosted Ghostty
surface went blank until a tab switch forced a refresh. This test exercises the
real OSC notification path and checks both portal visibility and post-notification
rendering.
"""

import os
import sys
import time
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_for(
    predicate: Callable[[], bool],
    *,
    timeout_s: float = 5.0,
    cadence_s: float = 0.05,
    label: str = "condition",
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(cadence_s)
    raise cmuxError(f"Timed out waiting for {label}")


def _focused_surface_id(c: cmux) -> str:
    surfaces = c.list_surfaces()
    if not surfaces:
        raise cmuxError("Expected at least one terminal surface")
    return next((sid for _idx, sid, focused in surfaces if focused), surfaces[0][1])


def _surface_health_row(c: cmux, surface_id: str) -> Optional[dict]:
    surface_id = surface_id.lower()
    for row in c.surface_health():
        if str(row.get("surface_id") or "").lower() == surface_id:
            return row
    return None


def _rect_size(rect: object) -> tuple[float, float]:
    if not isinstance(rect, dict):
        return (0.0, 0.0)
    return (
        float(rect.get("width") or 0.0),
        float(rect.get("height") or 0.0),
    )


def _assert_surface_visible(c: cmux, surface_id: str, context: str) -> None:
    row = _surface_health_row(c, surface_id)
    if row is None:
        raise cmuxError(f"{context}: surface missing from health output: {surface_id}")

    failures: list[str] = []
    expected_true = [
        "mapped",
        "tree_visible",
        "workspace_selected",
        "surface_focused",
        "runtime_surface_ready",
        "hosted_view_in_window",
        "hosted_view_has_superview",
        "hosted_view_visible_in_ui",
    ]
    for key in expected_true:
        if row.get(key) is not True:
            failures.append(f"{key}={row.get(key)!r}")

    expected_false = [
        "hosted_view_hidden",
        "hosted_view_hidden_or_ancestor_hidden",
    ]
    for key in expected_false:
        if row.get(key) is not False:
            failures.append(f"{key}={row.get(key)!r}")

    width, height = _rect_size(row.get("hosted_view_frame"))
    if width < 80 or height < 80:
        failures.append(f"hosted_view_frame={row.get('hosted_view_frame')!r}")

    if failures:
        raise cmuxError(
            f"{context}: terminal surface is not visibly mounted after notification.\n"
            f"surface_id={surface_id}\n"
            f"failures={', '.join(failures)}\n"
            f"health_row={row}"
        )


def _assert_surface_stays_visible(
    c: cmux,
    surface_id: str,
    *,
    duration_s: float = 1.2,
    cadence_s: float = 0.02,
) -> None:
    deadline = time.time() + duration_s
    samples = 0
    while time.time() < deadline:
        _assert_surface_visible(c, surface_id, f"sample {samples}")
        samples += 1
        time.sleep(cadence_s)
    if samples == 0:
        _assert_surface_visible(c, surface_id, "final visibility sample")


def _send_osc777_notification(c: cmux, surface_id: str, title: str, body: str) -> None:
    # zsh/bash printf both interpret these escapes and emit the actual OSC 777.
    c.send_surface(surface_id, f"printf '\\033]777;notify;{title};{body}\\007'\n")


def _wait_for_notification(c: cmux, title: str, surface_id: str) -> None:
    surface_id = surface_id.lower()

    def seen() -> bool:
        for item in c.list_notifications():
            if str(item.get("title") or "") != title:
                continue
            if str(item.get("surface_id") or "").lower() == surface_id:
                return True
        return False

    _wait_for(seen, timeout_s=5.0, label=f"notification {title!r}")


def _wait_for_terminal_text(c: cmux, surface_id: str, text: str) -> None:
    _wait_for(
        lambda: text in c.read_terminal_text(surface_id),
        timeout_s=5.0,
        label=f"terminal text {text!r}",
    )


def _assert_renders_after_notification(c: cmux, surface_id: str, marker: str) -> None:
    c.panel_snapshot_reset(surface_id)
    before = c.panel_snapshot(surface_id, "notif_render_before")
    baseline_present = int(c.render_stats(surface_id).get("presentCount") or 0)

    c.send_surface(surface_id, f"printf '{marker}\\n'\n")
    _wait_for_terminal_text(c, surface_id, marker)

    def presented_new_contents() -> bool:
        stats = c.render_stats(surface_id)
        return int(stats.get("presentCount") or 0) > baseline_present

    _wait_for(presented_new_contents, timeout_s=2.0, label="new layer presentation")
    after = c.panel_snapshot(surface_id, "notif_render_after")
    changed_pixels = int(after.get("changed_pixels") or 0)
    if changed_pixels < 50:
        raise cmuxError(
            "Expected visible terminal pixels to change after OSC notification.\n"
            f"changed_pixels={changed_pixels}\n"
            f"before={before}\n"
            f"after={after}"
        )


def main() -> int:
    token = f"CMUX_OSC777_{int(time.time() * 1000)}"
    notify_title = f"{token}_TITLE"
    notify_body = f"{token}_BODY"
    after_marker = f"{token}_AFTER_NOTIFY_RENDER"

    with cmux(SOCKET_PATH) as c:
        try:
            c.activate_app()
            time.sleep(0.25)

            workspace_id = c.new_workspace()
            c.select_workspace(workspace_id)
            time.sleep(0.35)

            surface_id = _focused_surface_id(c)
            _wait_for(lambda: c.is_terminal_focused(surface_id), timeout_s=4.0, label="terminal focus")
            _assert_surface_visible(c, surface_id, "before notification")

            c.clear_notifications()
            _wait_for(lambda: not c.list_notifications(), timeout_s=3.0, label="notifications cleared")

            # Keep the window visible and focused while forcing the notification path to
            # store an unread notification and show the pane ring.
            c.set_app_focus(False)
            _send_osc777_notification(c, surface_id, notify_title, notify_body)
            _wait_for_notification(c, notify_title, surface_id)

            _assert_surface_stays_visible(c, surface_id)
            _assert_renders_after_notification(c, surface_id, after_marker)
        finally:
            try:
                c.set_app_focus(None)
            except Exception:
                pass

    print("PASS: OSC 777 notification keeps focused terminal visible and rendering")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
