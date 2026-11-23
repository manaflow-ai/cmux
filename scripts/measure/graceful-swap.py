#!/usr/bin/env python3
"""Measures what a web bundle swap shows: does an open page visibly reload when the web it runs changes?

  graceful-swap.py record --host air-blue --trigger 'CMD' --out DIR [--label before]
                          [--region NAME=x,y,w,h ...] [--pre 1.5] [--post 4] [--probe-file PATH]
  graceful-swap.py latency --host H --trigger 'SAVE' [--trigger-b 'UNDO'] --watch NAME --runs 20 --out DIR --region ...
  graceful-swap.py analyze MOVIE.mp4 --marks MARKS.txt --out DIR [--region ...] [--probe PROBE.ndjson]

`record` films the capture Mac's main display with Cua Driver's ScreenCaptureKit recorder (it holds the
Screen Recording grant; ffmpeg or screencapture over SSH have none), runs TRIGGER there in a shell
`--pre` seconds in (a swap: `cmux customize try ...`, `web-overlay.sh install-app APP`, a socket call
to `updates.web.apply`), keeps filming `--post` seconds, copies the movie back and analyzes it. The
recorder films at up to 30 fps (variable: 10-22 fps measured on air-blue, at the display's point size), so
a blank lasting a few 60 Hz frames shows; a one-frame one can fall between captures.

`analyze` compares every frame after the trigger, per region (video pixels; the whole frame without
any), against the region before the trigger and at the end:

  transient_frames  frames that match neither the before nor the end picture: what a person sees as a
                    reload (a blank, a skeleton, a half-drawn page, a jump that comes back)
  blank_frames      frames much flatter than before (a cleared page, an empty pane)
  changed_frames    frames that differ from before at all
  kept              whether the end picture is the before picture. A trigger that swaps in the SAME
                    web (`web-overlay.sh install-app` of the app's own bundle) must keep it: a lost
                    draft, attachment, scroll place or folded row shows here
  end_diff          the share of the region's pixels that changed between before and end
  shift_px          the vertical offset that best maps the end picture onto the before one (layout
                    shift / scroll jump), 0 when none fits better than none
  first_change_ms, settled_ms   from the trigger to the first changed frame and to the last frame
                    that still differs from the end picture
  probe             the in-page probe's `swap` records (webviews/src/pages/shared/swapProbe.ts) written
                    after the trigger: composer text, selection, focus, attachments, scroll kept,
                    layout-shift sum and the time to the restored first frame, per page

Prints one line `GRACEFUL_SWAP {json}` and writes DIR/run.json (the bench `graceful-swap` reads
either). With --frames-dir every transient frame is kept as a PNG for a frame-by-frame look.
Needs ffmpeg and ffprobe; no Python packages.
"""

from __future__ import annotations

import argparse
import json
import shlex
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

VERSION = "1"
# Downscale before comparing: video pixels per sample (a 2x display: 2 points). Text stays legible
# enough that a lost line of a draft changes many samples, and a caret's blink changes almost none.
SCALE = 4
# A sample changed when it moved by more than this (0..255 gray).
PIXEL_DELTA = 24
# A frame differs from another when more than this share of its samples changed (a blinking caret,
# a spinner or a cursor stay under it).
FRAME_DIFF = 0.004
MAX_SHIFT = 48  # samples

