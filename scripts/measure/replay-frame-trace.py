#!/usr/bin/env python3
"""What filled each slow frame of a replay-under-load trace, on every thread of the frame pipeline.

    scripts/measure/replay-frame-trace.py TRACE.json [TRACE.json ...] [--slow-ms 20] [--json OUT]

Each TRACE is `bench/replay-under-load.bench.ts --trace FILE --trace-frames` output ({profile, trace}). The page's frame
tally reads the gap between animation frames; here a frame starts where the renderer main thread's first
FireAnimationFrame of a BeginMainFrame starts, so a gap is the same rAF-to-rAF time. For every gap of at least --slow-ms
(a frame that missed its vsync: 33.3 ms reads as two), the time between the two frames is split:

  main thread    exclusive wall time by kind (script, style, layout, paint, gc, parse, other; style or layout inside
                 script is forced) and the time it ran nothing (idle); the wall time its tasks spent off-CPU (wall less
                 the trace's thread time: the CPU under 4x load ran something else) is `descheduled`
  other threads  busy wall time on the compositor, raster workers, the GPU process's main thread and viz compositor
  vsyncs         the compositor's BeginFrames inside the gap, and whether the main frame it asked for was late
  functions      the CPU profile's self time on the main thread inside slow frames, by function@bundle:line

and each slow frame is put down to its biggest bucket. Prints the buckets over all slow frames, the dominant causes
by frame count, and the hottest functions. Measuring only: the trace's own cost makes the run's p95 read high.
"""
from __future__ import annotations

import argparse
import bisect
import importlib.util
import json
import os
import sys
from collections import Counter, defaultdict

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("replay_attribution", os.path.join(_here, "replay-attribution.py"))
attr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(attr)  # type: ignore[union-attr]

MAIN = "CrRendererMain"
THREAD_GROUPS = {
    "Compositor": "compositor",
    "CrGpuMain": "gpu main",
    "VizCompositorThread": "viz compositor",
    "CrBrowserMain": "browser main",
}
TASKS = set(attr.TASK_NAMES)
# Off the main thread a thread's busy time is its tasks: the sequence manager's, the raster workers' task graph.
OTHER_TASKS = TASKS | {"ThreadPool_RunTask", "TaskGraphRunner::RunTask", "RasterTask"}
FRAME_START = "FireAnimationFrame"
BEGIN_FRAME = {"BeginFrame", "Scheduler::BeginFrame", "Scheduler::BeginImplFrame"}
DROPPED = {"DroppedFrame", "Scheduler::MissedBeginFrame"}


def group_of(name: str | None) -> str | None:
    if not name:
        return None
    if name == MAIN:
        return "main"
    if name in THREAD_GROUPS:
        return THREAD_GROUPS[name]
    if name.startswith("CompositorTileWorker"):
        return "raster"
    return None


def read(path: str) -> tuple[dict, dict, list[dict]]:
    """(profile, {(pid, tid): group}, slim events on those threads): one pass names the threads, a second keeps what
    the frame split reads (complete events with their thread time, BeginFrame instants)."""
    names: dict[tuple, str] = {}
    count: Counter = Counter()

    def scan(e: dict) -> bool:
        if e.get("ph") == "M" and e.get("name") == "thread_name":
            names[(e.get("pid"), e.get("tid"))] = (e.get("args") or {}).get("name") or ""
        elif e.get("ph") == "X":
            count[(e.get("pid"), e.get("tid"))] += 1
        return False

    attr.load(path, scan)
    mains = [pt for pt, n in names.items() if n == MAIN]
    if not mains:
        return {}, {}, []
    main = max(mains, key=lambda pt: count.get(pt, 0))
    groups = {pt: g for pt, n in names.items() if (g := group_of(n)) and g != "main"}
    groups[main] = "main"

    st, profile, kept = attr._Stream(path), None, []
    for key in st.items():
        if key == "profile":
            profile = st.value()
            continue
        for e in attr._events(st, key):
            pt = (e.get("pid"), e.get("tid"))
            g = groups.get(pt)
            if g is None:
                continue
            ph = e.get("ph")
            name = e.get("name")
            if ph == "X" and "dur" in e:
                # Off the main thread only the tasks count (busy time); on it, every event (the kind split).
                if g != "main" and name not in OTHER_TASKS and name not in BEGIN_FRAME and name not in DROPPED:
                    continue
                d = (e.get("args") or {}).get("data") or {}
                slim = {k: d[k] for k in ("functionName", "type", "name", "url") if d.get(k)}
                kept.append({"g": g, "name": name, "ph": "X", "ts": e["ts"], "dur": e["dur"], "tdur": e.get("tdur"),
                             "pid": pt[0], "tid": pt[1], "args": {"data": slim}})
            elif ph in ("I", "i", "n") and (name in BEGIN_FRAME or name in DROPPED):
                kept.append({"g": g, "name": name, "ph": "I", "ts": e["ts"], "dur": 0})
    st.f.close()
    return profile or {}, groups, kept


