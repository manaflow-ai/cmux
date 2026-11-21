#!/usr/bin/env python3
"""Tab drags and pane-header drags through the real mouse path, at 2, 8 and 30 panes of mixed kinds (RFD 0022
work item 1, cmuxterm-hq docs/rfd/0022-panes-windows-resize.md).

Leo, 2026-11-21: "we need to be able to do our shit at least as good as them on speed and reliability" and "i meant
the windows andresizing anddragging panes around".

Launches a tagged Debug (or bench) app with ``bench_launch.BenchApp``. For each count in --counts it makes a workspace,
splits it into that many panes (the largest pane splits along its longer side; `newColumn` when a split is refused),
and gives the panes mixed kinds in turn: terminal, Chromium page (a local file), New Tab page (the chat surface) and
Markdown file viewer. Each non-terminal pane holds its terminal and its content tab, so every such pane has a tab to
drag. Then, per count, two gestures, each --drops times:

- `tab`: a content tab dragged (`debug.mouse` down, one drag event per 120 Hz frame, up: the AppKit path a hand takes,
  TabDragSession) to another pane's bottom edge (a split), then the moved tab dragged back to its pane's center (a
  join), and again from a pane of another kind;
- `pane`: a pane's header pressed on empty strip space with Option and dragged onto another pane (PaneSwapDrag: today a
  swap), then back.

Around each drop: `debug.motion` `trace_*` (every display frame: pane rects, alpha, `late` = panes showing their ground
because their content was not ready when the layout change showed; `tabs`), `debug.frames` raw (display intervals and
main-thread busy ms per frame), `debug.journal` (the mouse-up's event time) and, when the app's recorder runs,
`debug.motion` `record_*` pixel rows (ScreenCaptureKit, every composited frame). The judge (`judge_drop`) reports:

- `lift_ms`: first drag event to the first frame the tab strip changes (tab drag only; a pane drag lifts nothing today);
- `drop_ms`: input to move: the mouse-up's event time (the input journal's, when the app dispatched it) to the first
  display frame whose pane layout differs; `drop_ms_send` from when the script sent it (the queue's wait included);
- `main_over_8_33` / `missed`: frames whose main-thread work went over 8.33 ms, and display intervals over 1.5 refresh
  periods, while dragging and from the drop to rest (`drag_` and `drop_` prefixes);
- `blank_frames`: frames from the commit on in which some pane shows its late ground, is listed with alpha 0, or a
  pane of the final layout is not listed yet (a pop-in); the app's own signal, exact per frame;
- `pixel_late_frames`: frames after the layout rests in which a pane's pixel rows still differ from their final
  picture on more than a third of the sampled pixels (only pixels can tell a page that has not painted); and
  `pixel_noise_frames`, the same test on the frames at rest before the press, which bounds what live content adds;
- `jumps`: a pane whose rect changes again after it rested (unchanged for `REST_FRAMES` frames) since the commit.

Report only: no threshold fails the run (exit 0 unless the app never came up). Out: --json (the report), and per drop
the trace file in --out.

The "theirs" column (Claude Code desktop) is not driven: see `theirs()`.

Usage: pane_drag.py --app PATH [--counts 2,8,30] [--drops 4] [--json PATH] [--out DIR] [--no-pixels] [--deadline 1500]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "cmux-next"))

KINDS = ("terminal", "chromium", "chat", "markdown")
REFRESH_120 = 1000 / 120
BUDGET_MS = 1000 / 120  # 8.33 ms: one 120 Hz frame
REST_FRAMES = 4  # a pane unchanged this many frames has rested
PIXEL_DIFF = 1 / 3  # a pane's sampled pixels differing from their final picture on more than this share: not painted
PIXEL_STEP = 4  # every 4th device pixel of a kept row is compared
ROW_STEP_PT = 48  # a kept pixel row every 48 points down the window
TRACE_TARGETS = ["panes", "late", "tabs", "window"]


def now_s() -> float:
    """Host seconds on CACurrentMediaTime's clock (mach_absolute_time, CLOCK_UPTIME_RAW): the trace's `t0_s` clock."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


# ---------------------------------------------------------------- the judge (pure: tests feed it synthetic traces)


def pane_map(sample: dict) -> dict:
    """{pane id: (x, y, w, h, alpha)} of one trace sample's `panes` rows."""
    out = {}
    for row in sample.get("panes") or []:
        if len(row) >= 6:
            out[str(row[0])] = tuple(float(v) for v in row[1:6])
    return out


def _moved(a: tuple | None, b: tuple | None, tol: float = 0.5) -> bool:
    if a is None or b is None:
        return a is not b
    return any(abs(p - q) > tol for p, q in zip(a[:4], b[:4]))


def _layout_differs(a: dict, b: dict) -> bool:
    return set(a) != set(b) or any(_moved(a[k], b[k]) for k in a)


def _tabs_key(sample: dict) -> tuple:
    return tuple(tuple(round(float(v), 1) if isinstance(v, (int, float)) else v for v in row) for row in sample.get("tabs") or [])


def _percentile(values: list, q: float):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * q))]


