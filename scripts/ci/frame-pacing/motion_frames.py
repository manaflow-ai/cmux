"""Frame checks for the motion areas: no blank frame, no content a frame late.

Used by golden.py (`motion_frames`, and alone as the `frames` suite of
cmux-next-frame-pacing.yml, which cmux-next-motion-golden.yml starts when a pull request
touches a motion area). Leo, 2026-11-27: "what are minimally rigorous things we can be adding
to the app ci situation to be proving correctness and perf in fast fail open ways/targetted
tests per type of situation that things touch based off relevance."

Each gesture goes through the real key path inside one `debug.new_tab` `frame_strip`
recording (the window as the window server composited it, Chromium's page windows and the
palette's panel over it too: `above`), about 30 frames at 120 Hz after the key:

- `zoom`: Cmd-Shift-Enter on the right of two Chromium panes, then Cmd-Shift-Enter again;
- `palette`: Cmd-P over a Chromium pane, then Escape;
- `close`: Cmd-D beside a Chromium pane, then Cmd-W on the new pane (the close is recorded).

The judge reads two things per recording, both from the strip's own per-frame report:

- `blank`: a frame in which any shown pane's content area is one flat color that is in
  neither the frame before the key nor the last frame (frame_strip's `blank`). cmux#58266:
  a zoom hid the pane it covered from its first frame, so that pane's Chromium page went to
  the window's backdrop until the growing pane reached it. Judged in every run.
- `late`: under Reduce Motion a gesture lands in one step, so every frame after the key
  is either the frame before it or the last one. `late` counts the frames from the first
  change to the frame the window reached its last frame for good: a frame that shows the
  palette's panel without its pill, or a zoomed pane whose page is still at its old size,
  is one of them. Judged for `zoom` and `palette` (the gestures whose content has arrived a
  frame late before); reported for `close`, whose neighbor's page resize is its own lane.

Fail open: a run that could not set up a gesture, record it, or read enough frames says
"not measured" and never fails. Only a measured frame can fail. The pages are static and
carry text, so nothing on screen moves on its own (a flat page would read as blank).
"""

from __future__ import annotations

import json
import time
from pathlib import Path

# About 30 display frames at 120 Hz after the key; frame_strip also keeps some before it.
DURATION_MS = 260
# Frames a recording needs after the key to count as measured (fewer: a dropped capture).
MIN_FRAMES = 12
# frame_strip's mean-difference tolerance: a frame this close to another is the same frame.
# Text on a static page, no caret: frames at rest read 0.
TOLERANCE = 0.002
# Downscale of each captured frame; frame_strip compares at this size.
SCALE = 0.25
# Frames a gesture may take to land under Reduce Motion: it lands in one step.
MAX_LATE = {"zoom": 0, "unzoom": 0, "palette": 0, "palette_close": 0}

PAGE = """<!doctype html><meta charset="utf-8"><title>%(title)s</title>
<style>html,body{margin:0;height:100%%;background:%(background)s;color:%(ink)s;font:600 15px -apple-system,sans-serif}
main{padding:20px;line-height:1.5}</style>
<main><h1>%(title)s</h1>%(lines)s</main>
"""
# Two pages unlike each other, so a covered pane, its backdrop and the pane over it all differ.
PAGES = {
    "left": {"title": "Left page", "background": "#20242c", "ink": "#c8ccd4"},
    "right": {"title": "Right page", "background": "#2b2130", "ink": "#e0c8a8"},
}


def _page(name: str) -> str:
    spec = PAGES[name]
    lines = "".join(f"<p>{spec['title']} line {index}: the quick brown fox jumps over the lazy dog.</p>"
                    for index in range(1, 25))
    return PAGE % {**spec, "lines": lines}


def _strip(driver, folder: Path, key: str, modifiers: list[str]) -> dict:
    """One frame_strip around `key`: its report, or an error."""
    folder.mkdir(parents=True, exist_ok=True)
    reply = driver.call("debug.new_tab", {
        "action": "frame_strip", "key": key, "modifiers": modifiers, "dir": str(folder), "above": True,
        "duration_ms": DURATION_MS, "scale": SCALE, "tolerance": TOLERANCE, "content": "focused",
    }, timeout=60)
    if "error" in reply:
        return {"error": f"frame_strip {'+'.join(modifiers + [key])}: {reply['error']}"}
    return reply


