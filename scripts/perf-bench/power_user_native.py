#!/usr/bin/env python3
"""Power-user input bursts on the native Mac app: fast, seeded window resizes, workspace switches and tab switches
in a cmux NEXT build, judged per display frame. The native half of the power-user input stress harness (the web half
is webviews/test/power-user-bursts.browser.test.ts).

Leo, 2026-11-22 12:07Z: "you guys also need to be testing flicks of extremely fast input for scrolling and
resizing/mouse movement and typing/pasting/switching workspaces around. we need to test like power users more often."
Earlier: "IF IT NEEDS TO SHIFT, IT SHIFTS MOTHERFUCKING GRACEFULLY ... MATHEMATICALLY, ALL OF THESE SHOULD BE
FLAGGABLE" and "EVERY POSSIBLE CASE, NO MATTER HOW WILD".

No second engine: it launches through scripts/cmux-next/bench_launch.py, drives and samples the app through
scripts/ci/frame-pacing/pane_drag.py's Driver (workspace building, `debug.mouse`, `debug.motion` trace and recorder,
the `.scan` reader), and reads `debug.frames` raw as anim-perf-terminal.py and pane_drag.py do. Only the seeded plan
and the judge below are new.

Set-up (untimed): workspaces of 1, 4, 2 and 6 panes of mixed kinds (pane_drag.Driver.build: terminal, Chromium
page, New Tab page, Markdown); the 1-pane workspace's pane also gets TAB_PAGES Chromium tabs of a local HTTP fixture
(no-store: every load reaches the harness, so a reload on a tab switch is counted), a Markdown file and a New Tab
page. At rest it learns each workspace's pane layout, which workspace each Ctrl+digit shows, and which tab each
Cmd+digit selects.

The plan (`plan_run`, pure, seeded): BURSTS bursts per class, each 8 to 120 events with gaps drawn from 0 to 33 ms
(flicks: most gaps are 0 to 4 ms, so events come as fast as the socket takes them):
  resize     `drag`: the window's bottom-right corner pressed and flicked along a seeded random walk (steps of 2 to
             160 points, AppKit's live resize through `debug.mouse`), back to where it started; `jump`: setFrame
             jumps (`debug.window_frame`) to seeded sizes, the last one the start size
  workspace  Ctrl+digit jumps, Ctrl-Cmd-] / [ steps and goToWorkspace actions in a seeded mix; the last event is
             always a jump, so the workspace that must show at the end is known
  tab        Ctrl-Tab / Ctrl-Shift-Tab steps and Cmd+digit jumps in the 1-pane workspace's tabs; the last event is a
             Cmd+digit jump
  mixed      workspace jumps, tab steps and window jumps interleaved; ends on a workspace jump and the start size
Every event is sent in order, one socket call each, at its planned time or as soon as the previous call returned.

The judge, per burst (`judge_burst`, pure; every rule is a number and every breach fails the run):
  frames     display intervals (`debug.frames` raw) from the first event to SETTLE_S after the last: p50, p95, p99,
             max, missed (an interval over 1.5 refresh periods) and long (over LONG_MS)
  blank      frames where a pane shows its ground because its content was not ready (`late`), is listed at alpha 0,
             or the window lists no pane at all; `flashes`: blank episodes (blank after not blank); with the recorder,
             `pixel_blank_frames`: frames in which a pane's sampled pixel rows are one flat colour although its final
             picture is not
  shift      a layout move of more than SHIFT_PX that the input did not cause:
             tab        any pane's frame or content size differs from rest (a tab switch moves no pane);
             workspace  a pane whose size differs from its workspace's rest layout, or the panes of one workspace
                        moving by different offsets (an animation moves a workspace as one rigid body), or a pane
                        id no workspace has;
             resize     a pane that moves while the window has held its size for 2 frames (`unprovoked`), two
                        frames at the same window size with different layouts (`hysteresis`), the rest layout
                        after the walk back to the start size not equal to the start's (`return`), and `lag`: frames
                        where the layout's edge does not follow the window's (the gap to the window edge differs
                        from rest), a breach when LAG_RUN or more in a row
  lost       the workspace (and tab) shown after the burst is not the one its last event asked for
Budgets (BUDGETS, --budget KEY=VALUE overrides): p95 <= 1.5 refresh, p99 <= 2.5 refresh, long 0, blank 0, flashes 0,
pixel blank 0, shift 0, lost 0, lag run < LAG_RUN. `--report-only` prints breaches and exits 0.

The seed is printed first (`POWER-USER-NATIVE seed=N`); `--seed N --only CLASS:INDEX` replays one burst. Each burst
prints one `POWER-USER-NATIVE burst` line; each class one `POWER-USER-NATIVE class` line; then `POWER-USER-NATIVE
BREACH ...` lines and `POWER-USER-NATIVE-VERDICT PASS|FAIL seed=N`.

Usage: power_user_native.py --app PATH [--seed N] [--classes resize,workspace,tab,mixed] [--bursts 6]
       [--only CLASS:INDEX] [--json PATH] [--out DIR] [--no-pixels] [--deadline 1500] [--budget KEY=VALUE]
       [--report-only] [--plan]   (--plan prints the plan and exits: no app)
Fleet: scripts/measure/split-spring.sh --arg=--suite=power-user (split-spring-terminal.py execs this script).
"""
from __future__ import annotations

import argparse
import http.server
import json
import math
import os
import random
import re
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci", "frame-pacing"))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
import pane_drag as pd  # noqa: E402