RUNNER = r'''
import json, os, subprocess, sys, time
pre, post, trigger, out = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3], os.path.expanduser(sys.argv[4])
driver = subprocess.Popen([os.path.expanduser("~/.local/bin/cua-driver"), "mcp"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
ids = iter(range(1, 1 << 30))
def rpc(method, params=None, notify=False):
    message = {"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}
    if not notify: message["id"] = next(ids)
    driver.stdin.write(json.dumps(message) + "\n"); driver.stdin.flush()
    while not notify:
        line = driver.stdout.readline()
        if not line: sys.exit("cua-driver mcp closed")
        reply = json.loads(line)
        if reply.get("id") == message["id"]:
            if "error" in reply or reply.get("result", {}).get("isError"):
                sys.exit(f"{params}: {json.dumps(reply)[:300]}")
            return reply
rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "graceful-swap", "version": "1"}})
rpc("notifications/initialized", notify=True)
rpc("tools/call", {"name": "set_agent_cursor_enabled", "arguments": {"enabled": False}})
rpc("tools/call", {"name": "start_recording", "arguments": {"output_dir": out, "record_video": True, "include_accessibility_tree": False}})
start = time.time()
print("start 0.000", flush=True)
time.sleep(pre)
print("trigger %.3f" % (time.time() - start), flush=True)
done = subprocess.run(["/bin/zsh", "-lc", trigger], capture_output=True, text=True, timeout=120)
print("trigger-returned %.3f %d" % (time.time() - start, done.returncode), flush=True)
sys.stderr.write(done.stdout[-2000:] + done.stderr[-2000:])
time.sleep(post)
print("stop %.3f" % (time.time() - start), flush=True)
rpc("tools/call", {"name": "stop_recording", "arguments": {}})
'''


def parse_region(text: str) -> tuple[str, tuple[int, int, int, int]]:
    name, _, rect = text.partition("=")
    parts = [int(float(v)) for v in rect.split(",")]
    if len(parts) != 4 or not name:
        raise argparse.ArgumentTypeError(f"region {text!r}: NAME=x,y,w,h")
    return name, (parts[0], parts[1], parts[2], parts[3])


def probe_video(movie: Path) -> tuple[int, int, float, float]:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,r_frame_rate,avg_frame_rate:format=duration", "-of", "json", str(movie)],
                         capture_output=True, text=True, check=True)
    info = json.loads(out.stdout)
    stream = info["streams"][0]
    num, _, den = (stream.get("avg_frame_rate") or stream["r_frame_rate"]).partition("/")
    fps = float(num) / float(den or 1) if float(num) else 30.0
    return int(stream["width"]), int(stream["height"]), fps, float(info["format"].get("duration", 0))


