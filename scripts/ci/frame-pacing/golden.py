#!/usr/bin/env python3
"""Golden interactions: assert that cmux NEXT's motion actually runs (cx-codh2).

    golden.py drive SOCKET OUT_DIR   drive a running tagged app; writes OUT_DIR/<scenario>.json
    golden.py judge OUT_DIR          judge those files; prints markdown, exits 1 on a failure

#20216 turned the New Tab tab-grow animation off and nothing noticed; #20365 brought it
back. Since b235e5f5d752 a new tab is there at once at full width by design, so the New Tab
rows now check that it lands in one step and its neighbors make room in the same frame.
Each scenario here records the animated property itself, once per display frame,
through DEBUG-only socket probes: a tab cell's width and x and the sidebar width
(`debug.motion` `trace_start`/`trace_stop`), the transcript's scrollTop (`debug.agent_pane` `stream` with
`trace`) and the window and pane content size during a live resize. The judge then checks
that the property moved over enough intermediate frames, that no single frame carried too
much of the travel, and that frames came on time. Under Reduce Motion (`debug.motion`
`reduce`) the same interactions must land in one step and leave no repeating animation.

The thresholds below were set from tip runs on the owned mini's 120 Hz virtual display,
with margin (see THRESHOLDS). The live resize also reports how many frames the content
lagged the window edge; that is reported only until the live-resize tracking work lands.
The script uses only the standard library: it runs on the mini's system python3.
"""

from __future__ import annotations

import json
import socket
import sys
import time
from pathlib import Path

import browser_resize
import dark_load_flash
import sidebar_content
import split_resize

EPS = 0.75  # points: a value this close to its start or end counts as there

# Per scenario: `min_intermediate` frames strictly between the start and end values,
# `max_step` the largest share of the travel one frame may carry, `p95_frames` and
# `max_frames` the frame interval budget during the motion in refresh periods. Reduce
# Motion scenarios and the New Tab rows instead allow at most `max_intermediate` frames between
# the ends, over a trace of at least `min_frames` frames (two frames would pass by having no
# room to move). A new tab is there at once at its slot and full width, and the strip makes
# room in the same frame (b235e5f5d752, Lawrence 10-14): no grow-in by default.
THRESHOLDS: dict[str, dict[str, float]] = {
    "new_tab_cold": {"max_intermediate": 1, "min_frames": 20},
    "new_tab_warm": {"max_intermediate": 1, "min_frames": 20},
    "sidebar_collapse": {"min_intermediate": 8, "max_step": 0.4, "p95_frames": 2.5, "max_frames": 8},
    "sidebar_expand": {"min_intermediate": 8, "max_step": 0.4, "p95_frames": 2.5, "max_frames": 8},
    "transcript_follow": {"min_intermediate": 60, "max_step": 0.2, "p95_frames": 2.5, "max_frames": 12, "max_trail": 0.9, "end_trail": 0.2},
    "window_resize": {"min_intermediate": 20, "max_step": 0.25, "p95_frames": 3, "max_frames": 12},
    "reduce_new_tab": {"max_intermediate": 1, "min_frames": 20},
    "reduce_sidebar_collapse": {"max_intermediate": 1, "min_frames": 20},
    "reduce_sidebar_expand": {"max_intermediate": 1, "min_frames": 20},
    # Reported only (browser_resize.py): frames a Chromium page trails its host in a live resize.
    "browser_resize": {},
    # Reported only (split_resize.py): a Chromium page beside a split divider a person drags.
    "split_resize": {},
    # Judged by dark_load_flash.py: no frame brighter than the window at rest while a page loads.
    "dark_load_flash": {},
}
SCENARIOS = list(THRESHOLDS)


# ---------------------------------------------------------------- socket