CLASSES = ("resize", "workspace", "tab", "mixed")
WORKSPACE_PANES = (1, 4, 2, 6)  # workspace 0 (1 pane) holds the tab-switch pane
TAB_PAGES = 4
SETTLE_S = 0.8
LONG_MS = 50.0
SHIFT_PX = 1.0
LAG_RUN = 3
GAPS_MS = (0, 0, 0, 1, 2, 2, 4, 4, 8, 16, 33)  # flicks: mostly back to back
WINDOW = (40, 40, 1600, 1000)
MIN_SIZE = (760, 520)
TRACE_TARGETS = ["panes", "late", "window", "dividers"]
BUDGETS = {
    "p95_refresh": 1.5,  # frame p95 at most 1.5 refresh periods
    "p99_refresh": 2.5,
    "long": 0,
    "blank_frames": 0,
    "flashes": 0,
    "pixel_blank_frames": 0,
    "shift_frames": 0,
    "lost": 0,
    "lag_run": LAG_RUN - 1,
    "reloads": 0,
}

# ---------------------------------------------------------------- the plan (pure)


def _gap(rng: random.Random) -> int:
    return rng.choice(GAPS_MS)


def _walk(rng: random.Random, steps: int, span: tuple) -> list:
    """A random walk of (dw, dh) offsets from the start size (shrink only, within `span`), with flicks: each step's
    length is drawn from 2 to 160 points; it ends with a straight run back to (0, 0)."""
    dw = dh = 0.0
    out = []
    for _ in range(steps):
        length = rng.choice((2, 4, 8, 16, 24, 40, 60, 90, 120, 160))
        angle = rng.uniform(0, 2 * math.pi)
        dw = max(-span[0], min(0.0, dw + length * math.cos(angle)))
        dh = max(-span[1], min(0.0, dh + length * math.sin(angle)))
        out.append((round(dw), round(dh)))
    back = max(2, int(max(abs(dw), abs(dh)) / 80))
    for k in range(1, back + 1):
        out.append((round(dw * (1 - k / back)), round(dh * (1 - k / back))))
    return out


def plan_burst(rng: random.Random, klass: str, index: int, workspaces: int, tabs: int, span: tuple) -> dict:
    events, at = [], 0
    digits_ws = list(range(workspaces))
    digits_tab = list(range(min(tabs, 8)))

    def add(event):
        nonlocal at
        at += _gap(rng)
        events.append({"at_ms": at, **event})

    if klass == "resize":
        mode = rng.choice(("drag", "drag", "jump"))
        if mode == "drag":
            for dw, dh in _walk(rng, rng.randint(20, 110), span):
                add({"kind": "drag", "dw": dw, "dh": dh})
        else:
            for _ in range(rng.randint(6, 24)):
                add({"kind": "frame", "dw": -rng.randint(0, span[0]), "dh": -rng.randint(0, span[1])})
            add({"kind": "frame", "dw": 0, "dh": 0})
        start_ws = rng.choice(digits_ws)
    elif klass == "workspace":
        mode = rng.choice(("digit", "step", "mixed"))
        for _ in range(rng.randint(8, 40)):
            how = mode if mode != "mixed" else rng.choice(("digit", "step", "action"))
            if how == "step":
                add({"kind": "ws", "how": "step", "dir": rng.choice((1, -1))})
            else:
                add({"kind": "ws", "how": how, "target": rng.choice(digits_ws)})
        add({"kind": "ws", "how": "digit", "target": rng.choice(digits_ws)})
        start_ws = rng.choice(digits_ws)
    elif klass == "tab":
        mode = rng.choice(("ctrl-tab", "number", "mixed"))
        for _ in range(rng.randint(8, 40)):
            how = mode if mode != "mixed" else rng.choice(("ctrl-tab", "number"))
            if how == "ctrl-tab":
                add({"kind": "tab", "how": "step", "dir": rng.choice((1, 1, -1))})
            else:
                add({"kind": "tab", "how": "number", "target": rng.choice(digits_tab)})
        add({"kind": "tab", "how": "number", "target": rng.choice(digits_tab)})
        start_ws = 0
    else:  # mixed
        mode = "mixed"
        for _ in range(rng.randint(12, 48)):
            pick = rng.random()
            if pick < 0.4:
                add({"kind": "ws", "how": "digit", "target": rng.choice(digits_ws)})
            elif pick < 0.7:
                add({"kind": "tab", "how": "step", "dir": rng.choice((1, -1))})
            else:
                add({"kind": "frame", "dw": -rng.randint(0, span[0]), "dh": -rng.randint(0, span[1])})
        add({"kind": "ws", "how": "digit", "target": rng.choice(digits_ws)})
        add({"kind": "frame", "dw": 0, "dh": 0})
        start_ws = rng.choice(digits_ws)
    return {"class": klass, "index": index, "mode": mode, "start_ws": start_ws, "events": events}


def plan_run(seed: int, classes=CLASSES, bursts: int = 6, workspaces: int = len(WORKSPACE_PANES),
             tabs: int = TAB_PAGES + 3, span: tuple = (WINDOW[2] - MIN_SIZE[0], WINDOW[3] - MIN_SIZE[1])) -> list:
    """Every burst of a run, from `seed` alone: the same seed is the same run. One stream per class, so narrowing
    --classes or --only replays the same bursts."""
    out = []
    for klass in classes:
        rng = random.Random(f"{seed}:{klass}")
        out.extend(plan_burst(rng, klass, i, workspaces, tabs, span) for i in range(bursts))
    return out


# ---------------------------------------------------------------- the judge (pure: tests feed it synthetic traces)


def pct(values: list, q: float):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * q)))], 3)


