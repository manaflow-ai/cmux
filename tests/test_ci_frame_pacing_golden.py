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


def sidebar_trace(widths: list[float], looping: list[str] | None = None, *,
                  panes: list[float] | None = None, grid_reports: int | None = None) -> dict:
    """The sidebar's width per frame, optionally with a pane's content width per frame
    (`panes`, as `ScreenContentView+MotionSample` samples it) and the terminal grid reports
    the toggle cost (`debug.layout_counters`), which `sidebar_content.py` reports."""
    samples = []
    for index, width in enumerate(widths):
        sample: dict = {"t": index * REFRESH, "sidebar": [width, width]}
        if panes is not None:
            content = panes[index]
            sample["panes"] = [["p1", 0, 0, content + 20, 600, 1, 0,
                                0, 0, content + 20, 600, content, 600, 0, 0, 0, content, 600]]
        samples.append(sample)
    trace: dict = {"refresh_ms": REFRESH, "samples": samples, "looping": looping or []}
    if grid_reports is not None:
        trace["counters"] = {"before": {"terminal_grid_reports": 7},
                             "after": {"terminal_grid_reports": 7 + grid_reports}}
    return trace


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


def test_a_sidebar_slide_reports_what_it_cost_the_panes() -> None:
    """Leo, 2026-10-20: side panes lag when the sidebar opens and closes. The row says how
    many frames re-laid the panes out and how many grid reports (PTY resizes and shell
    redraws) the slide cost: one per terminal at the landing, not one per frame."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        widths = eased(260, 0, 28)
        # The content follows the edge every frame; the PTY hears the grid once, at the landing.
        content = [1200 - width for width in widths]
        (out / "sidebar_collapse.json").write_text(json.dumps(
            sidebar_trace(widths, panes=content, grid_reports=1)))
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)["sidebar_collapse"]["content"]
        assert found["panes"] == 1, found
        assert found["relayouts"] == 28, found  # the eased frames; the 12 at rest move nothing
        assert found["stalled"] == 0, found
        assert found["grid_reports"] == 1, found
        assert "1 terminal grid report(s)" in result.stdout
        assert "no pane following it" not in result.stdout


def test_a_pane_that_stops_following_the_sidebar_edge_is_reported() -> None:
    """A pane whose content freezes while the edge keeps moving (the lag Leo saw) shows up
    as stalled frames, not as a perfect follow. Reported only: the run still passes."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        widths = eased(260, 0, 28)
        (out / "sidebar_collapse.json").write_text(json.dumps(
            sidebar_trace(widths, panes=[940.0] * len(widths), grid_reports=28)))
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)["sidebar_collapse"]["content"]
        assert found["relayouts"] == 0, found
        assert found["stalled"] == 28, found
        assert found["grid_reports"] == 28, found
        assert "no pane following it on 28 frame(s)" in result.stdout


def test_a_sidebar_trace_without_pane_samples_still_passes() -> None:
    """An older trace, or a run whose screen samples no pane, reports no pane numbers rather
    than failing: the pane cost is context, never a gate."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)["sidebar_collapse"]["content"]
        assert found == {"frames": 0}, found
        assert "no pane samples" in result.stdout


def test_browser_resize_is_reported_only() -> None:
    """The Chromium resize lag is reported, never judged: a run without it still passes."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        (out / "browser_resize.json").unlink(missing_ok=True)
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)["browser_resize"]
        assert found["ok"] and not found["measured"], found
        assert "| browser_resize | report |" in result.stdout


def test_dark_load_flash_without_a_result_is_not_measured() -> None:
    """It needs an owned Mac in a dark theme, so a run without it reports and still passes."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)["dark_load_flash"]
        assert found["ok"] and not found["measured"], found
        assert "| dark_load_flash | report |" in result.stdout


def test_dark_load_flash_fails_when_a_frame_was_brighter_than_the_window_at_rest() -> None:
    """The run that did measure still judges: a page brighter than the theme is the bug (#22963)."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        (out / "dark_load_flash.json").write_text(json.dumps({
            "theme_background": "#2e3440", "theme_luminance": 0.05, "theme_is_dark": True,
            "rest": {"peak": [0.06] * 12, "luminance": [0.05] * 12},
            "navigate": {"peak": [0.06] * 59 + [0.98], "luminance": [0.05] * 59 + [0.93]},
        }) + "\n")
        result = judge(out)
        assert result.returncode == 1, result.stdout + result.stderr
        found = verdicts(out)["dark_load_flash"]
        assert found["measured"] and not found["ok"], found
        assert any("flashed" in problem for problem in found["problems"]), found
        assert "| dark_load_flash | FAIL |" in result.stdout


def test_dark_load_flash_reports_when_an_unstyled_page_got_its_own_background() -> None:
    """How long the theme color stayed under a page that had already painted (#22963).

    A page with no background of its own is *meant* to end up white, so this is reported
    and never judged: a late rise is the signal, not the rise itself.
    """
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        rest = {"peak": [0.06] * 12, "luminance": [0.05] * 12}
        quiet = {"peak": [0.06] * 70, "luminance": [0.05] * 70}
        # Painted at once, white from frame 6: the hand-over followed the paint.
        early = {"peak": [0.06] * 6 + [0.98] * 64, "luminance": [0.05] * 6 + [0.93] * 64}
        # White only at the very end: the theme color sat under painted text for the load.
        late = {"peak": [0.06] * 64 + [0.98] * 6, "luminance": [0.05] * 64 + [0.93] * 6}
        for unstyled, share in ((early, 6 / 70), (late, 64 / 70)):
            (out / "dark_load_flash.json").write_text(json.dumps({
                "theme_background": "#2e3440", "theme_luminance": 0.05, "theme_is_dark": True,
                "rest": rest, "navigate": quiet, "unstyled": unstyled,
            }) + "\n")
            result = judge(out)
            found = verdicts(out)["dark_load_flash"]
            # Judged on the `navigate` pass only: the unstyled numbers never fail a run.
            assert result.returncode == 0, result.stdout + result.stderr
            assert found["ok"] and found["measured"], found
            assert found["unstyled"]["rise_share"] == round(share, 3), found["unstyled"]


def test_dark_load_flash_unstyled_pass_may_be_missing() -> None:
    """An older run, or one whose third recording failed, still judges the rest of it."""
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out)
        (out / "dark_load_flash.json").write_text(json.dumps({
            "theme_background": "#2e3440", "theme_luminance": 0.05, "theme_is_dark": True,
            "rest": {"peak": [0.06] * 12, "luminance": [0.05] * 12},
            "navigate": {"peak": [0.06] * 70, "luminance": [0.05] * 70},
        }) + "\n")
        result = judge(out)
        assert result.returncode == 0, result.stdout + result.stderr
        found = verdicts(out)["dark_load_flash"]
        assert found["ok"] and found["measured"], found
        assert "not measured" in found["unstyled"]["note"], found["unstyled"]


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
