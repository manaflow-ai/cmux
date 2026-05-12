#!/usr/bin/env python3
"""
Regression test for #2509: workspace churn must not leave portal-hosted content from
other workspaces bleeding across the reactivated workspace's pane bounds.

The repro pattern from the issue was:
  1. Create/close browser panes across several workspaces.
  2. Rename and reorder workspaces aggressively.
  3. Return to the original "HQ" workspace.
  4. Observe terminal/browser content layered on top of each other.

This test drives that path via the socket API and verifies that, after switching back
to the original workspace, the selected panels recover sane bounds and the terminal
portal registry no longer reports visible orphaned views.
"""

import json
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
MARKER_DIR = Path(tempfile.gettempdir())


def _v2(c: cmux, method: str, params: dict | None = None) -> dict:
    request = {
        "id": int(time.time() * 1000),
        "method": method,
        "params": params or {},
    }
    response = c._send_command(json.dumps(request))
    try:
        payload = json.loads(response)
    except json.JSONDecodeError as exc:
        raise cmuxError(f"{method} returned invalid JSON: {response[:200]}") from exc
    if not payload.get("ok"):
        error = payload.get("error") or {}
        raise cmuxError(
            f"{method} failed: {error.get('code', 'unknown')} {error.get('message', response)}"
        )
    result = payload.get("result")
    return result if isinstance(result, dict) else {}


def _open_browser(c: cmux, url: str) -> str:
    response = c._send_command(f"open_browser {url}")
    if not response.startswith("OK "):
        raise cmuxError(response)
    return response[3:]


def _rename_workspace(c: cmux, workspace_id: str, title: str) -> None:
    _v2(c, "workspace.rename", {"workspace_id": workspace_id, "title": title})


def _move_workspace_to_top(c: cmux, workspace_id: str) -> None:
    _v2(c, "workspace.action", {"workspace_id": workspace_id, "action": "move_top"})


def _reorder_workspace(c: cmux, workspace_id: str, index: int) -> None:
    _v2(c, "workspace.reorder", {"workspace_id": workspace_id, "index": index})


def _marker(name: str) -> Path:
    return MARKER_DIR / f"cmux_issue_2509_{name}_{os.getpid()}"


def _clear(marker: Path) -> None:
    marker.unlink(missing_ok=True)