def frame_window(frames: dict, start_s: float, end_s: float) -> dict:
    """Display intervals of `debug.frames` raw whose frame lands in [start_s, end_s] (host seconds)."""
    intervals = frames.get("intervals_ms") or []
    first = frames.get("first_frame_s")
    refresh = float(frames.get("refresh_ms") or pd.REFRESH_120) or pd.REFRESH_120
    if not intervals or first is None:
        return {"measured": False, "refresh_ms": round(refresh, 3)}
    at, kept = float(first), []
    for interval in intervals:
        at += float(interval) / 1000
        if start_s <= at <= end_s:
            kept.append(float(interval))
    return {"measured": bool(kept), "refresh_ms": round(refresh, 3), "frames": len(kept), "intervals": kept,
            "p50_ms": pct(kept, 0.5), "p95_ms": pct(kept, 0.95), "p99_ms": pct(kept, 0.99),
            "max_ms": round(max(kept), 3) if kept else None,
            "missed": sum(1 for v in kept if v > 1.5 * refresh), "long": sum(1 for v in kept if v > LONG_MS)}


def pane_rows(sample: dict) -> dict:
    """{pane: (fx, fy, fw, fh, cw, ch, alpha)}: each listed pane's laid-out frame (the host's, uncut by the strip
    clip), its content size and alpha. Rows without the laid-out columns use the shown rect."""
    out = {}
    for row in sample.get("panes") or []:
        if len(row) < 6:
            continue
        if len(row) >= 13:
            fx, fy, fw, fh, cw, ch = (float(v) for v in row[7:13])
        else:
            fx, fy, fw, fh = (float(v) for v in row[1:5])
            cw, ch = fw, fh
        out[str(row[0])] = (fx, fy, fw, fh, cw, ch, float(row[5]))
    return out


def _differs(a: tuple, b: tuple, tol: float = SHIFT_PX, fields=range(6)) -> bool:
    return any(abs(a[i] - b[i]) > tol for i in fields)


def blank_judge(samples: list, expect_panes: bool = True) -> dict:
    """Blank frames (late ground, alpha 0, no pane listed) and flashes (blank episodes) over `samples`."""
    blank = flashes = 0
    was = False
    late_panes = set()
    for sample in samples:
        rows = pane_rows(sample)
        late = [str(r[0]) for r in sample.get("late") or [] if r]
        zero = [p for p, r in rows.items() if r[6] < 0.05]
        empty = expect_panes and not rows
        now = bool(late or zero or empty)
        late_panes.update(late)
        if now:
            blank += 1
            if not was:
                flashes += 1
        was = now
    return {"blank_frames": blank, "flashes": flashes, "late_panes": sorted(late_panes)[:8]}


def shift_tab(samples: list, rest: dict, contents: dict) -> dict:
    """A tab switch moves no pane: any pane frame off its rest frame, or a content size never seen at rest for it."""
    frames, where = 0, []
    for sample in samples:
        rows = pane_rows(sample)
        bad = []
        for pane, r in rows.items():
            ref = rest.get(pane)
            if ref is None:
                bad.append([pane, "unknown pane"])
            elif _differs(r, ref, fields=range(4)):
                bad.append([pane, "frame", [round(v, 1) for v in r[:4]], [round(v, 1) for v in ref[:4]]])
            elif not any(abs(r[4] - c[0]) <= SHIFT_PX and abs(r[5] - c[1]) <= SHIFT_PX for c in contents.get(pane, [ref[4:6]])):
                bad.append([pane, "content", [round(r[4], 1), round(r[5], 1)]])
        if bad:
            frames += 1
            if len(where) < 6:
                where.append({"t": sample.get("t"), "panes": bad[:3]})
    return {"shift_frames": frames, "shift_where": where}


def shift_workspace(samples: list, refs: dict) -> dict:
    """`refs`: {workspace: {pane: rest row}}. Each frame's panes, grouped by workspace, must keep their rest sizes
    and move together (one common offset per workspace: an animation moves a workspace as a rigid body)."""
    owner = {pane: ws for ws, panes in refs.items() for pane in panes}
    frames, where = 0, []
    for sample in samples:
        rows = pane_rows(sample)
        groups: dict = {}
        bad = []
        for pane, r in rows.items():
            ws = owner.get(pane)
            if ws is None:
                bad.append([pane, "unknown pane"])
                continue
            ref = refs[ws][pane]
            if _differs(r, ref, fields=(2, 3, 4, 5)):
                bad.append([pane, "size", [round(v, 1) for v in r[2:6]], [round(v, 1) for v in ref[2:6]]])
            groups.setdefault(ws, []).append((pane, r[0] - ref[0], r[1] - ref[1]))
        for ws, moved in groups.items():
            dxs, dys = [m[1] for m in moved], [m[2] for m in moved]
            if max(dxs) - min(dxs) > SHIFT_PX or max(dys) - min(dys) > SHIFT_PX:
                bad.append([ws, "not rigid", [round(v, 1) for v in dxs[:4]], [round(v, 1) for v in dys[:4]]])
        if bad:
            frames += 1
            if len(where) < 6:
                where.append({"t": sample.get("t"), "panes": bad[:3]})
    return {"shift_frames": frames, "shift_where": where}


def same_layout(rows: dict, ref: dict) -> bool:
    """`rows` (pane_rows) are exactly `ref`'s panes at their frames and content sizes, within SHIFT_PX."""
    return bool(ref) and set(rows) == set(ref) and not any(_differs(rows[p], ref[p]) for p in ref)


def settled_on(sample: dict, ref: dict) -> bool:
    """The rest sample shows exactly `ref`'s panes at their rest frames (offset 0)."""
    return same_layout(pane_rows(sample), ref)


