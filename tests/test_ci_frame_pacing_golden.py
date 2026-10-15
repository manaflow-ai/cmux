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


def tabs_trace(widths: list[float], *, spare: bool, looping: list[str] | None = None,
               strips: list[list[float]] | None = None) -> dict:
    samples = []
    for index, width in enumerate(widths):
        tabs = [["tab-a", 0, 180, 1], ["tab-b", 180, 180, 1]]
        if width > 0:
            # The new tab sits between the two; tab-b moves right as it grows.
            tabs = [["tab-a", 0, 180, 1], ["new-tab", 180, width, 1], ["tab-b", 180 + width, 180, 1]]
        # Each traced strip's width (two in a split); the same every frame unless given.
        samples.append({"t": index * REFRESH, "tabs": tabs, "strip": strips[index] if strips else [413, 413]})
    return {"refresh_ms": REFRESH, "samples": samples, "opening": {"spare": spare}, "looping": looping or []}


def sidebar_trace(widths: list[float], looping: list[str] | None = None) -> dict:
    samples = [{"t": i * REFRESH, "sidebar": [w, w]} for i, w in enumerate(widths)]
    return {"refresh_ms": REFRESH, "samples": samples, "looping": looping or []}


def reduced(trace: dict, on: bool) -> dict:
    """What `golden.py drive` saves for a Reduce Motion scenario: the app's answer when it was set."""
    return {**trace, "reduce_motion": on}


def write_run(
    out: Path,
    *,
    cold_frames: int = 0,
    warm_frames: int = 0,
    reduce_frames: int = 0,
    looping: list[str] | None = None,
    reduce_on: bool = True,
    warm_spare: bool | None = True,
) -> None:
    out.mkdir(parents=True, exist_ok=True)

    def save(name: str, data: dict) -> None:
        (out / f"{name}.json").write_text(json.dumps(data))

    # A new tab is there at once, full width, and the strip makes room in the same frame
    # (b235e5f5d752): one step, with frames at rest on both sides.
    save("new_tab_cold", tabs_trace(eased(0, 200, cold_frames, rest=14), spare=False))
    save("new_tab_warm", {**tabs_trace(eased(0, 200, warm_frames, rest=14), spare=bool(warm_spare)), "spare_ready": warm_spare})
    save("sidebar_collapse", sidebar_trace(eased(260, 0, 28)))
    save("sidebar_expand", sidebar_trace(eased(0, 260, 28)))
    # A Reduce Motion trace still runs ~0.9 s: frames at rest on both sides of the one step.
    save("reduce_new_tab", reduced(tabs_trace(eased(0, 200, reduce_frames, rest=14), spare=False, looping=looping), reduce_on))
    save("reduce_sidebar_collapse", reduced(sidebar_trace(eased(260, 0, reduce_frames, rest=14), looping), reduce_on))
    save("reduce_sidebar_expand", reduced(sidebar_trace(eased(0, 260, reduce_frames, rest=14)), reduce_on))
    tops = [1000 + 2.5 * i for i in range(360)]
    save("transcript_follow", {"scroll_top": tops, "scroll_height": [top + 600 + (40 if i % 7 else 0) for i, top in enumerate(tops)],
                               "frame_ms": [i * REFRESH for i in range(360)], "detached_frames": 300})
    drags = []
    for start, end in ((1100, 1400), (1400, 1100)):
        widths = eased(start, end, 90)
        drags.append({"refresh_ms": REFRESH, "samples": [
            {"t": i * REFRESH, "window": [w, 720], "strip": [w - 300]} for i, w in enumerate(widths)]})
    save("window_resize", {"drags": drags})


def judge(out: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(SCRIPT), "judge", str(out)], capture_output=True, text=True, check=False)


def verdicts(out: Path) -> dict:
    return json.loads((out / "verdicts.json").read_text())