def _wait_marker(marker: Path, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if marker.exists():
            return True
        time.sleep(0.1)
    return False


def _first_surface_index(c: cmux, panel_type: str) -> int | None:
    for row in c.surface_health():
        if row.get("type") == panel_type:
            return int(row["index"])
    return None


def _verify_terminal_responsive(c: cmux, surface_idx: int, marker: Path, retries: int = 3) -> bool:
    for _ in range(retries):
        _clear(marker)
        try:
            c.send_key_surface(surface_idx, "ctrl-c")
        except Exception:
            time.sleep(0.3)
        time.sleep(0.2)
        try:
            c.send_surface(surface_idx, f"touch {marker}\n")
        except Exception:
            time.sleep(0.4)
            continue
        if _wait_marker(marker, timeout=3.0):
            return True
        time.sleep(0.3)
    return False


def _rect_area(rect: dict) -> float:
    return max(0.0, float(rect.get("width", 0.0))) * max(0.0, float(rect.get("height", 0.0)))


def _rect_intersection_area(lhs: dict, rhs: dict) -> float:
    lx1 = float(lhs["x"])
    ly1 = float(lhs["y"])
    lx2 = lx1 + float(lhs["width"])
    ly2 = ly1 + float(lhs["height"])

    rx1 = float(rhs["x"])
    ry1 = float(rhs["y"])
    rx2 = rx1 + float(rhs["width"])
    ry2 = ry1 + float(rhs["height"])

    ix1 = max(lx1, rx1)
    iy1 = max(ly1, ry1)
    ix2 = min(lx2, rx2)
    iy2 = min(ly2, ry2)
    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    return (ix2 - ix1) * (iy2 - iy1)


def _assert_selected_panels_healthy(payload: dict, *, min_panels: int, min_wh: float = 80.0) -> None:
    selected = payload.get("selectedPanels") or []
    if len(selected) < min_panels:
        raise cmuxError(f"layout_debug expected >= {min_panels} selected panels, got {len(selected)}")

    for i, row in enumerate(selected):
        pane_id = row.get("paneId")
        panel_id = row.get("panelId")
        pane_frame = row.get("paneFrame")
        view_frame = row.get("viewFrame")

        if not panel_id:
            raise cmuxError(f"selectedPanels[{i}] missing panelId (pane={pane_id})")
        if row.get("inWindow") is not True:
            raise cmuxError(f"selectedPanels[{i}] panel not in window (pane={pane_id}, panel={panel_id})")
        if row.get("hidden") is True:
            raise cmuxError(f"selectedPanels[{i}] panel hidden (pane={pane_id}, panel={panel_id})")
        if not view_frame:
            raise cmuxError(f"selectedPanels[{i}] missing viewFrame (pane={pane_id}, panel={panel_id})")
        if float(view_frame.get("width", 0.0)) < min_wh or float(view_frame.get("height", 0.0)) < min_wh:
            raise cmuxError(
                f"selectedPanels[{i}] viewFrame too small: {view_frame} "
                f"(pane={pane_id}, panel={panel_id})"
            )

        if pane_frame:
            inter = _rect_intersection_area(pane_frame, view_frame)
            denom = min(_rect_area(pane_frame), _rect_area(view_frame))
            overlap = inter / denom if denom > 0 else 0.0
            if overlap < 0.50:
                raise cmuxError(
                    f"selectedPanels[{i}] bounds mismatch overlap={overlap:.2f} "
                    f"pane={pane_frame} view={view_frame} pane_id={pane_id} panel={panel_id}"
                )


def _wait_for_reactivated_layout(c: cmux, *, min_panels: int, timeout: float = 5.0) -> None:
    deadline = time.time() + timeout
    last_error: Exception | None = None
    last_layout: dict | None = None
    last_portal_stats: dict | None = None

    while time.time() < deadline:
        try:
            last_layout = c.layout_debug()
            last_portal_stats = _v2(c, "debug.portal.stats")
            _assert_selected_panels_healthy(last_layout, min_panels=min_panels)

            totals = last_portal_stats.get("totals") or {}
            visible_orphans = int(totals.get("visible_orphan_terminal_subview_count", 0))
            stale_entries = int(totals.get("stale_entry_count", 0))
            if visible_orphans != 0 or stale_entries != 0:
                raise cmuxError(
                    "terminal portal registry still contains stale visible entries "
                    f"(visible_orphans={visible_orphans}, stale_entries={stale_entries})"
                )
            return
        except Exception as exc:
            last_error = exc
            time.sleep(0.1)

    raise cmuxError(
        "workspace reactivation never recovered layout: "
        f"{last_error}; layout={last_layout}; portal_stats={last_portal_stats}"
    )


def main() -> int:
    created_workspaces: list[str] = []

    with cmux(SOCKET_PATH) as c:
        try:
            hq = c.new_workspace()
            created_workspaces.append(hq)
            _rename_workspace(c, hq, "HQ")
            time.sleep(0.2)
            _open_browser(c, "about:blank#hq")
            time.sleep(0.4)
            _wait_for_reactivated_layout(c, min_panels=2)

            build = c.new_workspace()
            created_workspaces.append(build)
            _rename_workspace(c, build, "Build")
            time.sleep(0.2)
            _open_browser(c, "about:blank#build")
            time.sleep(0.3)
            c.close_surface()
            time.sleep(0.3)
            _open_browser(c, "about:blank#build-reopen")
            time.sleep(0.3)

            scratch = c.new_workspace()
            created_workspaces.append(scratch)
            _rename_workspace(c, scratch, "Scratch")
            time.sleep(0.2)
            _open_browser(c, "about:blank#scratch")
            time.sleep(0.3)

            _move_workspace_to_top(c, build)
            _reorder_workspace(c, scratch, 99)
            _rename_workspace(c, build, "Build Logs")
            _rename_workspace(c, scratch, "Scratch Bottom")
            time.sleep(0.3)

            c.select_workspace(build)
            time.sleep(0.2)
            c.select_workspace(scratch)
            time.sleep(0.2)
            c.select_workspace(hq)

            _wait_for_reactivated_layout(c, min_panels=2)

            terminal_idx = _first_surface_index(c, "terminal")
            if terminal_idx is None:
                raise cmuxError("Reactivated HQ workspace has no terminal surface")

            marker = _marker("hq_reactivated")
            try:
                if not _verify_terminal_responsive(c, terminal_idx, marker):
                    raise cmuxError(
                        "HQ terminal did not respond after workspace portal recovery churn"
                    )
            finally:
                _clear(marker)
        finally:
            for workspace_id in reversed(created_workspaces):
                try:
                    c.close_workspace(workspace_id)
                except Exception:
                    pass
                time.sleep(0.1)

    print("PASS: workspace reactivation recovers portal layout after churn")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
