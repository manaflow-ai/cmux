#!/usr/bin/env python3
"""
Focused fuzz regression for rapid Cmd+D / Ctrl+D churn in a strict 1<->2 pane loop.

Intent:
  - Keep topology limited to one pane or two left/right panes only.
  - Run across multiple fresh workspaces.
  - Sample layout as fast as the debug socket allows during transitions/holds.
  - Fail immediately if outer container x/y/width/height drifts at any sampled frame.
"""

from collections import deque
import os
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
FUZZ_SEED = int(os.environ.get("CMUX_SPLIT_2PANE_SEED", "20260223"))
WORKSPACES = int(os.environ.get("CMUX_SPLIT_2PANE_WORKSPACES", "3"))
CYCLES_PER_WORKSPACE = int(os.environ.get("CMUX_SPLIT_2PANE_CYCLES", "220"))
TRANSITION_TIMEOUT_S = float(os.environ.get("CMUX_SPLIT_2PANE_TIMEOUT_S", "2.0"))
HOLD_MIN_S = float(os.environ.get("CMUX_SPLIT_2PANE_HOLD_MIN_S", "0.003"))
HOLD_MAX_S = float(os.environ.get("CMUX_SPLIT_2PANE_HOLD_MAX_S", "0.018"))
PRE_ACTION_JITTER_MAX_S = float(os.environ.get("CMUX_SPLIT_2PANE_ACTION_JITTER_MAX_S", "0.002"))
EPSILON = float(os.environ.get("CMUX_SPLIT_2PANE_EPSILON", "0.0"))
TRACE_TAIL = int(os.environ.get("CMUX_SPLIT_2PANE_TRACE_TAIL", "64"))
LAYOUT_POLL_SLEEP_S = float(os.environ.get("CMUX_SPLIT_2PANE_POLL_SLEEP_S", "0.0008"))
LAYOUT_TIMEOUT_RETRIES = int(os.environ.get("CMUX_SPLIT_2PANE_LAYOUT_TIMEOUT_RETRIES", "4"))
LAYOUT_TIMEOUT_RETRY_SLEEP_S = float(os.environ.get("CMUX_SPLIT_2PANE_LAYOUT_TIMEOUT_RETRY_SLEEP_S", "0.0015"))
MAX_LAYOUT_TIMEOUTS = int(os.environ.get("CMUX_SPLIT_2PANE_MAX_LAYOUT_TIMEOUTS", "80"))
CTRL_D_RETRY_INTERVAL_S = float(os.environ.get("CMUX_SPLIT_2PANE_CTRL_D_RETRY_INTERVAL_S", "0.18"))
CTRL_D_MAX_EXTRA = int(os.environ.get("CMUX_SPLIT_2PANE_CTRL_D_MAX_EXTRA", "6"))


def _pane_count(layout_payload: dict) -> int:
    layout = layout_payload.get("layout") or {}
    return len(layout.get("panes") or [])


def _largest_split_frame(layout_payload: dict) -> dict:
    selected = layout_payload.get("selectedPanels") or []
    best = None
    best_area = -1.0
    for row in selected:
        for split in row.get("splitViews") or []:
            frame = split.get("frame")
            if not frame:
                continue
            try:
                x = float(frame.get("x", 0.0))
                y = float(frame.get("y", 0.0))
                width = float(frame.get("width", 0.0))
                height = float(frame.get("height", 0.0))
            except (TypeError, ValueError):
                continue
            if width <= 0.0 or height <= 0.0:
                continue
            area = width * height
            if area > best_area:
                best_area = area
                best = {"x": x, "y": y, "width": width, "height": height}
    if best is None:
        raise cmuxError(f"layout_debug contains no usable split-view frame: {layout_payload}")
    return best


def _container_frame(layout_payload: dict) -> dict:
    container = (layout_payload.get("layout") or {}).get("containerFrame")
    if container:
        try:
            return {
                "x": float(container.get("x", 0.0)),
                "y": float(container.get("y", 0.0)),
                "width": float(container.get("width", 0.0)),
                "height": float(container.get("height", 0.0)),
            }
        except (TypeError, ValueError):
            pass
    return _largest_split_frame(layout_payload)


def _pane_frames_sorted_x(layout_payload: dict) -> list[dict]:
    layout = layout_payload.get("layout") or {}
    panes = layout.get("panes") or []
    frames: list[dict] = []
    for pane in panes:
        frame = pane.get("frame") or {}
        try:
            frames.append(
                {
                    "pane_id": str(pane.get("paneId") or ""),
                    "x": float(frame.get("x", 0.0)),
                    "y": float(frame.get("y", 0.0)),
                    "width": float(frame.get("width", 0.0)),
                    "height": float(frame.get("height", 0.0)),
                }
            )
        except (TypeError, ValueError):
            continue
    return sorted(frames, key=lambda p: (p["x"], p["y"]))


