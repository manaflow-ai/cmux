#!/usr/bin/env python3
"""
Regression: a Ctrl-D closed terminal must never become visible again before deinit.

This targets the "ghost terminal" race:
  1) close starts (`surface.close.childExited`)
  2) panel is detached
  3) stale host callback re-binds the same surface
  4) it flips visible/active again (`ws.term.visible transition=0->1`)
  5) deinit only happens later

Old behavior can pass steady-state orphan counts while still showing this transient bug.
"""

import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
LOG_PATH_OVERRIDE = os.environ.get("CMUX_DEBUG_LOG")
ITERATIONS = int(os.environ.get("CMUX_PORTAL_ORPHAN_ITERS", "16"))
PANE_TIMEOUT_S = float(os.environ.get("CMUX_PORTAL_ORPHAN_PANE_TIMEOUT_S", "3.0"))
INTEGRITY_TIMEOUT_S = float(os.environ.get("CMUX_PORTAL_ORPHAN_INTEGRITY_TIMEOUT_S", "1.5"))
POLL_S = float(os.environ.get("CMUX_PORTAL_ORPHAN_POLL_S", "0.02"))
CTRL_D_RETRY_INTERVAL_S = float(os.environ.get("CMUX_PORTAL_ORPHAN_CTRL_D_RETRY_INTERVAL_S", "0.20"))
CTRL_D_MAX_EXTRA = int(os.environ.get("CMUX_PORTAL_ORPHAN_CTRL_D_MAX_EXTRA", "3"))
POST_CLOSE_SETTLE_S = float(os.environ.get("CMUX_PORTAL_ORPHAN_POST_CLOSE_SETTLE_S", "0.08"))
LOG_FLUSH_S = float(os.environ.get("CMUX_PORTAL_ORPHAN_LOG_FLUSH_S", "0.15"))

RE_CLOSE = re.compile(r"surface\.close\.childExited .* surface=([0-9A-F]{5})\b")
RE_DEINIT_BEGIN = re.compile(r"surface\.lifecycle\.deinit\.begin surface=([0-9A-F]{5})\b")
RE_DEINIT_END = re.compile(r"surface\.lifecycle\.deinit\.end surface=([0-9A-F]{5})\b")
RE_VISIBLE_ON = re.compile(r"ws\.term\.visible .* surface=([0-9A-F]{5}) .* transition=0->1\b")


def _derive_log_path(socket_path: str) -> str:
    if LOG_PATH_OVERRIDE:
        return LOG_PATH_OVERRIDE
    base = os.path.basename(socket_path)
    if base.startswith("cmux-debug-") and base.endswith(".sock"):
        slug = base[len("cmux-debug-") : -len(".sock")]
        return f"/tmp/cmux-debug-{slug}.log"
    return "/tmp/cmux-debug.log"


def _read_new_lines(log_path: str, offset: int) -> tuple[list[str], int]:
    if not os.path.exists(log_path):
        raise cmuxError(f"debug log not found at {log_path}")
    with open(log_path, "rb") as f:
        f.seek(offset)
        data = f.read()
        new_offset = f.tell()
    if not data:
        return [], new_offset
    return data.decode("utf-8", errors="replace").splitlines(), new_offset


def _pane_count(layout_payload: dict) -> int:
    return len((layout_payload.get("layout") or {}).get("panes") or [])


def _selected_panel_by_pane(layout_payload: dict) -> dict[str, str]:
    out: dict[str, str] = {}
    for row in layout_payload.get("selectedPanels") or []:
        pane_id = str(row.get("paneId") or "")
        panel_id = str(row.get("panelId") or "")
        if pane_id and panel_id:
            out[pane_id] = panel_id
    return out


def _pane_sort_key(pane: dict) -> tuple[float, float]:
    frame = pane.get("frame") or {}
    x = float(frame.get("x", 0.0))
    y = float(frame.get("y", 0.0))
    return (x, y)


def _panel_for_pane(layout_payload: dict, pane: dict) -> str:
    pane_id = str(pane.get("paneId") or "")
    selected = _selected_panel_by_pane(layout_payload)
    panel_id = str(selected.get(pane_id) or "")
    if not panel_id:
        raise cmuxError(f"missing selected panel for pane: pane_id={pane_id} selected={selected}")
    return panel_id


def _rightmost_panel(layout_payload: dict) -> str:
    panes = (layout_payload.get("layout") or {}).get("panes") or []
    if len(panes) < 2:
        raise cmuxError(f"expected >=2 panes to find rightmost panel, got {len(panes)}")
    rightmost = max(panes, key=_pane_sort_key)
    return _panel_for_pane(layout_payload, rightmost)


def _bottom_right_panel(layout_payload: dict) -> str:
    panes = (layout_payload.get("layout") or {}).get("panes") or []
    if len(panes) < 3:
        raise cmuxError(f"expected >=3 panes to find bottom-right panel, got {len(panes)}")
    bottom_right = max(panes, key=_pane_sort_key)
    return _panel_for_pane(layout_payload, bottom_right)


def _wait_for_panes(c: cmux, target_panes: int, *, timeout_s: float, context: str) -> dict:
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        last = c.layout_debug()
        if _pane_count(last) == target_panes:
            return last
        time.sleep(POLL_S)
    raise cmuxError(
        f"timed out waiting for {target_panes} panes ({context}); "
        f"last_panes={_pane_count(last or {})} last_layout={last}"
    )


def _portal_stats(c: cmux, *, timeout_s: float) -> dict:
    stats = c._call("debug.portal.stats", timeout_s=timeout_s) or {}
    if not isinstance(stats, dict):
        raise cmuxError(f"debug.portal.stats returned non-dict payload: {stats!r}")
    return stats


