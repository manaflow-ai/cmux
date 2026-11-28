#!/usr/bin/env python3
"""Swift live code in the iOS Simulator, timed: an edit saved to the edit visible in the simulator's
screenshot, live (scripts/live-code/ios-sim.sh patch) against a warm incremental xcodebuild, simctl
install and relaunch of the same edit. One harness, the same edits, the same pixel check.

  scripts/measure/ios-live-code.py --mode live --out OUT --udid UDID FILE --old TEXT --x X --y Y
  scripts/measure/ios-live-code.py --mode rebuild --derived-data DD --udid UDID FILE --old TEXT --x X --y Y

FILE holds TEXT, a color expression whose fill covers the screenshot pixel (X, Y). Edit N writes the
Nth color of COLORS in its place and times from the write to the first screenshot whose pixel is
nearest that color. Prints one JSON line per edit and a summary with the p50. Restores FILE at the
end. IOS_SIM_SET names the simctl device set; JOBS bounds the rebuild's xcodebuild jobs.

CMUX_LIVE_CODE_DISTINCT_BENCH=SECONDS (live, with --out): once SECONDS have passed since the first run on
that --out, every edit writes code no earlier edit wrote (the same color, with a counter in the literal's
trailing digits that the pixel cannot see), so a session of distinct saves runs on the same app after a
session of repeated ones. The clock and the counter live in OUT/distinct-bench.json.
"""
import argparse
import json
import os
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
# Distinct colors, each far from the last and from the app's dark and light surfaces.
COLORS = [(255, 0, 0), (0, 200, 0), (0, 0, 255), (255, 0, 255), (255, 200, 0), (0, 220, 220), (255, 120, 0), (140, 0, 255)]


def simctl(*args):
    base = ["xcrun", "simctl"] + (["--set", os.environ["IOS_SIM_SET"]] if os.environ.get("IOS_SIM_SET") else [])
    return base + list(args)


def pixel(udid, x, y, path):
    """The screenshot's (x, y) pixel as (r, g, b): a BMP, read in place with no image library."""
    subprocess.run(simctl("io", udid, "screenshot", "--type=bmp", path), check=True, capture_output=True)
    with open(path, "rb") as f:
        data = f.read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (width * bpp + 3) & ~3
    line = y if height < 0 else abs(height) - 1 - y
    at = offset + line * row + x * bpp
    b, g, r = data[at], data[at + 1], data[at + 2]
    return r, g, b


def nearest(rgb):
    return min(range(len(COLORS)), key=lambda i: sum((a - b) ** 2 for a, b in zip(rgb, COLORS[i])))


def color_expr(rgb, serial=None):
    r, g, b = (round(c / 255, 3) for c in rgb)
    # A serial lands past the 9th decimal: a different literal, the same pixel.
    red = f"{r:.3f}{serial:08d}" if serial is not None else r
    return f"Color(red: {red}, green: {g}, blue: {b})"


