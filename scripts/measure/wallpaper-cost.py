#!/usr/bin/env python3
"""What a moving wallpaper costs (plans/cmux-next/live-wallpapers.md, "Cost"): the app process's CPU time per second,
the wallpaper's GPU time per second and the app's phys_footprint, each over `--measure` seconds, for:

  picture         a bundled painting (the baseline: a still backdrop)
  live            each live wallpaper, kept awake by pointer moves over the window (one phase per id)
  video           each local test video (--videos: 1080p30 H.264, 4k60 HEVC), made on the host by
                  wallpaper-cost-helper.swift (AVFoundation's encoder; nothing is downloaded); `file:` backgrounds
  youtube         a YouTube wallpaper (--youtube ID) at each --youtube-qualities (`youtube:ID`, `youtube:ID?quality=Q`)

and, for each subject in --holds (default: the first live wallpaper, every video and every YouTube one), the holds:

  idle            no pointer move or key for longer than its idle hold (a live wallpaper's own; a video's
                  appearance.videoWallpaperIdlePause, set to --idle-pause for this phase when the build has it)
  occluded        the window moved off every screen
  covered         another app's opaque window over every screen (wallpaper-cost-helper.swift `cover`)
  minimized       the window in the Dock
  low-power       Low Power Mode (`debug.low_power_mode`)

It launches the tagged app once with a scratch HOME (scripts/cmux-next/bench_memory.py `launch`), switches
`appearance.background` by rewriting the scratch config and running `reloadConfiguration`, and reads the wallpaper's
state from `debug.themes` (`backdrop.live_state`, `live_fps`, `live_frames`, `live_gpu_s`: GPU seconds from each
command buffer's gpuStartTime and gpuEndTime; a video's `video_state` when the build reports one). The app's CPU and
footprint come from proc_pid_rusage of the app process. Every phase also samples, once a second:

  tree            the app and every process it owns (bench_memory.owned: its bundle's processes and the WebKit
                  processes it is responsible for: WebContent, Networking, GPU), CPU mean and p95, footprint at the end
  webkit          those WebKit processes alone
  decoder         VTDecoderXPCService (the system's video decoder service; every instance, owned or not)
  windowserver    WindowServer (the compositor; any app's drawing shows here too)
  gpu util        IOAccelerator PerformanceStatistics "Device Utilization %" (the whole GPU, no sudo), mean and p95
  network         bytes in and out of the app's processes (nettop -P -x -d per second, summed over the window) and of
                  every non-loopback interface (netstat -ib deltas: the host's other traffic is in it)

One line per phase:

  WALLPAPER-COST <phase> id=<subject> cpu_s_per_s=.. gpu_s_per_s=.. footprint_mb=.. frames_per_s=.. state=.. fps=..
      tree_cpu_s_per_s=.. tree_cpu_p95_s_per_s=.. webkit_cpu_s_per_s=.. decoder_cpu_s_per_s=..
      windowserver_cpu_s_per_s=.. gpu_util_pct=.. gpu_util_p95_pct=.. tree_footprint_mb=..
      net_in_kb_per_s=.. net_out_kb_per_s=.. if_in_kb_per_s=.. if_out_kb_per_s=..

then the same rows as a Markdown table between WALLPAPER-COST-TABLE-BEGIN and -END. Pointer moves are synthesized
mouse-moved events (CoreGraphics), so run it only on a fleet Mac nobody is using: scripts/measure/wallpaper-cost.sh
builds the app and runs it there.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "cmux-next"))
import bench_memory as bm  # noqa: E402

FIRST_PARTY = ROOT / "cmux-tui" / "crates" / "cmux-wallpaper" / "wallpapers"
APPEARANCE_SCHEMA = ROOT / "schemas" / "settings" / "source" / "appearance.json"
HELPER_SOURCE = Path(__file__).resolve().parent / "wallpaper-cost-helper.swift"
# Not shipped: the crate's test sample (cmux_wallpaper_first_party_count leaves it out).
NOT_SHIPPED = {"smoke"}
DEFAULT_PICTURE = "van-gogh-starry-night"
MB = 1024 * 1024
# The test videos --videos names: (width, height, fps, codec, average Mbps). 10 s each, looped by the app.
VIDEOS = {"1080p30": (1920, 1080, 30, "h264", 12), "4k60": (3840, 2160, 60, "hevc", 40)}
CLIP_SECONDS = 10
HOLD_PHASES = ("idle", "occluded", "covered", "minimized", "low-power")
DECODER = "VTDecoderXPCService"
WINDOW_SERVER = "WindowServer"
# The fields after the original seven, in line order (wallpaper_cost.py ingests them by name).
EXTRA_FIELDS = ("tree_cpu_s_per_s", "tree_cpu_p95_s_per_s", "webkit_cpu_s_per_s", "decoder_cpu_s_per_s",
                "windowserver_cpu_s_per_s", "gpu_util_pct", "gpu_util_p95_pct", "tree_footprint_mb",
                "net_in_kb_per_s", "net_out_kb_per_s", "if_in_kb_per_s", "if_out_kb_per_s")


def first_party_ids() -> list[str]:
    """The shipped first-party wallpapers, sorted by id as the library lists them."""
    ids = []
    for manifest in sorted(FIRST_PARTY.glob("*/wallpaper.json")):
        wallpaper_id = json.loads(manifest.read_text()).get("id") or manifest.parent.name
        if wallpaper_id not in NOT_SHIPPED:
            ids.append(wallpaper_id)
    return sorted(ids)


# ---------------------------------------------------------------- readers (pure: tests/wallpaper-cost.test.py)

def p95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * 0.95)))]


def parse_cpu_time(field: str) -> float | None:
    """Seconds of a `ps -o time=` field ("S.ss", "M:SS.ss", "H:MM:SS", "D-HH:MM:SS"); None when it does not parse."""
    days, text = 0, field.strip()
    if "-" in text:
        day_text, _, text = text.partition("-")
        if not day_text.isdigit():
            return None
        days = int(day_text)
    seconds = 0.0
    for part in text.split(":"):
        try:
            seconds = seconds * 60 + float(part)
        except ValueError:
            return None
    return days * 86400 + seconds


def parse_ps_times(text: str) -> dict[int, float]:
    """{pid: CPU seconds} of `ps -o pid=,time=` output."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            seconds = parse_cpu_time(parts[1])
            if seconds is not None:
                out[int(parts[0])] = seconds
    return out