def frame_starts(main_ev: list[dict]) -> list[int]:
    """One start per BeginMainFrame: the first FireAnimationFrame of each run of them (one frame's callbacks fire back
    to back inside one task)."""
    starts: list[int] = []
    last_end = -1
    for e in main_ev:
        if e["name"] != FRAME_START:
            continue
        if e["ts"] > last_end + 1000:  # more than 1 ms after the previous callback: a new frame
            starts.append(e["ts"])
        last_end = max(last_end, e["ts"] + e["dur"])
    return starts


def busy(intervals: list[tuple[int, int]], a: int, b: int) -> float:
    """Wall µs of [a, b) the (possibly overlapping) intervals cover."""
    cut = sorted((max(x, a), min(y, b)) for x, y in intervals if y > a and x < b)
    total, at = 0, a
    for x, y in cut:
        x = max(x, at)
        if y > x:
            total += y - x
            at = y
    return float(total)


def analyze(path: str, slow_ms: float) -> dict:
    profile, groups, ev = read(path)
    if not groups:
        return {"file": path, "error": "no CrRendererMain in the trace"}
    main_ev = sorted((e for e in ev if e["g"] == "main" and e["ph"] == "X"), key=lambda e: (e["ts"], -e["dur"]))
    starts = frame_starts(main_ev)
    if len(starts) < 10:
        return {"file": path, "error": f"only {len(starts)} animation frames in the trace"}
    gaps = [(starts[i], starts[i + 1]) for i in range(len(starts) - 1)]
    slow = [(a, b) for a, b in gaps if b - a >= slow_ms * 1000]

    # Main thread top-level tasks (non-overlapping) and their nested events.
    tasks, end = [], -1
    for e in main_ev:
        if e["name"] in TASKS and e["ts"] >= end:
            tasks.append(e)
            end = e["ts"] + e["dur"]
    t_starts = [t["ts"] for t in tasks]
    m_starts = [e["ts"] for e in main_ev]
    other: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for e in ev:
        if e["g"] != "main" and e["ph"] == "X" and e["name"] in OTHER_TASKS:
            other[e["g"]].append((e["ts"], e["ts"] + e["dur"]))
    vsync = sorted(e["ts"] for e in ev if e["g"] == "compositor" and e["name"] in BEGIN_FRAME)
    dropped = sorted(e["ts"] for e in ev if e["name"] in DROPPED)

    # CPU profile samples (main thread only: the profile is the page's V8 isolate).
    by_id = {n["id"]: n for n in profile.get("nodes", [])}
    parent = {c: n["id"] for n in profile.get("nodes", []) for c in n.get("children", [])}
    t, samples = profile.get("startTime", 0), []
    for sid, dt in zip(profile.get("samples", []), profile.get("timeDeltas", [])):
        t += dt
        samples.append((t, sid))
    s_times = [s[0] for s in samples]
    deltas = profile.get("timeDeltas", [])
    weight = [(deltas[i + 1] if i + 1 < len(deltas) else 200) / 1000 for i in range(len(samples))]
    attr._stacks.clear()

    totals: dict[str, float] = defaultdict(float)
    causes: Counter = Counter()
    funcs: Counter = Counter()
    owners: Counter = Counter()
    vsyncs_per_slow: Counter = Counter()
    per_frame = []
    for a, b in slow:
        span = (b - a) / 1000
        buckets: dict[str, float] = defaultdict(float)
        covered = 0.0
        desched = 0.0
        i0 = max(0, bisect.bisect_right(t_starts, a) - 1)
        for task in tasks[i0:bisect.bisect_left(t_starts, b)]:
            ta, tb = task["ts"], task["ts"] + task["dur"]
            if tb <= a or ta >= b:
                continue
            kids = [(0, e) for e in main_ev[bisect.bisect_left(m_starts, ta):bisect.bisect_right(m_starts, tb)]
                    if e is not task and e["ts"] + e["dur"] <= tb]
            for s_a, s_b, kind, _name in attr.exclusive(task, kids):
                x, y = max(s_a, a), min(s_b, b)
                if y > x:
                    buckets[f"main {kind}"] += (y - x) / 1000
            inside = (min(tb, b) - max(ta, a)) / 1000
            covered += inside
            if task.get("tdur") is not None and task["dur"] > 0:
                # Off-CPU share of the task, spread evenly over its wall time.
                off = max(0.0, 1 - task["tdur"] / task["dur"])
                desched += inside * off
        buckets["main idle"] = max(0.0, span - covered)
        # The off-CPU part of the main thread's time is moved out of its kinds into one bucket of its own.
        if covered > 0 and desched > 0:
            scale = 1 - desched / covered
            for k in list(buckets):
                if k.startswith("main ") and k != "main idle":
                    buckets[k] *= scale
            buckets["main descheduled (CPU taken by load)"] = desched
        for g, iv in other.items():
            ms = busy(iv, a, b) / 1000
            if ms > 0:
                buckets[f"{g} busy"] = ms
        nv = bisect.bisect_left(vsync, b) - bisect.bisect_left(vsync, a)
        nd = bisect.bisect_left(dropped, b) - bisect.bisect_left(dropped, a)
        vsyncs_per_slow[nv] += 1
        for k, v in buckets.items():
            totals[k] += v
        # The cause: the biggest main-thread bucket, unless the main thread mostly sat idle (then the frame waited on
        # something else: the biggest other thread's busy time names it, or the vsync clock if none was busy).
        main_b = {k: v for k, v in buckets.items() if k.startswith("main ") and k != "main idle"}
        if buckets["main idle"] > sum(main_b.values()):
            oth = {k: v for k, v in buckets.items() if not k.startswith("main ")}
            top = max(oth, key=oth.get) if oth and max(oth.values()) > 0.25 * span else "main idle (waiting on vsync)"
            cause = f"idle main; {top}"
        else:
            cause = max(main_b, key=main_b.get)
        causes[cause] += 1
        j, k = bisect.bisect_left(s_times, a), bisect.bisect_right(s_times, b)
        for i in range(j, k):
            frames = attr.stack_of(samples[i][1], by_id, parent)
            if not frames or frames[0] in attr.IDLE:
                continue
            where = attr.where_of(samples[i][1], by_id, parent)
            funcs[where[0]] += weight[i]
            owners[attr.script_owner(frames)] += weight[i]
        per_frame.append({"at_us": a, "ms": round(span, 2), "vsyncs": nv, "dropped": nd, "cause": cause,
                          "buckets": {k: round(v, 2) for k, v in buckets.items()}})

    all_gaps = sorted((b - a) / 1000 for a, b in gaps)
    q = lambda p: all_gaps[min(len(all_gaps) - 1, int(p * len(all_gaps)))]
    return {"file": path, "frames": len(starts), "gap_p50_ms": round(q(0.5), 2), "gap_p95_ms": round(q(0.95), 2),
            "slow_frames": len(slow), "slow_ms_total": round(sum((b - a) for a, b in slow) / 1000, 1),
            "buckets_ms": {k: round(v, 1) for k, v in sorted(totals.items(), key=lambda kv: -kv[1])},
            "causes": dict(causes.most_common()), "vsyncs_per_slow_frame": dict(sorted(vsyncs_per_slow.items())),
            "functions_ms": [(f, round(w, 1)) for f, w in funcs.most_common(25)],
            "owners_ms": [(o, round(w, 1)) for o, w in owners.most_common(15)],
            "threads": sorted(set(groups.values())), "slowest": sorted(per_frame, key=lambda f: -f["ms"])[:20]}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--slow-ms", type=float, default=20.0)
    ap.add_argument("--json")
    a = ap.parse_args()
    runs = [analyze(p, a.slow_ms) for p in a.traces]
    for r in runs:
        if "error" in r:
            print(f"frame-trace {r['file']}: {r['error']}")
            continue
        print(f"== frame-trace {r['file']}: {r['slow_frames']} of {r['frames']} frames >= {a.slow_ms} ms "
              f"(gap p50 {r['gap_p50_ms']} p95 {r['gap_p95_ms']} ms), {r['slow_ms_total']} ms in slow frames; "
              f"threads {', '.join(r['threads'])}")
        tot = r["slow_ms_total"] or 1
        print("   where slow-frame time went (wall ms; threads overlap, so other threads' rows add past 100%):")
        for k, v in r["buckets_ms"].items():
            print(f"     {v:9.1f} ms {100 * v / tot:5.1f}%  {k}")
        print("   cause by slow frames: " + "; ".join(f"{n} {c}" for c, n in r["causes"].items()))
        print("   compositor BeginFrames per slow frame: " +
              ", ".join(f"{k}: {v}" for k, v in r["vsyncs_per_slow_frame"].items()))
        print("   main-thread owners in slow frames (CPU profile ms):")
        for o, w in r["owners_ms"][:10]:
            print(f"     {w:8.1f} ms  {o}")
        print("   hottest self-time functions in slow frames:")
        for f, w in r["functions_ms"][:15]:
            print(f"     {w:8.1f} ms  {f}")
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(runs, f)
    return 0 if any("error" not in r for r in runs) else 1


if __name__ == "__main__":
    sys.exit(main())