def frame_phases(frames: dict, press_s: float, up_s: float) -> dict:
    """`debug.frames` raw (`intervals_ms`, `main_ms`, `first_frame_s`, `refresh_ms`) split into the drag (press to up)
    and the drop (up on): main-thread frames over 8.33 ms, missed vsyncs (an interval over 1.5 refresh periods), worst
    main ms. Empty when the reply has no raw arrays."""
    intervals, busy = frames.get("intervals_ms") or [], frames.get("main_ms") or []
    first = frames.get("first_frame_s")
    if not intervals or first is None:
        return {}
    refresh = float(frames.get("refresh_ms") or REFRESH_120)
    out = {f"{phase}_{key}": 0 for phase in ("drag", "drop") for key in ("main_over_8_33", "missed", "frames")}
    out.update({"drag_main_max_ms": 0.0, "drop_main_max_ms": 0.0, "refresh_ms": round(refresh, 3)})
    at = float(first)
    for index, interval in enumerate(intervals):
        at += float(interval) / 1000
        if at < press_s:
            continue
        phase = "drag" if at < up_s else "drop"
        out[f"{phase}_frames"] += 1
        if float(interval) > 1.5 * refresh:
            out[f"{phase}_missed"] += 1
        work = float(busy[index]) if index < len(busy) else 0.0
        out[f"{phase}_main_max_ms"] = round(max(out[f"{phase}_main_max_ms"], work), 2)
        if work > BUDGET_MS:
            out[f"{phase}_main_over_8_33"] += 1
    return out


def read_scan(path: str):
    """(header, [(host seconds, bytes of the kept rows)]) of a `record_*` PATH.scan: complete frames only."""
    with open(path, "rb") as handle:
        data = handle.read()
    nl = data.index(b"\n")
    head = json.loads(data[:nl])
    size = 8 + 4 * (len(head["rows"]) * head["width"] + len(head.get("columns") or []) * head["height"])
    frames, off = [], nl + 1
    while off + size <= len(data):
        frames.append((struct.unpack_from("<d", data, off)[0], data[off + 8:off + size]))
        off += size
    return head, frames


def _segments(head: dict, rect: tuple, scale: float, inset: float = 6.0) -> list:
    """Byte spans of `rect`'s (window points, top-left) kept pixel rows, inset `inset` points."""
    x, y, w, h = rect[:4]
    width = int(head["width"])
    x0, x1 = int((x + inset) * scale), int((x + w - inset) * scale)
    y0, y1 = (y + inset) * scale, (y + h - inset) * scale
    x0, x1 = max(0, x0), min(width, x1)
    if x1 - x0 < 8:
        return []
    return [(4 * (i * width + x0), 4 * (i * width + x1)) for i, row in enumerate(head["rows"]) if y0 <= row < y1]


def _differs(blob: bytes, final: bytes, spans: list) -> bool:
    """Whether more than PIXEL_DIFF of the sampled pixels of `spans` differ between two frames."""
    total = changed = 0
    stride = 4 * PIXEL_STEP
    for start, end in spans:
        a, b = blob[start:end], final[start:end]
        if a == b:
            total += (end - start) // stride
            continue
        for k in range(0, end - start - 3, stride):
            total += 1
            if a[k:k + 3] != b[k:k + 3]:
                changed += 1
    return total > 0 and changed / total > PIXEL_DIFF


def pixel_late(head: dict, frames: list, scale: float, rects: dict, after_s: float, rest_rects: dict,
               before_s: float) -> dict:
    """Frames (host time > `after_s`) in which a pane of `rects` still differs from its last recorded picture, and the
    noise: frames at rest before `before_s` in which a pane of `rest_rects` differs from the last frame before it."""
    if not frames:
        return {"pixel_measured": False}
    final = frames[-1][1]
    spans = {pane: _segments(head, rect, scale) for pane, rect in rects.items()}
    late, late_panes = 0, set()
    for t, blob in frames:
        if t <= after_s:
            continue
        hit = [pane for pane, s in spans.items() if s and _differs(blob, final, s)]
        if hit:
            late += 1
            late_panes.update(hit)
    before = [(t, blob) for t, blob in frames if t < before_s]
    noise = 0
    if len(before) >= 2:
        ref = before[-1][1]
        rest_spans = [s for s in (_segments(head, rect, scale) for rect in rest_rects.values()) if s]
        noise = sum(1 for _, blob in before[:-1] if any(_differs(blob, ref, s) for s in rest_spans))
    return {"pixel_measured": True, "pixel_late_frames": late, "pixel_late_panes": sorted(late_panes),
            "pixel_noise_frames": noise, "pixel_rest_frames": max(0, len(before) - 1),
            "pixel_frames": len(frames)}


