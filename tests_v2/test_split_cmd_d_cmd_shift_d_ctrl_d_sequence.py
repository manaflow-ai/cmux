#!/usr/bin/env python3
"""
Regression: repeat cmd+d -> cmd+shift+d -> ctrl+d sequence without layout drift.

This keeps a strict shortcut order per cycle, then resets to one pane for the next
cycle so we can stress the transition repeatedly.
"""

from collections import deque
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
CYCLES = int(os.environ.get("CMUX_COMBO_SHORTCUT_CYCLES", "80"))
WAIT_TIMEOUT_S = float(os.environ.get("CMUX_COMBO_SHORTCUT_WAIT_TIMEOUT_S", "2.5"))
SAMPLE_INTERVAL_S = float(os.environ.get("CMUX_COMBO_SHORTCUT_SAMPLE_INTERVAL_S", "0.012"))
TRACE_TAIL = int(os.environ.get("CMUX_COMBO_SHORTCUT_TRACE_TAIL", "30"))
EPSILON = float(os.environ.get("CMUX_COMBO_SHORTCUT_EPSILON", "0.0"))
ASSERT_NO_UNDERFLOW = os.environ.get("CMUX_COMBO_SHORTCUT_ASSERT_NO_UNDERFLOW", "1") == "1"
ASSERT_NO_EMPTY_PANEL = os.environ.get("CMUX_COMBO_SHORTCUT_ASSERT_NO_EMPTY_PANEL", "1") == "1"


def _pane_count(layout_payload: dict) -> int:
    panes = (layout_payload.get("layout") or {}).get("panes") or []
    return len(panes)


def _container_frame(layout_payload: dict) -> dict:
    container = (layout_payload.get("layout") or {}).get("containerFrame")
    if not container:
        raise cmuxError(f"layout_debug missing containerFrame: {layout_payload}")
    try:
        return {
            "x": float(container.get("x", 0.0)),
            "y": float(container.get("y", 0.0)),
            "width": float(container.get("width", 0.0)),
            "height": float(container.get("height", 0.0)),
        }
    except (TypeError, ValueError) as exc:
        raise cmuxError(f"layout_debug has invalid containerFrame: {container}") from exc


def _assert_same_frame(current: dict, baseline: dict, *, phase: str, cycle: int, trace: list[str]) -> None:
    deltas = {
        key: abs(float(current[key]) - float(baseline[key]))
        for key in ("x", "y", "width", "height")
    }
    shifted = {k: v for k, v in deltas.items() if v > EPSILON}
    if shifted:
        raise cmuxError(
            "containerFrame shifted during shortcut sequence "
            f"(cycle={cycle}, phase={phase}, baseline={baseline}, current={current}, "
            f"deltas={deltas}, epsilon={EPSILON}, trace={trace})"
        )


def _wait_for_panes(
    c: cmux,
    expected: int,
    *,
    cycle: int,
    phase: str,
    trace: list[str],
) -> dict:
    deadline = time.time() + WAIT_TIMEOUT_S
    last = None
    while time.time() < deadline:
        payload = c.layout_debug()
        panes = _pane_count(payload)
        last = (panes, payload)
        if panes == expected:
            return payload
        time.sleep(SAMPLE_INTERVAL_S)
    raise cmuxError(
        f"Timed out waiting for panes={expected} "
        f"(cycle={cycle}, phase={phase}, last={last[0] if last else 'n/a'}, trace={trace})"
    )


def _reset_to_single_pane(
    c: cmux,
    *,
    cycle: int,
    trace: deque[str],
) -> dict:
    deadline = time.time() + WAIT_TIMEOUT_S
    while time.time() < deadline:
        payload = c.layout_debug()
        panes = _pane_count(payload)
        if panes <= 1:
            return payload
        trace.append(f"cycle={cycle} action=surface.close(reset) panes_before={panes}")
        c.close_surface()
        time.sleep(SAMPLE_INTERVAL_S)
    raise cmuxError(f"Failed to reset to one pane (cycle={cycle}, trace={list(trace)})")


def main() -> int:
    trace: deque[str] = deque(maxlen=max(8, TRACE_TAIL))
    completed = 0

    with cmux(SOCKET_PATH) as c:
        ws = c.new_workspace()
        c.select_workspace(ws)
        c.activate_app()
        time.sleep(0.2)

        c.reset_bonsplit_underflow_count()
        c.reset_empty_panel_count()

        start = _reset_to_single_pane(c, cycle=0, trace=trace)
        baseline = _container_frame(start)

        for cycle in range(1, CYCLES + 1):
            # Always start each cycle from one pane.
            one = _reset_to_single_pane(c, cycle=cycle, trace=trace)
            _assert_same_frame(
                _container_frame(one),
                baseline,
                phase="cycle_start",
                cycle=cycle,
                trace=list(trace),
            )

            trace.append(f"cycle={cycle} action=cmd+d")
            c.simulate_shortcut("cmd+d")
            after_cmd_d = _wait_for_panes(c, 2, cycle=cycle, phase="after_cmd+d", trace=list(trace))
            _assert_same_frame(
                _container_frame(after_cmd_d),
                baseline,
                phase="after_cmd+d",
                cycle=cycle,
                trace=list(trace),
            )

            trace.append(f"cycle={cycle} action=cmd+shift+d")
            c.simulate_shortcut("cmd+shift+d")
            after_cmd_shift_d = _wait_for_panes(
                c,
                3,
                cycle=cycle,
                phase="after_cmd+shift+d",
                trace=list(trace),
            )
            _assert_same_frame(
                _container_frame(after_cmd_shift_d),
                baseline,
                phase="after_cmd+shift+d",
                cycle=cycle,
                trace=list(trace),
            )

            trace.append(f"cycle={cycle} action=ctrl+d")
            c.simulate_shortcut("ctrl+d")
            after_ctrl_d = _wait_for_panes(c, 2, cycle=cycle, phase="after_ctrl+d", trace=list(trace))
            _assert_same_frame(
                _container_frame(after_ctrl_d),
                baseline,
                phase="after_ctrl+d",
                cycle=cycle,
                trace=list(trace),
            )

            completed = cycle

        underflows = c.bonsplit_underflow_count()
        if ASSERT_NO_UNDERFLOW and underflows != 0:
            raise cmuxError(f"bonsplit arranged-subview underflow count={underflows}")

        empty_panels = c.empty_panel_count()
        if ASSERT_NO_EMPTY_PANEL and empty_panels != 0:
            raise cmuxError(f"EmptyPanelView appeared count={empty_panels}")

    print(
        "PASS: cmd+d -> cmd+shift+d -> ctrl+d sequence "
        f"(cycles={completed}, epsilon={EPSILON}, underflows={underflows}, empty_panel={empty_panels})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