def _rows(report: dict) -> list[dict]:
    """The report's per-frame rows, without the paths of the PNGs (they stay in the artifact)."""
    keep = ("ms", "blank", "blank_panes", "content_blank", "outside_vs_before", "outside_vs_final",
            "content_vs_before", "content_vs_final", "flatness")
    return [{key: row[key] for key in keep if key in row} for row in report.get("frames") or []]


def _compact(report: dict) -> dict:
    if "error" in report:
        return report
    fields = ("frame_count", "blank", "blank_pane_frames", "pane_rects", "settled_ms", "first_change_ms",
              "mean_interval_ms", "dir")
    return {**{key: report.get(key) for key in fields}, "frames": _rows(report)}


def drive(driver, out: Path) -> None:
    """Two Chromium panes in a workspace of their own, then each gesture at the default motion and under Reduce Motion."""
    folder = out / "motion-frames"
    folder.mkdir(parents=True, exist_ok=True)
    pages = {}
    for name in PAGES:
        path = folder / f"{name}.html"
        path.write_text(_page(name))
        pages[name] = path

    def evaluate(script: str):
        result = driver.call("browser.page.eval", {"script": script}, timeout=20)
        return result.get("value") if "error" not in result else None

    def open_page(name: str) -> bool:
        driver.call("action.run", {"action": "openBrowser.chromium", "args": {"url": pages[name].as_uri()}, "focus": True},
                    timeout=90)
        title = PAGES[name]["title"]
        loaded = driver.until(lambda: evaluate(f"document.readyState === 'complete' && document.title === {json.dumps(title)}") is True,
                              f"the {name} page loading in a Chromium tab", 60, 0.25)
        if loaded:
            driver.until(lambda: evaluate("performance.getEntriesByType('paint').some(e => e.name === 'first-contentful-paint')") is True,
                         f"the {name} page's first contentful paint")
        return bool(loaded)

    # A workspace of its own: a fresh launch lands on the docked Home, whose chat dock does not split (split_resize.py).
    setup: dict = {"workspace": driver.call("action.run", {"action": "workspace.newAtBottom", "focus": True}, timeout=30)}
    driver.settle("the new workspace")
    if not open_page("left"):
        driver.save("motion_frames", {"error": "the left page never loaded in a Chromium tab", "setup": setup})
        return
    setup["split"] = driver.call("action.run", {"action": "splitRight", "focus": True}, timeout=30)
    driver.settle("the window after the split")
    if not open_page("right"):
        driver.save("motion_frames", {"error": "the right page never loaded in a Chromium tab", "setup": setup})
        return
    driver.settle("the two pages")

    runs: dict[str, dict] = {}
    for mode in ("default", "reduce"):
        reduce = mode == "reduce"
        set_reduce = driver.call("debug.motion", {"action": "reduce", "value": reduce})
        runs_mode: dict[str, dict] = {"reduce_motion": set_reduce.get("reduce_motion")}
        driver.settle(f"{mode}: the window at rest")

        def record(name: str, key: str, modifiers: list[str]) -> dict:
            report = _strip(driver, folder / mode / name, key, modifiers)
            driver.settle(f"{mode}: the window after {name}")
            return _compact(report)

        runs_mode["zoom"] = record("zoom", "return", ["command", "shift"])
        runs_mode["unzoom"] = record("unzoom", "return", ["command", "shift"])
        runs_mode["palette"] = record("palette", "p", ["command"])
        runs_mode["palette_close"] = record("palette_close", "escape", [])
        # Cmd-D splits the right pane; Cmd-W then closes the new pane's tab, and with it the pane.
        driver.key("d", ["command"])
        driver.settle(f"{mode}: the window after Cmd-D")
        runs_mode["close"] = record("close", "w", ["command"])
        runs[mode] = runs_mode
    driver.call("debug.motion", {"action": "reduce", "value": False})
    time.sleep(0.1)  # sleep-ok: one frame for the restored motion setting before the next scenario
    driver.save("motion_frames", {"setup": setup, "runs": runs})


