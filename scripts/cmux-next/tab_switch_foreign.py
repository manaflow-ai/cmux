"""Foreign windows over the measured app, for the tab switch harness (scripts/cmux-next/tab_switch_frames.py).

The NIGHTLY run of 2026-11-17 (L0 to L5) measured through a macOS crash dialog, a Keychain password prompt and a
notification banner that covered the app: its recording shows those pixels, so the settle detector reported
never-settled, late-change and layout-after-content at every load, even idle. A round recorded while any window that is
not the app's own covers the content or sidebar rect measures the window, not the app. This module finds those rounds
so the harness leaves them out of the settled statistics, counts them in the table and fails a run that lost too many.

The window list is CGWindowListCopyWindowInfo through `tab-switch-tools windows` (no grant needed): every on-screen
window with its owner. `Watch` samples it in the background; `ForeignLog` answers, for the wall-clock span of one round,
which foreign windows overlapped the rects. Everything below the `Watch` class is pure, so it runs on any host.

Rects are (x0, y0, x1, y1) in recorded pixels, origin at the app window's top-left (as the harness's content and sidebar
rects); a window's bounds are [x, y, w, h] in global points, as CGWindowList reports them.

Not an own window: the app's pid, the marker's pid, and the system's furniture that is on screen in every round (the
window server's cursor and menu bar, the Dock, the recorder's cursor overlay). The notification banner is another
process's window (NotificationCenter), so it counts.

A window covers the app only when it can hide the app's pixels (`covers`): it is in front of the app's window (the
list is front to back, so a higher layer, or the same layer earlier in the list), it intersects a measured rect, it is
visible (alpha), and it is not a full-display overlay. The 2026-11-17 run on a 1920x1080 worker excluded every round
for windows that cover nothing: the desktop layer (WindowManager, layer -2147483624, below every app), the notification
overlay (layer 21, full display, transparent unless a banner shows) and a computer-use helper's overlay (layer 0, full
display). A full-display overlay could count only with nonzero alpha and a backing store that shows something; the
window list (no grant) gives store type, sharing state and on-screen, but none of them says whether the overlay drew a
pixel, so a full-display overlay never excludes a round on its own. A banner is its own window and still counts. Every
foreign window seen in an excluded round stays in its record with its verdict and the fields behind it.
"""
from __future__ import annotations

import glob
import json
import os
import select
import signal
import subprocess
import threading
import time

IGNORED_OWNERS = ("Window Server", "Dock", "SystemUIServer", "CuaDriver", "cua-driver")
MAX_EXCLUDED_SHARE = 0.2  # a run that lost more than this share of its rounds to foreign windows measured nothing
MIN_ALPHA = 0.05  # an invisible window covers nothing
MIN_POINTS = 2.0  # a hairline (a shadow, an edge) covers nothing


def rect_of_bounds(bounds, window, scale):
    """A window's bounds [x, y, w, h] (global points) as a pixel rect relative to the app window [x, y, w, h]."""
    x, y, w, h = bounds
    return ((x - window[0]) * scale, (y - window[1]) * scale, (x + w - window[0]) * scale, (y + h - window[1]) * scale)


def overlap(a, b):
    """The area (px squared) where rects `a` and `b` (x0, y0, x1, y1) overlap; 0 when they only touch or are apart."""
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    return w * h if w > 0 and h > 0 else 0.0


def alpha_of(win):
    """A window's alpha (1.0 when the list leaves it out)."""
    return win.get("alpha") if win.get("alpha") is not None else 1.0


def is_overlay(bounds, display):
    """Whether `bounds` [x, y, w, h] (points) cover the whole display [x, y, w, h], to a point: a full-display overlay,
    not a window someone placed over the app. False when the display is unknown."""
    if not display or len(display) != 4 or not bounds or len(bounds) != 4:
        return False
    dx, dy, dw, dh = display
    x, y, w, h = bounds
    return x <= dx + 1 and y <= dy + 1 and x + w >= dx + dw - 1 and y + h >= dy + dh - 1


