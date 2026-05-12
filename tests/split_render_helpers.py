#!/usr/bin/env python3
"""Shared runtime assertions for terminal split rendering tests."""

from __future__ import annotations

import time
from typing import Any

from cmux import cmuxError


def _panel_snapshot_retry(c: Any, panel_id: str, label: str, timeout_s: float = 3.0) -> dict:
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


def _snapshot_ratio(snapshot: dict) -> float:
    changed = int(snapshot.get("changed_pixels") or 0)
    width = int(snapshot.get("width") or 0)
    height = int(snapshot.get("height") or 0)
    return float(max(0, changed)) / float(max(1, width * height))


def assert_split_terminal_renders_output(c: Any, panel_id: str) -> None:
    if not panel_id:
        terminal_rows = [row for row in c.surface_health() if row.get("type") == "terminal"]
        if len(terminal_rows) < 2:
            raise cmuxError(f"Expected split terminal surface, got health={terminal_rows}")
        panel_id = terminal_rows[-1]["id"]

    c.panel_snapshot_reset(panel_id)
    _panel_snapshot_retry(c, panel_id, "split_render_noise_baseline")
    time.sleep(0.2)
    noise_snapshot = _panel_snapshot_retry(c, panel_id, "split_render_noise_sample")
    noise = _snapshot_ratio(noise_snapshot)

    c.panel_snapshot_reset(panel_id)
    pre_send = _panel_snapshot_retry(c, panel_id, "split_render_pre_send")
    pre_dims = (int(pre_send.get("width") or 0), int(pre_send.get("height") or 0))
    if pre_dims[0] <= 0 or pre_dims[1] <= 0:
        raise cmuxError(f"panel_snapshot has invalid dims before send: {pre_dims}; path={pre_send.get('path')}")

    draw_cmd = "i=0; while [ $i -lt 30 ]; do echo CMUX_SPLIT_RENDER_$i; i=$((i+1)); done\n"
    c.send_surface(panel_id, draw_cmd)

    threshold = max(0.01, noise * 5.0)
    deadline = time.time() + 3.0
    last_snapshot = pre_send
    last_change = 0.0
    while time.time() < deadline:
        last_snapshot = _panel_snapshot_retry(c, panel_id, "split_render_after", timeout_s=0.5)
        dims = (int(last_snapshot.get("width") or 0), int(last_snapshot.get("height") or 0))
        if dims[0] <= 0 or dims[1] <= 0 or dims != pre_dims:
            raise cmuxError(
                f"panel_snapshot dims differ: {pre_dims} {dims}; "
                f"paths: {pre_send.get('path')} {last_snapshot.get('path')}"
            )
        last_change = _snapshot_ratio(last_snapshot)
        if last_change > threshold:
            return
        time.sleep(0.1)

    raise cmuxError(
        "New split terminal did not render output immediately.\n"
        f"  noise_ratio={noise:.5f}\n"
        f"  change_ratio={last_change:.5f} (threshold={threshold:.5f})\n"
        f"  snapshots: {pre_send.get('path')} {last_snapshot.get('path')}"
    )
