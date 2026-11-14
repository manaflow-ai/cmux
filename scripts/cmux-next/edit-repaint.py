#!/usr/bin/env python3
"""Edit to repaint: how long after a file is saved the cmux NEXT window shows the change.

Three cases, each timed `--rounds` times on one launched bench app (BenchApp, its own cmux-next.json and
customize folder, never the account's):
- `theme`: cmux-next.json `appearance.themeFile` flips between two shipped theme files (phosphor, charcoal).
- `sidebar`: cmux-next.json `sidebar.density` flips between compact and expanded (four workspaces listed).
- `extension`: the customize folder's `main.js` (local/customize, a `cmux.section/1` sidebar section) is
  saved with a new headline; the daemon's watcher reloads it and the app redraws the section.

How a round is timed: five window snapshots (`debug.window_snapshot`, the window server's composite of the
main window, no page images) taken 0.25 s apart before the write mark the parts of the window that change
on their own (a blinking cursor, a spinner); those 32 px blocks are left out. Then the file is written in
place (open, write, close: an editor's in-place save) and snapshots are taken back to back for `--window`
seconds, each with the wall time its request went out and its reply came back. A snapshot shows the change
when at least `MIN_BLOCKS` other blocks differ from the last baseline. The round's numbers:
- `upper_ms`: the reply of the first snapshot that shows the change, after the write ended. The repaint
  happened before this snapshot was taken, so this bounds it from above.
- `lower_ms`: the request of the last snapshot before it, which did not show the change: the repaint came
  after that capture began.
A capture holds the main actor for about 50 ms, so the back-to-back snapshots can push a repaint later by up
to one capture; `snap_ms` (each round's median capture time) says how much.
Writes one `EDIT_REPAINT {json}` line per case and `--json` with every round.
"""
import argparse
import json
import os
import statistics
import struct
import subprocess
import sys
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
from bench_launch import BenchApp  # noqa: E402

BLOCK = 32          # px of the snapshot per block side
STEP = 4            # sample every 4th pixel in each direction
MIN_BLOCKS = 2      # changed blocks (outside the baseline mask) that make a change
PIXEL_DELTA = 24    # summed |dr|+|dg|+|db| over which a sample counts as changed
MIN_SAMPLES = 3     # changed samples that make a block changed

MANIFEST = {
    "manifestVersion": 2, "id": "local/customize", "name": "Edit repaint", "version": "1.0.0",
    "description": "A section whose headline the bench rewrites.", "engines": {"cmux": "^2.0"},
    "runtime": {"main": "main.js"},
    "implements": {"cmux.section/1": {"export": "renderSection", "title": "Edit repaint",
                                      "symbol": "bolt.horizontal", "options": {"defaultRegion": "bottom"}}},
}
HEADLINES = ["WWWWWWWW 0000", "iiiiiiii 1111"]


def main_js(headline):
    return ("// Written by scripts/cmux-next/edit-repaint.py.\n"
            "function renderSection() {\n"
            f"  return VStack({{ spacing: 2 }}, [Text({json.dumps(headline)}).font(\"headline\"),\n"
            f"    Row({{ title: {json.dumps(headline + ' row')}, symbol: \"bolt.horizontal\" }})])\n"
            "}\n")


def bmp(png):
    """(width, height, rows) of a PNG through sips, rows as bytes top-down, 3 or 4 bytes a pixel."""
    out = png[:-4] + ".bmp"
    subprocess.run(["sips", "-s", "format", "bmp", png, "--out", out], capture_output=True, check=True)
    data = open(out, "rb").read()
    os.unlink(out)
    offset, = struct.unpack_from("<I", data, 10)
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, = struct.unpack_from("<H", data, 28)
    step = bpp // 8
    row = (width * step + 3) & ~3
    rows = [data[offset + y * row: offset + y * row + width * step] for y in range(abs(height))]
    if height > 0:
        rows.reverse()  # a positive height is bottom-up
    return width, abs(height), step, rows