def _portal_integrity_error(stats: dict) -> str | None:
    totals = stats.get("totals") or {}
    if not isinstance(totals, dict):
        return f"portal totals payload is not a dict: {totals!r}"

    required_keys = (
        "orphan_terminal_subview_count",
        "visible_orphan_terminal_subview_count",
        "stale_entry_count",
    )
    missing = [key for key in required_keys if key not in totals]
    if missing:
        return f"portal totals missing required counters: {', '.join(missing)}"

    try:
        orphan = int(totals["orphan_terminal_subview_count"])
        visible_orphan = int(totals["visible_orphan_terminal_subview_count"])
        stale = int(totals["stale_entry_count"])
    except (TypeError, ValueError):
        return (
            "portal totals contains non-integer counters "
            f"(orphan={totals.get('orphan_terminal_subview_count')!r}, "
            f"visible_orphan={totals.get('visible_orphan_terminal_subview_count')!r}, "
            f"stale={totals.get('stale_entry_count')!r})"
        )

    if orphan != 0 or visible_orphan != 0 or stale != 0:
        return (
            "portal totals show orphan/stale entries "
            f"(orphan={orphan}, visible_orphan={visible_orphan}, stale={stale})"
        )
    return None


def _wait_for_portal_integrity(c: cmux, *, timeout_s: float, context: str) -> None:
    deadline = time.time() + timeout_s
    last = None
    error = None
    while time.time() < deadline:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        last = _portal_stats(c, timeout_s=min(remaining, 0.5))
        error = _portal_integrity_error(last)
        if error is None:
            return
        time.sleep(POLL_S)
    raise cmuxError(f"{context}: {error}; stats={last}")


def _close_bottom_right_via_ctrl_d(c: cmux, *, bottom_right_panel_id: str, context: str) -> dict:
    c.send_key_surface(bottom_right_panel_id, "ctrl-d")
    next_retry_at = time.time() + CTRL_D_RETRY_INTERVAL_S
    extra = 0
    deadline = time.time() + PANE_TIMEOUT_S
    last = None

    while time.time() < deadline:
        last = c.layout_debug()
        if _pane_count(last) == 2:
            return last

        if extra < CTRL_D_MAX_EXTRA and time.time() >= next_retry_at:
            c.send_key_surface(bottom_right_panel_id, "ctrl-d")
            extra += 1
            next_retry_at = time.time() + CTRL_D_RETRY_INTERVAL_S
        time.sleep(POLL_S)

    raise cmuxError(
        f"{context}: timed out collapsing back to 2 panes after ctrl-d "
        f"(extra_ctrl_d={extra}, panel={bottom_right_panel_id}); last_layout={last}"
    )


def _find_close_rebind_violations(lines: list[str]) -> tuple[int, list[str]]:
    close_pending: set[str] = set()
    deinit_started: set[str] = set()
    close_count = 0
    violations: list[str] = []

    for line in lines:
        m = RE_CLOSE.search(line)
        if m:
            sid = m.group(1)
            close_pending.add(sid)
            close_count += 1
            continue

        m = RE_DEINIT_BEGIN.search(line)
        if m:
            sid = m.group(1)
            deinit_started.add(sid)
            continue

        m = RE_DEINIT_END.search(line)
        if m:
            sid = m.group(1)
            close_pending.discard(sid)
            deinit_started.discard(sid)
            continue

        m = RE_VISIBLE_ON.search(line)
        if m:
            sid = m.group(1)
            if sid in close_pending:
                violations.append(line)

    return close_count, violations


def main() -> int:
    log_path = _derive_log_path(SOCKET_PATH)
    if not os.path.exists(log_path):
        raise cmuxError(f"debug log not found at {log_path} for socket={SOCKET_PATH}")
    log_offset = os.path.getsize(log_path)

    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        workspace_id = c.new_workspace()
        c.select_workspace(workspace_id)
        time.sleep(0.2)

        c.new_split("right")
        layout = _wait_for_panes(c, 2, timeout_s=PANE_TIMEOUT_S, context="initial right split")
        _wait_for_portal_integrity(c, timeout_s=INTEGRITY_TIMEOUT_S, context="after initial right split")

        for iteration in range(1, ITERATIONS + 1):
            right_panel_id = _rightmost_panel(layout)
            c.focus_surface_by_panel(right_panel_id)
            c.new_split("down")
            layout = _wait_for_panes(
                c,
                3,
                timeout_s=PANE_TIMEOUT_S,
                context=f"iter={iteration} after split down",
            )

            bottom_right_panel_id = _bottom_right_panel(layout)
            layout = _close_bottom_right_via_ctrl_d(
                c,
                bottom_right_panel_id=bottom_right_panel_id,
                context=f"iter={iteration}",
            )
            _wait_for_portal_integrity(c, timeout_s=INTEGRITY_TIMEOUT_S, context=f"iter={iteration} integrity")
            if POST_CLOSE_SETTLE_S > 0:
                time.sleep(POST_CLOSE_SETTLE_S)

        c.close_workspace(workspace_id)

    if LOG_FLUSH_S > 0:
        time.sleep(LOG_FLUSH_S)
    lines, _ = _read_new_lines(log_path, log_offset)
    close_count, violations = _find_close_rebind_violations(lines)
    if close_count == 0:
        raise cmuxError("no surface.close.childExited events captured; test did not exercise close path")
    if violations:
        sample = "\n".join(violations[:5])
        raise cmuxError(
            "detected close->visible rebind race (closed surface became visible before deinit):\n"
            f"{sample}"
        )

    print(
        "PASS: no close->visible rebind races during split-down + ctrl-d churn "
        f"(iters={ITERATIONS}, closes={close_count})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