def judge_drop(drop: dict) -> dict:
    """One drop's numbers from its trace (`samples`, `t0_s`, `refresh_ms`), its input times (`press_s`,
    `first_move_s`, `up_s`, host seconds), `frames` (debug.frames raw) and optional `scan` ((head, frames, scale))."""
    trace = drop.get("trace") or {}
    samples = [s for s in trace.get("samples") or [] if "panes" in s]
    t0 = trace.get("t0_s")
    if len(samples) < 3 or t0 is None:
        return {"gesture": drop.get("gesture"), "kind": drop.get("kind"), "drop": drop.get("what"), "landed": False,
                "error": drop.get("error") or "no per-frame samples"}
    refresh = float(trace.get("refresh_ms") or REFRESH_120) or REFRESH_120
    at = [float(t0) + float(s.get("t", 0)) / 1000 for s in samples]
    maps = [pane_map(s) for s in samples]
    press, first_move, up = float(drop["press_s"]), float(drop.get("first_move_s") or drop["press_s"]), float(drop["up_s"])
    pre = max((i for i, t in enumerate(at) if t < press), default=0)
    # A sample's `t` is its display link's vsync time, not when its tick ran: a tick the drop's main-thread work held
    # can carry a vsync time before the up and already show the drop. So the layout before the drop is the last
    # sample a whole refresh before the up, and the commit is the first later sample that differs from it.
    before_up = max((i for i, t in enumerate(at) if t + refresh / 1000 < up), default=pre)
    result: dict = {"gesture": drop.get("gesture"), "kind": drop.get("kind"), "drop": drop.get("what"),
                    "panes_before": len(maps[pre]), "refresh_ms": round(refresh, 3)}

    # Lift: the first frame after the first drag event whose tab strip cells differ from rest (tab drag only).
    if drop.get("gesture") == "tab":
        rest_tabs = _tabs_key(samples[pre])
        lifted = next((i for i in range(pre + 1, len(samples)) if at[i] >= first_move and _tabs_key(samples[i]) != rest_tabs), None)
        result["lift_ms"] = round((at[lifted] - first_move) * 1000, 2) if lifted is not None and at[lifted] < up + 0.5 else None

    # The commit: the first frame after that whose layout differs; it shows at the next vsync (`at + refresh`). A pane
    # swap keeps every layout pane's rect and moves the tabs between them: its commit is the strips' change.
    swap = drop.get("gesture") == "pane"
    def changed(i: int, j: int) -> bool:
        return _layout_differs(maps[i], maps[j]) or (swap and _tabs_key(samples[i]) != _tabs_key(samples[j]))
    commit = next((i for i in range(before_up + 1, len(samples)) if changed(i, before_up)), None)
    if commit is None:
        result.update({"landed": False, "note": "no layout change after the drop"})
        result.update(frame_phases(drop.get("frames") or {}, press, up))
        return result
    result["landed"] = True
    shown = at[commit] + refresh / 1000
    result["drop_ms"] = round(max(0.0, shown - up) * 1000, 2)
    result["drop_frames"] = round(max(0.0, shown - up) * 1000 / refresh, 2)
    if drop.get("up_send_s"):
        # From the moment the script sent the up (before the app's queue): an upper bound on the event's own age.
        result["drop_ms_send"] = round(max(0.0, shown - float(drop["up_send_s"])) * 1000, 2)
    final = maps[-1]
    result["panes_after"] = len(final)
    last_change = max((i for i in range(commit, len(samples)) if i == commit or changed(i, i - 1)), default=commit)
    result["settle_ms"] = round((at[last_change] - up) * 1000, 1)

    # Blank: late ground, alpha 0, or a final pane not listed yet, in any frame from the commit on.
    blank, late_pane_frames, popin = 0, 0, 0
    for i in range(commit, len(samples)):
        late = [str(row[0]) for row in samples[i].get("late") or [] if row]
        zero = [p for p, r in maps[i].items() if p in final and r[4] < 0.05]
        missing = [p for p in final if p not in maps[i]]
        late_pane_frames += len(set(late) | set(zero) | set(missing))
        popin += len(missing)
        if late or zero or missing:
            blank += 1
    result.update({"blank_frames": blank, "late_pane_frames": late_pane_frames, "popin_pane_frames": popin})

    # Layout jumps: a pane that moves again after it rested REST_FRAMES frames, from the commit on.
    jumps, jumped = 0, []
    for pane in final:
        still, rested = 0, False
        for i in range(commit + 1, len(samples)):
            if maps[i].get(pane) is None or maps[i - 1].get(pane) is None:
                still, rested = 0, False  # missing (a pop-in, counted above): not at rest, and its arrival no jump
                continue
            if _moved(maps[i].get(pane), maps[i - 1].get(pane)):
                if rested:
                    jumps += 1
                    jumped.append([pane, round((at[i] - up) * 1000, 1)])
                    rested = False
                still = 0
            else:
                still += 1
                if still >= REST_FRAMES:
                    rested = True
    result.update({"jumps": jumps, "jumped": jumped[:8]})
    result.update(frame_phases(drop.get("frames") or {}, press, up))
    scan = drop.get("scan")
    if scan:
        head, frames, scale = scan
        rest_after = at[last_change] + refresh / 1000
        result.update(pixel_late(head, frames, scale, final, rest_after, maps[pre], press))
    return result