NETTOP_ROW = re.compile(r"^(.*)\.(\d+)$")


def parse_nettop(text: str) -> dict[int, list[int]]:
    """{pid: [bytes in, bytes out]} summed over every sample but the first of `nettop -P -x -d -J bytes_in,bytes_out`
    output (in delta mode the first sample is each process's total so far; the rest are per-interval deltas). A
    sample starts at its header line (the one naming bytes_in)."""
    totals: dict[int, list[int]] = {}
    sample, columns = -1, None
    for line in text.splitlines():
        cells = [c.strip() for c in line.split(",")]
        if "bytes_in" in cells and "bytes_out" in cells:
            sample += 1
            columns = (cells.index("bytes_in"), cells.index("bytes_out"))
            continue
        if columns is None or sample < 1:
            continue
        name = next((c for c in cells if NETTOP_ROW.match(c)), None)
        if not name:
            continue
        try:
            got_in, got_out = int(cells[columns[0]]), int(cells[columns[1]])
        except (ValueError, IndexError):
            continue
        entry = totals.setdefault(int(NETTOP_ROW.match(name).group(2)), [0, 0])
        entry[0] += got_in
        entry[1] += got_out
    return totals


def parse_netstat(text: str) -> tuple[int, int]:
    """(bytes in, bytes out) summed over the link rows (`<Link#N>`) of every non-loopback interface in `netstat -ib`
    output. Columns are counted from the right (an interface with no address has one cell fewer)."""
    lines = text.splitlines()
    if not lines:
        return 0, 0
    header = lines[0].split()
    if "Ibytes" not in header or "Obytes" not in header:
        return 0, 0
    from_right_in, from_right_out = len(header) - header.index("Ibytes"), len(header) - header.index("Obytes")
    got_in = got_out = 0
    for line in lines[1:]:
        cells = line.split()
        if len(cells) < from_right_in or not cells[0] or cells[0].startswith("lo") or not any(c.startswith("<Link#") for c in cells):
            continue
        try:
            got_in += int(cells[-from_right_in])
            got_out += int(cells[-from_right_out])
        except ValueError:
            continue
    return got_in, got_out


def group_of(kind: str) -> str:
    """The cost group of a bench_memory kind: app, webkit or other (Chromium helpers, daemons, holders)."""
    if kind == "app":
        return "app"
    if kind.startswith("webkit-"):
        return "webkit"
    return "other"