def shift_resize(samples: list, start: dict, end: dict, start_sample: dict) -> dict:
    """The layout as a function of the window size: no pane moves while the window holds its size (2 frames), one
    window size gives one layout, the walk back to the start size gives the start layout, and the layout's edges
    follow the window's (lag: the gap from the panes' right and bottom edges to the window's differs from rest)."""
    sizes = [tuple(round(float(v), 1) for v in (s.get("window") or [0, 0])[:2]) for s in samples]
    rows = [pane_rows(s) for s in samples]
    unprovoked, hysteresis, seen, where = 0, 0, {}, []

    def extent(r: dict):
        if not r:
            return None
        return max(v[0] + v[2] for v in r.values()), max(v[1] + v[3] for v in r.values())

    win0 = (start_sample.get("window") or [0, 0])[:2]
    ext0 = extent(start)
    gap0 = (float(win0[0]) - ext0[0], float(win0[1]) - ext0[1]) if ext0 else None
    lag_frames, lag_run, run = 0, 0, 0
    for i in range(len(samples)):
        if i >= 2 and sizes[i] == sizes[i - 1] == sizes[i - 2]:
            moved = [p for p in rows[i] if p in rows[i - 1] and _differs(rows[i][p], rows[i - 1][p])]
            if moved or set(rows[i]) != set(rows[i - 1]):
                unprovoked += 1
                if len(where) < 6:
                    where.append({"t": samples[i].get("t"), "kind": "unprovoked", "panes": moved[:3]})
            ref = seen.get(sizes[i])
            if ref is None:
                seen[sizes[i]] = rows[i]
            elif set(ref) != set(rows[i]) or any(_differs(rows[i][p], ref[p]) for p in ref):
                hysteresis += 1
                if len(where) < 6:
                    where.append({"t": samples[i].get("t"), "kind": "hysteresis", "size": sizes[i]})
        ext = extent(rows[i])
        if gap0 and ext:
            lagging = abs(sizes[i][0] - ext[0] - gap0[0]) > SHIFT_PX or abs(sizes[i][1] - ext[1] - gap0[1]) > SHIFT_PX
            run = run + 1 if lagging else 0
            lag_frames += lagging
            lag_run = max(lag_run, run)
    returned = same_layout(end, start)
    return {"shift_frames": unprovoked + hysteresis + (0 if returned else 1), "unprovoked": unprovoked,
            "hysteresis": hysteresis, "returned": returned, "lag_frames": lag_frames, "lag_run": lag_run,
            "shift_where": where}


def pixel_blank(scan, samples: list, t0: float, after_s: float) -> dict:
    """Frames (host time > `after_s`) in which a listed pane's sampled pixel rows are one flat colour while the same
    pane is not flat in its last recorded frame (a pane that is flat at rest, an empty terminal, never counts)."""
    if not scan:
        return {"pixel_measured": False}
    head, frames, scale = scan
    if not frames or not samples:
        return {"pixel_measured": False}
    times = [t0 + float(s.get("t", 0)) / 1000 for s in samples]

    def rects_at(t):
        i = max((k for k, v in enumerate(times) if v <= t), default=0)
        return {p: (r[0], r[1], r[2], r[3]) for p, r in pane_rows(samples[i]).items()}

    def flat(blob, spans):
        first = None
        for a, b in spans:
            for k in range(a, b - 3, 4 * pd.PIXEL_STEP):
                px = blob[k:k + 3]
                if first is None:
                    first = px
                elif any(abs(px[c] - first[c]) > 3 for c in range(3)):
                    return False
        return first is not None

    last_t, last_blob = frames[-1]
    final = {p: flat(last_blob, pd._segments(head, r, scale)) for p, r in rects_at(last_t).items()}
    counted, panes = 0, set()
    ever_textured: set = {p for p, f in final.items() if not f}
    for t, blob in frames:
        for p, r in rects_at(t).items():
            spans = pd._segments(head, r, scale)
            if spans and not flat(blob, spans):
                ever_textured.add(p)
    for t, blob in frames:
        if t <= after_s:
            continue
        hit = [p for p, r in rects_at(t).items() if p in ever_textured and (s := pd._segments(head, r, scale)) and flat(blob, s)]
        if hit:
            counted += 1
            panes.update(hit)
    return {"pixel_measured": True, "pixel_blank_frames": counted, "pixel_blank_panes": sorted(panes)[:8],
            "pixel_frames": len(frames)}


def judge_burst(burst: dict, run: dict, refs: dict, contents: dict) -> dict:
    """One burst's numbers. `run`: trace (samples, t0_s), frames (debug.frames raw), first_s / last_s (host seconds
    of the first and last event sent), before / after (rest samples), expected / observed workspace and tab,
    reloads, scan. `refs`: {workspace: {pane: rest row}}; `contents`: {pane: [content sizes at rest]}."""
    trace = run.get("trace") or {}
    samples = [s for s in trace.get("samples") or [] if "panes" in s]
    t0 = trace.get("t0_s")
    out = {"class": burst["class"], "index": burst["index"], "mode": burst["mode"], "events": len(burst["events"]),
           "sent": run.get("sent"), "send_ms": run.get("send_ms"), "samples": len(samples)}
    first, last = run.get("first_s"), run.get("last_s")
    if first is None or last is None:
        out["error"] = run.get("error") or "no event sent"
        return out
    span_end = last + SETTLE_S
    fw = frame_window(run.get("frames") or {}, first, span_end)
    out.update({k: v for k, v in fw.items() if k != "intervals"})
    out["burst_ms"] = round((last - first) * 1000, 1)
    out["rate_hz"] = round(len(burst["events"]) / max(1e-3, last - first), 1)
    if t0 is None or len(samples) < 3:
        out["error"] = "no per-frame trace samples"
        return out
    inside = [s for s in samples if first - 0.02 <= float(t0) + float(s.get("t", 0)) / 1000 <= span_end]
    out.update(blank_judge(inside))
    before = pane_rows(run.get("before") or {})
    after = pane_rows(run.get("after") or {})
    klass = burst["class"]
    if klass == "tab":
        out.update(shift_tab(inside, before, contents))
    elif klass == "workspace":
        out.update(shift_workspace(inside, refs))
    elif klass == "resize":
        out.update(shift_resize(inside, before, after, run.get("before") or {}))
    else:  # mixed: the window size moves with the input; the rest after it must be the expected workspace's layout
        out["shift_frames"] = 0 if settled_on(run.get("after") or {}, refs.get(run.get("expected_ws"), {})) else 1
    lost = 0
    if run.get("expected_ws") is not None and run.get("observed_ws") != run.get("expected_ws"):
        lost += 1
    if run.get("expected_tab") is not None and run.get("observed_tab") != run.get("expected_tab"):
        lost += 1
    if klass == "workspace" and run.get("expected_ws") in refs and not settled_on(run.get("after") or {}, refs[run["expected_ws"]]):
        out["shift_frames"] = out.get("shift_frames", 0) + 1
        out.setdefault("shift_where", []).append({"kind": "rest after the burst is not the workspace's rest layout"})
    out.update({"lost": lost, "expected_ws": run.get("expected_ws"), "observed_ws": run.get("observed_ws"),
                "expected_tab": run.get("expected_tab"), "observed_tab": run.get("observed_tab"),
                "reloads": run.get("reloads", 0), "hangs": run.get("hangs")})
    if run.get("scan"):
        out.update(pixel_blank(run["scan"], inside, float(t0), first))
    return out


