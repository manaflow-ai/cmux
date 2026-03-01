#!/usr/bin/env python3
"""
Fuzz regression: rapid Cmd+D / Ctrl+D churn must not shift the outer bonsplit container frame.

This targets the user-reported visual shift/flash while spamming split + close.
We treat any drift in x/y/width/height of the outer container frame as a failure.
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
FUZZ_SEED = int(os.environ.get("CMUX_SPLIT_FUZZ_SEED", "424242"))
FUZZ_STEPS = int(os.environ.get("CMUX_SPLIT_FUZZ_STEPS", "1400"))
SAMPLES_PER_STEP = int(os.environ.get("CMUX_SPLIT_FUZZ_SAMPLES", "4"))
SAMPLE_INTERVAL_S = float(os.environ.get("CMUX_SPLIT_FUZZ_SAMPLE_INTERVAL_S", "0.0015"))
ACTION_JITTER_MAX_S = float(os.environ.get("CMUX_SPLIT_FUZZ_ACTION_JITTER_MAX_S", "0.0035"))
BURST_MAX = int(os.environ.get("CMUX_SPLIT_FUZZ_BURST_MAX", "3"))
MAX_PANES = int(os.environ.get("CMUX_SPLIT_FUZZ_MAX_PANES", "10"))
EPSILON = float(os.environ.get("CMUX_SPLIT_FUZZ_EPSILON", "0.0"))
TRACE_TAIL = int(os.environ.get("CMUX_SPLIT_FUZZ_TRACE_TAIL", "40"))
ASSERT_NO_UNDERFLOW = os.environ.get("CMUX_SPLIT_FUZZ_ASSERT_NO_UNDERFLOW", "0") == "1"
ASSERT_NO_EMPTY_PANEL = os.environ.get("CMUX_SPLIT_FUZZ_ASSERT_NO_EMPTY_PANEL", "0") == "1"


def _pane_count(layout_payload: dict) -> int:
    layout = layout_payload.get("layout") or {}
    panes = layout.get("panes") or []
    return len(panes)


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

    # Back-compat fallback for older payloads that don't expose containerFrame.
    return _largest_split_frame(layout_payload)


def _assert_same_frame(
    current: dict,
    baseline: dict,
    *,
    step: int,
    sample: int,
    action: str,
    seed: int,
    action_index: int,
    trace: list[str],
) -> None:
    deltas = {
        key: abs(float(current[key]) - float(baseline[key]))
        for key in ("x", "y", "width", "height")
    }
    shifted = {k: v for k, v in deltas.items() if v > EPSILON}
    if shifted:
        raise cmuxError(
            "Outer split container shifted during fuzz churn "
            f"(step={step}, sample={sample}, action={action}, action_index={action_index}, seed={seed}, "
            f"baseline={baseline}, current={current}, deltas={deltas}, epsilon={EPSILON})"
            f"; recent_actions={trace}"
        )


def _warm_start_split(c: cmux) -> dict:
    # Ensure we have at least one split so the container frame exists in layout_debug.
    c.simulate_shortcut("cmd+d")
    deadline = time.time() + 2.0
    last = None
    while time.time() < deadline:
        payload = c.layout_debug()
        last = payload
        if _pane_count(payload) >= 2:
            return payload
        time.sleep(0.02)
    raise cmuxError(f"Timed out waiting for first split to appear: {last}")


def main() -> int:
    rng = random.Random(FUZZ_SEED)
    recent_actions: deque[str] = deque(maxlen=max(8, TRACE_TAIL))
    total_actions = 0

    with cmux(SOCKET_PATH) as c:
        ws = c.new_workspace()
        c.select_workspace(ws)
        c.activate_app()
        time.sleep(0.2)

        c.reset_bonsplit_underflow_count()
        c.reset_empty_panel_count()

        initial = _warm_start_split(c)
        baseline = _container_frame(initial)
        if _pane_count(initial) < 2:
            raise cmuxError("Expected at least 2 panes after warm start split")

        for step in range(1, FUZZ_STEPS + 1):
            burst = rng.randint(1, max(1, BURST_MAX))

            for burst_index in range(1, burst + 1):
                before = c.layout_debug()
                pane_count = _pane_count(before)

                if pane_count <= 2:
                    action = "cmd+d"
                elif pane_count >= MAX_PANES:
                    action = "ctrl+d"
                else:
                    # Bias toward split to keep churn dense while still frequently collapsing via ctrl+d.
                    action = "cmd+d" if rng.random() < 0.60 else "ctrl+d"

                if action == "cmd+d":
                    c.simulate_shortcut("cmd+d")
                else:
                    # Ctrl+D equivalent sent directly to the focused terminal surface.
                    c.send_ctrl_d()

                total_actions += 1
                recent_actions.append(
                    f"step={step}/burst={burst_index}/{burst} panes_before={pane_count} action={action}"
                )

                # Random micro-jitter to emulate uneven key-repeat timing while keeping churn fast.
                if ACTION_JITTER_MAX_S > 0:
                    time.sleep(rng.uniform(0.0, ACTION_JITTER_MAX_S))

            # Sample repeatedly after each burst to catch transient shifts.
            for sample in range(0, SAMPLES_PER_STEP + 1):
                payload = c.layout_debug()
                current = _container_frame(payload)
                _assert_same_frame(
                    current,
                    baseline,
                    step=step,
                    sample=sample,
                    action="burst",
                    seed=FUZZ_SEED,
                    action_index=total_actions,
                    trace=list(recent_actions),
                )
                if SAMPLE_INTERVAL_S > 0:
                    time.sleep(rng.uniform(0.0, SAMPLE_INTERVAL_S))

        underflows = c.bonsplit_underflow_count()
        if ASSERT_NO_UNDERFLOW and underflows != 0:
            raise cmuxError(f"bonsplit arranged-subview underflow observed during fuzz run: {underflows}")

        flashes = c.empty_panel_count()
        if ASSERT_NO_EMPTY_PANEL and flashes != 0:
            raise cmuxError(f"EmptyPanelView appeared during fuzz run (count={flashes})")

    print(
        "PASS: cmd+d/ctrl+d fuzz geometry invariant "
        f"(seed={FUZZ_SEED}, steps={FUZZ_STEPS}, samples={SAMPLES_PER_STEP}, burst_max={BURST_MAX}, "
        f"actions={total_actions}, epsilon={EPSILON}, underflows={underflows}, empty_panel={flashes})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