def frames(movie: Path, rect: tuple[int, int, int, int]) -> tuple[list[bytes], list[float], int, int]:
    """Gray samples of `rect` per frame and each frame's time (s)."""
    x, y, w, h = rect
    sw, sh = max(1, w // SCALE), max(1, h // SCALE)
    # showinfo prints each frame's pts_time at info level: "-v error" hid it, and frame index / average fps put
    # the recorder's frames (written only when the screen changes) at the wrong times, about 1 s late.
    proc = subprocess.run(["ffmpeg", "-hide_banner", "-v", "info", "-i", str(movie), "-vf",
                           f"crop={w}:{h}:{x}:{y},scale={sw}:{sh}:flags=area,format=gray,showinfo",
                           "-fps_mode", "passthrough", "-f", "rawvideo", "-"],
                          capture_output=True, check=True)
    size = sw * sh
    data = proc.stdout
    out = [data[i:i + size] for i in range(0, len(data) - size + 1, size)]
    times = []
    for line in proc.stderr.decode(errors="replace").splitlines():
        if "pts_time:" in line:
            times.append(float(line.split("pts_time:")[1].split()[0]))
    if len(times) != len(out):
        # A variable-rate film has no frame time but its own: never guess one from the average rate.
        raise SystemExit(f"{movie}: ffmpeg gave {len(times)} frame times for {len(out)} frames")
    return out, times, sw, sh


def changed_share(a: bytes, b: bytes) -> float:
    if not a:
        return 0.0
    return sum(1 for p, q in zip(a, b) if abs(p - q) > PIXEL_DELTA) / len(a)


def spread(a: bytes) -> float:
    return statistics.pstdev(a) if a else 0.0


def best_shift(before: bytes, after: bytes, w: int, h: int) -> int:
    """The vertical offset (samples) that maps `after` onto `before` best; 0 unless clearly better."""
    def cost(dy: int) -> float:
        rows = range(max(0, dy), min(h, h + dy))
        total = count = 0
        for r in rows[::2]:
            a = before[r * w:(r + 1) * w]
            b = after[(r - dy) * w:(r - dy + 1) * w]
            total += sum(1 for p, q in zip(a, b) if abs(p - q) > PIXEL_DELTA)
            count += w
        return total / count if count else 1.0
    base = cost(0)
    if base < FRAME_DIFF:
        return 0
    best, at = base, 0
    for dy in range(-min(MAX_SHIFT, h // 3), min(MAX_SHIFT, h // 3) + 1):
        if dy and (c := cost(dy)) < best:
            best, at = c, dy
    return at if best < base * 0.5 else 0


def write_png(path: Path, data: bytes, w: int, h: int) -> None:
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{w}x{h}",
                    "-i", "-", str(path)], input=data, check=True)


def analyze_region(movie: Path, name: str, rect, trigger: float, frames_dir: Path | None) -> dict:
    samples, times, w, h = frames(movie, rect)
    if not samples:
        return {"error": "no frames"}
    before_idx = [i for i, t in enumerate(times) if trigger - 0.6 <= t <= trigger - 0.1] or [0]
    before = samples[before_idx[-1]]
    # The end picture: a few frames before the last (an encoder's final frame can differ).
    end = max(0, len(samples) - 4)
    after = samples[end]
    after_idx = [i for i, t in enumerate(times) if t >= trigger and i <= end]
    base_spread = spread(before)
    transient, blank, changed = [], [], []
    for i in after_idx:
        f = samples[i]
        d_before, d_after = changed_share(f, before), changed_share(f, after)
        if d_before > FRAME_DIFF:
            changed.append(i)
            if d_after > FRAME_DIFF:
                transient.append(i)
        if base_spread > 8 and spread(f) < base_spread * 0.35:
            blank.append(i)
    unsettled = [i for i in after_idx if changed_share(samples[i], after) > FRAME_DIFF]
    end_diff = changed_share(before, after)
    if frames_dir:
        frames_dir.mkdir(parents=True, exist_ok=True)
        write_png(frames_dir / f"{name}-before.png", before, w, h)
        write_png(frames_dir / f"{name}-end.png", after, w, h)
        for i in transient[:60]:
            write_png(frames_dir / f"{name}-t{int((times[i] - trigger) * 1000):05d}ms.png", samples[i], w, h)
    ms = lambda i: round((times[i] - trigger) * 1000)
    return {
        "rect": list(rect),
        "frames_after_trigger": len(after_idx),
        "transient_frames": len(transient),
        "blank_frames": len(blank),
        "changed_frames": len(changed),
        "kept": end_diff <= FRAME_DIFF,
        "end_diff": round(end_diff, 5),
        "shift_px": best_shift(before, after, w, h) * SCALE,
        "first_change_ms": ms(changed[0]) if changed else None,
        "settled_ms": ms(unsettled[-1]) if unsettled else 0,
        "transient_at_ms": [ms(i) for i in transient],
    }


def read_marks(path: Path) -> dict[str, float]:
    marks = {}
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2:
            try:
                marks[parts[0]] = float(parts[1])
            except ValueError:
                pass
    return marks


def read_probe(path: Path | None, since_epoch_ms: float | None) -> list[dict]:
    if not path or not path.exists():
        return []
    out = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("kind") != "swap":
            continue
        if since_epoch_ms and record.get("at", 0) < since_epoch_ms:
            continue
        out.append(record)
    return out


def analyze(movie: Path, marks_path: Path, regions: list, out: Path, label: str, trigger_text: str,
            probe: Path | None, frames_dir: Path | None, trigger_epoch_ms: float | None = None) -> dict:
    width, height, fps, duration = probe_video(movie)
    marks = read_marks(marks_path)
    # The recorder starts a moment after the runner's clock does: the first frame is ~0. Its offset
    # is under one frame on Cua Driver 0.32, inside the 100 ms margin the before picture keeps.
    trigger = marks.get("trigger", 1.5)
    regions = regions or [("window", (0, 0, width, height))]
    # Cua Driver 0.32 films the display at its POINT size (1440x932 on a 2x MacBook Air), not its
    # backing pixels: a rect given in backing pixels falls off the frame and ffmpeg's crop fails.
    # Refuse such a rect with the frame size, instead of a CalledProcessError from ffmpeg.
    # Keep a sample ~2 display points whether the movie is in backing pixels or in points.
    global SCALE
    SCALE = 4 if width > 2000 else 2
    for name, (x, y, w, h) in regions:
        if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > width or y + h > height:
            sys.exit(f"region {name}={x},{y},{w},{h} is outside the {width}x{height} video "
                     f"(regions are in video pixels; this recorder films the display at its point size)")
    result = {
        "version": VERSION, "label": label, "trigger": trigger_text, "movie": str(movie),
        "video": {"width": width, "height": height, "fps": round(fps, 2), "seconds": round(duration, 2)},
        "trigger_returned_s": round(marks.get("trigger-returned", trigger) - trigger, 3),
        "regions": {name: analyze_region(movie, name, rect, trigger, frames_dir) for name, rect in regions},
        "probe": read_probe(probe, trigger_epoch_ms),
    }
    totals = [r for r in result["regions"].values() if "error" not in r]
    result["ok"] = all(r["transient_frames"] == 0 and r["blank_frames"] == 0 and r["kept"] and r["shift_px"] == 0
                       for r in totals) and all(p.get("kept", True) for p in result["probe"])
    out.mkdir(parents=True, exist_ok=True)
    (out / "run.json").write_text(json.dumps(result, indent=2) + "\n")
    print("GRACEFUL_SWAP " + json.dumps(result, separators=(",", ":")))
    return result


class FilmMissing(Exception):
    """The recorder wrote no film for a run (its reason)."""


def record(args, trigger: str | None = None, out: Path | None = None) -> dict:
    trigger = trigger or args.trigger
    out = out or args.out
    out.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%S")
    remote = f"~/graceful-swap/{args.label}-{stamp}"
    with tempfile.TemporaryDirectory() as scratch:
        runner = Path(scratch, "graceful-swap-runner.py")
        runner.write_text(RUNNER)
        subprocess.run(["scp", "-q", str(runner), f"{args.host}:/tmp/graceful-swap-runner.py"], check=True)
    trigger_epoch_ms = (time.time() + args.pre) * 1000 - 2000  # probe records from shortly before the trigger
    cmd = " ".join(shlex.quote(v) for v in ["python3", "/tmp/graceful-swap-runner.py", str(args.pre), str(args.post),
                                             trigger, remote])
    run = subprocess.run(["ssh", args.host, cmd], capture_output=True, text=True, timeout=600)
    (out / "marks.txt").write_text(run.stdout)
    (out / "trigger.log").write_text(run.stderr)
    if run.returncode:
        sys.exit(f"record failed: {run.stderr.strip()[-800:]}")
    movie = out / "recording.mp4"
    if subprocess.run(["scp", "-q", f"{args.host}:{remote}/recording.mp4", str(movie)]).returncode:
        # The recorder wrote no film (ScreenCaptureKit said "no displays available" for one run on air-blue,
        # 2026-11-22): its session.json says why. The trigger did run, so a latency series counts it as missed
        # and goes on with the next save instead of ending.
        session = subprocess.run(["ssh", args.host, f"cat {remote}/session.json"], capture_output=True, text=True)
        try:
            why = json.loads(session.stdout).get("video", {}).get("error") or "no recording.mp4"
        except ValueError:
            why = "no recording.mp4"
        raise FilmMissing(why)
    probe = None
    if args.probe_file:
        probe = out / "probe.ndjson"
        subprocess.run(["scp", "-q", f"{args.host}:{shlex.quote(args.probe_file)}", str(probe)], check=False)
    return analyze(movie, out / "marks.txt", args.region, out, args.label, trigger, probe,
                   args.frames_dir or out / "frames", trigger_epoch_ms)


def percentile(values: list[float], q: float) -> float | None:
    """Nearest-rank percentile (q in 0..100) of `values`, None when empty."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * q // 100))
    return ordered[int(rank) - 1]


def latency(args) -> dict:
    """Edit-to-visible: `--runs` films, each one save (`--trigger`, then `--trigger-b` on odd runs to undo it),
    timed to the first frame the `--watch` region changed in; every other region must keep its picture (a
    draft, a chip, a streaming turn's text outside the edit). The film's frame rate bounds the resolution."""
    runs = []
    for i in range(args.runs):
        trigger = args.trigger_b if (i % 2 and args.trigger_b) else args.trigger
        try:
            result = record(args, trigger, args.out / f"run-{i:02d}")
        except FilmMissing as missing:
            print(f"run {i}: no film ({missing}); counted as missed", file=sys.stderr)
            result = {"video": {"fps": None}, "regions": {}, "film_missing": str(missing)}
        runs.append(result)
    regions = {name for name, _ in args.region}
    summary: dict = {"version": VERSION, "label": args.label, "runs": len(runs), "watch": args.watch,
                     "surface": args.surface,
                     "fps": [r["video"]["fps"] for r in runs], "regions": {}}
    for name in sorted(regions):
        rows = [r["regions"].get(name, {}) for r in runs]
        if name == args.watch:
            seen = [float(r["first_change_ms"]) for r in rows if r.get("first_change_ms") is not None]
            summary["regions"][name] = {"n": len(seen), "missed": len(rows) - len(seen),
                                        "p50_ms": percentile(seen, 50), "p95_ms": percentile(seen, 95),
                                        "max_ms": max(seen) if seen else None, "samples_ms": seen}
        else:
            kept = [bool(r.get("kept")) for r in rows]
            summary["regions"][name] = {"n": len(kept), "kept": sum(kept), "lost": len(kept) - sum(kept),
                                        "transient_frames": sum(r.get("transient_frames", 0) for r in rows)}
    (args.out / "latency.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("GRACEFUL_SWAP_LATENCY " + json.dumps(summary, separators=(",", ":")))
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--host", required=True)
    rec.add_argument("--trigger", required=True, help="shell command run on the host mid-recording")
    rec.add_argument("--out", type=Path, required=True)
    rec.add_argument("--label", default="run")
    rec.add_argument("--region", type=parse_region, action="append", default=[])
    rec.add_argument("--pre", type=float, default=1.5)
    rec.add_argument("--post", type=float, default=4.0)
    rec.add_argument("--probe-file", help="the app's agent-page-flicker.ndjson on the host")
    rec.add_argument("--frames-dir", type=Path)
    lat = sub.add_parser("latency", help="edit-to-visible p50/p95 over --runs saves")
    lat.add_argument("--host", required=True)
    lat.add_argument("--trigger", required=True, help="the save that makes the change (run on the host)")
    lat.add_argument("--trigger-b", help="the save that undoes it, run on odd runs")
    lat.add_argument("--watch", required=True, help="the region the change shows in")
    lat.add_argument("--runs", type=int, default=20)
    lat.add_argument("--out", type=Path, required=True)
    lat.add_argument("--label", default="latency")
    lat.add_argument("--surface", choices=("focused", "unfocused", "hidden"),
                     help="which bar the watched region answers to (the bench's hot_swap_mac_* row)")
    lat.add_argument("--region", type=parse_region, action="append", default=[])
    lat.add_argument("--pre", type=float, default=1.0)
    lat.add_argument("--post", type=float, default=2.5)
    lat.add_argument("--probe-file")
    lat.add_argument("--frames-dir", type=Path)
    ana = sub.add_parser("analyze")
    ana.add_argument("movie", type=Path)
    ana.add_argument("--marks", type=Path, required=True)
    ana.add_argument("--out", type=Path, required=True)
    ana.add_argument("--label", default="run")
    ana.add_argument("--trigger-text", default="")
    ana.add_argument("--region", type=parse_region, action="append", default=[])
    ana.add_argument("--probe", type=Path)
    ana.add_argument("--frames-dir", type=Path)
    args = parser.parse_args()
    if args.cmd == "record":
        record(args)
    elif args.cmd == "latency":
        latency(args)
    else:
        analyze(args.movie, args.marks, args.region, args.out, args.label, args.trigger_text, args.probe,
                args.frames_dir)


if __name__ == "__main__":
    main()