class Distinct:
    """CMUX_LIVE_CODE_DISTINCT_BENCH: the serial for the next edit, or None while saves still repeat."""

    def __init__(self, opts):
        after = os.environ.get("CMUX_LIVE_CODE_DISTINCT_BENCH")
        self.path = os.path.join(opts.out, "distinct-bench.json") if after and opts.mode == "live" and opts.out else None
        if not self.path:
            return
        try:
            with open(self.path) as f:
                self.state = json.load(f)
        except (OSError, ValueError):
            self.state = {"since": time.time(), "after_s": float(after), "serial": 0}
            self.save()

    def save(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        with open(self.path, "w") as f:
            json.dump(self.state, f)

    def next(self):
        if not self.path or time.time() - self.state["since"] < self.state["after_s"]:
            return None
        self.state["serial"] += 1
        self.save()
        return self.state["serial"]


def wait_visible(udid, x, y, want, started, deadline, failed=lambda: False):
    """Seconds from `started` to the first screenshot whose pixel is nearest COLORS[want]; None past `deadline`."""
    shot = tempfile.mktemp(suffix=".bmp")
    try:
        while time.time() < deadline and not failed():
            rgb = pixel(udid, x, y, shot)
            if nearest(rgb) == want:
                return time.time() - started, rgb
        return None, None
    finally:
        if os.path.exists(shot):
            os.remove(shot)


def apply_live(opts, path):
    run = subprocess.run([os.path.join(ROOT, "scripts/live-code/ios-sim.sh"), "patch", opts.out, path], capture_output=True, text=True)
    return run.returncode == 0, (run.stdout + run.stderr).strip().splitlines()


def apply_rebuild(opts, path):
    app = os.path.join(opts.derived_data, "Build/Products", f"{opts.config}-iphonesimulator", "CmuxMobileApp.app")
    conditions = "DEBUG CMUX_MOBILE_DEMO" if opts.config == "Demo" else "DEBUG"
    build = subprocess.run([
        "xcodebuild", "-project", os.path.join(ROOT, "cmux-next-ios/CmuxMobileApp.xcodeproj"), "-scheme", "CmuxMobileApp",
        "-configuration", opts.config, "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", opts.derived_data,
        "-jobs", os.environ.get("JOBS", "6"), "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=", "ARCHS=arm64",
        "ONLY_ACTIVE_ARCH=YES", "COMPILER_INDEX_STORE_ENABLE=NO", f"SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) {conditions}", "build",
    ], capture_output=True, text=True)
    if build.returncode != 0:
        return False, [line for line in build.stdout.splitlines() if "error:" in line][:10]
    built = time.time()
    subprocess.run(simctl("install", opts.udid, app), check=True, capture_output=True)
    subprocess.run(simctl("terminate", opts.udid, opts.bundle_id), capture_output=True)
    subprocess.run(simctl("launch", opts.udid, opts.bundle_id), check=True, capture_output=True)
    return True, [f"build_s={built - apply_rebuild.started:.2f} install_launch_s={time.time() - built:.2f}"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["live", "rebuild"], required=True)
    parser.add_argument("--out", help="live: the ios-sim.sh build folder")
    parser.add_argument("--derived-data", help="rebuild: the regular build's warm DerivedData")
    parser.add_argument("--config", default="Demo")
    parser.add_argument("--bundle-id", default="dev.cmux.mobile")
    parser.add_argument("--udid", required=True)
    parser.add_argument("--old", required=True, help="the color expression in FILE the edits replace")
    parser.add_argument("--within", help="a text of FILE that holds OLD once and is itself in FILE once (OLD may repeat)")
    parser.add_argument("--x", type=int, required=True)
    parser.add_argument("--y", type=int, required=True)
    parser.add_argument("--edits", type=int, default=6)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("file")
    opts = parser.parse_args()
    path = os.path.realpath(opts.file)
    with open(path) as f:
        original = f.read()
    within = opts.within or opts.old
    if original.count(within) != 1 or within.count(opts.old) != 1:
        sys.exit(f"ios-live-code.py: {within!r} is in {path} {original.count(within)} times, not once (or holds no {opts.old!r})")
    results = []
    distinct = Distinct(opts)
    try:
        for edit in range(opts.edits):
            want = edit % len(COLORS)
            serial = distinct.next()
            with open(path, "w") as f:
                f.write(original.replace(within, within.replace(opts.old, color_expr(COLORS[want], serial))))
            started = time.time()
            apply_rebuild.started = started
            outcome = {}

            def apply():
                ok, lines = (apply_live if opts.mode == "live" else apply_rebuild)(opts, path)
                outcome.update(ok=ok, lines=lines, applied_s=time.time() - started)

            worker = threading.Thread(target=apply)
            worker.start()
            seconds, rgb = wait_visible(opts.udid, opts.x, opts.y, want, started, started + opts.timeout, lambda: outcome.get("ok") is False)
            worker.join()
            row = {"mode": opts.mode, "edit": edit + 1, "color": COLORS[want], "visible_s": None if seconds is None else round(seconds, 3),
                   "distinct": serial, "pixel": rgb, "apply_s": round(outcome.get("applied_s", 0), 3), "ok": outcome.get("ok"), "log": outcome.get("lines", [])[-3:]}
            print(json.dumps(row), flush=True)
            if seconds is None or not outcome.get("ok"):
                sys.exit(f"ios-live-code.py: edit {edit + 1} did not show")
            results.append(seconds)
    finally:
        with open(path, "w") as f:
            f.write(original)
    print(json.dumps({"mode": opts.mode, "edits": len(results), "p50_s": round(statistics.median(results), 3),
                      "min_s": round(min(results), 3), "max_s": round(max(results), 3)}), flush=True)


if __name__ == "__main__":
    main()
