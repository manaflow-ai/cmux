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

Only a window in front of the app covers it. The list is front to back, so `ForeignLog.add` keeps the foreign windows
listed before the app's first own window: the desktop (Finder, WindowManager) and a dialog the app is in front of are
behind it. On a CI mini (macOS 27, 2026-11-18) every round of a run was left out over those, a stale accessibility prompt
behind the app among them. A sample without an own window keeps every foreign window.
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

IGNORED_OWNERS = ("Window Server", "Dock", "SystemUIServer", "CuaDriver", "cua-driver", "Cua Driver")
# Owners whose window spanning the whole app window is a transparent host that is on screen in every round (macOS 27's
# Notification Center keeps one over the display at layer 21); their small windows (a banner) still count.
HOST_OWNERS = ("Notification Center",)
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


def is_foreign(win, own_pids, ignored=IGNORED_OWNERS):
    """Whether `win` ({"owner", "pid", "alpha", "bounds"}) is a window of some other process that could cover pixels."""
    if win.get("pid") in own_pids:
        return False
    owner = str(win.get("owner") or "")
    if any(owner == name for name in ignored):
        return False
    if (win.get("alpha") if win.get("alpha") is not None else 1.0) < MIN_ALPHA:
        return False
    bounds = win.get("bounds") or ()
    return len(bounds) == 4 and bounds[2] >= MIN_POINTS and bounds[3] >= MIN_POINTS


def in_front(windows, own_pids):
    """The windows listed before the first of `own_pids`' (the list is front to back); all of them when none is own."""
    for i, win in enumerate(windows):
        if win.get("pid") in own_pids:
            return windows[:i]
    return windows


def is_host(win, window, hosts=HOST_OWNERS):
    """Whether `win` is a system host window spanning the whole app window [x, y, w, h] (see HOST_OWNERS)."""
    if str(win.get("owner") or "") not in hosts:
        return False
    x, y, w, h = win.get("bounds") or (0, 0, 0, 0)
    return x <= window[0] and y <= window[1] and x + w >= window[0] + window[2] and y + h >= window[1] + window[3]


def foreign_over(windows, own_pids, rects, window, scale):
    """The foreign windows among `windows` that intersect any of `rects` (None entries skipped): one
    {"owner", "pid", "layer", "bounds"} each, in the list's order."""
    wanted = [r for r in rects if r]
    found = []
    for win in windows:
        if not is_foreign(win, own_pids):
            continue
        box = rect_of_bounds(win["bounds"], window, scale)
        if any(overlap(box, r) > 0 for r in wanted):
            found.append({k: win.get(k) for k in ("owner", "pid", "layer", "bounds")})
    return found


class ForeignLog:
    """Timed samples of the on-screen windows. `add(t, windows)` keeps only the foreign ones (a clean sample is an empty
    list), `between(t0, t1, rects)` the foreign windows over the rects in any sample of that span (seconds, one clock)."""

    def __init__(self, own_pids, window, scale):
        self.own_pids, self.window, self.scale = set(own_pids), window, scale
        self.samples = []  # (t, [window])
        self.lock = threading.Lock()

    def add(self, t, windows):
        kept = [w for w in in_front(windows, self.own_pids) if is_foreign(w, self.own_pids)
                and not is_host(w, self.window)]
        with self.lock:
            self.samples.append((t, kept))

    def between(self, t0, t1, rects):
        with self.lock:
            span = [windows for t, windows in self.samples if t0 <= t <= t1 and windows]
        seen = {}
        for windows in span:
            for win in foreign_over(windows, self.own_pids, rects, self.window, self.scale):
                seen.setdefault((win["owner"], win["pid"]), win)
        return list(seen.values())

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

    def __init__(self, tools, own_pids, window, scale, interval_ms=150):
        self.log = ForeignLog(own_pids, window, scale)
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