def test_a_run_as_designed_passes() -> None:
    """New tabs land at once at full width (b235e5f5d752); the sidebar and transcript move."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)
        assert found["new_tab_cold"]["intermediate"] == 0
        assert found["new_tab_cold"]["neighbors"], "tab-b made room in the same frame"
        assert "| new_tab_cold | ok |" in result.stdout


def test_a_new_tab_that_grows_in_fails() -> None:
    """Grow-in is not the default since b235e5f5d752: a cold opening that eases in is a regression."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, cold_frames=30)
        result = judge(out)
        assert result.returncode == 1
        found = verdicts(out)
        assert not found["new_tab_cold"]["ok"]
        assert found["new_tab_cold"]["intermediate"] >= 25
        assert any("should land at once" in problem for problem in found["new_tab_cold"]["problems"])
        assert any("neighbor" in problem for problem in found["new_tab_cold"]["problems"])
        assert found["new_tab_warm"]["ok"]
        assert "new_tab_cold" in result.stderr and "::warning" in result.stderr
        assert "| new_tab_cold | FAIL |" in result.stdout


def test_a_strip_that_changes_width_during_the_opening_fails() -> None:
    """cx-codh2, 10 tabs in a 440 pt split: the pane's "…" hid for one frame after a cold Cmd-T,
    the strip took its 26 pt and laid every tab out at once, then gave it back."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, cold_frames=30)
        widths = eased(0, 200, 30)
        strips = [[413, 413] for _ in widths]
        strips[20] = [439, 413]
        (out / "new_tab_cold.json").write_text(json.dumps(tabs_trace(widths, spare=False, strips=strips)))
        result = judge(out)
        assert result.returncode == 1
        found = verdicts(out)
        assert not found["new_tab_cold"]["ok"]
        assert "1 tab strip(s) changed width during the opening" in found["new_tab_cold"]["problems"]
        assert found["new_tab_warm"]["ok"]


def test_reduce_motion_expects_one_step_and_no_loops() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, reduce_frames=20, looping=["CALayer/spinner/rotation"])
        result = judge(out)
        assert result.returncode == 1
        found = verdicts(out)
        for name in ("reduce_new_tab", "reduce_sidebar_collapse", "reduce_sidebar_expand"):
            assert not found[name]["ok"], name
        assert any("repeating" in problem for problem in found["reduce_new_tab"]["problems"])


def test_reduce_motion_passes_when_the_app_reports_it_on_and_nothing_moves_between_the_ends() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        judge(out)
        found = verdicts(out)
        for name in ("reduce_new_tab", "reduce_sidebar_collapse", "reduce_sidebar_expand"):
            assert found[name]["ok"], (name, found[name]["problems"])


def test_a_reduce_scenario_the_app_did_not_run_under_reduce_motion_is_not_measured() -> None:
    """A Reduce Motion override that silently failed must not pass as a Reduce Motion run."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, reduce_on=False)
        result = judge(out)
        assert result.returncode == 1
        found = verdicts(out)
        for name in ("reduce_new_tab", "reduce_sidebar_collapse", "reduce_sidebar_expand"):
            assert "not measured: Reduce Motion was not on" in found[name]["problems"], name


def test_a_reduce_trace_of_two_frames_fails() -> None:
    """Two frames have no room for an intermediate one: a throttled trace must not pass."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        (out / "reduce_sidebar_collapse.json").write_text(json.dumps(reduced(sidebar_trace([260, 0]), True)))
        judge(out)
        problems = verdicts(out)["reduce_sidebar_collapse"]["problems"]
        assert any(problem.startswith("only 2 frames traced") for problem in problems), problems


def test_a_repeating_animation_fails_every_reduce_scenario_it_shows_in() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, looping=["CALayer/spinner/rotation"])
        judge(out)
        found = verdicts(out)
        for name in ("reduce_new_tab", "reduce_sidebar_collapse"):
            assert any("repeating" in problem for problem in found[name]["problems"]), name
        assert found["reduce_sidebar_expand"]["ok"]


def test_a_warm_opening_without_a_ready_spare_is_not_measured() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, warm_spare=False)
        result = judge(out)
        assert result.returncode == 1
        problems = verdicts(out)["new_tab_warm"]["problems"]
        assert "not measured: no ready spare, so the opening was cold" in problems, problems


def test_a_missing_scenario_fails_as_not_measured() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
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