def breaches(result: dict, budgets: dict) -> list:
    """The budget rules one judged burst breaks, as strings."""
    if result.get("error"):
        return [f"not measured: {result['error']}"]
    refresh = float(result.get("refresh_ms") or pd.REFRESH_120)
    out = []
    for key, limit in (("p95_ms", budgets["p95_refresh"] * refresh), ("p99_ms", budgets["p99_refresh"] * refresh)):
        if result.get(key) is not None and result[key] > limit:
            out.append(f"{key} {result[key]:.1f} > {limit:.1f}")
    for key in ("long", "blank_frames", "flashes", "pixel_blank_frames", "shift_frames", "lost", "lag_run", "reloads"):
        value = result.get(key)
        if value is not None and value > budgets[key]:
            out.append(f"{key} {value} > {budgets[key]}")
    return out


def summarize(results: list) -> dict:
    """One class over its bursts: frame percentiles over every interval, the counts summed."""
    good = [r for r in results if not r.get("error")]
    def total(key):
        values = [r[key] for r in good if r.get(key) is not None]
        return sum(values) if values else None
    return {"bursts": len(results), "measured": len(good), "events": sum(r.get("events", 0) for r in results),
            "rate_hz_p50": pct([r["rate_hz"] for r in good if r.get("rate_hz")], 0.5),
            "p50_ms": pct([r["p50_ms"] for r in good if r.get("p50_ms") is not None], 0.5),
            "p95_ms_worst": max([r["p95_ms"] for r in good if r.get("p95_ms") is not None], default=None),
            "p99_ms_worst": max([r["p99_ms"] for r in good if r.get("p99_ms") is not None], default=None),
            "max_ms": max([r["max_ms"] for r in good if r.get("max_ms") is not None], default=None),
            "frames": total("frames"), "missed": total("missed"), "long": total("long"),
            "blank_frames": total("blank_frames"), "flashes": total("flashes"),
            "pixel_blank_frames": total("pixel_blank_frames"), "shift_frames": total("shift_frames"),
            "lag_frames": total("lag_frames"), "lost": total("lost"), "reloads": total("reloads")}


# The perf cron's rows (perf-cron.py's budgets kind reads report.json `rows`; part `power-user-native`). One family a
# class: frame p95 and p99 (worst burst; budget BUDGETS' refresh multiple at the run's refresh), and each count rule
# summed over the class's bursts (budget 0, or BUDGETS' value). A burst the run could not measure (the app hung or
# died, a socket call failed, the deadline) counts in `not_measured` (budget 0): a hang is a row, not a silence.
COUNT_ROWS = ("missed", "long", "blank_frames", "flashes", "pixel_blank_frames", "shift_frames", "lost", "reloads")


def cron_rows(report: dict) -> list:
    """report.json `rows` for the perf cron, from a finished (or cut) run's bursts."""
    rows = []
    budgets = report.get("budgets") or BUDGETS
    bursts = report.get("bursts") or []
    for klass in CLASSES:
        mine = [b for b in bursts if b.get("class") == klass]
        if not mine:
            continue
        good = [b for b in mine if not b.get("error")]
        prefix = f"power_user.native.{klass}"
        refresh = max([float(b["refresh_ms"]) for b in good if b.get("refresh_ms")], default=pd.REFRESH_120)
        for key, mult in (("p95_ms", budgets["p95_refresh"]), ("p99_ms", budgets["p99_refresh"])):
            values = [b[key] for b in good if b.get(key) is not None]
            if values:
                rows.append({"name": f"{prefix}.{key[:3]}", "p50": pct(values, 0.5), "p95": max(values), "unit": "ms",
                             "budget": round(mult * refresh, 2), "floor": 1.0})
        for key in COUNT_ROWS:
            values = [b[key] for b in good if b.get(key) is not None]
            if values:
                total = sum(values)
                rows.append({"name": f"{prefix}.{key}", "p50": total, "p95": total, "unit": "frames" if
                             key.endswith("frames") or key in ("missed", "long") else "count",
                             "budget": budgets.get(key, 0) if key not in ("missed",) else None, "floor": 0.5})
        lag = [b["lag_run"] for b in good if b.get("lag_run") is not None]
        if lag:
            rows.append({"name": f"{prefix}.lag_run", "p50": pct(lag, 0.5), "p95": max(lag), "unit": "frames",
                         "budget": budgets["lag_run"], "floor": 0.5})
        missing = len(mine) - len(good)
        rows.append({"name": f"{prefix}.not_measured", "p50": missing, "p95": missing, "unit": "bursts", "budget": 0,
                     "floor": 0.5})
    return rows