def markdown(rows: list[dict]) -> str:
    """The rows as one Markdown table (CPU and GPU as % of one core / of the GPU)."""
    def pct(row, key):
        value = row.get(key)
        return "-" if value is None else f"{value * 100:.1f}"

    def num(row, key, digits=1):
        value = row.get(key)
        return "-" if value is None else f"{value:.{digits}f}"

    lines = ["| phase | subject | state | app CPU % | app+helpers CPU % (p95) | WebKit CPU % | decoder CPU % | "
             "WindowServer CPU % | GPU util % (p95) | wallpaper GPU % | footprint MB (app / tree) | "
             "net in / out KB/s (app; all interfaces) |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        lines.append(
            f"| {row['phase']} | {row['id']} | {row.get('state', '-')} | {pct(row, 'cpu_s_per_s')} | "
            f"{pct(row, 'tree_cpu_s_per_s')} ({pct(row, 'tree_cpu_p95_s_per_s')}) | {pct(row, 'webkit_cpu_s_per_s')} | "
            f"{pct(row, 'decoder_cpu_s_per_s')} | {pct(row, 'windowserver_cpu_s_per_s')} | "
            f"{num(row, 'gpu_util_pct')} ({num(row, 'gpu_util_p95_pct')}) | {pct(row, 'gpu_s_per_s')} | "
            f"{num(row, 'footprint_mb', 0)} / {num(row, 'tree_footprint_mb', 0)} | "
            f"{num(row, 'net_in_kb_per_s')} / {num(row, 'net_out_kb_per_s')}; "
            f"{num(row, 'if_in_kb_per_s')} / {num(row, 'if_out_kb_per_s')} |")
    return "\n".join(lines)


# ---------------------------------------------------------------- the host

class Pointer:
    """Mouse-moved events over a screen point, in a circle, while `moving` is set (a background thread)."""

    def __init__(self):
        self._cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics") or
                               "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self._cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation") or
                               "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

        class Point(ctypes.Structure):
            _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

        self._point = Point
        self._cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        self._cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, Point, ctypes.c_uint32]
        self._cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        self._cf.CFRelease.argtypes = [ctypes.c_void_p]
        self.center = (400.0, 300.0)
        self.radius = 120.0
        self.moving = threading.Event()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def move_to(self, x: float, y: float):
        event = self._cg.CGEventCreateMouseEvent(None, 5, self._point(x, y), 0)  # kCGEventMouseMoved
        if event:
            self._cg.CGEventPost(0, event)  # kCGHIDEventTap
            self._cf.CFRelease(event)

    def _run(self):
        import math
        angle = 0.0
        while not self._stop.is_set():
            if self.moving.wait(0.5) and not self._stop.is_set():
                angle += 0.35
                self.move_to(self.center[0] + self.radius * math.cos(angle), self.center[1] + self.radius * math.sin(angle))
                time.sleep(1 / 30)  # test script: a pointer moving at 30 events per second

    def stop(self):
        self._stop.set()
        self.moving.set()
        self._thread.join(timeout=2)


