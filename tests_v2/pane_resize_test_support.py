from __future__ import annotations

import re
import secrets
import time

from cmux import cmux, cmuxError


ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC_ESCAPE_RE = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def wait_for(pred, timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def clean_line(raw: str) -> str:
    line = OSC_ESCAPE_RE.sub("", raw)
    line = ANSI_ESCAPE_RE.sub("", line)
    line = line.replace("\r", "")
    return line.strip()


def layout_panes(client: cmux) -> list[dict]:
    layout_payload = client.layout_debug() or {}
    layout = layout_payload.get("layout") or {}
    return list(layout.get("panes") or [])


def pane_extent(client: cmux, pane_id: str, axis: str) -> float:
    panes = layout_panes(client)
    for pane in panes:
        pid = str(pane.get("paneId") or pane.get("pane_id") or "")
        if pid != pane_id:
            continue
        frame = pane.get("frame") or {}
        return float(frame.get(axis) or 0.0)
    raise cmuxError(f"Pane {pane_id} missing from debug layout panes: {panes}")


def workspace_panes(client: cmux, workspace_id: str) -> list[tuple[str, bool, int]]:
    payload = client._call("pane.list", {"workspace_id": workspace_id}) or {}
    out: list[tuple[str, bool, int]] = []
    for row in payload.get("panes") or []:
        out.append((
            str(row.get("id") or ""),
            bool(row.get("focused")),
            int(row.get("surface_count") or 0),
        ))
    return out


def focused_pane_id(client: cmux, workspace_id: str) -> str:
    for pane_id, focused, _surface_count in workspace_panes(client, workspace_id):
        if focused:
            return pane_id
    raise cmuxError("No focused pane found")


def surface_scrollback_text(client: cmux, workspace_id: str, surface_id: str) -> str:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
    ) or {}
    return str(payload.get("text") or "")


def surface_scrollback_lines(client: cmux, workspace_id: str, surface_id: str) -> list[str]:
    text = surface_scrollback_text(client, workspace_id, surface_id)
    return [clean_line(raw) for raw in text.splitlines()]


def scrollback_has_exact_line(client: cmux, workspace_id: str, surface_id: str, token: str) -> bool:
    return token in surface_scrollback_lines(client, workspace_id, surface_id)


def wait_for_surface_command_roundtrip(client: cmux, workspace_id: str, surface_id: str) -> None:
    for _attempt in range(1, 5):
        token = f"CMUX_READY_{secrets.token_hex(4)}"
        client.send_surface(surface_id, f"echo {token}\n")
        try:
            wait_for(
                lambda: scrollback_has_exact_line(client, workspace_id, surface_id, token),
                timeout_s=2.5,
            )
            return
        except cmuxError:
            time.sleep(0.1)
    raise cmuxError("Timed out waiting for surface command roundtrip")


def pick_resize_direction_for_pane(client: cmux, pane_ids: list[str], target_pane: str) -> tuple[str, str]:
    panes = [p for p in layout_panes(client) if str(p.get("paneId") or p.get("pane_id") or "") in pane_ids]
    if len(panes) < 2:
        raise cmuxError(f"Need >=2 panes for resize test, got {panes}")

    def x_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("x") or 0.0)

    def y_of(p: dict) -> float:
        return float((p.get("frame") or {}).get("y") or 0.0)

    x_span = max(x_of(p) for p in panes) - min(x_of(p) for p in panes)
    y_span = max(y_of(p) for p in panes) - min(y_of(p) for p in panes)

    if x_span >= y_span:
        left_pane = min(panes, key=x_of)
        left_id = str(left_pane.get("paneId") or left_pane.get("pane_id") or "")
        return ("right" if target_pane == left_id else "left"), "width"

    top_pane = min(panes, key=y_of)
    top_id = str(top_pane.get("paneId") or top_pane.get("pane_id") or "")
    return ("down" if target_pane == top_id else "up"), "height"