def incomplete(report: dict) -> list:
    """The run's coverage gaps, perf-cron.py's `incomplete` (the rows are kept; the tip is not a new last good)."""
    out = []
    if report.get("error"):
        out.append({"name": "power_user.native", "reason": str(report["error"])[:300]})
    elif not report.get("bursts"):
        out.append({"name": "power_user.native", "reason": "no burst ran"})
    cut = [b for b in report.get("bursts") or [] if b.get("error")]
    if cut:
        out.append({"name": "power_user.native", "reason": f"{len(cut)} bursts not measured: {cut[0]['error']}"[:300]})
    return out


# ---------------------------------------------------------------- the fixture (reloads are counted on it)


class Fixture:
    """Local pages for the Chromium tabs, served no-store, every GET logged: a load after set-up is a reload."""

    def __init__(self):
        hits = self.hits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                hits.append((self.path, time.monotonic()))
                index = re.sub(r"\D", "", self.path) or "0"
                hue = int(index) * 67 % 360
                body = (f"<!doctype html><title>pu{index}</title><body style='margin:0;background:hsl({hue},55%,42%);"
                        f"color:#fff;font:22px -apple-system'>" + "".join(f"<p>page {index} line {i} " + "lorem ipsum " * 6 + "</p>"
                                                                       for i in range(60))).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def url(self, index: int) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}/p/{index}"

    def count(self, since: float, until: float) -> int:
        return sum(1 for path, t in self.hits if path.startswith("/p/") and since <= t <= until)

    def close(self):
        self.server.shutdown()


# ---------------------------------------------------------------- the driver (a live app)


class Native(pd.Driver):
    """pane_drag's Driver with keys, window frames and the state reads the bursts need."""

    def key(self, key: str, modifiers: list) -> dict:
        return self.rpc("debug.key", {"key": key, "modifiers": modifiers}, timeout=5)

    def layers_frame(self):
        windows = (self.rpc("debug.layers") or {}).get("windows") or []
        return (windows[0].get("frame") if windows else None) or None

    def set_frame(self, frame) -> dict:
        return self.rpc("debug.window_frame", {"frame": [round(v, 1) for v in frame]}, timeout=5)

    def shown_ws(self):
        return (((self.rpc("snapshot.get") or {}).get("topology") or {}).get("focus") or {}).get("workspace")

    def selected_tab(self):
        panes = [p for w in (self.rpc("debug.surfaces") or {}).get("windows") or [] for p in w.get("panes") or []]
        focused = next((p for p in panes if p.get("focused")), None) or {}
        return focused.get("selected_tab")

    def go(self, ws_id) -> None:
        self.action("goToWorkspace", {"workspace": ws_id})