def rpc(path: str, method: str, params: dict | None = None, timeout: float = 70) -> dict:
    """One JSON-lines request to the app's debug socket; {"error": ...} on any failure."""
    request = {"id": 1, "method": method, "params": params or {}}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout)
            client.connect(path)
            client.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode())
            reply = bytearray()
            while not reply.endswith(b"\n"):
                chunk = client.recv(1 << 20)
                if not chunk:
                    break
                reply.extend(chunk)
        response = json.loads(reply)
    except (OSError, ValueError) as error:
        return {"error": f"{method}: {error}"}
    if not isinstance(response, dict) or response.get("ok") is False or "result" not in response:
        return {"error": response.get("error") if isinstance(response, dict) else response}
    result = response["result"]
    return result if isinstance(result, dict) else {"value": result}


# ---------------------------------------------------------------- drive


class Driver:
    def __init__(self, path: str, out: Path) -> None:
        self.path, self.out = path, out
        self.log: list[str] = []

    def call(self, method: str, params: dict | None = None, timeout: float = 70) -> dict:
        result = rpc(self.path, method, params, timeout)
        if "error" in result:
            self.log.append(f"{method} {json.dumps(params or {})}: {result['error']}")
        return result

    def save(self, name: str, data: dict) -> None:
        if name.startswith("reduce_") and name in THRESHOLDS:
            # What the app said when Reduce Motion was set: a scenario run without it is not one.
            data = {**data, "reduce_motion": getattr(self, "reduce_on", False)}
        (self.out / f"{name}.json").write_text(json.dumps(data, separators=(",", ":")) + "\n")

    def trace(self, targets: list[str], act, seconds: float) -> dict:
        """Samples `targets` on every frame around `act()`, for `seconds` after it."""
        started = self.call("debug.motion", {"action": "trace_start", "targets": targets})
        if "error" in started:
            return started
        time.sleep(0.1)  # a few frames at rest first
        acted = act()
        time.sleep(seconds)
        trace = self.call("debug.motion", {"action": "trace_stop"})
        trace["acted"] = acted
        return trace

    def key(self, key: str, modifiers: list[str] | None = None) -> dict:
        return self.call("debug.key", {"key": key, "modifiers": modifiers or []})

    def wait_spare(self, seconds: float = 20) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            spares = self.call("debug.new_tab", {"action": "state"}).get("spares") or []
            if any(spare.get("ready") for spare in spares):
                return True
            time.sleep(0.25)
        return False

    def new_tab(self, name: str, cold: bool) -> None:
        if cold:
            self.call("debug.new_tab", {"action": "drop_spare"})
        else:
            ready = self.wait_spare()
            if not ready:
                self.log.append(f"{name}: no ready spare after 20 s; the opening is cold")
        before = len(self.call("debug.new_tab", {"action": "state"}).get("openings") or [])
        trace = self.trace(["tabs", "strip"], lambda: self.key("t", ["command"]), 0.9)
        openings = self.call("debug.new_tab", {"action": "state"}).get("openings") or []
        trace["opening"] = openings[-1] if len(openings) > before else None
        if not cold:
            trace["spare_ready"] = ready
        self.save(name, trace)
        # Close it again, so every opening starts from the same strip; with no opening, Cmd-W
        # would close a tab that was there before.
        if trace["opening"] is not None:
            self.key("w", ["command"])
            time.sleep(0.6)

    def sidebar(self, prefix: str) -> None:
        """Each toggle with the sidebar width, the panes beside it, and the work the toggle cost.

        The pane rows say what each pane's content is laid out at on every display frame, and
        `debug.layout_counters` says how often that reached the costly parts: one PTY resize and
        shell redraw per `terminal_grid_reports`. A sidebar slide should add one per terminal, at
        the landing, not one per frame (`sidebar_content.py`).
        """
        for name in ("collapse", "expand"):
            before = self.call("debug.layout_counters", {})
            trace = self.trace(["sidebar", "panes"], lambda: self.call("action.run", {"action": "toggleSidebar"}), 0.8)
            trace["counters"] = {"before": before, "after": self.call("debug.layout_counters", {})}
            self.save(f"{prefix}sidebar_{name}", trace)
            time.sleep(0.3)

    def drag_corner(self, dx: float, dy: float, steps: int = 90) -> dict:
        """A live resize at the pace of a real drag: the bottom-right corner pressed once, then one
        `debug.mouse` drag event per 120 Hz frame by (dx, dy) points. Vendored from
        op-next-toolbar's scripts/cmux-next/resize-frames-live.py (#20398, not landed yet)."""
        period = 1 / 120
        layers = (self.call("debug.layers").get("windows") or [{}])[0]
        frame = layers.get("frame") or [0, 0, 1100, 720]
        x0, y0 = frame[2] - 1, frame[3] - 1
        self.call("debug.mouse", {"action": "down", "x": x0, "y": y0})
        started = time.monotonic()
        for step in range(1, steps + 1):
            x, y = x0 + dx * step / steps, y0 + dy * step / steps
            self.call("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                      "press": False, "release": False})
            wait = started + step * period - time.monotonic()
            if wait > 0:
                time.sleep(wait)
        self.call("debug.mouse", {"action": "up", "x": x0 + dx, "y": y0 + dy})
        return {"from": frame, "wall_s": round(time.monotonic() - started, 3)}

    def window_resize(self) -> None:
        """Out by 300 x 150 points and back (`drag_corner`), each drag traced."""
        drags = []
        for dx, dy in ((300, 150), (-300, -150)):
            trace = self.trace(["window"], lambda dx=dx, dy=dy: self.drag_corner(dx, dy), 0.4)
            drags.append(trace)
            time.sleep(0.5)
        self.save("window_resize", {"drags": drags})

    def browser_resize(self) -> None:
        browser_resize.drive(self, self.out)

    def split_resize(self) -> None:
        split_resize.drive(self, self.out)

    def dark_load_flash(self) -> None:
        dark_load_flash.drive(self, self.out)

    def transcript(self) -> None:
        opened = self.call("action.run", {"action": "palette.newAgentChat"})
        # The chat opens hidden, then moves into a dock column: wait up to 10 s for a pane to show
        # it and stream from that pane. If none does, the stream's error names the panes.
        ready: dict = {}
        for _ in range(20):
            ready = rpc(self.path, "debug.agent_pane", {"action": "readiness"}, 30)
            if "error" not in ready:
                break
            time.sleep(0.5)
        time.sleep(2)
        target = {"pane": ready["pane"]} if "error" not in ready and ready.get("pane") else {}
        result = self.call("debug.agent_pane", {"action": "stream", "rows": 2000, "seconds": 3, "trace": 1, **target},
                           timeout=90)
        result["opened"] = opened
        result["ready"] = ready
        self.save("transcript_follow", result)

    def capture(self) -> None:
        """Window frames around one cold Cmd-T, for before/after proof: `debug.window_record` (the
        window as composited, one JPEG per display frame; no Screen Recording permission needed)."""
        folder = self.out / "capture-new-tab"
        self.call("debug.new_tab", {"action": "drop_spare"})
        time.sleep(0.3)
        started = time.monotonic()
        record = self.call("debug.window_record", {"dir": str(folder), "seconds": 1.2})
        time.sleep(0.15)
        key_ms = (time.monotonic() - started) * 1000
        self.key("t", ["command"])
        time.sleep(1.5)
        self.save("capture_new_tab", {"record": record, "key_ms_after_start": round(key_ms, 1)})
        self.key("w", ["command"])

    def run(self) -> None:
        self.save("motion_before", self.call("debug.motion", {"action": "read"}))
        # Measure the default speed whatever this host's config says, with Reduce Motion off.
        self.call("debug.motion", {"action": "speed", "value": "fast"})
        self.call("debug.motion", {"action": "reduce", "value": False})
        steps = [
            ("sidebar", lambda: self.sidebar("")),
            ("new_tab_cold", lambda: self.new_tab("new_tab_cold", cold=True)),
            ("new_tab_warm", lambda: self.new_tab("new_tab_warm", cold=False)),
            ("reduce", self.reduced),
            ("window_resize", self.window_resize),
            ("transcript_follow", self.transcript),
            ("capture", self.capture),
            ("browser_resize", self.browser_resize),
            ("split_resize", self.split_resize),
            # Last: it leaves the app in a dark theme of its own.
            ("dark_load_flash", self.dark_load_flash),
        ]
        for name, step in steps:
            try:
                step()
            except Exception as error:  # one broken scenario must not hide the others
                self.log.append(f"{name}: {type(error).__name__}: {error}")
        self.call("debug.motion", {"action": "reduce", "value": None})
        self.save("drive_log", {"log": self.log})

    def reduced(self) -> None:
        self.reduce_on = self.call("debug.motion", {"action": "reduce", "value": True}).get("reduce_motion") is True
        if not self.reduce_on:
            self.log.append("reduce: the app did not report Reduce Motion on")
        self.call("debug.motion", {"action": "start"})
        try:
            self.sidebar("reduce_")
            self.new_tab("reduce_new_tab", cold=True)
        finally:
            self.save("reduce_motion_spans", self.call("debug.motion", {"action": "stop"}))
            self.call("debug.motion", {"action": "reduce", "value": False})


# ---------------------------------------------------------------- judge


def percentile(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))] if ordered else 0.0


