"""Checks run after every step. Each returns None or a Failure."""

from __future__ import annotations

import re
import time
from dataclasses import dataclass, field

from .geometry import Rect, tiling_problems
from .signature import Signature, invariant_signature, log_signature
from .sock import SocketError, SocketTimeout


@dataclass
class Failure:
    signature: Signature
    detail: str
    evidence: dict = field(default_factory=dict)


# Debug-log lines that always mean a bug. Everything else in the log is noise to the fuzzer.
LOG_PATTERNS = [
    re.compile(r"(?i)\b(fatal error|assertion failed|precondition failed|invariant violated)\b"),
    re.compile(r"(?i)\bbonsplit\b.*\bunderflow\b"),
    re.compile(r"runloop\.stall gapMs=(\d{4,})"),  # a main-thread stall of at least STALL_REPORT_MS
]
# A main-thread stall this long is a bug on any machine; shorter ones happen on a busy Mac with a debug build.
STALL_REPORT_MS = 8000


def scan_log(lines: list[str], ignore: set[str] | frozenset[str] = frozenset()) -> Failure | None:
    """The first fatal line whose key is not in `ignore` (keys a fresh app already logs)."""
    for line in lines:
        for pattern in LOG_PATTERNS:
            m = pattern.search(line)
            if not m:
                continue
            if m.groups() and m.group(1).isdigit() and int(m.group(1)) < STALL_REPORT_MS:
                continue
            key = "runloop.stall" if "runloop.stall" in line else line
            failure = Failure(log_signature(key), line.strip()[:500])
            if failure.signature.key in ignore:
                continue
            return failure
    return None


HANG_CONFIRM_S = 20.0


def heartbeat(sock, *, timeout: float = 6.0) -> tuple[float | None, str]:
    """(seconds the main thread took to answer, why not). system.identify hops to the main thread;
    system.ping does not, so ping OK with identify timing out means main is stuck."""
    start = time.monotonic()
    try:
        sock.call("system.identify", timeout=timeout)
        return time.monotonic() - start, ""
    except SocketTimeout:
        # One slow answer is load; a hang is a main thread that stays silent through a much longer wait.
        try:
            sock.call("system.identify", timeout=HANG_CONFIRM_S)
            return time.monotonic() - start, ""
        except SocketTimeout:
            pass
        except Exception:  # noqa: BLE001
            pass
        try:
            sock.call("system.ping", timeout=3)
            return None, f"main thread did not answer for {timeout + HANG_CONFIRM_S:g} s (socket worker did)"
        except Exception as error:  # noqa: BLE001
            return None, f"socket dead ({type(error).__name__})"
    except SocketError as error:
        return time.monotonic() - start, f"identify error {error}"
    except OSError as error:
        return None, f"socket dead ({type(error).__name__})"


def has_window(sock) -> bool:
    """Whether the app still has a main window (closing the last one is a user action, not a bug)."""
    try:
        return bool(sock.call("system.tree", timeout=8).get("windows"))
    except Exception:  # noqa: BLE001 - the layout oracle reports a failing tree query
        return True


def _rect(d: dict | None) -> Rect | None:
    if not d:
        return None
    return Rect(float(d.get("x", 0)), float(d.get("y", 0)), float(d.get("width", 0)), float(d.get("height", 0)))


