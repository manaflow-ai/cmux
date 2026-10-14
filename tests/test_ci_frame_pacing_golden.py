#!/usr/bin/env python3
"""Behavioral tests for the golden interactions judge (scripts/ci/frame-pacing/golden.py).

#20216 turned the New Tab tab-grow animation off and every check stayed green. The judge
must fail a New Tab whose tab lands at full width in one frame, pass one that grows over
many frames, and expect the opposite under Reduce Motion. It reads the files `golden.py
drive` writes, so these tests write the same shapes.
"""

from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "frame-pacing" / "golden.py"
REFRESH = 1000 / 120


def eased(start: float, end: float, frames: int, rest: int = 6) -> list[float]:
    """`rest` frames at `start`, `frames` eased frames, `rest` frames at `end` (frames=0: one jump)."""
    moving = [start + (end - start) * (1 - math.cos(math.pi * (k + 1) / frames)) / 2 for k in range(frames)]
    return [start] * rest + moving + [end] * rest


def tabs_trace(widths: list[float], *, spare: bool, looping: list[str] | None = None) -> dict:
    samples = []
    for index, width in enumerate(widths):
        tabs = [["tab-a", 0, 180, 1], ["tab-b", 180, 180, 1]]
        if width > 0:
            # The new tab sits between the two; tab-b moves right as it grows.
            tabs = [["tab-a", 0, 180, 1], ["new-tab", 180, width, 1], ["tab-b", 180 + width, 180, 1]]
        samples.append({"t": index * REFRESH, "tabs": tabs})
    return {"refresh_ms": REFRESH, "samples": samples, "opening": {"spare": spare}, "looping": looping or []}


def sidebar_trace(widths: list[float]) -> dict:
    return {"refresh_ms": REFRESH, "samples": [{"t": i * REFRESH, "sidebar": [w, w]} for i, w in enumerate(widths)]}


def write_run(out: Path, *, cold_frames: int, reduce_frames: int = 0, looping: list[str] | None = None) -> None:
    out.mkdir(parents=True, exist_ok=True)

    def save(name: str, data: dict) -> None:
        (out / f"{name}.json").write_text(json.dumps(data))

    save("new_tab_cold", tabs_trace(eased(0, 200, cold_frames), spare=False))
    save("new_tab_warm", tabs_trace(eased(0, 200, 30), spare=True))
    save("sidebar_collapse", sidebar_trace(eased(260, 0, 28)))
    save("sidebar_expand", sidebar_trace(eased(0, 260, 28)))
    save("reduce_new_tab", tabs_trace(eased(0, 200, reduce_frames), spare=False, looping=looping))
    save("reduce_sidebar_collapse", sidebar_trace(eased(260, 0, reduce_frames)))
    save("reduce_sidebar_expand", sidebar_trace(eased(0, 260, reduce_frames)))
    tops = [1000 + 2.5 * i for i in range(360)]
    save("transcript_follow", {"scroll_top": tops, "frame_ms": [i * REFRESH for i in range(360)], "detached_frames": 3})
    drags = []
    for start, end in ((1100, 1400), (1400, 1100)):
        widths = eased(start, end, 90)
        drags.append({"refresh_ms": REFRESH, "samples": [
            {"t": i * REFRESH, "window": [w, 720, w - 300, 640]} for i, w in enumerate(widths)]})
    save("window_resize", {"drags": drags})


def judge(out: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), "judge", str(out)], capture_output=True, text=True, check=False)


def verdicts(out: Path) -> dict:
    return json.loads((out / "verdicts.json").read_text())


def test_animations_that_run_pass() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, cold_frames=30)
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)
        assert found["new_tab_cold"]["intermediate"] >= 25
        assert found["new_tab_cold"]["neighbors"], "tab-b moved as the new tab grew"
        assert "| new_tab_cold | ok |" in result.stdout


def test_a_new_tab_that_lands_in_one_frame_fails() -> None:
    """The #20216 state: the cold opening's tab is at full width on its first frame."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, cold_frames=0)
        result = judge(out)
        assert result.returncode == 1
        found = verdicts(out)
        assert not found["new_tab_cold"]["ok"]
        assert found["new_tab_cold"]["intermediate"] == 0
        assert found["new_tab_warm"]["ok"]
        assert "new_tab_cold" in result.stderr and "::warning" in result.stderr
        assert "| new_tab_cold | FAIL |" in result.stdout


def test_reduce_motion_expects_one_step_and_no_loops() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, cold_frames=30, reduce_frames=20, looping=["CALayer/spinner/rotation"])
        result = judge(out)
        assert result.returncode == 1
        found = verdicts(out)
        for name in ("reduce_new_tab", "reduce_sidebar_collapse", "reduce_sidebar_expand"):
            assert not found[name]["ok"], name
        assert any("repeating" in problem for problem in found["reduce_new_tab"]["problems"])


def test_a_missing_scenario_fails_as_not_measured() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, cold_frames=30)
        (out / "transcript_follow.json").unlink()
        result = judge(out)
        assert result.returncode == 1
        assert verdicts(out)["transcript_follow"]["problems"][0].startswith("not measured")


if __name__ == "__main__":
    failures = 0
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok {name}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {name}: {error}")
    sys.exit(1 if failures else 0)
