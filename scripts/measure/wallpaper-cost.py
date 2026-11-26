#!/usr/bin/env python3
"""What a live wallpaper costs (plans/cmux-next/live-wallpapers.md, "Cost"): the app process's CPU time per second,
the wallpaper's GPU time per second and the app's phys_footprint, each over `--measure` seconds, for:

  picture         a bundled painting (the baseline: a still backdrop)
  live            each live wallpaper, kept awake by pointer moves over the window (one phase per id)
  idle            the first live wallpaper with no pointer move or key for longer than its idle hold
  occluded        the first live wallpaper, the window moved off every screen
  minimized       the first live wallpaper, the window in the Dock
  low-power       the first live wallpaper under Low Power Mode (`debug.low_power_mode`), pointer moving

It launches the tagged app once with a scratch HOME (scripts/cmux-next/bench_memory.py `launch`), switches
`appearance.background` by rewriting the scratch config and running `reloadConfiguration`, and reads the wallpaper's
state from `debug.themes` (`backdrop.live_state`, `live_fps`, `live_frames`, `live_gpu_s`: GPU seconds from each
command buffer's gpuStartTime and gpuEndTime). CPU and footprint come from proc_pid_rusage of the app process only;
the compositor's cost of the layer is not in it. One line per phase:

  WALLPAPER-COST <phase> id=<wallpaper or picture> cpu_s_per_s=.. gpu_s_per_s=.. footprint_mb=.. frames_per_s=..
      state=<run|hold:<reason>|loading> fps=..

Pointer moves are synthesized mouse-moved events (CoreGraphics), so run it only on a fleet Mac nobody is using:
scripts/measure/wallpaper-cost.sh builds the app and runs it there.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "cmux-next"))
import bench_memory as bm  # noqa: E402

FIRST_PARTY = ROOT / "cmux-tui" / "crates" / "cmux-wallpaper" / "wallpapers"
# Not shipped: the crate's test sample (cmux_wallpaper_first_party_count leaves it out).
NOT_SHIPPED = {"smoke"}
DEFAULT_PICTURE = "van-gogh-starry-night"
MB = 1024 * 1024


def first_party_ids() -> list[str]:
    """The shipped first-party wallpapers, sorted by id as the library lists them."""
    ids = []
    for manifest in sorted(FIRST_PARTY.glob("*/wallpaper.json")):
        wallpaper_id = json.loads(manifest.read_text()).get("id") or manifest.parent.name
        if wallpaper_id not in NOT_SHIPPED:
            ids.append(wallpaper_id)
    return sorted(ids)


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


def set_background(app: bm.App, config_path: str, background: str, frame_rate: str):
    with open(config_path) as handle:
        config = json.load(handle)
    appearance = config.setdefault("appearance", {})
    appearance["background"] = background
    appearance["liveWallpaperFrameRate"] = frame_rate
    with open(config_path, "w") as handle:
        json.dump(config, handle)
    reply = app.action("reloadConfiguration")
    if reply.get("error"):
        print(f"WALLPAPER-COST-NOTE reloadConfiguration: {reply['error']}", flush=True)


def measure(app: bm.App, pid: int, phase: str, ident: str, seconds: float) -> dict:
    """CPU and GPU seconds per second and footprint over `seconds`; the wallpaper's state at the end."""
    before, start, live_before = bm.usage(pid), time.monotonic(), backdrop(app)
    time.sleep(seconds)  # test script: the measured window
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
           "frames_per_s": round(max(frames, 0) / elapsed, 2), "state": live_after.get("live_state") or "none",
           "fps": live_after.get("live_fps") or "0"}
    print("WALLPAPER-COST " + phase + " " + " ".join(f"{k}={v}" for k, v in row.items() if k != "phase"), flush=True)
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the tagged app bundle")
    parser.add_argument("--measure", type=float, default=60, help="seconds per phase (default 60)")
    parser.add_argument("--settle", type=float, default=10, help="seconds before each phase's window (default 10)")
    parser.add_argument("--ids", default="", help="live wallpapers to measure, comma separated (default every shipped one)")
    parser.add_argument("--picture", default=DEFAULT_PICTURE, help="the baseline's bundled painting")
    parser.add_argument("--frame-rate", default="30", choices=("15", "30", "60"), help="appearance.liveWallpaperFrameRate")
    parser.add_argument("--out", help="write the rows as JSON here")
    args = parser.parse_args()
    ids = [i for i in args.ids.split(",") if i] or first_party_ids()
    if not ids:
        raise SystemExit(f"wallpaper-cost: no first-party wallpaper under {FIRST_PARTY}")
    host = os.uname().nodename
    print(f"WALLPAPER-COST-MACHINE host={host} measure={args.measure} frame_rate={args.frame_rate} ids={','.join(ids)}", flush=True)
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
        rows.append(measure(app, pid, "picture", args.picture, args.measure))

        for wallpaper in ids:
            set_background(app, config_path, f"live:{wallpaper}", args.frame_rate)
            pointer.moving.set()
            state = wait_state(app, lambda s: s == "run", 30)
            if state != "run":
                print(f"WALLPAPER-COST-NOTE live:{wallpaper} is {state or 'not shown'} with the pointer moving", flush=True)
            time.sleep(args.settle)  # test script: the wallpaper settles
            rows.append(measure(app, pid, "live", wallpaper, args.measure))
            pointer.moving.clear()

        first = ids[0]
        set_background(app, config_path, f"live:{first}", args.frame_rate)
        # Idle: no pointer move or key until the scheduler holds it.
        wait_state(app, lambda s: s.startswith("hold:idle"), 60)
        rows.append(measure(app, pid, "idle", first, args.measure))

        frame = (app.call("debug.window_frame", {}, timeout=30) or {}).get("frame")
        app.call("debug.window_frame", {"frame": [-20000, -20000, frame[2], frame[3]] if frame else [-20000, -20000, 1200, 800]},
                 timeout=30)
        pointer.moving.set()
        wait_state(app, lambda s: s.startswith("hold:"), 15)
        time.sleep(args.settle)  # test script: occlusion settles
        rows.append(measure(app, pid, "occluded", first, args.measure))
        pointer.moving.clear()
        if frame:
            app.call("debug.window_frame", {"frame": frame}, timeout=30)

        app.action("minimizeWindow")
        wait_state(app, lambda s: s.startswith("hold:"), 15)
        time.sleep(args.settle)  # test script: the minimize animation ends
        rows.append(measure(app, pid, "minimized", first, args.measure))
        app.action("showMainWindow")

        app.call("debug.low_power_mode", {"enabled": True}, timeout=30)
        pointer.moving.set()
        wait_state(app, lambda s: s.startswith("hold:"), 15)
        time.sleep(args.settle)  # test script: Low Power Mode settles
        rows.append(measure(app, pid, "low-power", first, args.measure))
        pointer.moving.clear()
        app.call("debug.low_power_mode", {"enabled": None}, timeout=30)
    finally:
        pointer.stop()
        bm.end_bundle(args.app)
        shutil.rmtree(scratch, ignore_errors=True)
    if args.out:
        Path(args.out).write_text(json.dumps({"host": host, "rows": rows}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
