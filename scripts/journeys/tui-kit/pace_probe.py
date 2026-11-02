#!/usr/bin/env python3
"""How evenly the 120 fps gradient paces on this host, per pacing variant (no terminal in between).

  pace_probe.py [--seconds 30] [--size 160x48] [--out DIR] [--only NAME,...]

Each variant runs `tuikit.py gradient` for --seconds with its output to /dev/null and its frame log in
DIR; one line per variant:

  TUI-KIT-PACE-VARIANT <name> frames=N in S s (target T) interval_ms p50 p95 p99 max
      late_over_one_frame=N late_ms p95 draw_ms p95 cpu=P% darwin_bg=yes|no

Variants: the gradient's --pace sleep, hybrid and spin, and `sleep` under wrappers that change timer
coalescing (taskpolicy throughput and latency tier 0, caffeinate -i). A wrapper missing on this host is
reported as skipped. `interval_ms` is between consecutive frame starts (monotonic), so 8.33 is 120 fps.
"""
import argparse
import json
import os
import resource
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, "tuikit.py")
VARIANTS = (
    ("sleep", [], "sleep"),
    ("hybrid", [], "hybrid"),
    ("spin", [], "spin"),
    ("taskpolicy-t0-l0+sleep", ["/usr/sbin/taskpolicy", "-t", "0", "-l", "0"], "sleep"),
    ("caffeinate-i+sleep", ["/usr/bin/caffeinate", "-i"], "sleep"),
)


def pct(values, q):
    return values[min(len(values) - 1, int(q * len(values)))] if values else 0.0


def darwin_bg():
    """Whether this process is in the Darwin background class (its children inherit it)."""
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        value = libc.getpriority(4, 0)  # PRIO_DARWIN_PROCESS
        if value == -1:
            return "err%d" % ctypes.get_errno()
        return "yes" if value & 0x1000 else "no"
    except (OSError, AttributeError):
        return "?"


def summarize(frames, seconds, cpu, wall):
    stamps = [e["mono"] for e in frames]
    gaps = sorted((b - a) * 1000 for a, b in zip(stamps, stamps[1:]))
    late = sorted(e["late_ms"] for e in frames)
    draw = sorted(e.get("draw_ms", 0.0) for e in frames)
    return {"frames": len(frames), "seconds": seconds, "target": int(round(seconds * 120)),
            "p50": pct(gaps, 0.5), "p95": pct(gaps, 0.95), "p99": pct(gaps, 0.99), "max": gaps[-1] if gaps else 0.0,
            "late_over_one_frame": sum(1 for v in late if v > 1000 / 120), "late_p95": pct(late, 0.95),
            "draw_p95": pct(draw, 0.95), "cpu": 100 * cpu / wall if wall else 0.0}


def line(name, r, bg):
    return ("TUI-KIT-PACE-VARIANT %s frames=%d in %g s (target %d) interval_ms p50=%.2f p95=%.2f p99=%.2f max=%.2f "
            "late_over_one_frame=%d late_ms p95=%.2f draw_ms p95=%.2f cpu=%.0f%% darwin_bg=%s"
            % (name, r["frames"], r["seconds"], r["target"], r["p50"], r["p95"], r["p99"], r["max"],
               r["late_over_one_frame"], r["late_p95"], r["draw_p95"], r["cpu"], bg))


def run_variant(name, wrap, pace, seconds, size, out):
    log = os.path.join(out, "pace-%s.jsonl" % name)
    if os.path.exists(log):
        os.remove(log)
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with open(os.devnull, "w") as sink:
        subprocess.run(wrap + [sys.executable, KIT, "gradient", "--seed", "1", "--size", size, "--duration",
                               str(seconds), "--pace", pace, "--log", log], stdout=sink, check=True)
    wall = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    with open(log) as f:
        frames = [e for e in map(json.loads, f) if e["ev"] == "frame"]
    return summarize(frames, seconds, cpu, wall)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--size", default="160x48")
    ap.add_argument("--out")
    ap.add_argument("--only", help="comma-separated variant names")
    a = ap.parse_args(argv)
    out = a.out or tempfile.mkdtemp(prefix="tuikit-pace-")
    os.makedirs(out, exist_ok=True)
    only = set(a.only.split(",")) if a.only else None
    bg = darwin_bg()
    results = {}
    for name, wrap, pace in VARIANTS:
        if only and name not in only:
            continue
        if wrap and not os.path.exists(wrap[0]):
            print("TUI-KIT-PACE-VARIANT %s skipped: no %s" % (name, wrap[0]), flush=True)
            continue
        results[name] = run_variant(name, wrap, pace, a.seconds, a.size, out)
        print(line(name, results[name], bg), flush=True)
    with open(os.path.join(out, "pace.json"), "w") as f:
        json.dump({"darwin_bg": bg, "results": results}, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
