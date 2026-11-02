#!/usr/bin/env python3
"""How evenly the 120 fps gradient paces on this host, per pacing variant (no terminal in between).

  pace_probe.py [--seconds 30] [--size 160x48] [--out DIR] [--only NAME,...]

Each variant runs `tuikit.py gradient` for --seconds with its output to /dev/null and its frame log in
DIR; one line per variant:

  TUI-KIT-PACE-VARIANT <name> frames=N in S s (target T) interval_ms p50 p95 p99 max late_over_one_frame=N
      late_ms p95 hist before_over_one_frame draw_ms p95 max cpu=P% csw_voluntary csw_involuntary darwin_bg

Variants: the gradient's --pace sleep, hybrid and spin; `sleep` under taskpolicy throughput and latency
tier 0, under `taskpolicy -B -p PID` (out of the background class), under caffeinate -i; `sleep` again
last. A missing tool is "skipped", a variant that could not run "failed" (the others still run).
`interval_ms` is between consecutive frame starts (monotonic), so 8.33 is 120 fps; `hist` buckets each
frame's late_ms; `before_over_one_frame` counts frames already late before their wait (the frame before
took too long); csw_* are the gradient's context switches (involuntary: it was preempted).
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
sys.path.insert(0, HERE)
from tuikit import darwin_bg, rust_bin  # noqa: E402
# (name, wrapper argv, --pace, after-start hook). taskpolicy -B (leave the background class) takes only
# a pid, so that variant runs it on the gradient's pid once it started. `sleep` runs again last, so a cold
# first run shows as a difference between the two.
# The Python engine's variants keep the evidence that led to spin and to compiled code; the rust-*
# variants are the compiled tk-gradient (tuikit.py build-bins), "skipped" when it is not built.
VARIANTS = (
    ("sleep", [], "sleep", None),
    ("hybrid", [], "hybrid", None),
    ("spin", [], "spin", None),
    ("taskpolicy-t0-l0+sleep", ["/usr/sbin/taskpolicy", "-t", "0", "-l", "0"], "sleep", None),
    ("taskpolicy-B-pid+sleep", [], "sleep", ["/usr/sbin/taskpolicy", "-B", "-p"]),
    ("caffeinate-i+sleep", ["/usr/bin/caffeinate", "-i"], "sleep", None),
    ("sleep-again", [], "sleep", None),
    ("rust-spin", [], "spin", None),
    ("rust-hybrid", [], "hybrid", None),
    ("rust-sleep", [], "sleep", None),
)
BUCKETS = (1, 4, 8.34, 16.7, 33.4)  # late_ms histogram edges


def pct(values, q):
    return values[min(len(values) - 1, int(q * len(values)))] if values else 0.0


def histogram(values):
    counts = [0] * (len(BUCKETS) + 1)
    for v in values:
        counts[sum(1 for edge in BUCKETS if v >= edge)] += 1
    labels = ["<1"] + ["%g-%g" % (a, b) for a, b in zip(BUCKETS, BUCKETS[1:])] + [">=%g" % BUCKETS[-1]]
    return ",".join("%s:%d" % (label, n) for label, n in zip(labels, counts))


def summarize(frames, seconds, cpu, wall, switches=(0, 0)):
    stamps = [e["mono"] for e in frames]
    gaps = sorted((b - a) * 1000 for a, b in zip(stamps, stamps[1:]))
    late = sorted(e["late_ms"] for e in frames)
    draw = sorted(e.get("draw_ms", 0.0) for e in frames)
    return {"frames": len(frames), "seconds": seconds, "target": int(round(seconds * 120)),
            "p50": pct(gaps, 0.5), "p95": pct(gaps, 0.95), "p99": pct(gaps, 0.99), "max": gaps[-1] if gaps else 0.0,
            "late_over_one_frame": sum(1 for v in late if v > 1000 / 120), "late_p95": pct(late, 0.95),
            "draw_p95": pct(draw, 0.95), "draw_max": draw[-1] if draw else 0.0, "late_hist": histogram(late),
            "before_over_one_frame": sum(1 for e in frames if e.get("before_ms", 0) > 1000 / 120),
            "cpu": 100 * cpu / wall if wall else 0.0, "nvcsw": switches[0], "nivcsw": switches[1]}


def line(name, r):
    return ("TUI-KIT-PACE-VARIANT %s frames=%d in %g s (target %d) interval_ms p50=%.2f p95=%.2f p99=%.2f max=%.2f "
            "late_over_one_frame=%d late_ms p95=%.2f hist=%s before_over_one_frame=%d draw_ms p95=%.2f max=%.2f "
            "cpu=%.0f%% csw_voluntary=%d csw_involuntary=%d darwin_bg=%s engine=%s achieved_fps=%.2f verdict=%s"
            % (name, r["frames"], r["seconds"], r["target"], r["p50"], r["p95"], r["p99"], r["max"],
               r["late_over_one_frame"], r["late_p95"], r["late_hist"], r["before_over_one_frame"], r["draw_p95"],
               r["draw_max"], r["cpu"], r["nvcsw"], r["nivcsw"], r.get("darwin_bg", "?"), r.get("engine", "?"),
               r.get("achieved_fps") or 0.0, str(r.get("verdict", "?")).replace(" ", "_")))


def read_log(log):
    with open(log) as f:
        events = [json.loads(line) for line in f]
    end = next((e for e in events if e["ev"] == "end"), {})
    return [e for e in events if e["ev"] == "frame"], end


def run_variant(name, wrap, pace, hook, seconds, size, out):
    engine = "rust" if name.startswith("rust-") else "python"
    """The variant's summary, or {"error": ...} when it could not run (the others still run)."""
    log = os.path.join(out, "pace-%s.jsonl" % name)
    if os.path.exists(log):
        os.remove(log)
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    argv = wrap + [sys.executable, KIT, "gradient", "--seed", "1", "--size", size, "--duration", str(seconds),
                   "--pace", pace, "--log", log, "--engine", engine]
    hooked = None
    with open(os.devnull, "w") as sink:
        proc = subprocess.Popen(argv, stdout=sink)
        if hook:
            hooked = subprocess.run(hook + [str(proc.pid)], capture_output=True, text=True)
        code = proc.wait()
    wall = time.monotonic() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if code != 0:
        return {"error": "gradient exit %d" % code}
    if hooked is not None and hooked.returncode != 0:
        return {"error": "%s exit %d: %s" % (hook[0], hooked.returncode, (hooked.stderr or "").strip()[:120])}
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    switches = (after.ru_nvcsw - before.ru_nvcsw, after.ru_nivcsw - before.ru_nivcsw)
    frames, ended = read_log(log)
    result = summarize(frames, seconds, cpu, wall, switches)
    result["darwin_bg"] = ended.get("darwin_bg", "?")  # the gradient's own class at its end (after any hook)
    result["engine"] = ended.get("engine", "?")
    result["verdict"] = ended.get("verdict", "?")  # the program's own: ok, or NOT RUN below 95 % of 120 fps
    result["achieved_fps"] = ended.get("achieved_fps", 0.0)
    return result


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
    results = {}
    for name, wrap, pace, hook in VARIANTS:
        if only and name not in only:
            continue
        if name.startswith("rust-") and not rust_bin("tk-gradient"):
            print("TUI-KIT-PACE-VARIANT %s skipped: tk-gradient is not built (tuikit.py build-bins)" % name, flush=True)
            continue
        tool = (wrap or hook or [None])[0]
        if tool and not os.path.exists(tool):
            print("TUI-KIT-PACE-VARIANT %s skipped: no %s" % (name, tool), flush=True)
            continue
        results[name] = run_variant(name, wrap, pace, hook, a.seconds, a.size, out)
        if "error" in results[name]:
            print("TUI-KIT-PACE-VARIANT %s failed: %s" % (name, results[name]["error"]), flush=True)
        else:
            print(line(name, results[name]), flush=True)
    with open(os.path.join(out, "pace.json"), "w") as f:
        json.dump({"probe_darwin_bg": darwin_bg(), "results": results}, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