def app_place(windows, own_pids, window):
    """(index, layer) of the app's window in `windows` (front to back): the own window whose bounds match `window`
    [x, y, w, h] to two points, else the largest own window that is not a hairline. None when no own window is listed;
    then every foreign window counts as in front (the strict reading)."""
    best = None
    for index, win in enumerate(windows):
        bounds = win.get("bounds") or ()
        if win.get("pid") not in own_pids or len(bounds) != 4:
            continue
        if window and len(window) == 4 and all(abs(a - b) <= 2 for a, b in zip(bounds, window)):
            return index, win.get("layer") or 0
        area = bounds[2] * bounds[3]
        if bounds[2] >= MIN_POINTS and bounds[3] >= MIN_POINTS and (best is None or area > best[0]):
            best = (area, index, win.get("layer") or 0)
    return (best[1], best[2]) if best else None


def judge_window(win, index, place, display):
    """One foreign window's fields plus its verdicts that need no rect: "above" (in front of the app's window: a higher
    layer, or the same layer earlier in the front-to-back list), "overlay" (covers the whole display) and "visible"
    (alpha at least MIN_ALPHA)."""
    fields = ("owner", "pid", "layer", "alpha", "bounds", "number", "onscreen", "store", "sharing")
    out = {k: win.get(k) for k in fields}
    layer = win.get("layer") or 0
    if place is None:
        out["above"] = True
    else:
        app_index, app_layer = place
        out["above"] = layer > app_layer or (layer == app_layer and index < app_index)
    out["overlay"] = is_overlay(win.get("bounds"), display)
    out["visible"] = alpha_of(win) >= MIN_ALPHA
    return out


def judged(windows, own_pids, window, display, ignored=IGNORED_OWNERS):
    """The foreign windows of one sample (`windows` front to back, own windows included), each through judge_window."""
    place = app_place(windows, own_pids, window)
    return [judge_window(win, index, place, display) for index, win in enumerate(windows)
            if win.get("pid") not in own_pids and str(win.get("owner") or "") not in ignored]


def covers(item, rects, window, scale):
    """Whether one judged window can hide the app's pixels in `rects` (None entries skipped): in front, visible, not a
    hairline, not a full-display overlay (module note) and intersecting a rect. Sets item["intersects"] and
    item["covers"], so the round's record says why."""
    bounds = item.get("bounds") or ()
    sized = len(bounds) == 4 and bounds[2] >= MIN_POINTS and bounds[3] >= MIN_POINTS
    box = rect_of_bounds(bounds, window, scale) if sized else None
    item["intersects"] = bool(box) and any(overlap(box, r) > 0 for r in rects if r)
    item["covers"] = bool(item["above"] and item["visible"] and not item["overlay"] and item["intersects"])
    return item["covers"]


def foreign_over(windows, own_pids, rects, window, scale, display=None):
    """The windows among `windows` (one sample, front to back) that can hide the app's pixels in any of `rects`: one
    judged record each (judge_window, covers), in the list's order."""
    return [item for item in judged(windows, own_pids, window, display) if covers(item, rects, window, scale)]


class ForeignLog:
    """Timed samples of the on-screen windows. `add(t, windows)` keeps the foreign ones, judged against the app's window
    in that sample (a sample with none is an empty list); `seen(t0, t1, rects)` every foreign window of that span with
    its verdict, `between(t0, t1, rects)` only those that covered the rects (seconds, one clock)."""

    def __init__(self, own_pids, window, scale, display=None):
        self.own_pids, self.window, self.scale, self.display = set(own_pids), window, scale, display
        self.samples = []  # (t, [judged window])
        self.lock = threading.Lock()

    def add(self, t, windows):
        kept = judged(windows, self.own_pids, self.window, self.display)
        with self.lock:
            self.samples.append((t, kept))

    def seen(self, t0, t1, rects):
        """Every foreign window of the span, one per (owner, pid, bounds); a covering sample's verdict wins."""
        with self.lock:
            span = [windows for t, windows in self.samples if t0 <= t <= t1 and windows]
        out = {}
        for windows in span:
            for item in windows:
                item = dict(item)
                covers(item, rects, self.window, self.scale)
                key = (item["owner"], item["pid"], tuple(item.get("bounds") or ()))
                if key not in out or (item["covers"] and not out[key]["covers"]):
                    out[key] = item
        return list(out.values())

    def between(self, t0, t1, rects):
        found = {}
        for item in self.seen(t0, t1, rects):
            if item["covers"]:
                found.setdefault((item["owner"], item["pid"]), item)
        return list(found.values())

    def count(self):
        with self.lock:
            return len(self.samples)


def owners(found):
    """The owner names of `found`, in order, without repeats."""
    names = []
    for win in found:
        if win["owner"] not in names:
            names.append(win["owner"])
    return names