def blocks_changed(a, b):
    """The set of (bx, by) blocks where samples of image a and b differ."""
    width, height, step, rows_a = a
    _, _, _, rows_b = b
    if len(rows_a) != len(rows_b):
        return {"size"}
    counts = {}
    for y in range(0, height, STEP):
        ra, rb = rows_a[y], rows_b[y]
        if ra == rb:
            continue
        for x in range(0, width, STEP):
            i = x * step
            if abs(ra[i] - rb[i]) + abs(ra[i + 1] - rb[i + 1]) + abs(ra[i + 2] - rb[i + 2]) > PIXEL_DELTA:
                key = (x // BLOCK, y // BLOCK)
                counts[key] = counts.get(key, 0) + 1
    return {k for k, n in counts.items() if n >= MIN_SAMPLES}


class Round:
    def __init__(self, app, out, name):
        self.app, self.out, self.name = app, out, name
        self.n = 0

    def snap(self):
        self.n += 1
        path = os.path.join(self.out, f"{self.name}-{self.n:04d}.png")
        sent = time.time()
        reply = self.app.rpc("debug.window_snapshot", {"kind": "main", "path": path, "webviews": False}, timeout=30)
        back = time.time()
        if not isinstance(reply, dict) or "path" not in reply:
            raise SystemExit(f"edit-repaint: snapshot failed: {reply}")
        return {"path": path, "sent": sent, "back": back}

    def run(self, write, window):
        base = []
        for _ in range(5):
            base.append(self.snap())
            time.sleep(0.25)
        images = [bmp(s["path"]) for s in base]
        mask = set()
        for image in images[:-1]:
            mask |= blocks_changed(image, images[-1])
        reference = images[-1]
        started = time.time()
        write()
        written = time.time()
        shots = []
        while time.time() - written < window:
            shots.append(self.snap())
        found, last_unchanged = None, None
        for shot in shots:
            changed = blocks_changed(reference, bmp(shot["path"])) - mask
            shot["blocks"] = len(changed)
            if len(changed) >= MIN_BLOCKS:
                found = shot
                break
            last_unchanged = shot
        final = len(blocks_changed(reference, bmp(shots[-1]["path"])) - mask) if shots else 0
        for s in base + shots:
            if s is not found and s is not last_unchanged:
                os.unlink(s["path"])
        snap_ms = statistics.median([(s["back"] - s["sent"]) * 1000 for s in shots]) if shots else None
        row = {"write_ms": round((written - started) * 1000, 1), "mask_blocks": len(mask), "snaps": len(shots),
               "snap_ms": round(snap_ms, 1) if snap_ms else None, "final_blocks": final}
        if found:
            row["upper_ms"] = round((found["back"] - written) * 1000, 1)
            row["lower_ms"] = round(((last_unchanged["sent"] if last_unchanged else written) - written) * 1000, 1)
            row["blocks"] = found["blocks"]
            row["shot"] = os.path.basename(found["path"])
        return row


def summary(rows):
    upper = [r["upper_ms"] for r in rows if "upper_ms" in r]
    lower = [r["lower_ms"] for r in rows if "lower_ms" in r]
    if not upper:
        return {"n": 0, "missed": len(rows)}
    return {"n": len(upper), "missed": len(rows) - len(upper),
            "upper_median_ms": round(statistics.median(upper), 1), "upper_max_ms": max(upper),
            "lower_median_ms": round(statistics.median(lower), 1), "lower_max_ms": max(lower),
            "snap_median_ms": round(statistics.median([r["snap_ms"] for r in rows if r.get("snap_ms")]), 1)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--window", type=float, default=3.0, help="seconds of snapshots after each write")
    parser.add_argument("--cases", default="theme,sidebar,extension")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    customize = os.path.join(opts.out, "customize")
    os.makedirs(customize, exist_ok=True)
    config = {"appearance": {"backgroundOpacity": 1}, "sidebar": {"density": "compact"}}
    app = BenchApp(opts.app, out=opts.out, config=config, env={"CMUX_CUSTOMIZE_DIR": customize})
    result = {"host": os.uname().nodename, "app": opts.app, "rounds": opts.rounds, "window_s": opts.window,
              "method": "debug.window_snapshot back to back; see the module docstring", "cases": {}}
    try:
        app.launch()
        config_path = app.launched_env["CMUX_NEXT_CONFIG_FILE"]
        time.sleep(3)
        for _ in range(3):
            app.rpc("action.run", {"action": "workspace.newAtBottom", "focus": True})
            time.sleep(0.5)
        time.sleep(2)

        def save_config(update):
            def write():
                current = json.load(open(config_path))
                update(current)
                with open(config_path, "w") as f:
                    f.write(json.dumps(current, indent=2))
            return write

        cases = opts.cases.split(",")
        for case in cases:
            rows = []
            rnd = Round(app, opts.out, case)
            for i in range(opts.rounds):
                if case == "theme":
                    name = ["phosphor", "charcoal"][i % 2]
                    write = save_config(lambda c, n=name: c.setdefault("appearance", {}).__setitem__("themeFile", n))
                elif case == "sidebar":
                    density = ["expanded", "compact"][i % 2]
                    write = save_config(lambda c, d=density: c.setdefault("sidebar", {}).__setitem__("density", d))
                elif case == "extension":
                    if i == 0:
                        with open(os.path.join(customize, "cmux-app.json"), "w") as f:
                            json.dump(MANIFEST, f, indent=2)
                        with open(os.path.join(customize, "main.js"), "w") as f:
                            f.write(main_js("edit repaint ready"))
                        time.sleep(8)  # the section installs and draws once before the first timed save
                    js = main_js(HEADLINES[i % 2])

                    def write(js=js):
                        with open(os.path.join(customize, "main.js"), "w") as f:
                            f.write(js)
                else:
                    raise SystemExit(f"edit-repaint: unknown case {case}")
                row = rnd.run(write, opts.window)
                row["round"] = i
                rows.append(row)
                print(f"edit-repaint: {case} round {i}: {json.dumps(row)}", flush=True)
                time.sleep(1.0)
            stats = summary(rows)
            result["cases"][case] = {"summary": stats, "rounds": rows}
            print("EDIT_REPAINT " + json.dumps({"case": case, **stats}), flush=True)
            if case == "theme":  # the next cases run on the default look
                save_config(lambda c: c.get("appearance", {}).pop("themeFile", None))()
                time.sleep(2)
    finally:
        with open(opts.json, "w") as f:
            json.dump(result, f, indent=2)
        app.stop()


if __name__ == "__main__":
    main()