def motion(values: list[float], times: list[float]) -> dict:
    """How `values` (one per frame, at `times` ms) moved from their first to their last value."""
    if len(values) < 2:
        return {"frames": len(values), "travel": 0.0, "intermediate": 0, "max_step": 0.0, "intervals": []}
    start, end = values[0], values[-1]
    travel = abs(end - start)
    intermediate = sum(1 for value in values if abs(value - start) > EPS and abs(value - end) > EPS)
    steps = [abs(b - a) for a, b in zip(values, values[1:])]
    moving = [index for index, value in enumerate(values) if abs(value - start) > EPS]
    unsettled = [index for index, value in enumerate(values) if abs(value - end) > EPS]
    first = max(1, moving[0]) if moving else 1
    last = min(len(values) - 1, (unsettled[-1] + 1) if unsettled else first)
    intervals = [times[index] - times[index - 1] for index in range(first, last + 1)] if moving else []
    return {
        "frames": len(values),
        "start": round(start, 2),
        "end": round(end, 2),
        "travel": round(travel, 2),
        "intermediate": intermediate,
        "moving_frames": sum(1 for step in steps if step > EPS / 3),
        "max_step": round(max(steps) / travel, 3) if travel > EPS else 0.0,
        "intervals": [round(value, 2) for value in intervals],
    }