def late_frames(frames: list[dict], tolerance: float = TOLERANCE) -> int | None:
    """Frames from the first change after the key to the frame the window reached its last frame for good.

    0: the gesture landed in one step. None: nothing changed (the gesture did nothing on screen).
    """
    after = [row for row in frames if float(row.get("ms", 0)) > 0]
    if not after:
        return None

    def changed(row: dict) -> bool:
        return max(float(row.get("outside_vs_before", 0)), float(row.get("content_vs_before", 0))) > tolerance

    def final(row: dict) -> bool:
        return max(float(row.get("outside_vs_final", 0)), float(row.get("content_vs_final", 0))) <= tolerance

    first = next((index for index, row in enumerate(after) if changed(row)), None)
    if first is None:
        return None
    landed = len(after)
    for index in range(len(after) - 1, -1, -1):
        if not final(after[index]):
            break
        landed = index
    return max(0, landed - first)


def judge(data: dict, refresh: float) -> dict:
    """Fails on a blank frame in any measured recording, or a late frame where MAX_LATE judges one."""
    del refresh  # frames, not pacing
    if "error" in data:
        return {"ok": True, "measured": False, "problems": [], "note": f"not measured: {data['error']}"}
    problems: list[str] = []
    unmeasured: list[str] = []
    rows: dict[str, dict] = {}
    for mode, gestures in (data.get("runs") or {}).items():
        if mode == "reduce" and gestures.get("reduce_motion") is not True:
            unmeasured.append("reduce: the app did not report Reduce Motion on")
            continue
        for name, report in gestures.items():
            if not isinstance(report, dict):
                continue
            label = f"{mode}/{name}"
            if "error" in report:
                unmeasured.append(f"{label}: {report['error']}")
                continue
            frames = report.get("frames") or []
            after = [row for row in frames if float(row.get("ms", 0)) > 0]
            if len(after) < MIN_FRAMES:
                unmeasured.append(f"{label}: {len(after)} frames after the key")
                continue
            blank = sum(1 for row in after if row.get("blank"))
            late = late_frames(frames)
            rows[label] = {"frames": len(after), "blank": blank, "late": late}
            if blank:
                first = next(row for row in after if row.get("blank"))
                problems.append(f"{label}: {blank} blank frame(s), the first {first.get('ms'):g} ms after the key "
                                f"({first.get('blank_panes', 0):g} pane(s) blank)")
            if mode == "reduce" and name in MAX_LATE:
                if late is None:
                    unmeasured.append(f"{label}: nothing changed on screen")
                elif late > MAX_LATE[name]:
                    problems.append(f"{label}: content landed {late} frame(s) late under Reduce Motion "
                                    f"(at most {MAX_LATE[name]})")
    if not rows:
        return {"ok": True, "measured": False, "problems": [],
                "note": "not measured: " + ("; ".join(unmeasured) or "no recording")}
    verdict = {"ok": not problems, "measured": True, "problems": problems, "gestures": rows}
    if unmeasured:
        verdict["note"] = "partly measured: " + "; ".join(unmeasured)
    return verdict


def markdown_row(verdict: dict) -> str:
    """The scenario's row of golden.py's table."""
    if not verdict.get("measured"):
        return f"| motion_frames | report |  |  |  | {verdict.get('note', 'not measured')} (fails open) |"
    gestures = verdict.get("gestures") or {}
    summary = ", ".join(f"{label} {row['blank']}b/{'-' if row['late'] is None else row['late']}l"
                        for label, row in gestures.items())
    notes = list(verdict.get("problems") or []) or ["no blank frame; Cmd-Shift-Enter and Cmd-P land in one frame under Reduce Motion"]
    if verdict.get("note"):
        notes.append(verdict["note"])
    return f"| motion_frames | {'ok' if verdict.get('ok') else 'FAIL'} | {summary} |  |  | {'; '.join(notes)} |"