def summarize(drops: list[dict]) -> dict:
    """One gesture at one pane count: sums and spreads over its judged drops."""
    landed = [d for d in drops if d.get("landed")]

    def total(key):
        values = [d[key] for d in drops if d.get(key) is not None]
        return sum(values) if values else None

    def spread(key):
        values = [d[key] for d in landed if d.get(key) is not None]
        if not values:
            return None
        return {"p50": round(_percentile(values, 0.5), 2), "max": round(max(values), 2), "n": len(values)}

    pixel = [d for d in landed if d.get("pixel_measured")]
    return {
        "drops": len(drops), "landed": len(landed),
        "drop_ms": spread("drop_ms"), "lift_ms": spread("lift_ms"), "settle_ms": spread("settle_ms"),
        "drag_main_over_8_33": total("drag_main_over_8_33"), "drop_main_over_8_33": total("drop_main_over_8_33"),
        "drag_missed": total("drag_missed"), "drop_missed": total("drop_missed"),
        "drag_frames": total("drag_frames"), "drop_frames_counted": total("drop_frames"),
        "main_max_ms": max([d.get(k) or 0 for d in drops for k in ("drag_main_max_ms", "drop_main_max_ms")], default=None),
        "blank_frames": total("blank_frames"),
        "blank_frames_per_drop": round(total("blank_frames") / len(landed), 2) if landed and total("blank_frames") is not None else None,
        "jumps": total("jumps"),
        "pixel_late_frames": sum(d["pixel_late_frames"] for d in pixel) if pixel else None,
        "pixel_late_per_drop": round(sum(d["pixel_late_frames"] for d in pixel) / len(pixel), 2) if pixel else None,
        "pixel_noise_frames": sum(d["pixel_noise_frames"] for d in pixel) if pixel else None,
        "pixel_drops": len(pixel),
    }


def theirs() -> dict:
    """The Claude Code desktop column. Not driven: our debug socket does not reach another app, so its drags would
    need CGEvent posting (the Accessibility grant for the bench step's process) and its frames ScreenCaptureKit of
    another app's windows (the Screen Recording grant); its panes exist only behind a claude.ai login in the desktop
    app. A bench mini has none of the three, and placing a login there is an outward act no bench takes on its own."""
    present = os.path.isdir("/Applications/Claude.app")
    return {"ran": False, "app_present": present,
            "reason": ("Claude Code desktop is not driven: it needs a claude.ai login in the app on the bench mini, the "
                       "Accessibility grant to post its mouse events and the Screen Recording grant to capture its "
                       "windows; the bench host has none of them" + ("" if present else ", and no /Applications/Claude.app"))}


# ---------------------------------------------------------------- the driver (a live app)