def times_of(samples: list[dict]) -> list[float]:
    return [float(sample.get("t", 0)) for sample in samples]


def tab_series(trace: dict) -> tuple[dict, list[dict]]:
    """The new tab's width per frame (tabs absent from the first frame and present in the last;
    0 before they show), and each neighbor that moved (x per frame). A placeholder that shows
    at full width and then gives way to the real tab (`pending_tab_*`) is gone by the last
    frame, so it does not count as the new tab growing; it is reported as `placeholders`."""
    samples = trace.get("samples") or []
    if not samples:
        return motion([], []), []
    times = times_of(samples)
    rows = [{tab[0]: tab for tab in sample.get("tabs") or []} for sample in samples]
    initial = set(rows[0])
    added = set(rows[-1]) - initial
    widths = [sum(float(tab[2]) for id_, tab in row.items() if id_ in added) for row in rows]
    grow = motion(widths, times)
    grow["placeholders"] = len({id_ for row in rows for id_ in row} - initial - added)
    neighbors = []
    for id_ in sorted(initial & set(rows[-1])):
        xs = [float(row[id_][1]) if id_ in row else float(rows[0][id_][1]) for row in rows]
        if abs(xs[-1] - xs[0]) > 1:
            neighbors.append({"id": id_[-8:], **motion(xs, times)})
    return grow, neighbors


def sidebar_series(trace: dict) -> dict:
    samples = trace.get("samples") or []
    times = times_of(samples)
    candidates = [motion([float((sample.get("sidebar") or [0, 0])[index]) for sample in samples], times) for index in (0, 1)]
    # The model width and the presented width: judge whichever animated (the other may jump).
    return max(candidates, key=lambda result: (result["intermediate"], -result["max_step"]))


