#!/usr/bin/env python3
"""The app half of scripts/measure/live-code-app.sh: launch, patch twice, take a bad patch and roll it
back, time each and count pixels."""
import argparse
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
from bench_launch import BenchApp  # noqa: E402

VIEW = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift")
ORIGINAL = "layer?.backgroundColor = nil"
# Home's transcript fills the view (layout sets its frame to bounds) and covers the layer's color, so the
# first patch also insets it: the color then shows as a border around the chat (a fleet still of
# try-pr-live-code.sh at 71936c52 counted 0 red pixels without it).
FILL, INSET = "transcript.frame = bounds\n", "transcript.frame = bounds.insetBy(dx: 80, dy: 80)\n"


def pixels(png):
    """(red, blue) pixel counts of a PNG, read through sips as an uncompressed BMP."""
    bmp = png[:-4] + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", bmp], capture_output=True, check=True)
    data = open(bmp, "rb").read()
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    step = bpp // 8
    row = (width * step + 3) & ~3
    red = blue = 0
    for y in range(abs(height)):
        base = offset + y * row
        for x in range(0, width * step, step):
            b, g, r = data[base + x], data[base + x + 1], data[base + x + 2]
            if r > 180 and g < 90 and b < 90:
                red += 1
            elif b > 180 and r < 60 and g < 170:
                blue += 1
    return red, blue


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--build-seconds", type=int, default=0)
    opts = parser.parse_args()
    live = tempfile.mkdtemp(prefix="cmux-live-code.")
    live_log = os.path.join(live, "live-code.log")
    source = open(VIEW).read()
    for needed in (ORIGINAL, FILL):
        if needed not in source:
            sys.exit(f"live-code-app: {VIEW} no longer has {needed.strip()}")
    result = {"build_s": opts.build_seconds, "generations": []}
    app = BenchApp(opts.app, out=opts.out, env={"CMUX_LIVE_CODE_DIR": live})

    def snap(generation):
        path = os.path.join(opts.out, f"generation-{generation}.png")
        reply = app.rpc("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
        red, blue = pixels(path)
        return {"generation": generation, "png": os.path.basename(path), "red_px": red, "blue_px": blue,
                "snapshot": reply.get("method") if isinstance(reply, dict) else None}

    def wait_line(pattern, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            text = open(live_log).read() if os.path.exists(live_log) else ""
            match = re.search(pattern, text)
            if match:
                return match
            if " refused: " in text:
                break
            time.sleep(0.05)
        return None

    def patch(generation, old, new, *more):
        current = open(VIEW).read()
        for before, after in ((old, new),) + more:
            current = current.replace(before, after)
        with open(VIEW, "w") as f:
            f.write(current)
        edited = time.time()
        run = subprocess.run([sys.executable, os.path.join(ROOT, "scripts/live-code/patch.py"), "--log", opts.log,
                              "--module", "CmuxNextApp", "--live", live, VIEW], capture_output=True, text=True)
        print(run.stdout + run.stderr, end="")
        entry = {"edit": new, "patch_exit": run.returncode}
        times = re.search(r"compile_s=([\d.]+) link_s=([\d.]+)", run.stdout)
        if times:
            entry.update(compile_s=float(times.group(1)), link_s=float(times.group(2)))
        if run.returncode == 0:
            drawn = wait_line(rf"redrawn generation={generation} at=([\d.]+)", 60)
            log = open(live_log).read() if os.path.exists(live_log) else ""
            applied = re.findall(r"applied \S+ functions=(\d+) load_ms=(\d+)", log)
            applied = applied[generation - 1] if len(applied) >= generation else None
            if applied:
                entry.update(functions=int(applied[0]), load_ms=int(applied[1]))
            if drawn:
                entry["edit_to_redraw_s"] = round(float(drawn.group(1)) - edited, 2)
                time.sleep(0.5)
                entry.update(snap(generation))
        return entry

    def roll_back(generation):
        # A dropped `*.rollback` file undoes the newest patch (cmuxterm-hq#7149 L4).
        dropped = time.time()
        open(os.path.join(live, f"undo-{generation}.rollback"), "w").close()
        entry = {"edit": "rollback"}
        drawn = wait_line(rf"redrawn generation={generation} at=([\d.]+)", 30)
        rolled = re.search(r"rolled back \S+ functions=(\d+) rollback_ms=(\d+)", open(live_log).read() if os.path.exists(live_log) else "")
        if rolled:
            entry.update(functions=int(rolled.group(1)), rollback_ms=int(rolled.group(2)))
        if drawn:
            entry["rollback_to_redraw_s"] = round(float(drawn.group(1)) - dropped, 2)
            time.sleep(0.5)
            entry.update(snap(generation))
        return entry

    try:
        app.launch()
        result["pid"] = app.process.pid
        result["ready_s"] = app.ready_seconds
        time.sleep(3)
        result["generations"].append(snap(0))
        red, blue = "layer?.backgroundColor = NSColor.systemRed.cgColor", "layer?.backgroundColor = NSColor.systemBlue.cgColor"
        result["generations"].append(patch(1, ORIGINAL, red, (FILL, INSET)))
        result["generations"].append(patch(2, red, blue))
        # A bad patch (red again, standing in for one a probe fails), then its rollback: blue again.
        result["generations"].append(patch(3, blue, red))
        result["generations"].append(roll_back(4))
        # Live means the same process all along (cmuxterm-hq#7149 L3: same pid).
        result["same_pid"] = app.process.poll() is None and app.process.pid in app.running_pids()
    finally:
        with open(VIEW, "w") as f:
            f.write(source)
        if os.path.exists(live_log):
            subprocess.run(["cp", live_log, os.path.join(opts.out, "live-code.log")])
        app.stop()
    gens = {g["generation"]: g for g in result["generations"] if "generation" in g}
    base = gens.get(0, {})
    result["shown"] = bool(
        result.get("same_pid")
        and gens.get(1, {}).get("red_px", 0) > base.get("red_px", 0) + 1000
        and gens.get(2, {}).get("blue_px", 0) > base.get("blue_px", 0) + 1000
        and gens.get(2, {}).get("red_px", 0) < gens.get(1, {}).get("red_px", 0))
    # L4: the rollback brings generation 2's blue back, red gone, in under 2 s, in the same process.
    rollback = gens.get(4, {})
    result["rolled_back"] = bool(
        result.get("same_pid")
        and gens.get(3, {}).get("red_px", 0) > base.get("red_px", 0) + 1000
        and rollback.get("blue_px", 0) > base.get("blue_px", 0) + 1000
        # Red back to where it was before any patch (within 1000 px), not merely less of it.
        and rollback.get("red_px", 0) <= base.get("red_px", 0) + 1000
        and rollback.get("rollback_to_redraw_s", 99) < 2)
    with open(os.path.join(opts.out, "result.json"), "w") as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result))
    if os.path.exists(os.path.join(opts.out, "live-code.log")):
        print(open(os.path.join(opts.out, "live-code.log")).read())
    else:
        # The engine writes "watching" first, so no log means it never started: say whether the app
        # has the engine compiled in (its log lines are string literals) and what the app printed.
        binary = app.binary  # "cmux DEV" in a tagged bundle
        compiled = b"live code: cannot watch" in open(binary, "rb").read()
        print(f"live-code-app: no live-code.log in {live}: the engine never started; "
              f"its code is {'in' if compiled else 'NOT in'} {binary}")
        if os.path.exists(app.log_path):
            lines = [line for line in open(app.log_path, errors="replace") if "live" in line.lower()]
            print("live-code-app: the app's log lines naming live code:\n" + "".join(lines[-20:]))
    sys.exit(0 if result["shown"] and result["rolled_back"] else 1)


if __name__ == "__main__":
    main()
