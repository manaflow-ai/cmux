#!/usr/bin/env python3
"""Relaunch after an update, measured from the first frame: what moves, flashes or fills in after it.

Leo, 2026-11-04: "i feel like the restarted after nightly update does too many layout shifts/flicker renderings and
takes too long to reconnect acpmux or whatever". The budget: the first frame is the final frame.

Launches a tagged Debug (or bench) `cmux DEV <tag>.app` with a fresh state (BenchApp), then runs restore-journey.py
against it with `--record-launch`: the journey seeds a session (three windows, workspaces with uneven splits and
several tabs, terminals with scrollback, a counter and `top`, local web pages, agent chats on the fake agent), quits it
through the updater's relaunch path (`debug.updater relaunch`, what Sparkle runs before an update relaunch) and opens
the app again; the app records every window from its first frame (DebugWindowRecord), and launch_shift.py counts what
changed after it. The shown chat's page also reports its own layout_watch (transcript rows and composer moving after
the page first drew them). Runs `--rounds` relaunches in one journey (variants update,update,...).

  python3 scripts/cmux-next/relaunch-shift-bench.py --app "cmux DEV <tag>.app" [--out DIR] [--rounds 3]
      [--seconds 8] [--skip cloud] [--variants update]

Writes DIR/report.json ({"rounds": [launch-shift summary per relaunch], "median": {...}, "journey": rows}) and
DIR/report.md, and prints RELAUNCH-SHIFT {json}. Fleet entry: scripts/measure/relaunch-shift.sh.
"""
import argparse, glob, json, os, statistics, subprocess, sys, threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402  the one launch path
import launch_shift  # noqa: E402

KEYS = ["first_paint_ms", "last_paint_ms", "blank_first", "geometry_frames", "pixel_frames", "blank_frames",
        "layout_passes", "window_moves", "last_change_ms", "closed_while_recorded"]


def median_of(rounds):
    out = {}
    for key in KEYS:
        values = [r["total"].get(key) for r in rounds if isinstance(r.get("total", {}).get(key), (int, float))]
        out[key] = statistics.median(values) if values else None
    shifts = [len((r.get("chat") or {}).get("shifts") or []) for r in rounds if "first_content_ms" in (r.get("chat") or {})]
    out["chat_shifts"] = statistics.median(shifts) if shifts else None
    return out


def markdown(rounds, median):
    lines = ["| relaunch | " + " | ".join(KEYS) + " | chat shifts |", "|" + "---|" * (len(KEYS) + 2)]
    for n, r in enumerate(rounds, 1):
        chat = r.get("chat") or {}
        lines.append(f"| {n} | " + " | ".join(str(r["total"].get(k)) for k in KEYS) +
                     f" | {len(chat.get('shifts') or []) if 'first_content_ms' in chat else 'n/a'} |")
    lines.append("| median | " + " | ".join(str(median.get(k)) for k in KEYS) + f" | {median.get('chat_shifts')} |")
    for n, r in enumerate(rounds, 1):
        views = r["total"].get("views") or {}
        if views:
            lines.append(f"\nRelaunch {n}, views that moved after the first frame (frames): " +
                         ", ".join(f"{k} {v}" for k, v in views.items()))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "artifacts/relaunch-shift")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--seconds", type=float, default=8)
    parser.add_argument("--variants", default="update", help="the journey variant each round relaunches with")
    parser.add_argument("--skip", default="cloud", help="restore-journey seed parts to leave out")
    args = parser.parse_args()
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    # No test window frame: the relaunch must restore each window's own saved frame, not move it to a fixed one.
    app = BenchApp(args.app, out=out, window=None)
    app.launch()
    # The journey quits and relaunches this app: reap the first process when it ends, so it is not left a zombie that
    # still answers kill(pid, 0) and looks alive to the journey.
    threading.Thread(target=app.process.wait, daemon=True).start()
    journey_out = os.path.join(out, "journey")
    variants = ",".join([args.variants] * max(1, args.rounds))
    command = [sys.executable, os.path.join(HERE, "restore-journey.py"), "--socket", app.socket, "--allow-non-slot",
               "--variants", variants, "--record-launch", str(args.seconds), "--out", journey_out]
    if args.skip:
        command += ["--skip", args.skip]
    try:
        code = subprocess.run(command).returncode
    finally:
        app.stop()
    # The journey names each round's file after its variant, so repeated variants overwrite: read each recording.
    rounds = []
    for path in sorted(glob.glob(os.path.join(journey_out, "launch-shift-*.json")), key=lambda p: int(os.path.basename(p).split("-")[2])):
        with open(path) as f:
            rounds.append(json.load(f))
    median = median_of(rounds)
    rows = []
    try:
        with open(os.path.join(journey_out, "report.json")) as f:
            rows = json.load(f)
    except (OSError, ValueError):
        pass
    report = {"app": args.app, "rounds": rounds, "median": median, "journey_exit": code,
              "journey": [r for r in rows if r.get("area") in ("launch frames", "layout")]}
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)
    text = markdown(rounds, median)
    with open(os.path.join(out, "report.md"), "w") as f:
        f.write(text + "\n")
    print(text)
    print("RELAUNCH-SHIFT " + json.dumps(median))
    return 0 if rounds else 1


if __name__ == "__main__":
    sys.exit(main())