def run_bursts(opts) -> int:
    from bench_launch import BenchApp, LaunchError  # noqa: E402  (macOS only)

    budgets = dict(BUDGETS)
    for item in opts.budget:
        key, _, value = item.partition("=")
        if key not in budgets:
            raise SystemExit(f"unknown budget {key}; known: {', '.join(budgets)}")
        budgets[key] = float(value)
    classes = [c for c in opts.classes.split(",") if c]
    plan = plan_run(opts.seed, classes, opts.bursts)
    if opts.only:
        klass, _, index = opts.only.partition(":")
        plan = [b for b in plan if b["class"] == klass and (index == "" or b["index"] == int(index))]
    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="power-user-native-"))
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="power-user-native-files-")
    replay = f"--seed {opts.seed} --classes {opts.classes} --bursts {opts.bursts}"
    report: dict = {"tool": "scripts/perf-bench/power_user_native.py", "seed": opts.seed, "replay": replay,
                    "budgets": budgets, "bursts": [], "classes": {}, "breaches": []}

    def write():
        report["rows"] = cron_rows(report)
        gaps = incomplete(report)
        if gaps:
            report["incomplete"] = gaps
        else:
            report.pop("incomplete", None)
        if opts.json:
            with open(opts.json + ".tmp", "w") as handle:
                json.dump(report, handle, indent=1)
            os.replace(opts.json + ".tmp", opts.json)

    fixture = Fixture()
    app = BenchApp(opts.app, out=out, window=WINDOW, screen="last")
    try:
        try:
            app.launch(timeout=180)
        except LaunchError as error:
            report["error"] = f"launch: {error}"
            print(f"POWER-USER-NATIVE-VERDICT FAIL seed={opts.seed} launch: {error}", flush=True)
            write()
            return 1
        d = Native(app, out, pixels=not opts.no_pixels, deadline=time.monotonic() + opts.deadline)
        time.sleep(3)  # bench: launch work settles
        d.learn_scale()
        report["pixels"], report["scale"] = bool(d.pixels), d.scale
        frame0 = d.layers_frame()
        report["window"] = frame0

        # -- set-up (untimed): the workspaces, the tab pane, rest layouts, the digit maps
        workspaces = []
        for count in WORKSPACE_PANES:
            built = d.build(count, scratch)
            ws = d.workspace or d.shown_ws()
            workspaces.append(ws)
            print(f"POWER-USER-NATIVE setup ws={ws} panes={built.get('panes')} kinds={built.get('kinds')} "
                  f"error={built.get('error')}", flush=True)
        d.go(workspaces[0])
        time.sleep(1.0)  # bench: the switch lands
        d.action("terminal.sendText", {"text": "seq 1 4000\r"})
        for i in range(TAB_PAGES):
            d.action("openBrowser.chromium", {"url": fixture.url(i)}, timeout=120)
            time.sleep(0.8)  # bench: the page loads before the next
        md = os.path.join(scratch, "tabs.md")
        with open(md, "w") as handle:
            handle.write("# Tabs\n\n" + "\n".join(f"- row {i} with `code` and **bold**" for i in range(120)) + "\n")
        d.action("openMarkdownFile", {"path": md})
        d.action("newTab.page")
        time.sleep(3.0)  # bench: pages settle
        refs = {}
        for ws in workspaces:
            d.go(ws)
            time.sleep(1.2)  # bench: the switch rests
            refs[ws] = {p: r for p, r in pane_rows(d.rest()).items()}
        # Which workspace each Ctrl+digit shows, in sidebar order (the app's own first workspace may be digit 1).
        digit_ws = {}
        for digit in range(1, 10):
            d.key(str(digit), ["control"])
            time.sleep(0.5)  # bench: the switch lands
            ws = d.shown_ws()
            if ws in workspaces and ws not in digit_ws.values():
                digit_ws[digit] = ws
        ws_digit = {ws: k for k, ws in digit_ws.items()}
        d.go(workspaces[0])
        time.sleep(0.8)
        pane0 = next(iter(refs.get(workspaces[0]) or {}), None)
        if pane0:
            d.click(refs[workspaces[0]][pane0][:4])
        tab_digit, contents = {}, {}
        for digit in range(1, 9):
            d.key(str(digit), ["command"])
            time.sleep(0.6)  # bench: the tab shows
            tab_digit[digit] = d.selected_tab()
            for p, r in pane_rows(d.rest()).items():
                contents.setdefault(p, [])
                if (r[4], r[5]) not in contents[p]:
                    contents[p].append((r[4], r[5]))
        report["setup"] = {"workspaces": workspaces, "digit_ws": digit_ws, "tab_digit": tab_digit,
                           "panes": {ws: len(r) for ws, r in refs.items()}, "log": d.log[-10:]}
        print("POWER-USER-NATIVE setup " + json.dumps(report["setup"])[:1500], flush=True)
        write()
        setup_done = time.monotonic()

        # -- the bursts
        for burst in plan:
            if d.left() < 60 or d.dead:
                report["bursts"].append({"class": burst["class"], "index": burst["index"], "error": "run deadline"})
                break
            result = one_burst(d, burst, workspaces, ws_digit, digit_ws, tab_digit, refs, contents, frame0, fixture,
                               setup_done)
            report["bursts"].append(result)
            broke = breaches(result, budgets)
            result["breaches"] = broke
            print("POWER-USER-NATIVE burst " + json.dumps({k: result.get(k) for k in (
                "class", "index", "mode", "events", "rate_hz", "burst_ms", "frames", "p50_ms", "p95_ms", "p99_ms",
                "max_ms", "missed", "long", "blank_frames", "flashes", "pixel_blank_frames", "shift_frames",
                "lag_run", "lost", "reloads", "error")}) + (f" BREACH {broke}" if broke else ""), flush=True)
            for b in broke:
                report["breaches"].append({"class": burst["class"], "index": burst["index"], "breach": b,
                                           "replay": f"{replay} --only {burst['class']}:{burst['index']}"})
            write()
        for klass in classes:
            summary = summarize([r for r in report["bursts"] if r.get("class") == klass])
            report["classes"][klass] = summary
            print(f"POWER-USER-NATIVE class {klass} " + json.dumps(summary), flush=True)
        report["log"] = d.log[-40:]
    finally:
        write()
        app.stop()
        fixture.close()
    for b in report["breaches"]:
        print(f"POWER-USER-NATIVE BREACH seed={opts.seed} {b['class']}:{b['index']} {b['breach']} "
              f"(replay: {b['replay']})", flush=True)
    failed = bool(report["breaches"]) or not report["bursts"]
    print(f"POWER-USER-NATIVE-VERDICT {'FAIL' if failed else 'PASS'} seed={opts.seed} bursts={len(report['bursts'])} "
          f"breaches={len(report['breaches'])}" + (" (report only)" if opts.report_only else ""), flush=True)
    write()
    return 0 if (opts.report_only or not failed) else 1