def _assert_same_frame(
    *,
    current: dict,
    baseline: dict,
    workspace_index: int,
    cycle: int,
    phase: str,
    sample: int,
    trace: list[str],
) -> None:
    deltas = {
        key: abs(float(current[key]) - float(baseline[key]))
        for key in ("x", "y", "width", "height")
    }
    shifted = {k: v for k, v in deltas.items() if v > EPSILON}
    if shifted:
        raise cmuxError(
            "Container frame shifted "
            f"(workspace={workspace_index}, cycle={cycle}, phase={phase}, sample={sample}, "
            f"baseline={baseline}, current={current}, deltas={deltas}, epsilon={EPSILON}); "
            f"recent_actions={trace}"
        )


def _assert_two_panes_left_right(layout_payload: dict, *, workspace_index: int, cycle: int, trace: list[str]) -> None:
    panes = _pane_frames_sorted_x(layout_payload)
    if len(panes) != 2:
        raise cmuxError(
            f"Expected exactly 2 panes in two-pane phase, got {len(panes)} "
            f"(workspace={workspace_index}, cycle={cycle}); panes={panes}; recent_actions={trace}"
        )

    left, right = panes[0], panes[1]
    if left["width"] <= 0.0 or left["height"] <= 0.0 or right["width"] <= 0.0 or right["height"] <= 0.0:
        raise cmuxError(
            f"Collapsed pane in two-pane phase (workspace={workspace_index}, cycle={cycle}): "
            f"left={left} right={right}; recent_actions={trace}"
        )

    if left["x"] >= right["x"]:
        raise cmuxError(
            f"Two-pane geometry is not left/right (workspace={workspace_index}, cycle={cycle}): "
            f"left={left} right={right}; recent_actions={trace}"
        )


def _selected_panel_by_pane(layout_payload: dict) -> dict[str, str]:
    out: dict[str, str] = {}
    for row in layout_payload.get("selectedPanels") or []:
        pane_id = str(row.get("paneId") or "")
        panel_id = str(row.get("panelId") or "")
        if pane_id and panel_id:
            out[pane_id] = panel_id
    return out


def _rightmost_pane_id(layout_payload: dict) -> str:
    panes = _pane_frames_sorted_x(layout_payload)
    if len(panes) < 2:
        raise cmuxError(f"Expected at least 2 panes to resolve rightmost pane: {panes}")
    pane_id = str(panes[-1].get("pane_id") or "")
    if not pane_id:
        raise cmuxError(f"Rightmost pane is missing pane_id: {panes[-1]}")
    return pane_id


def _rightmost_panel_id(layout_payload: dict) -> str:
    pane_id = _rightmost_pane_id(layout_payload)
    selected = _selected_panel_by_pane(layout_payload)
    panel_id = str(selected.get(pane_id) or "")
    if not panel_id:
        raise cmuxError(f"Missing selected panel for rightmost pane: pane_id={pane_id}, selected={selected}")
    return panel_id


def _safe_layout_debug(c: cmux, *, timeout_state: dict[str, int], context: str) -> dict:
    for attempt in range(0, max(0, LAYOUT_TIMEOUT_RETRIES) + 1):
        try:
            return c.layout_debug()
        except cmuxError as exc:
            if "timed out waiting for response" not in str(exc).lower():
                raise

            timeout_state["count"] = timeout_state.get("count", 0) + 1
            count = timeout_state["count"]
            if count > max(0, MAX_LAYOUT_TIMEOUTS):
                raise cmuxError(
                    f"Exceeded layout_debug timeout budget (count={count}, max={MAX_LAYOUT_TIMEOUTS}, context={context})"
                ) from exc

            if attempt >= max(0, LAYOUT_TIMEOUT_RETRIES):
                raise cmuxError(
                    f"layout_debug timed out after retries (attempts={attempt + 1}, count={count}, context={context})"
                ) from exc

            if LAYOUT_TIMEOUT_RETRY_SLEEP_S > 0:
                time.sleep(LAYOUT_TIMEOUT_RETRY_SLEEP_S)

    raise cmuxError(f"layout_debug retry loop exhausted unexpectedly (context={context})")