def layout_problems(tree: dict, layout: dict) -> list[tuple[str, str]]:
    """Invariants between the socket's tab model (system.tree) and the bonsplit/AppKit view tree
    (debug.layout) of the selected workspace."""
    problems: list[tuple[str, str]] = []
    windows = tree.get("windows") or []
    if not windows:
        return [("no-window", "system.tree lists no window")]
    snap = (layout or {}).get("layout") or {}
    model_panes = snap.get("panes") or []
    view_ids = {str(p.get("paneId", "")).lower() for p in model_panes}
    # debug.layout describes one window (the last active one); compare the tree's window whose selected
    # workspace holds those panes. With no match (a window mid-switch), compare nothing rather than two windows.
    window = None
    for candidate in windows:
        spaces = candidate.get("workspaces") or []
        selected = [w for w in spaces if w.get("selected")]
        if len(selected) != 1:
            problems.append(("selected-workspace-count", f"{len(selected)} selected workspaces"))
            return problems
        ids = {str(p.get("id", "")).lower() for p in selected[0].get("panes") or []}
        if ids & view_ids or (len(windows) == 1):
            window = candidate
            break
    if window is None:
        return problems
    ws = [w for w in window.get("workspaces") or [] if w.get("selected")][0]
    panes = ws.get("panes") or []
    if not panes:
        problems.append(("workspace-without-panes", ws.get("ref", "")))
        return problems
    focused = [p for p in panes if p.get("focused")]
    if len(focused) != 1:
        problems.append(("focused-pane-count", f"{len(focused)} of {len(panes)} panes focused"))
    for p in panes:
        ids = p.get("surface_ids") or []
        if not ids:  # moving a pane's last tab away leaves a supported empty pane
            continue
        if p.get("selected_surface_id") not in ids:
            problems.append(("selected-tab-not-in-pane", p.get("ref", "")))

    tree_ids = {str(p.get("id", "")).lower() for p in panes}
    if tree_ids != view_ids:
        problems.append(("model-view-pane-mismatch",
                         f"system.tree has {len(tree_ids)} panes, bonsplit has {len(view_ids)}"))
    by_id = {str(p.get("id", "")).lower(): p for p in panes}
    for mp in model_panes:
        tp = by_id.get(str(mp.get("paneId", "")).lower())
        if tp is not None and len(mp.get("tabIds") or []) != len(tp.get("surface_ids") or []):
            problems.append(("tab-count-mismatch",
                             f"pane {tp.get('ref')}: {len(tp.get('surface_ids') or [])} surfaces, "
                             f"{len(mp.get('tabIds') or [])} bonsplit tabs"))
    focused_model = str(snap.get("focusedPaneId") or "").lower()
    if focused and focused_model and focused_model != str(focused[0].get("id", "")).lower():
        problems.append(("focus-model-view-mismatch", "system.tree and bonsplit disagree on the focused pane"))

    container = _rect(snap.get("containerFrame"))
    if container and container.w > 0 and container.h > 0:
        rects = {str(p.get("paneId")): r for p in model_panes if (r := _rect(p.get("frame")))}
        # Each divider takes a strip out of the container, so many narrow panes cover less of it.
        coverage = max(0.8, 0.97 - 0.01 * max(0, len(rects) - 1))
        for name, detail in tiling_problems(container, rects, divider_slack=2.0, min_coverage=coverage):
            problems.append(("model-" + name, detail))
    elif model_panes:
        problems.append(("container-degenerate", f"container {snap.get('containerFrame')}"))

    # The AppKit views behind the selected tabs.
    selected_panels = layout.get("selectedPanels") or []
    visible = [p for p in selected_panels if p.get("inWindow") and not p.get("hidden")]
    hosted = [p for p in selected_panels if p.get("inWindow") is not None]
    if hosted and len(visible) not in (1, len(hosted)):
        # Zoomed shows one pane; otherwise all of them. Anything in between is a blank pane.
        problems.append(("hidden-pane-views", f"{len(visible)} of {len(hosted)} pane views visible"))
    view_rects = {}
    for p in visible:
        r = _rect(p.get("viewFrame"))
        if r is None:
            continue
        if r.w < 1 or r.h < 1:
            problems.append(("pane-view-degenerate", f"{p.get('paneId')} view is {r.w:g}x{r.h:g}"))
            continue
        view_rects[str(p.get("paneId"))] = r
    ids = sorted(view_rects)
    for i, a in enumerate(ids):
        for b in ids[i + 1:]:
            if view_rects[a].intersection(view_rects[b]) > 16:
                problems.append(("pane-views-overlap", f"{a[:8]} and {b[:8]}"))
    if len(visible) == len(hosted) and len(hosted) > 1:
        model_by_id = {str(p.get("paneId")): _rect(p.get("frame")) for p in model_panes}
        terminals = {str(p.get("paneId")) for p in visible if p.get("panelType") == "terminal"}
        for pid, r in view_rects.items():
            if pid not in terminals:  # a browser's view sits under its own toolbar
                continue
            m = model_by_id.get(pid)
            if m is None or m.w < 60 or m.h < 60:
                continue
            if abs(m.w - r.w) > 24 or not (-8 <= m.h - r.h <= 80):
                problems.append(("view-does-not-follow-model",
                                 f"{pid[:8]} model {m.w:.0f}x{m.h:.0f} view {r.w:.0f}x{r.h:.0f}"))
    return problems


def debug_layout(sock) -> dict:
    """debug.layout's payload: {"layout": bonsplit's LayoutSnapshot, "selectedPanels": [...], ...}."""
    reply = sock.call("debug.layout", timeout=8)
    inner = reply.get("layout")
    return inner if isinstance(inner, dict) and ("selectedPanels" in inner or "layout" in inner) else reply


def check_layout(sock) -> list[tuple[str, str]]:
    tree = sock.call("system.tree", timeout=8)
    return layout_problems(tree, debug_layout(sock))


def counters(sock) -> dict[str, int]:
    out = {}
    # debug.empty_panel.count is not here: an empty pane is a supported state (moving a pane's last tab away).
    for name in ("debug.bonsplit_underflow.count",):
        try:
            out[name] = int(sock.call(name, timeout=5).get("count", 0))
        except Exception:  # noqa: BLE001 - older builds lack a counter
            continue
    return out


def counter_failure(before: dict[str, int], after: dict[str, int]) -> Failure | None:
    for name, value in after.items():
        if value > before.get(name, 0):
            short = name.split(".")[1]
            return Failure(invariant_signature(f"{short}-counter"), f"{name} went {before.get(name, 0)} -> {value}")
    return None


def first_problem(problems: list[tuple[str, str]]) -> Failure | None:
    if not problems:
        return None
    name, detail = problems[0]
    return Failure(invariant_signature(name), detail, {"all": problems})