def frame_budget(intervals: list[float], refresh: float, limits: dict[str, float]) -> tuple[dict, list[str]]:
    p95, worst = percentile(intervals, 0.95), max(intervals, default=0.0)
    problems = []
    if intervals and refresh > 0:
        if p95 > limits["p95_frames"] * refresh:
            problems.append(f"frame p95 {p95:.1f} ms > {limits['p95_frames'] * refresh:.1f} ms")
        if worst > limits["max_frames"] * refresh:
            problems.append(f"frame max {worst:.1f} ms > {limits['max_frames'] * refresh:.1f} ms")
    return {"p95_ms": round(p95, 2), "max_ms": round(worst, 2)}, problems


def judge_motion(name: str, result: dict, refresh: float) -> dict:
    limits = THRESHOLDS[name]
    problems = []
    if "max_intermediate" in limits:
        if result["travel"] <= EPS:
            problems.append("nothing changed")
        if result["frames"] < limits["min_frames"]:
            problems.append(f"only {result['frames']} frames traced (< {limits['min_frames']:g})")
        if result["intermediate"] > limits["max_intermediate"]:
            why = "under Reduce Motion" if name.startswith("reduce_") else "; a new tab should land at once (b235e5f5d752)"
            problems.append(f"{result['intermediate']} intermediate frames {why} (> {limits['max_intermediate']:g})")
        return {"ok": not problems, "problems": problems, **result}
    if result["travel"] <= EPS:
        problems.append("nothing moved")
    if result["intermediate"] < limits["min_intermediate"]:
        problems.append(f"{result['intermediate']} intermediate frames (< {limits['min_intermediate']:g})")
    if result["max_step"] > limits["max_step"]:
        problems.append(f"one frame carried {result['max_step']:.0%} of the travel (> {limits['max_step']:.0%})")
    frames, budget = frame_budget(result.get("intervals") or [], refresh, limits)
    problems += budget
    return {"ok": not problems, "problems": problems, **result, **frames}


def load(out: Path, name: str) -> dict | None:
    try:
        data = json.loads((out / f"{name}.json").read_text())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def refresh_of(out: Path) -> float:
    for name in ("new_tab_cold", "sidebar_collapse", "new_tab_warm"):
        data = load(out, name) or {}
        if float(data.get("refresh_ms") or 0) > 0:
            return float(data["refresh_ms"])
    return 1000 / 120


def judge(out: Path) -> dict[str, dict]:
    refresh = refresh_of(out)
    verdicts: dict[str, dict] = {}
    for name in SCENARIOS:
        data = load(out, name)
        if name == "browser_resize":
            verdicts[name] = browser_resize.judge(data or {"error": "no result file"}, refresh)
            continue
        if name == "split_resize":
            verdicts[name] = split_resize.judge(data or {"error": "no result file"}, refresh)
            continue
        if name == "dark_load_flash":
            verdicts[name] = dark_load_flash.judge(data or {"error": "no result file"}, refresh)
            continue
        if data is None or ("error" in data and "samples" not in data and "scroll_top" not in data and "drags" not in data):
            verdicts[name] = {"ok": False, "problems": [f"not measured: {(data or {}).get('error', 'no result file')}"]}
            continue
        if name.startswith(("new_tab", "reduce_new_tab")):
            grow, neighbors = tab_series(data)
            verdict = judge_motion(name, grow, refresh)
            verdict["neighbors"] = [{key: n[key] for key in ("id", "travel", "intermediate", "max_step")} for n in neighbors]
            if "min_intermediate" in THRESHOLDS[name]:
                slow = [n for n in neighbors if n["intermediate"] < THRESHOLDS[name]["min_intermediate"] / 2]
                if slow:
                    verdict["problems"].append(f"{len(slow)} neighbor(s) jumped instead of moving")
                    verdict["ok"] = False
            elif any(n["intermediate"] > THRESHOLDS[name]["max_intermediate"] for n in neighbors):
                verdict["problems"].append("a neighbor animated under Reduce Motion" if name.startswith("reduce_")
                                           else "a neighbor moved over frames instead of making room at once")
                verdict["ok"] = False
            # Each strip keeps its width through a Cmd-T: a bar that gives up or takes back width
            # (the pane's "…") lays every tab out again at once, past any spring.
            widths = [sample.get("strip") for sample in data.get("samples") or [] if sample.get("strip")]
            moved = [index for index in range(len(widths[0]) if widths else 0)
                     if any(len(row) != len(widths[0]) or abs(float(row[index]) - float(widths[0][index])) > EPS for row in widths)]
            if moved:
                verdict["problems"].append(f"{len(moved)} tab strip(s) changed width during the opening")
                verdict["ok"] = False
            verdict["opening"] = data.get("opening")
            if data.get("spare_ready") is False:
                verdict["problems"].append("not measured: no ready spare, so the opening was cold")
                verdict["ok"] = False
        elif "sidebar" in name:
            verdict = judge_motion(name, sidebar_series(data), refresh)
            verdict["content"] = sidebar_content.metrics(data)
        elif name == "transcript_follow":
            verdict = judge_transcript(data, refresh)
        else:
            verdict = judge_resize(data, refresh)
        if name.startswith("reduce_"):
            if data.get("reduce_motion") is not True:
                verdict["problems"].append("not measured: Reduce Motion was not on")
                verdict["ok"] = False
            looping = data.get("looping") or []
            verdict["looping"] = looping
            if looping:
                verdict["problems"].append(f"{len(looping)} repeating animation(s) under Reduce Motion")
                verdict["ok"] = False
        verdicts[name] = verdict
    return verdicts