def _sample_while(
    c: cmux,
    *,
    baseline: dict,
    deadline: float,
    workspace_index: int,
    cycle: int,
    phase: str,
    trace: list[str],
    timeout_state: dict[str, int],
) -> int:
    sampled = 0
    while time.time() < deadline:
        payload = _safe_layout_debug(
            c,
            timeout_state=timeout_state,
            context=f"sample workspace={workspace_index} cycle={cycle} phase={phase} sample={sampled}",
        )
        current = _container_frame(payload)
        _assert_same_frame(
            current=current,
            baseline=baseline,
            workspace_index=workspace_index,
            cycle=cycle,
            phase=phase,
            sample=sampled,
            trace=trace,
        )

        panes_now = _pane_count(payload)
        if panes_now > 2:
            raise cmuxError(
                f"Observed >2 panes in strict two-pane fuzz "
                f"(workspace={workspace_index}, cycle={cycle}, phase={phase}, panes={panes_now}); "
                f"recent_actions={trace}"
            )
        sampled += 1
        if LAYOUT_POLL_SLEEP_S > 0:
            time.sleep(LAYOUT_POLL_SLEEP_S)
    return sampled


def _wait_for_panes(
    c: cmux,
    *,
    target_panes: int,
    baseline: dict,
    workspace_index: int,
    cycle: int,
    phase: str,
    timeout_s: float,
    trace: list[str],
    timeout_state: dict[str, int],
) -> tuple[dict, int]:
    deadline = time.time() + timeout_s
    sampled = 0
    last = None

    while time.time() < deadline:
        payload = _safe_layout_debug(
            c,
            timeout_state=timeout_state,
            context=f"wait workspace={workspace_index} cycle={cycle} phase={phase} sample={sampled}",
        )
        last = payload
        current = _container_frame(payload)
        _assert_same_frame(
            current=current,
            baseline=baseline,
            workspace_index=workspace_index,
            cycle=cycle,
            phase=phase,
            sample=sampled,
            trace=trace,
        )

        panes_now = _pane_count(payload)
        if panes_now > 2:
            raise cmuxError(
                f"Observed >2 panes in strict two-pane fuzz while waiting "
                f"(workspace={workspace_index}, cycle={cycle}, phase={phase}, panes={panes_now}); "
                f"recent_actions={trace}"
            )
        if panes_now == target_panes:
            return payload, sampled + 1
        sampled += 1
        if LAYOUT_POLL_SLEEP_S > 0:
            time.sleep(LAYOUT_POLL_SLEEP_S)

    raise cmuxError(
        f"Timed out waiting for {target_panes} panes "
        f"(workspace={workspace_index}, cycle={cycle}, phase={phase}, sampled={sampled}, "
        f"last_panes={_pane_count(last or {})}, timeout_s={timeout_s}); recent_actions={trace}"
    )


def _wait_for_single_pane_after_ctrl_d(
    c: cmux,
    *,
    baseline: dict,
    workspace_index: int,
    cycle: int,
    phase: str,
    timeout_s: float,
    recent_actions: deque[str],
    timeout_state: dict[str, int],
) -> tuple[dict, int, int]:
    deadline = time.time() + timeout_s
    sampled = 0
    extra_ctrl_d = 0
    last = None
    next_retry_at = time.time() + max(0.0, CTRL_D_RETRY_INTERVAL_S)

    while time.time() < deadline:
        payload = _safe_layout_debug(
            c,
            timeout_state=timeout_state,
            context=f"wait workspace={workspace_index} cycle={cycle} phase={phase} sample={sampled}",
        )
        last = payload
        current = _container_frame(payload)
        trace = list(recent_actions)
        _assert_same_frame(
            current=current,
            baseline=baseline,
            workspace_index=workspace_index,
            cycle=cycle,
            phase=phase,
            sample=sampled,
            trace=trace,
        )

        panes_now = _pane_count(payload)
        if panes_now > 2:
            raise cmuxError(
                f"Observed >2 panes in strict two-pane fuzz while waiting "
                f"(workspace={workspace_index}, cycle={cycle}, phase={phase}, panes={panes_now}); "
                f"recent_actions={trace}"
            )
        if panes_now == 1:
            return payload, sampled + 1, extra_ctrl_d

        now = time.time()
        if panes_now == 2 and extra_ctrl_d < max(0, CTRL_D_MAX_EXTRA) and now >= next_retry_at:
            retry_right_panel_id = _rightmost_panel_id(payload)
            try:
                c.send_key_surface(retry_right_panel_id, "ctrl-d")
            except cmuxError as exc:
                # Pane/surface can disappear between layout sample and send call under heavy churn.
                # Skip this retry tick and re-sample.
                if "not_found" in str(exc).lower():
                    next_retry_at = now + max(0.0, CTRL_D_RETRY_INTERVAL_S)
                    sampled += 1
                    if LAYOUT_POLL_SLEEP_S > 0:
                        time.sleep(LAYOUT_POLL_SLEEP_S)
                    continue
                raise
            extra_ctrl_d += 1
            recent_actions.append(
                f"ws={workspace_index} cycle={cycle} action=ctrl+d(extra:{extra_ctrl_d}/{CTRL_D_MAX_EXTRA},surface={retry_right_panel_id})"
            )
            next_retry_at = now + max(0.0, CTRL_D_RETRY_INTERVAL_S)

        sampled += 1
        if LAYOUT_POLL_SLEEP_S > 0:
            time.sleep(LAYOUT_POLL_SLEEP_S)

    raise cmuxError(
        f"Timed out waiting for 1 pane after ctrl+d "
        f"(workspace={workspace_index}, cycle={cycle}, phase={phase}, sampled={sampled}, "
        f"extra_ctrl_d={extra_ctrl_d}, last_panes={_pane_count(last or {})}, timeout_s={timeout_s}); "
        f"recent_actions={list(recent_actions)}"
    )