def exclude(switches, found_for):
    """Splits one scenario row's switches. `found_for(switch)` is the foreign windows over that round ([] for none).
    Returns (kept, excluded): an excluded round is {"label", "foreign_window": owners joined by "+", "windows"}."""
    kept, excluded = [], []
    for switch in switches:
        found = found_for(switch)
        if found:
            excluded.append({"label": switch.get("label"), "foreign_window": "+".join(owners(found)), "windows": found})
        else:
            kept.append(switch)
    return kept, excluded


def excluded_share(rows):
    """(excluded, total, share) over scenario rows that carry an "excluded" list beside their "switches"."""
    lost = sum(len(r.get("excluded") or []) for r in rows)
    total = lost + sum(len(r.get("switches") or []) for r in rows)
    return lost, total, (lost / total if total else 0.0)


def too_many(rows, limit=MAX_EXCLUDED_SHARE):
    """Whether more than `limit` of the rounds were excluded."""
    _lost, _total, share = excluded_share(rows)
    return share > limit


def by_owner(rows):
    """{owner: excluded rounds} over the rows."""
    out = {}
    for row in rows:
        for item in row.get("excluded") or []:
            out[item["foreign_window"]] = out.get(item["foreign_window"], 0) + 1
    return out


class Watch:
    """`tab-switch-tools windows INTERVAL_MS`: a sample of the on-screen windows every interval, read on a thread."""

    def __init__(self, tools, own_pids, window, scale, interval_ms=150, display=None):
        self.log = ForeignLog(own_pids, window, scale, display)
        self.process = subprocess.Popen([tools, "windows", str(interval_ms)], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1, start_new_session=True)
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        for line in self.process.stdout:
            try:
                windows = json.loads(line).get("windows")
            except ValueError:
                continue
            if isinstance(windows, list):
                self.log.add(time.monotonic(), windows)

    def ready(self, seconds=5.0):
        """Whether a sample arrived (a tool that cannot list windows leaves every round unchecked)."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.log.count():
                return True
            if self.process.poll() is not None:
                return False
            select.select([], [], [], 0.05)  # test script: waiting for the first sample
        return False

    def close(self):
        if self.process.poll() is None:
            try:
                os.killpg(self.process.pid, signal.SIGTERM)  # this run's own watcher, by its own process group
                self.process.wait(timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except OSError:
                    pass


class CrashDialogOff:
    """`defaults write com.apple.CrashReporter DialogType none` for the run, the previous value put back after it: a
    crashing helper process (the harness's own agent scripts, a load) then leaves a report on disk, never a dialog over
    the app. `run` is subprocess.run's shape, injected by the test."""

    DOMAIN, KEY = "com.apple.CrashReporter", "DialogType"

    def __init__(self, run=subprocess.run):
        self.run, self.before = run, None

    def __enter__(self):
        read = self.run(["defaults", "read", self.DOMAIN, self.KEY], capture_output=True, text=True, timeout=30)
        self.before = read.stdout.strip() if read.returncode == 0 else None
        self.run(["defaults", "write", self.DOMAIN, self.KEY, "none"], capture_output=True, text=True, timeout=30)
        return self

    def __exit__(self, *_):
        if self.before is None:
            self.run(["defaults", "delete", self.DOMAIN, self.KEY], capture_output=True, text=True, timeout=30)
        else:
            self.run(["defaults", "write", self.DOMAIN, self.KEY, self.before], capture_output=True, text=True, timeout=30)
        return False


def crash_reports(folder, since, limit=8):
    """The crash reports in `folder` (DiagnosticReports) written at or after `since` (epoch seconds), newest first, as
    {"file", "process", "path"}: the process name from the file name and the first line that names an executable path."""
    out = []
    for path in glob.glob(os.path.join(folder, "*.ips")) + glob.glob(os.path.join(folder, "*.crash")):
        try:
            if os.path.getmtime(path) < since:
                continue
            with open(path, errors="replace") as handle:
                head = handle.read(4000)
        except OSError:
            continue
        name = os.path.basename(path)
        found = ""
        for line in head.splitlines():
            if '"procPath"' in line or line.startswith("Path:"):
                found = line.split(":", 1)[1].strip().strip('",')
                break
        out.append({"file": name, "process": name.split("_")[0].split("-")[0], "path": found,
                    "mtime": os.path.getmtime(path)})
    out.sort(key=lambda r: -r["mtime"])
    return [{k: v for k, v in r.items() if k != "mtime"} for r in out[:limit]]