def judge_transcript(data: dict, refresh: float) -> dict:
    tops = [float(value) for value in data.get("scroll_top") or []]
    times = [float(value) for value in data.get("frame_ms") or []]
    if not tops or len(tops) != len(times):
        return {"ok": False, "problems": [f"not measured: {data.get('error', 'no per-frame trace')}"]}
    result = motion(tops, times)
    # The stream's own `detached_frames` (gap > 2 px) is informational: the follow eases toward
    # the bottom, so it trails a growing transcript on most frames by design.
    result["detached_frames"] = int(data.get("detached_frames") or 0)
    # The stream keeps growing for its whole length, so "intermediate" counts the frames the view moved on.
    result["intermediate"] = result["moving_frames"]
    verdict = judge_motion("transcript_follow", result, refresh)
    # Following: how far below the view the newest text gets (scrollHeight - scrollTop over its
    # least value, the viewport plus the resting inset), in viewports; and where it ends.
    heights = [float(value) for value in data.get("scroll_height") or []]
    if len(heights) == len(tops) and tops:
        below = [height - top for height, top in zip(heights, tops)]
        viewport = max(1.0, min(below))
        trail = [(value - min(below)) / viewport for value in below]
        verdict["trail_max"] = round(max(trail), 3)
        verdict["trail_end"] = round(trail[-1], 3)
        limits = THRESHOLDS["transcript_follow"]
        if verdict["trail_max"] > limits["max_trail"]:
            verdict["problems"].append(f"the newest text fell {verdict['trail_max']:.0%} of a viewport behind (> {limits['max_trail']:.0%})")
        if verdict["trail_end"] > limits["end_trail"]:
            verdict["problems"].append(f"ended {verdict['trail_end']:.0%} of a viewport above the bottom (> {limits['end_trail']:.0%})")
    else:
        verdict["problems"].append("not measured: no per-frame scroll_height")
    verdict["ok"] = not verdict["problems"]
    return verdict