def one_burst(d: Native, burst: dict, workspaces, ws_digit, digit_ws, tab_digit, refs, contents, frame0, fixture,
              setup_done) -> dict:
    name = f"{burst['class']}-{burst['index']}"
    start_ws = workspaces[burst["start_ws"] % len(workspaces)]
    if frame0:
        d.set_frame(frame0)
    d.go(start_ws)
    time.sleep(0.8)  # bench: the start workspace rests
    if burst["class"] in ("tab", "mixed") and refs.get(start_ws):
        d.click(next(iter(refs[start_ws].values()))[:4])
        time.sleep(0.2)
    before = d.rest()
    frame = d.layers_frame() or frame0
    record = None
    if d.pixels and d.scale:
        height = float((before.get("window") or [0, WINDOW[3]])[1])
        rows = [int(y * d.scale) for y in range(int(pd.ROW_STEP_PT / 2), int(height), pd.ROW_STEP_PT)]
        record = os.path.join(d.out, f"{name}.mov")
        reply = d.rpc("debug.motion", {"action": "record_start", "path": record, "seconds": 30, "rows": rows, "filter": "display"})
        if "error" in reply or not d.wait(lambda: (d.rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 5):
            d.rpc("debug.motion", {"action": "record_stop"})
            record = None
    d.rpc("debug.hangs", {"clear": True})
    d.rpc("debug.frames", {"action": "start"})
    d.rpc("debug.motion", {"action": "trace_start", "targets": TRACE_TARGETS})
    time.sleep(0.2)  # bench: frames at rest before the first event
    run: dict = {"before": before}
    sent, send_ms = 0, []
    mono0 = time.monotonic()
    first_s = last_s = None
    dragging = False
    w0, h0 = (frame[2], frame[3]) if frame else (WINDOW[2], WINDOW[3])
    corner = (w0 - 1, h0 - 1)
    expected_ws = expected_tab = None
    try:
        for event in burst["events"]:
            wait = mono0 + event["at_ms"] / 1000 - time.monotonic()
            if wait > 0:
                time.sleep(wait)  # bench: the plan's gap (most are 0: as fast as the socket takes them)
            t = pd.now_s()
            first_s = first_s if first_s is not None else t
            kind = event["kind"]
            if kind == "drag":
                if not dragging:
                    d.rpc("debug.mouse", {"action": "down", "x": corner[0], "y": corner[1]}, timeout=5)
                    dragging = True
                x, y = corner[0] + event["dw"], corner[1] + event["dh"]
                d.rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                      "press": False, "release": False}, timeout=5)
            elif kind == "frame" and frame:
                nw, nh = w0 + event["dw"], h0 + event["dh"]
                d.set_frame([frame[0], frame[1] + frame[3] - nh, nw, nh])  # the top-left corner stays
            elif kind == "ws":
                if event["how"] == "step":
                    d.key("]" if event["dir"] > 0 else "[", ["control", "command"])
                    expected_ws = None
                elif event["how"] == "action":
                    target = workspaces[event["target"] % len(workspaces)]
                    d.go(target)
                    expected_ws = target
                else:
                    target = workspaces[event["target"] % len(workspaces)]
                    digit = ws_digit.get(target)
                    if digit is None:
                        d.go(target)
                    else:
                        d.key(str(digit), ["control"])
                    expected_ws = target
            elif kind == "tab":
                if event["how"] == "step":
                    d.key("tab", ["control", "shift"] if event["dir"] < 0 else ["control"])
                    expected_tab = None
                else:
                    digit = event["target"] + 1
                    d.key(str(digit), ["command"])
                    expected_tab = tab_digit.get(digit)
            sent += 1
            last_s = pd.now_s()
            send_ms.append((last_s - t) * 1000)
    finally:
        if dragging:
            d.rpc("debug.mouse", {"action": "up", "x": corner[0], "y": corner[1]}, timeout=5)
            last_s = pd.now_s()
    mono_end = time.monotonic()
    time.sleep(SETTLE_S + 0.4)  # bench: the last event's motion and its rest
    trace_path = os.path.join(d.out, f"{name}.trace.json")
    d.rpc("debug.motion", {"action": "trace_stop", "path": trace_path})
    run["frames"] = d.rpc("debug.frames", {"action": "stop", "raw": True})
    hangs = d.rpc("debug.hangs", {"limit": 8})
    run["hangs"] = len(hangs.get("hangs") or []) if isinstance(hangs, dict) else None
    if record:
        d.rpc("debug.motion", {"action": "record_stop"})
    run["trace"] = d.wait(lambda: pd._load(trace_path), 20) or {}
    if record:
        state = d.wait(lambda: (lambda s: s if s.get("written") else None)(d.rpc("debug.motion", {"action": "record_read"}) or {}), 20) or {}
        try:
            if state.get("complete") and not state.get("scan_dropped"):
                head, scan = pd.read_scan(record + ".scan")
                run["scan"] = (head, scan, d.scale)
        except (OSError, ValueError, KeyError):
            pass
        d._remove(record)
    run["after"] = d.rest()
    if burst["class"] in ("workspace", "mixed"):
        run["expected_ws"], run["observed_ws"] = expected_ws, d.shown_ws()
    if burst["class"] == "tab":
        run["expected_tab"], run["observed_tab"] = expected_tab, d.selected_tab()
    run["reloads"] = fixture.count(max(setup_done, mono0), mono_end + SETTLE_S + 0.4)
    run.update({"first_s": first_s, "last_s": last_s, "sent": sent,
                "send_ms": {"p50": pct(send_ms, 0.5), "p95": pct(send_ms, 0.95), "max": round(max(send_ms), 2) if send_ms else None}})
    result = judge_burst(burst, run, refs, contents)
    if frame0:
        d.set_frame(frame0)
    try:
        os.unlink(trace_path)
    except OSError:
        pass
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app")
    parser.add_argument("--tag", help="accepted for the split-spring dispatcher; the app's own tag is used")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--classes", default=",".join(CLASSES))
    parser.add_argument("--bursts", type=int, default=6)
    parser.add_argument("--only", default="", help="CLASS:INDEX (or CLASS) of the plan: replay one burst")
    parser.add_argument("--json")
    parser.add_argument("--out")
    parser.add_argument("--no-pixels", action="store_true")
    parser.add_argument("--deadline", type=float, default=1500)
    parser.add_argument("--budget", action="append", default=[], help="KEY=VALUE over BUDGETS")
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--plan", action="store_true", help="print the plan and exit")
    opts, _unknown = parser.parse_known_args(argv)
    if opts.seed is None:
        opts.seed = random.SystemRandom().randrange(1, 2**31)
    print(f"POWER-USER-NATIVE seed={opts.seed} classes={opts.classes} bursts={opts.bursts}"
          + (f" only={opts.only}" if opts.only else ""), flush=True)
    if opts.plan:
        print(json.dumps(plan_run(opts.seed, [c for c in opts.classes.split(",") if c], opts.bursts), indent=1))
        return 0
    if not opts.app:
        parser.error("--app is required (or --plan)")
    return run_bursts(opts)


if __name__ == "__main__":
    sys.exit(main())