def main() -> int:
    rng = random.Random(FUZZ_SEED)
    recent_actions: deque[str] = deque(maxlen=max(8, TRACE_TAIL))
    total_samples = 0
    total_cycles = 0
    total_extra_ctrl_d = 0
    timeout_state: dict[str, int] = {"count": 0}

    with cmux(SOCKET_PATH) as c:
        c.activate_app()

        for workspace_index in range(1, WORKSPACES + 1):
            ws = c.new_workspace()
            c.select_workspace(ws)
            c.activate_app()
            time.sleep(0.08)

            start = _safe_layout_debug(c, timeout_state=timeout_state, context=f"workspace={workspace_index} start")
            baseline = _container_frame(start)
            start_panes = _pane_count(start)
            if start_panes != 1:
                raise cmuxError(f"New workspace did not start as single pane (workspace={workspace_index}, panes={start_panes})")

            for cycle in range(1, CYCLES_PER_WORKSPACE + 1):
                total_cycles += 1

                if PRE_ACTION_JITTER_MAX_S > 0:
                    time.sleep(rng.uniform(0.0, PRE_ACTION_JITTER_MAX_S))

                recent_actions.append(f"ws={workspace_index} cycle={cycle} action=cmd+d")
                c.simulate_shortcut("cmd+d")

                after_split, sampled = _wait_for_panes(
                    c,
                    target_panes=2,
                    baseline=baseline,
                    workspace_index=workspace_index,
                    cycle=cycle,
                    phase="after_cmd+d",
                    timeout_s=TRANSITION_TIMEOUT_S,
                    trace=list(recent_actions),
                    timeout_state=timeout_state,
                )
                total_samples += sampled
                _assert_two_panes_left_right(after_split, workspace_index=workspace_index, cycle=cycle, trace=list(recent_actions))

                hold_split = rng.uniform(HOLD_MIN_S, HOLD_MAX_S)
                total_samples += _sample_while(
                    c,
                    baseline=baseline,
                    deadline=time.time() + hold_split,
                    workspace_index=workspace_index,
                    cycle=cycle,
                    phase="hold_2pane",
                    trace=list(recent_actions),
                    timeout_state=timeout_state,
                )

                if PRE_ACTION_JITTER_MAX_S > 0:
                    time.sleep(rng.uniform(0.0, PRE_ACTION_JITTER_MAX_S))

                right_panel_id = _rightmost_panel_id(after_split)
                recent_actions.append(f"ws={workspace_index} cycle={cycle} action=ctrl+d(surface={right_panel_id})")
                c.send_key_surface(right_panel_id, "ctrl-d")

                _, sampled, extra_ctrl_d = _wait_for_single_pane_after_ctrl_d(
                    c,
                    baseline=baseline,
                    workspace_index=workspace_index,
                    cycle=cycle,
                    phase="after_ctrl+d",
                    timeout_s=TRANSITION_TIMEOUT_S,
                    recent_actions=recent_actions,
                    timeout_state=timeout_state,
                )
                total_samples += sampled
                total_extra_ctrl_d += extra_ctrl_d

                hold_single = rng.uniform(HOLD_MIN_S, HOLD_MAX_S)
                total_samples += _sample_while(
                    c,
                    baseline=baseline,
                    deadline=time.time() + hold_single,
                    workspace_index=workspace_index,
                    cycle=cycle,
                    phase="hold_1pane",
                    trace=list(recent_actions),
                    timeout_state=timeout_state,
                )

            c.close_workspace(ws)
            time.sleep(0.05)

    print(
        "PASS: strict two-pane cmd+d/ctrl+d frame guard "
        f"(seed={FUZZ_SEED}, workspaces={WORKSPACES}, cycles={total_cycles}, samples={total_samples}, "
        f"extra_ctrl_d={total_extra_ctrl_d}, epsilon={EPSILON}, layout_timeouts={timeout_state.get('count', 0)})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