def judge_resize(data: dict, refresh: float) -> dict:
    """The pane content's width over each drag, and (reported only) how many frames it lagged the edge."""
    drags = data.get("drags") or []
    results, problems, lag_runs = [], [], []
    for trace in drags:
        # The pane content's width: its tab strip spans it.
        samples = [sample for sample in trace.get("samples") or [] if sample.get("window") and sample.get("strip")]
        times = times_of(samples)
        widths = [max(float(width) for width in sample["strip"]) for sample in samples]
        content = motion(widths, times)
        window = motion([float(sample["window"][0]) for sample in samples], times)
        offsets = [float(sample["window"][0]) - width for sample, width in zip(samples, widths)]
        rest = offsets[0] if offsets else 0.0
        run = longest = 0
        for offset in offsets:
            run = run + 1 if abs(offset - rest) > 1 else 0
            longest = max(longest, run)
        lag_runs.append(longest)
        content["window_intermediate"] = window["intermediate"]
        results.append(content)
    if not results:
        return {"ok": False, "problems": ["not measured: no drag"]}
    worst = min(results, key=lambda result: result["intermediate"])
    verdict = judge_motion("window_resize", {**worst, "intervals": [i for r in results for i in r["intervals"]]}, refresh)
    verdict["intervals"] = []
    verdict["drags"] = [{key: r[key] for key in ("travel", "intermediate", "window_intermediate", "max_step")} for r in results]
    verdict["lag_frames"] = max(lag_runs)
    # Strict tracking (content within one frame of the edge) is reported, not enforced, until
    # feat/live-resize-tracking lands.
    verdict["strict_lag_ok"] = max(lag_runs) <= 1
    return verdict


def markdown(out: Path, verdicts: dict[str, dict]) -> str:
    refresh = refresh_of(out)
    lines = ["## Golden interactions (motion guard, cx-codh2)", "",
             f"Display refresh {refresh:.2f} ms. Each row is the animated property sampled once per display frame.", "",
             "| scenario | result | intermediate frames | largest step | frame p95 / max | notes |",
             "|---|---|---|---|---|---|"]
    for name, verdict in verdicts.items():
        if name == "browser_resize":
            lines.append(browser_resize.markdown_row(verdict))
            continue
        if name == "split_resize":
            lines.append(split_resize.markdown_row(verdict))
            continue
        if name == "dark_load_flash":
            lines.append(dark_load_flash.markdown_row(verdict))
            continue
        limits = THRESHOLDS[name]
        bound = f"≥ {limits['min_intermediate']:g}" if "min_intermediate" in limits else f"≤ {limits['max_intermediate']:g}"
        step = f"{verdict['max_step']:.0%}" if "max_step" in verdict else ""
        timing = f"{verdict['p95_ms']:g} / {verdict['max_ms']:g} ms" if "p95_ms" in verdict else ""
        notes = list(verdict.get("problems") or [])
        if verdict.get("opening"):
            notes.append("spare" if verdict["opening"].get("spare") else "cold")
        if "lag_frames" in verdict:
            notes.append(f"content lagged the edge {verdict['lag_frames']} frame(s) at most (reported only)")
        if "content" in verdict:
            notes.append(sidebar_content.note(verdict["content"]))
        if verdict.get("neighbors"):
            notes.append("neighbors " + ", ".join(str(n["intermediate"]) for n in verdict["neighbors"]))
        lines.append(f"| {name} | {'ok' if verdict['ok'] else 'FAIL'} | {verdict.get('intermediate', '')} ({bound}) "
                     f"| {step} | {timing} | {'; '.join(notes)} |")
    log = (load(out, "drive_log") or {}).get("log") or []
    if log:
        lines += ["", "Driver notes:", ""] + [f"- {entry}" for entry in log[:20]]
    lines += ["", "Warning only: this never blocks a merge. Thresholds: scripts/ci/frame-pacing/golden.py THRESHOLDS."]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "drive":
        out = Path(argv[3])
        out.mkdir(parents=True, exist_ok=True)
        Driver(argv[2], out).run()
        return 0
    if len(argv) == 3 and argv[1] == "judge":
        out = Path(argv[2])
        verdicts = judge(out)
        (out / "verdicts.json").write_text(json.dumps(verdicts, indent=1) + "\n")
        sys.stdout.write(markdown(out, verdicts))
        failed = [name for name, verdict in verdicts.items() if not verdict["ok"]]
        for name in failed:
            print(f"::warning title=Golden interactions::{name}: {'; '.join(verdicts[name]['problems'])}", file=sys.stderr)
        return 1 if failed else 0
    print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
    print(__doc__.strip().splitlines()[3].strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