class Driver:
    def __init__(self, app, out: str, pixels: bool, deadline: float):
        self.app = app
        self.out = out
        self.pixels = pixels
        self.deadline = deadline
        self.scale = None
        self.dead = False
        self.workspace = None
        self.last_winner = None
        self.log: list[str] = []

    def rpc(self, method, params=None, timeout=30):
        # Every call is bounded by the run's deadline; past it, or once the app stopped answering, nothing is sent.
        if self.left() <= 0 or self.dead:
            return {"error": "run deadline" if self.left() <= 0 else "app not answering", "unreachable": True}
        reply = self.app.rpc(method, params or {}, timeout=max(1.0, min(timeout, self.left())))
        if isinstance(reply, dict) and reply.get("unreachable"):
            self.dead = True
        if isinstance(reply, dict) and "error" in reply:
            self.log.append(f"{method} {json.dumps(params or {})[:160]}: {str(reply['error'])[:200]}")
        return reply if isinstance(reply, dict) else {"value": reply}

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def wait(self, check, seconds: float, step: float = 0.2):
        until = min(time.monotonic() + seconds, self.deadline)
        while time.monotonic() < until:
            value = check()
            if value:
                return value
            time.sleep(step)  # bench: polling a live app, bounded by `until`
        return None

    def cli(self, *args) -> str:
        """The bundled CLI against this app's socket: stdout and stderr."""
        app = self.app.app
        cli = os.path.join(app, "Contents/Resources/bin/cmux")
        env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "CMUX_SOCKET_PATH": self.app.socket, "CMUX_QUIET": "1", "CMUX_TAG": self.app.tag,
               "CMUX_BUNDLED_CLI_PATH": cli}
        from bench_launch import bundle_id  # noqa: E402  (macOS only)
        if bundle_id(app):
            env["CMUX_BUNDLE_ID"] = bundle_id(app)
        try:
            done = subprocess.run([cli, *args], capture_output=True, text=True, env=env,
                                  timeout=max(1.0, min(30.0, self.left())))
            return done.stdout + done.stderr
        except (OSError, subprocess.TimeoutExpired) as error:
            return f"error: {error}"

    def action(self, name, args=None, target=None, timeout=60):
        # The trace's pane ids are layout ids, not the `pane:` targets actions resolve (a target can name a pane of
        # another workspace): the caller clicks the pane first, and the action runs on the focused pane.
        del target
        return self.rpc("action.run", {"action": name, "args": args or {}, "focus": True}, timeout=timeout)

    def rest(self) -> dict:
        """One trace sample of the window at rest."""
        if "error" in self.rpc("debug.motion", {"action": "trace_start", "targets": TRACE_TARGETS}):
            return {}
        time.sleep(0.15)  # bench: a few frames
        reply = self.rpc("debug.motion", {"action": "trace_stop"})
        rows = [s for s in reply.get("samples") or [] if "panes" in s]
        return rows[-1] if rows else {}

    def panes(self) -> dict:
        return pane_map(self.rest())

    def strips(self) -> list:
        return (self.rpc("debug.tab_drag") or {}).get("strips") or []

    def strip_of(self, rect: tuple, strips: list) -> dict | None:
        """The strip whose center is inside a pane rect (pane ids of the two reports are not assumed equal)."""
        x, y, w, h = rect[:4]
        for strip in strips:
            sx, sy, sw, sh = strip.get("frame") or [0, 0, 0, 0]
            cx, cy = sx + sw / 2, sy + sh / 2
            if x <= cx <= x + w and y - 4 <= cy <= y + h:
                return strip
        return None

    def click(self, rect: tuple):
        x, y, w, h = rect[:4]
        self.rpc("debug.mouse", {"action": "click", "x": x + w / 2, "y": y + h * 0.6})

    def build(self, count: int, scratch: str) -> dict:
        """A fresh workspace split into `count` panes of mixed kinds; what it reached."""
        # The CLI's `workspace create` (tab-switch-matrix.py's path): one terminal pane. `newWorkspace` is a person's
        # New Space, which may open a chat beside it. Whatever it starts with, the splits below grow it to `count`.
        made = self.cli("workspace", "create", "--name", f"pane-drag-{count}")
        found = re.search(r"value\.workspace_id\s+(\S+)", made)
        if found:
            self.workspace = found.group(1)
            self.cli("workspace", self.workspace, "focus")
        else:
            self.log.append(f"workspace create: {made[-300:]}")
            self.workspace = None
            self.action("newWorkspace")
        time.sleep(1.0)  # bench: the workspace shows
        start = self.wait(lambda: len(self.panes()), 20)
        if not start:
            return {"error": "no pane shown in a new workspace"}
        if start > count:
            return {"error": f"a new workspace shows {start} panes, more than {count}"}
        time.sleep(0.8)  # bench: the shell prompt
        refused = 0
        while self.left() > 60:  # the run's deadline bounds the splits
            panes = self.panes()
            if len(panes) >= count or not panes or self.dead:
                break
            pane, rect = max(panes.items(), key=lambda kv: kv[1][2] * kv[1][3])
            self.click(rect)
            grew = False
            for name in (("splitRight", "splitDown") if rect[2] >= rect[3] else ("splitDown", "splitRight")) + ("newColumn",):
                self.action(name, target=f"pane:{pane}")
                if self.wait(lambda: len(self.panes()) > len(panes), 5):
                    grew = True
                    break
            if not grew:
                surfaces = sum(len(w.get("panes") or []) for w in (self.rpc("debug.surfaces") or {}).get("windows") or [])
                self.log.append(f"split refused at {len(panes)} shown panes (debug.surfaces: {surfaces} panes)")
                refused += 1
                if refused >= 3:
                    break
            time.sleep(0.3)  # bench: the split's motion
        time.sleep(0.8)
        panes = sorted(self.panes().items(), key=lambda kv: (round(kv[1][0]), round(kv[1][1])))
        kinds = {}
        for index, (pane, rect) in enumerate(panes):
            kind = KINDS[index % len(KINDS)]
            kinds[pane] = kind
            if kind == "terminal" or self.left() < 60:
                continue
            self.click(rect)
            before = self.strip_of(rect, self.strips())
            had = len((before or {}).get("tabs") or [])
            if kind == "chromium":
                page = os.path.join(scratch, f"page-{count}-{index}.html")
                with open(page, "w") as handle:
                    handle.write(f"<!doctype html><title>p{index}</title><body style='margin:0;background:hsl({index * 37 % 360},60%,45%);"
                                 f"color:white;font:28px -apple-system'>" + f"<p>page {index}</p>" * 30)
                self.action("openBrowser.chromium", {"url": "file://" + page}, target=f"pane:{pane}", timeout=120)
            elif kind == "markdown":
                path = os.path.join(scratch, f"notes-{count}-{index}.md")
                with open(path, "w") as handle:
                    handle.write(f"# Notes {index}\n\n" + "\n".join(f"- item {i} with `code` and **bold**" for i in range(80)) + "\n")
                self.action("openMarkdownFile", {"path": path}, target=f"pane:{pane}")
            else:
                self.action("newTab.page", target=f"pane:{pane}")
            self.wait(lambda: len((self.strip_of(rect, self.strips()) or {}).get("tabs") or []) > had, 20)
            time.sleep(0.3 if kind != "chromium" else 0.6)  # bench: the page loads before the next
        time.sleep(2.0)  # bench: pages settle
        shown = self.panes()
        return {"asked": count, "panes": len(shown), "kinds": {k: sum(1 for v in kinds.values() if v == k) for k in KINDS},
                "kind_of": kinds, "splits_refused": refused}

    def learn_scale(self) -> None:
        """Starts and stops the app's recorder once: its device scale, or no pixel path (`self.pixels` False)."""
        if not self.pixels:
            return
        path = os.path.join(self.out, "probe.mov")
        reply = self.rpc("debug.motion", {"action": "record_start", "path": path, "seconds": 2, "rows": [10], "filter": "display"})
        if "error" in reply:
            self.pixels = False
            self.log.append(f"pixels off: {reply['error']}")
            return
        self.wait(lambda: (self.rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 5)
        self.rpc("debug.motion", {"action": "record_stop"})
        state = self.wait(lambda: (lambda s: s if s.get("written") else None)(self.rpc("debug.motion", {"action": "record_read"}) or {}), 15) or {}
        self.scale = float(reply.get("scale") or 0) or None
        if not self.scale or not state.get("callbacks"):
            self.pixels = False
            self.log.append(f"pixels off: recorder gave {state.get('callbacks')} callbacks, scale {reply.get('scale')}")
        self._remove(path)

    def _remove(self, path: str) -> None:
        for name in (path, path + ".scan", path + ".frames.json"):
            try:
                os.unlink(name)
            except OSError:
                pass

    def drag(self, start: tuple, end: tuple, modifiers: list, steps: int = 60) -> dict:
        """Down at `start`, one drag event per 120 Hz frame to `end`, up there. Host times of each phase."""
        mods = {"modifiers": modifiers} if modifiers else {}
        press = now_s()
        self.rpc("debug.mouse", {"action": "down", "x": start[0], "y": start[1], **mods})
        began, first_move = time.monotonic(), None
        try:
            for step in range(1, steps + 1):
                x = start[0] + (end[0] - start[0]) * step / steps
                y = start[1] + (end[1] - start[1]) * step / steps
                if first_move is None:
                    first_move = now_s()
                moved = self.rpc("debug.mouse", {"action": "drag", "x": x, "y": y, "to_x": x, "to_y": y, "steps": 1,
                                                 "press": False, "release": False, **mods}, timeout=5)
                if moved.get("unreachable"):
                    break
                wait = began + step * REFRESH_120 / 1000 - time.monotonic()
                if wait > 0:
                    time.sleep(wait)  # bench: pointer pace, one move per 120 Hz frame
        finally:
            state = self.rpc("debug.tab_drag", timeout=5)
            self.last_winner = {k: state.get(k) for k in ("dragging", "winner", "outcome")} if isinstance(state, dict) else None
            up = now_s()
            self.rpc("debug.mouse", {"action": "up", "x": end[0], "y": end[1], **mods}, timeout=5)
        return {"press_s": press, "first_move_s": first_move, "up_s": up}

    def journal_up(self, since_s: float) -> float | None:
        """The mouse-up's event time (host seconds) from the input journal, when it has one after `since_s`."""
        entries = (self.rpc("debug.journal", {"last": 400}) or {}).get("entries") or []
        for entry in reversed(entries):
            mouse = (entry.get("kind") or {}).get("mouse") or {}
            mouse = mouse.get("_0", mouse) if isinstance(mouse, dict) else {}
            if isinstance(mouse, dict) and mouse.get("phase") == "up":
                seconds = float(entry.get("uptimeNanos") or 0) / 1e9
                return seconds if seconds >= since_s else None
        return None

    def measure(self, start: tuple, end: tuple, modifiers: list, meta: dict, name: str) -> dict:
        """One drop: recorder, trace and frame probe around the drag, then the judge's input."""
        record = None
        if self.pixels and self.scale:
            sample = self.rest()
            height = float((sample.get("window") or [0, 900])[1])
            rows = [int(y * self.scale) for y in range(int(ROW_STEP_PT / 2), int(height), ROW_STEP_PT)]
            record = os.path.join(self.out, f"{name}.mov")
            reply = self.rpc("debug.motion", {"action": "record_start", "path": record, "seconds": 15, "rows": rows,
                                              "filter": "display"})
            if "error" in reply or not self.wait(lambda: (self.rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 5):
                self.rpc("debug.motion", {"action": "record_stop"})
                record = None
        self.rpc("debug.journal", {"clear": True})
        self.rpc("debug.hangs", {"clear": True})
        self.rpc("debug.frames", {"action": "start"})
        self.rpc("debug.motion", {"action": "trace_start", "targets": TRACE_TARGETS})
        time.sleep(0.25)  # bench: frames at rest before the press
        times = self.drag(start, end, modifiers)
        time.sleep(1.2)  # bench: the drop's motion and its rest
        trace_path = os.path.join(self.out, f"{name}.trace.json")
        self.rpc("debug.motion", {"action": "trace_stop", "path": trace_path})
        frames = self.rpc("debug.frames", {"action": "stop", "raw": True})
        hangs = self.rpc("debug.hangs", {"limit": 8})
        if record:
            self.rpc("debug.motion", {"action": "record_stop"})
        journal = self.journal_up(times["press_s"])
        drop = {**meta, **times, "frames": frames, "up_send_s": times["up_s"]}
        if journal:
            drop["up_s"] = journal
        drop["trace"] = self.wait(lambda: _load(trace_path), 20) or {}
        if record:
            state = self.wait(lambda: (lambda s: s if s.get("written") else None)(self.rpc("debug.motion", {"action": "record_read"}) or {}), 20) or {}
            try:
                if state.get("complete") and not state.get("scan_dropped"):
                    head, scan = read_scan(record + ".scan")
                    drop["scan"] = (head, scan, self.scale)
            except (OSError, ValueError, KeyError):
                pass
            self._remove(record)
        verdict = judge_drop(drop)
        verdict["up_from"] = "journal" if journal else "send"
        verdict["samples"] = len((drop.get("trace") or {}).get("samples") or [])
        verdict["winner_before_up"] = self.last_winner
        verdict["stalls"] = stall_stacks(hangs)
        verdict["panes_rest_after"] = len(self.panes())
        print("PANE-DRAG drop " + json.dumps({k: verdict.get(k) for k in (
            "gesture", "kind", "drop", "landed", "note", "error", "panes_before", "panes_after", "drop_ms", "lift_ms",
            "blank_frames", "jumps", "up_from", "samples", "pixel_measured", "winner_before_up", "panes_rest_after")})[:900], flush=True)
        for stall in verdict["stalls"][:3]:
            print(f"PANE-DRAG stall {stall['ms']} ms ({stall['kind']}): " + " < ".join(stall["frames"]), flush=True)
        time.sleep(0.4)  # bench: idle between drops
        return verdict

    def tab_drops(self, drops: int, kinds: dict) -> list:
        """Pairs of (tab to another pane's bottom edge: a split; the moved tab back to its pane's center: a join)."""
        out, used = [], set()
        for pair in range(max(1, drops // 2)):
            if self.left() < 30:
                break
            panes, strips = self.panes(), self.strips()
            sources = [(p, r, self.strip_of(r, strips)) for p, r in panes.items() if kinds.get(p, "terminal") != "terminal"]
            sources = [(p, r, s) for p, r, s in sources if s and len(s.get("tabs") or []) >= 2]
            fresh = [x for x in sources if kinds.get(x[0]) not in used] or sources
            if not fresh:
                out.append({"error": "no pane with two tabs"})
                break
            pane, rect, strip = fresh[0]
            kind = kinds.get(pane)
            used.add(kind)
            target = max(((p, r) for p, r in panes.items() if p != pane),
                         key=lambda kv: abs(kv[1][0] - rect[0]) + abs(kv[1][1] - rect[1]), default=None)
            if target is None:
                out.append({"error": "one pane only"})
                break
            tab = (strip.get("tabs") or [])[-1]
            tx, ty, tw, th = tab["frame"]
            tr = target[1]
            name = f"tab-{len(panes)}-{pair}"
            split = self.measure((tx + tw / 2, ty + th / 2), (tr[0] + tr[2] / 2, tr[1] + tr[3] * 0.9), [],
                                 {"gesture": "tab", "kind": kind, "what": "split"}, name + "-split")
            out.append(split)
            # Back: the new pane's only tab onto the source pane's center (a join).
            after = self.panes()
            new = [p for p in after if p not in panes]
            if not new or pane not in after:
                continue
            strip_new = self.strip_of(after[new[0]], self.strips())
            if not strip_new or not strip_new.get("tabs"):
                continue
            nx, ny, nw, nh = strip_new["tabs"][0]["frame"]
            home = after[pane]
            out.append(self.measure((nx + nw / 2, ny + nh / 2), (home[0] + home[2] / 2, home[1] + home[3] / 2), [],
                                    {"gesture": "tab", "kind": kind, "what": "join"}, name + "-join"))
        return out

    @staticmethod
    def empty_strip_point(strip: dict) -> tuple | None:
        """A point on empty strip space (where a press drags the pane): a run where a press moves the window (top
        row), else past the last tab and the + button."""
        sx, sy, sw, sh = strip.get("frame") or [0, 0, 0, 0]
        runs = [r for r in strip.get("moves_window_x") or [] if len(r) == 2 and r[1] - r[0] >= 24]
        if runs:
            a, b = max(runs, key=lambda r: r[1] - r[0])
            return ((a + b) / 2, sy + sh / 2)
        right = max((t["frame"][0] + t["frame"][2] for t in strip.get("tabs") or []), default=sx)
        x = right + 44  # past the + button
        if x > sx + sw - 16:
            return None
        return ((x + sx + sw - 16) / 2, sy + sh / 2)

    def pane_drops(self, drops: int, kinds: dict) -> list:
        """Pairs of (a pane's header onto another pane: a swap; and back)."""
        out, used = [], set()
        for pair in range(max(1, drops // 2)):
            if self.left() < 30:
                break
            panes, strips = self.panes(), self.strips()
            sources = []
            for p, r in panes.items():
                strip = self.strip_of(r, strips)
                point = self.empty_strip_point(strip) if strip else None
                if point:
                    sources.append((p, r, point))
            fresh = [x for x in sources if kinds.get(x[0]) not in used] or sources
            if not fresh:
                out.append({"error": "no pane header with empty strip space"})
                break
            pane, rect, point = fresh[0]
            kind = kinds.get(pane, "terminal")
            used.add(kind)
            target = max(((p, r) for p, r in panes.items() if p != pane),
                         key=lambda kv: abs(kv[1][0] - rect[0]) + abs(kv[1][1] - rect[1]), default=None)
            if target is None:
                out.append({"error": "one pane only"})
                break
            tr = target[1]
            name = f"pane-{len(panes)}-{pair}"
            out.append(self.measure(point, (tr[0] + tr[2] / 2, tr[1] + tr[3] / 2), ["option"],
                                    {"gesture": "pane", "kind": kind, "what": "swap"}, name + "-swap"))
            after = self.panes()
            if pane not in after or target[0] not in after:
                continue
            strip = self.strip_of(after[pane], self.strips())
            back = self.empty_strip_point(strip) if strip else None
            if not back:
                continue
            home = after[target[0]]
            out.append(self.measure(back, (home[0] + home[2] / 2, home[1] + home[3] / 2), ["option"],
                                    {"gesture": "pane", "kind": kind, "what": "swap back"}, name + "-back"))
        return out


def stall_stacks(hangs: dict) -> list:
    """The main-thread stalls `debug.hangs` caught during a drop, longest first: ms, kind and the app's own frames
    (CmuxNext, Ghostty, CEF) of each sampled stack, so a run names what held the frame."""
    out = []
    for record in (hangs or {}).get("records") or []:
        frames = [str(f) for f in record.get("frames") or []]
        ours = [f[:110] for f in frames if any(k in f for k in ("CmuxNext", "Ghostty", "ghostty", "CEF", "cef_"))][:10]
        out.append({"ms": round(float(record.get("duration_ms") or 0), 1), "kind": record.get("kind"),
                    "frames": ours or [f[:110] for f in frames[:10]]})
    return sorted(out, key=lambda r: -r["ms"])


def _load(path: str):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _strip_scan(drops: list) -> list:
    return [{k: v for k, v in d.items() if k != "scan"} for d in drops]


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--counts", default="2,8,30")
    parser.add_argument("--drops", type=int, default=4, help="drops per gesture per count (pairs: there and back)")
    parser.add_argument("--json")
    parser.add_argument("--out", default=None)
    parser.add_argument("--no-pixels", action="store_true", help="skip the recorder's pixel rows")
    parser.add_argument("--deadline", type=float, default=1500, help="seconds for the whole run")
    opts = parser.parse_args(argv)
    from bench_launch import BenchApp, LaunchError  # noqa: E402  (macOS only: the judge above imports nowhere)

    out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="pane-drag-"))
    os.makedirs(out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="pane-drag-files-")
    report: dict = {"tool": "scripts/ci/frame-pacing/pane_drag.py", "counts": [], "theirs": theirs(),
                    "budget_ms": round(BUDGET_MS, 3), "report_only": True}

    def write():
        if opts.json:
            with open(opts.json + ".tmp", "w") as handle:
                json.dump(report, handle, indent=1)
            os.replace(opts.json + ".tmp", opts.json)

    app = BenchApp(opts.app, out=out, window=(40, 40, 1600, 1000), screen="last")
    try:
        try:
            app.launch(timeout=180)
        except LaunchError as error:
            report["error"] = f"launch: {error}"
            write()
            return 1
        driver = Driver(app, out, pixels=not opts.no_pixels, deadline=time.monotonic() + opts.deadline)
        time.sleep(3)  # bench: launch work settles
        driver.learn_scale()
        report["pixels"] = bool(driver.pixels)
        print(f"PANE-DRAG pixels={driver.pixels} scale={driver.scale} log={json.dumps(driver.log[-4:])[:800]}", flush=True)
        report["scale"] = driver.scale
        for count in [int(c) for c in opts.counts.split(",") if c.strip()]:
            if driver.left() < 120:
                report["counts"].append({"asked": count, "error": "run deadline"})
                break
            built = driver.build(count, scratch)
            entry: dict = {"asked": count, "setup": {k: v for k, v in built.items() if k != "kind_of"}}
            print("PANE-DRAG setup " + json.dumps(entry["setup"]) + " log " + json.dumps(driver.log[-6:])[:1500], flush=True)
            if "error" in built:
                entry["error"] = built["error"]
                print(f"PANE-DRAG setup count={count}: {built['error']}; log: " + json.dumps(driver.log[-6:])[:1500], flush=True)
            else:
                kinds = built["kind_of"]
                for gesture, run in (("tab", driver.tab_drops), ("pane", driver.pane_drops)):
                    try:
                        drops = run(opts.drops, kinds)
                    except Exception as error:  # one gesture's failure must not hide the others
                        drops = [{"error": repr(error)[:300]}]
                    judged = [d for d in drops if "error" not in d or d.get("landed") is not None]
                    entry[gesture] = {**summarize([d for d in judged if "gesture" in d]), "each": _strip_scan(drops)}
                    print(f"PANE-DRAG {gesture} panes={built['panes']} " + json.dumps({k: v for k, v in entry[gesture].items() if k != 'each'}), flush=True)
            report["counts"].append(entry)
            report["refresh_ms"] = next((d.get("refresh_ms") for g in ("tab", "pane") for d in (entry.get(g) or {}).get("each", [])
                                         if d.get("refresh_ms")), report.get("refresh_ms"))
            write()
            if driver.workspace:
                driver.cli("workspace", driver.workspace, "close")
            else:
                driver.action("closeWorkspace")
            time.sleep(1.5)  # bench: the workspace's content goes
        report["log"] = driver.log[-40:]
        print("PANE-DRAG log " + json.dumps(driver.log[-25:])[:4000], flush=True)
        write()
    finally:
        app.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