class Helper:
    """wallpaper-cost-helper.swift, built once into the work folder; the cover processes it starts, by PID."""

    def __init__(self, work: str):
        self.path = os.path.join(work, "wallpaper-cost-helper")
        self.cover_process: subprocess.Popen | None = None

    def build(self) -> bool:
        if os.path.exists(self.path):
            return True
        done = subprocess.run(["xcrun", "swiftc", "-O", str(HELPER_SOURCE), "-o", self.path], capture_output=True, text=True,
                              timeout=600)
        if done.returncode != 0:
            print(f"WALLPAPER-COST-NOTE the helper did not build: {done.stderr.strip()[-600:]}", flush=True)
            return False
        return True

    def clip(self, name: str, folder: str) -> str | None:
        """The test video `name` (VIDEOS), made once per folder."""
        width, height, fps, codec, mbps = VIDEOS[name]
        path = os.path.join(folder, f"wallpaper-cost-{name}-{codec}-v1.mp4")
        if os.path.exists(path):
            return path
        if not self.build():
            return None
        os.makedirs(folder, exist_ok=True)
        start = time.monotonic()
        done = subprocess.run([self.path, "clip", path, str(width), str(height), str(fps), str(CLIP_SECONDS), codec, str(mbps)],
                              capture_output=True, text=True, timeout=900)
        if done.returncode != 0 or not os.path.exists(path):
            print(f"WALLPAPER-COST-NOTE clip {name} failed: {(done.stderr or done.stdout).strip()[-400:]}", flush=True)
            return None
        print(f"WALLPAPER-COST-NOTE {done.stdout.strip()} ({os.path.getsize(path) / MB:.1f} MB, made in "
              f"{time.monotonic() - start:.0f} s)", flush=True)
        return path

    def cover(self) -> bool:
        if not self.build():
            return False
        self.cover_process = subprocess.Popen([self.path, "cover", "900"], stdout=subprocess.PIPE, text=True)
        line = self.cover_process.stdout.readline().strip()  # `cover N` once the windows are up
        if not line.startswith("cover"):
            print(f"WALLPAPER-COST-NOTE the cover window did not come up ({line!r})", flush=True)
            self.uncover()
            return False
        return True

    def uncover(self):
        process, self.cover_process = self.cover_process, None
        if process and process.poll() is None:
            process.terminate()  # the cover process this script started, by its PID
            try:
                process.wait(10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(10)


def system_pids(names: tuple[str, ...]) -> dict[int, str]:
    """{pid: name} of the running processes whose executable's name is one of `names` (any user)."""
    found = {}
    for pid, _ppid, cmd in bm.process_table():
        name = os.path.basename(cmd.split(" -", 1)[0].strip())
        if name in names:
            found[pid] = name
    return found


def ps_times(pids) -> dict[int, float]:
    if not pids:
        return {}
    done = subprocess.run(["ps", "-o", "pid=,time=", "-p", ",".join(str(p) for p in pids)], capture_output=True, text=True,
                          env={**os.environ, "LC_ALL": "C"})
    return parse_ps_times(done.stdout)


def netstat_bytes() -> tuple[int, int]:
    done = subprocess.run(["netstat", "-ib"], capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"})
    return parse_netstat(done.stdout)


class Sampler:
    """Once a second over a phase's window, from a thread of this script: the CPU seconds of the app's processes
    (bench_memory.owned, refreshed every 5 s), of VTDecoderXPCService and WindowServer, and the GPU's utilization;
    nettop per process and the interfaces' byte counters around it."""

    def __init__(self, app_pid: int, bundle: str, seconds: float):
        self.app_pid, self.bundle, self.seconds = app_pid, bundle, seconds
        self.per_second: dict[str, list[float]] = {g: [] for g in ("tree", "app", "webkit", "other", "decoder", "windowserver")}
        self.totals: dict[str, float] = {g: 0.0 for g in self.per_second}
        self.gpu: list[dict] = []
        self.owned: dict[int, tuple[str, str]] = {}
        self.seen_owned: set[int] = set()
        self.nettop_out = ""
        self.nettop_error = None

    def _owned(self):
        try:
            self.owned = bm.owned(self.app_pid, self.bundle)
        except Exception as error:  # noqa: BLE001  a racing process table: keep the last set
            print(f"WALLPAPER-COST-NOTE owned(): {error}", flush=True)
        self.seen_owned.update(self.owned)

    def _read(self) -> dict[tuple[str, int], float]:
        """CPU seconds so far per (group, pid)."""
        got = {}
        for pid, (kind, _cmd) in self.owned.items():
            use = bm.usage(pid)
            if use is not None:
                got[(group_of(kind), pid)] = use[3] / 1e9
        for pid, seconds in ps_times(self.system).items():
            got[("decoder" if self.system[pid] == DECODER else "windowserver", pid)] = seconds
        return got

    def run(self) -> float:
        self._owned()
        self.system = system_pids((DECODER, WINDOW_SERVER))
        samples = int(round(self.seconds))
        nettop = None
        try:
            nettop = subprocess.Popen(["nettop", "-P", "-x", "-d", "-s", "1", "-L", str(samples + 1), "-J", "bytes_in,bytes_out"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except OSError as error:
            self.nettop_error = str(error)
        if_before = netstat_bytes()
        start = time.monotonic()
        last, last_at = self._read(), start
        for tick in range(1, samples + 1):
            time.sleep(max(0.0, start + tick - time.monotonic()))  # test script: the once-a-second sample
            if tick % 5 == 0:
                self._owned()
                self.system = system_pids((DECODER, WINDOW_SERVER))
            now, now_at = self._read(), time.monotonic()
            dt = max(now_at - last_at, 1e-3)
            groups = {g: 0.0 for g in self.per_second}
            for key, seconds in now.items():
                # A process first seen in this tick counts from here (no earlier reading of it).
                delta = max(0.0, seconds - last[key]) if key in last else 0.0
                groups[key[0]] += delta
            groups["tree"] = groups["app"] + groups["webkit"] + groups["other"] + groups["decoder"]
            for group, value in groups.items():
                self.per_second[group].append(value / dt)
                self.totals[group] += value
            stats = bm.gpu_stats()
            if stats:
                self.gpu.append(stats)
            last, last_at = now, now_at
        elapsed = time.monotonic() - start
        if_after = netstat_bytes()
        self.if_bytes = (max(0, if_after[0] - if_before[0]), max(0, if_after[1] - if_before[1]))
        if nettop is not None:
            try:
                out, err = nettop.communicate(timeout=20)
                self.nettop_out = out
                if nettop.returncode != 0 or not out.strip():
                    self.nettop_error = (err or f"exit {nettop.returncode}").strip()[:300]
            except subprocess.TimeoutExpired:
                nettop.kill()  # the nettop this script started, by its PID
                nettop.communicate()
                self.nettop_error = "nettop did not end"
        return elapsed

    def fields(self, elapsed: float) -> dict:
        out = {"tree_cpu_s_per_s": round(self.totals["tree"] / elapsed, 5),
               "tree_cpu_p95_s_per_s": round(p95(self.per_second["tree"]) or 0.0, 5),
               "webkit_cpu_s_per_s": round(self.totals["webkit"] / elapsed, 5),
               "decoder_cpu_s_per_s": round(self.totals["decoder"] / elapsed, 5),
               "windowserver_cpu_s_per_s": round(self.totals["windowserver"] / elapsed, 5)}
        util = [s["Device Utilization %"] for s in self.gpu if "Device Utilization %" in s]
        out["gpu_util_pct"] = round(sum(util) / len(util), 2) if util else None
        out["gpu_util_p95_pct"] = round(p95(util), 2) if util else None
        footprint = 0
        for pid in self.owned:
            use = bm.usage(pid)
            if use is not None:
                footprint += use[1]
        out["tree_footprint_mb"] = round(footprint / MB, 1)
        if self.nettop_error is None:
            per_pid = parse_nettop(self.nettop_out)
            got = [per_pid.get(pid, [0, 0]) for pid in self.seen_owned]
            out["net_in_kb_per_s"] = round(sum(g[0] for g in got) / 1024 / elapsed, 2)
            out["net_out_kb_per_s"] = round(sum(g[1] for g in got) / 1024 / elapsed, 2)
        else:
            out["net_in_kb_per_s"] = out["net_out_kb_per_s"] = None
        out["if_in_kb_per_s"] = round(self.if_bytes[0] / 1024 / elapsed, 2)
        out["if_out_kb_per_s"] = round(self.if_bytes[1] / 1024 / elapsed, 2)
        return out


# ---------------------------------------------------------------- the app

def backdrop(app: bm.App) -> dict:
    """The first window's `debug.themes` backdrop object."""
    windows = (app.call("debug.themes", timeout=30) or {}).get("windows") or []
    return (windows[0].get("backdrop") or {}) if windows else {}


def window_center(app: bm.App) -> tuple[float, float] | None:
    """The first window's center in CoreGraphics' space (top left of the main display)."""
    reply = app.call("debug.window_frame", {}, timeout=30) or {}
    frame, screen = reply.get("frame"), reply.get("screen_frame")
    if not frame or not screen:
        return None
    # AppKit's y grows up from the main display's bottom; CoreGraphics' grows down from its top.
    main_height = screen[1] + screen[3]
    return frame[0] + frame[2] / 2, main_height - (frame[1] + frame[3] / 2)


def set_background(app: bm.App, config_path: str, background: str, frame_rate: str, extra: dict | None = None):
    with open(config_path) as handle:
        config = json.load(handle)
    appearance = config.setdefault("appearance", {})
    appearance["background"] = background
    appearance["liveWallpaperFrameRate"] = frame_rate
    appearance.update(extra or {})
    with open(config_path, "w") as handle:
        json.dump(config, handle)
    reply = app.action("reloadConfiguration")
    if reply.get("error"):
        print(f"WALLPAPER-COST-NOTE reloadConfiguration: {reply['error']}", flush=True)


def state_of(state: dict) -> str:
    """The moving backdrop's state: a live wallpaper's `live_state`, else a video's `video_state` (when reported)."""
    return state.get("live_state") or state.get("video_state") or state.get("youtube_state") or "none"


def measure(app: bm.App, pid: int, bundle: str, phase: str, ident: str, seconds: float) -> dict:
    """CPU and GPU seconds per second and footprint over `seconds`, the helpers' and the host's costs (Sampler); the
    wallpaper's state at the end."""
    before, start, live_before = bm.usage(pid), time.monotonic(), backdrop(app)
    sampler = Sampler(pid, bundle, seconds)
    sampler.run()
    after, elapsed, live_after = bm.usage(pid), time.monotonic() - start, backdrop(app)
    if before is None or after is None:
        raise SystemExit(f"wallpaper-cost: the app (pid {pid}) ended during {phase}")

    def number(state: dict, key: str) -> float:
        try:
            return float(state.get(key) or 0)
        except ValueError:
            return 0.0

    same = live_before.get("live") == live_after.get("live")
    gpu = number(live_after, "live_gpu_s") - (number(live_before, "live_gpu_s") if same else 0)
    frames = number(live_after, "live_frames") - (number(live_before, "live_frames") if same else 0)
    row = {"phase": phase, "id": ident, "cpu_s_per_s": round((after[3] - before[3]) / 1e9 / elapsed, 5),
           "gpu_s_per_s": round(max(gpu, 0) / elapsed, 5), "footprint_mb": round(after[1] / MB, 1),
           "frames_per_s": round(max(frames, 0) / elapsed, 2), "state": state_of(live_after),
           "fps": live_after.get("live_fps") or "0"}
    row.update(sampler.fields(elapsed))
    print("WALLPAPER-COST " + phase + " " + " ".join(f"{k}={v}" for k, v in row.items() if k != "phase" and v is not None),
          flush=True)
    if sampler.nettop_error:
        print(f"WALLPAPER-COST-NOTE {phase} {ident}: nettop gave nothing ({sampler.nettop_error}); interface bytes only",
              flush=True)
    row["backdrop"] = live_after
    row["processes"] = {str(p): k for p, (k, _c) in sampler.owned.items()}
    row["seconds"] = round(elapsed, 2)
    return row


def wait_state(app: bm.App, wanted, seconds: float) -> str:
    """Polls the wallpaper's state until `wanted(state)` or `seconds` pass; the last state."""
    deadline, state = time.monotonic() + seconds, ""
    while time.monotonic() < deadline:
        state = backdrop(app).get("live_state") or ""
        if wanted(state):
            return state
        time.sleep(0.5)  # test script: waiting for the app's wallpaper state
    return state


def has_idle_pause() -> bool:
    """Whether this checkout's app has appearance.videoWallpaperIdlePause (the bench runs at the app's commit)."""
    try:
        return "videoWallpaperIdlePause" in APPEARANCE_SCHEMA.read_text()
    except OSError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the tagged app bundle")
    parser.add_argument("--measure", type=float, default=60, help="seconds per phase (default 60)")
    parser.add_argument("--settle", type=float, default=10, help="seconds before each phase's window (default 10)")
    parser.add_argument("--ids", default="", help="live wallpapers to measure, comma separated (default every shipped "
                                                  "one; `none` for no live wallpaper)")
    parser.add_argument("--picture", default=DEFAULT_PICTURE, help="the baseline's bundled painting")
    parser.add_argument("--frame-rate", default="30", choices=("15", "30", "60"), help="appearance.liveWallpaperFrameRate")
    parser.add_argument("--videos", default="", help=f"local test videos, comma separated, of {','.join(VIDEOS)}")
    parser.add_argument("--clips", help="folder the test videos are made in and kept (default the work folder)")
    parser.add_argument("--youtube", default="", help="a YouTube video id (11 characters) for the youtube subjects")
    parser.add_argument("--youtube-qualities", default="default",
                        help="comma list of `default` (the 1080 player) and 360,480,720,1080,1440,2160")
    parser.add_argument("--youtube-settle", type=float, default=25, help="seconds a YouTube wallpaper loads before its window")
    parser.add_argument("--holds", default="", help="subjects that get the hold phases (default: the first live "
                                                     "wallpaper, every video and every YouTube one); `none` for none")
    parser.add_argument("--hold-phases", default=",".join(HOLD_PHASES), help="which holds, comma separated")
    parser.add_argument("--idle-pause", type=int, default=20,
                        help="appearance.videoWallpaperIdlePause in the idle phase of a video or YouTube subject")
    parser.add_argument("--work", help="folder for the helper and the clips (default next to --out)")
    parser.add_argument("--out", help="write the rows as JSON here")
    args = parser.parse_args()
    ids = [] if args.ids == "none" else ([i for i in args.ids.split(",") if i] or first_party_ids())
    videos = [v for v in args.videos.split(",") if v]
    unknown = [v for v in videos if v not in VIDEOS]
    if unknown:
        raise SystemExit(f"wallpaper-cost: unknown video {unknown}; one of {list(VIDEOS)}")
    if args.youtube and not re.fullmatch(r"[A-Za-z0-9_-]{11}", args.youtube):
        raise SystemExit(f"wallpaper-cost: {args.youtube!r} is no YouTube video id (11 of A-Z a-z 0-9 _ -)")
    hold_phases = [p for p in args.hold_phases.split(",") if p]
    if set(hold_phases) - set(HOLD_PHASES):
        raise SystemExit(f"wallpaper-cost: unknown hold phase {sorted(set(hold_phases) - set(HOLD_PHASES))}")
    work = args.work or os.path.join(os.path.dirname(os.path.abspath(args.out or "rows.json")), "work")
    os.makedirs(work, exist_ok=True)
    helper = Helper(work)
    idle_pause = has_idle_pause()

    # (kind, subject id, background): the subjects in measuring order after the picture.
    subjects = [("live", wallpaper, f"live:{wallpaper}") for wallpaper in ids]
    for name in videos:
        path = helper.clip(name, args.clips or work)
        if path:
            subjects.append(("video", f"video-{name}", f"file:{path}"))
    if args.youtube:
        for quality in [q for q in args.youtube_qualities.split(",") if q]:
            suffix = "" if quality in ("default", "1080") else f"?quality={quality}"
            subjects.append(("youtube", "youtube" + ("" if not suffix else f"-{quality}"), f"youtube:{args.youtube}{suffix}"))
    if args.holds == "none":
        holds = set()
    elif args.holds:
        holds = set(args.holds.split(","))
    else:
        holds = ({ids[0]} if ids else set()) | {s[1] for s in subjects if s[0] != "live"}
    # A video plays whatever the input while the idle pause is 0; the idle phase sets --idle-pause.
    video_extra = {"videoWallpaperIdlePause": 0} if idle_pause else {}

    host = os.uname().nodename
    print(f"WALLPAPER-COST-MACHINE host={host} measure={args.measure} frame_rate={args.frame_rate} ids={','.join(ids)} "
          f"videos={','.join(videos)} youtube={args.youtube or '-'} idle_pause_setting={idle_pause}", flush=True)
    pid, socket_path, scratch = bm.launch(args.app, {"appearance": {"background": args.picture,
                                                                    "liveWallpaperFrameRate": args.frame_rate}})
    app = bm.App(args.app, socket_path)
    config_path = os.path.join(scratch, "cmux.json")
    pointer = Pointer()
    rows = []
    try:
        time.sleep(args.settle)  # test script: the launch settles
        center = window_center(app)
        if center is None:
            raise SystemExit("wallpaper-cost: debug.window_frame gave no frame (a DEBUG or bench-hooks build has it)")
        pointer.center = center
        rows.append(measure(app, pid, args.app, "picture", args.picture, args.measure))

        for kind, ident, background in subjects:
            live = kind == "live"
            set_background(app, config_path, background, args.frame_rate, None if live else video_extra)
            if live:
                pointer.moving.set()
                state = wait_state(app, lambda s: s == "run", 30)
                if state != "run":
                    print(f"WALLPAPER-COST-NOTE live:{ident} is {state or 'not shown'} with the pointer moving", flush=True)
            if kind == "youtube":
                time.sleep(args.youtube_settle)  # test script: the embed loads and starts
            time.sleep(args.settle)  # test script: the wallpaper settles
            rows.append(measure(app, pid, args.app, kind, ident, args.measure))
            pointer.moving.clear()
            if ident not in holds:
                continue
            rows += holds_of(app, pid, args, config_path, pointer, helper, kind, ident, background, hold_phases,
                             idle_pause, video_extra)
    finally:
        pointer.stop()
        helper.uncover()
        bm.end_bundle(args.app)
        shutil.rmtree(scratch, ignore_errors=True)
    table = markdown(rows)
    print("WALLPAPER-COST-TABLE-BEGIN\n" + table + "\nWALLPAPER-COST-TABLE-END", flush=True)
    if args.out:
        Path(args.out).write_text(json.dumps({"host": host, "rows": rows, "markdown": table}, indent=2))
    return 0


def holds_of(app, pid, args, config_path, pointer, helper, kind, ident, background, phases, idle_pause, video_extra):
    """The hold phases of one subject, each from the window shown and in front."""
    live = kind == "live"
    rows = []
    for phase in phases:
        set_background(app, config_path, background, args.frame_rate, None if live else video_extra)
        if phase == "idle":
            if live:
                # No pointer move or key until the scheduler holds it.
                wait_state(app, lambda s: s.startswith("hold:idle"), 60)
            elif idle_pause:
                set_background(app, config_path, background, args.frame_rate, {"videoWallpaperIdlePause": args.idle_pause})
                time.sleep(args.idle_pause + args.settle)  # test script: no input past the idle pause
            else:
                print(f"WALLPAPER-COST-NOTE {ident}: this build has no appearance.videoWallpaperIdlePause; idle is "
                      f"{args.settle:.0f} s without input", flush=True)
                time.sleep(args.settle)  # test script: no input
            rows.append(measure(app, pid, args.app, "idle", ident, args.measure))
        elif phase == "occluded":
            frame = (app.call("debug.window_frame", {}, timeout=30) or {}).get("frame")
            moved = app.call("debug.window_frame", {"frame": [-20000, -20000, frame[2], frame[3]] if frame else [-20000, -20000, 1200, 800]},
                             timeout=30) or {}
            # AppKit may constrain a titled window back onto a screen: say where it landed, so an "occluded" row that
            # measured a window still on screen is not read as an off-screen one.
            # The screen's name is empty in a fleet console session, so judge by the frame: AppKit keeps a titled
            # window on a screen, and a frame that still meets the screen it reports is on screen.
            landed, whole = moved.get("frame"), moved.get("screen_frame")
            on_screen = bool(landed and whole and landed[0] < whole[0] + whole[2] and whole[0] < landed[0] + landed[2]
                             and landed[1] < whole[1] + whole[3] and whole[1] < landed[1] + landed[3])
            print(f"WALLPAPER-COST-NOTE {ident}: occluded frame={landed} screen_frame={whole} off_screen={not on_screen}",
                  flush=True)
            if on_screen:
                print(f"WALLPAPER-COST-NOTE {ident}: AppKit kept the window on a screen; this occluded row measures a "
                      f"visible window", flush=True)
            if live:
                pointer.moving.set()
                wait_state(app, lambda s: s.startswith("hold:"), 15)
            time.sleep(args.settle)  # test script: occlusion settles
            rows.append(measure(app, pid, args.app, "occluded", ident, args.measure))
            pointer.moving.clear()
            if frame:
                app.call("debug.window_frame", {"frame": frame}, timeout=30)
        elif phase == "covered":
            if not helper.cover():
                continue
            try:
                if live:
                    pointer.moving.set()
                    wait_state(app, lambda s: s.startswith("hold:"), 15)
                time.sleep(args.settle)  # test script: coverage settles
                rows.append(measure(app, pid, args.app, "covered", ident, args.measure))
            finally:
                pointer.moving.clear()
                helper.uncover()
        elif phase == "minimized":
            app.action("minimizeWindow")
            if live:
                wait_state(app, lambda s: s.startswith("hold:"), 15)
            time.sleep(args.settle)  # test script: the minimize animation ends
            rows.append(measure(app, pid, args.app, "minimized", ident, args.measure))
            app.action("showMainWindow")
        elif phase == "low-power":
            app.call("debug.low_power_mode", {"enabled": True}, timeout=30)
            if live:
                pointer.moving.set()
                wait_state(app, lambda s: s.startswith("hold:"), 15)
            time.sleep(args.settle)  # test script: Low Power Mode settles
            rows.append(measure(app, pid, args.app, "low-power", ident, args.measure))
            pointer.moving.clear()
            app.call("debug.low_power_mode", {"enabled": None}, timeout=30)
        time.sleep(2)  # test script: the window is back before the next hold
    return rows


if __name__ == "__main__":
    sys.exit(main())
