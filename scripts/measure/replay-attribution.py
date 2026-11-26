#!/usr/bin/env python3
"""Attribute every renderer main-thread task over 8 ms in replay-under-load traces to its owner.

    scripts/measure/replay-attribution.py TRACE.json [TRACE.json ...] [--min-ms 8] [--json OUT]

Each TRACE is `bench/replay-under-load.bench.ts --trace FILE` output: {trace, profile}, a Chrome trace of the measured
window and the CPU profile beside it (one clock: both in base::TimeTicks microseconds). For each top-level task on
CrRendererMain of at least --min-ms, the trace's nested events give each microsecond's kind (exclusive time of the
innermost event): style (UpdateLayoutTree), layout, paint/commit, GC, parse/compile, or script. Script time is split by
the CPU profile samples inside the task, by owner: the React phase and the nearest component when React's work loop is
on the stack, else the handler the task entered. A style or layout run inside script is forced; its owner is the
script's. Prints, over all traces: owners by total ms and by the count of tasks each dominates, and each top owner's
three hottest self-time stacks.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict

TASK_NAMES = {"ThreadControllerImpl::RunTask", "RunTask"}
STYLE = {"UpdateLayoutTree", "RecalculateStyles", "ParseAuthorStyleSheet", "ScheduleStyleRecalculation"}
LAYOUT = {"Layout", "LayoutShift", "IntersectionObserverController::computeIntersections", "ResizeObserver"}
PAINT = {"Paint", "PrePaint", "Layerize", "UpdateLayer", "UpdateLayerTree", "Commit", "CompositeLayers", "PaintImage",
         "Decode Image", "Rasterize", "PaintArtifactCompositor::Update", "ProxyMain::BeginMainFrame::commit"}
PARSE = {"v8.compile", "v8.compileModule", "ParseHTML", "V8.ParseFunction", "CompileCode", "CompileScript",
         "v8.produceCache", "v8.deserializeOnBackground", "V8.CompileLazy", "ParseScript"}
SCRIPT = {"FunctionCall", "EvaluateScript", "TimerFire", "FireAnimationFrame", "EventDispatch", "v8.callFunction",
          "RunMicrotasks", "v8.run", "V8.Execute", "FireIdleCallback", "XHRReadyStateChange", "v8.evaluateModule"}
REACT_ROOTS = {"performWorkOnRoot", "performSyncWorkOnRoot", "performConcurrentWorkOnRoot", "renderRootSync",
               "renderRootConcurrent", "workLoopSync", "workLoopConcurrent", "workLoopConcurrentByScheduler",
               "commitRoot", "commitRootImpl", "flushPassiveEffects", "flushSyncWorkAcrossRoots_impl",
               "flushPassiveEffectsImpl", "commitRootWhenReady"}
REACT_PHASE = [("flushPassiveEffects", "React passive effects (useEffect)"),
               ("commitLayoutEffects", "React layout effects (useLayoutEffect)"),
               ("commitMutationEffects", "React commit (DOM mutation)"),
               ("commitRoot", "React commit"),
               ("beginWork", "React render"), ("completeWork", "React render"), ("workLoop", "React render"),
               ("renderRoot", "React render")]
IDLE = {"(idle)", "(program)", "(root)"}


def kind_of(name: str) -> str | None:
    if name in STYLE:
        return "style"
    if name in LAYOUT:
        return "layout"
    if name in PAINT:
        return "paint"
    if name in PARSE:
        return "parse"
    if name in SCRIPT:
        return "script"
    if "GC" in name or name.startswith("V8.GC") or name in {"MajorGC", "MinorGC", "BlinkGC.AtomicPhase"}:
        return "gc"
    return None


def main_thread(events: list[dict]) -> tuple[int, int] | None:
    names = [(e["pid"], e["tid"]) for e in events if e.get("ph") == "M" and e.get("name") == "thread_name"
             and e.get("args", {}).get("name") == "CrRendererMain"]
    if not names:
        return None
    count = Counter((e.get("pid"), e.get("tid")) for e in events if e.get("ph") == "X")
    return max(names, key=lambda pt: count.get(pt, 0))


def exclusive(task: dict, children: list[tuple[int, dict]]) -> list[tuple[int, int, str, str]]:
    """(start, end, kind, event name) of each slice of the task's exclusive time: each event's own time (its span less
    its children's), of the innermost known kind on its chain; an unknown event names the slice and keeps its parent's
    kind. Trace events on one thread nest, so one pass over them sorted by start does it."""
    nodes = [(task["ts"], task["ts"] + task["dur"], task["name"])] + \
        [(e["ts"], e["ts"] + e.get("dur", 0), e["name"]) for _d, e in children]
    kids: dict[int, list[int]] = {i: [] for i in range(len(nodes))}
    stack = [0]
    for i in range(1, len(nodes)):
        while len(stack) > 1 and nodes[stack[-1]][1] <= nodes[i][0]:
            stack.pop()
        kids[stack[-1]].append(i)
        stack.append(i)
    out: list[tuple[int, int, str, str]] = []

    def walk(i: int, kind: str, in_script: bool) -> None:
        a, b, name = nodes[i]
        k = kind_of(name)
        kind = k or kind
        in_script = in_script or k == "script"
        label = f"{kind}-forced" if kind in ("style", "layout") and in_script else kind
        at = a
        for c in kids[i]:
            ca, cb, _ = nodes[c]
            if ca > at:
                out.append((at, ca, label, name))
            walk(c, kind, in_script)
            at = max(at, cb)
        if b > at:
            out.append((at, b, label, name))

    walk(0, "other", False)
    return out


_stacks: dict[int, list[str]] = {}


def stack_of(node_id: int, by_id: dict, parent: dict) -> list[str]:
    if node_id in _stacks:
        return _stacks[node_id]
    frames = []
    at = node_id
    while at is not None:
        f = by_id[at]["callFrame"]
        name = f.get("functionName") or "(anon)"
        if name != "(root)":
            frames.append(name)
        at = parent.get(at)
    _stacks[node_id] = frames
    return frames  # innermost first


def script_owner(frames: list[str]) -> str:
    outer = list(reversed(frames))  # outermost first
    for i, name in enumerate(outer):
        if name in REACT_ROOTS or any(name.startswith(r) for r in ("performWorkOnRoot", "flushPassiveEffects")):
            inner = frames[: len(frames) - i]
            phase = "React render"
            for key, label in REACT_PHASE:
                if any(key in n for n in inner):
                    phase = label
                    break
            comp = next((n for n in inner if n[:1].isupper() and n not in IDLE), None)
            return f"{phase}: {comp}" if comp else phase
    entry = next((n for n in outer if n not in IDLE and n != "(anon)"), outer[0] if outer else "(anon)")
    return f"script: {entry}"


def analyze(doc: dict, min_ms: float) -> dict:
    _stacks.clear()
    trace = doc["trace"]
    events = trace["traceEvents"] if isinstance(trace, dict) else trace
    main = main_thread(events)
    if main is None:
        return {"error": "no CrRendererMain in the trace"}
    on_main = sorted((e for e in events if (e.get("pid"), e.get("tid")) == main and e.get("ph") == "X"
                      and "dur" in e), key=lambda e: (e["ts"], -e["dur"]))
    tasks, end = [], -1
    for e in on_main:
        if e["name"] in TASK_NAMES and e["ts"] >= end:
            tasks.append(e)
            end = e["ts"] + e["dur"]
    long = [t for t in tasks if t["dur"] >= min_ms * 1000]

    prof = doc["profile"]
    by_id = {n["id"]: n for n in prof["nodes"]}
    parent = {c: n["id"] for n in prof["nodes"] for c in n.get("children", [])}
    t, samples = prof.get("startTime", 0), []
    for sid, dt in zip(prof.get("samples", []), prof.get("timeDeltas", [])):
        t += dt
        samples.append((t, sid))
    deltas = prof.get("timeDeltas", [])
    weight = [(deltas[i + 1] if i + 1 < len(deltas) else 200) / 1000 for i in range(len(samples))]

    owner_ms: dict[str, float] = defaultdict(float)
    dominates: Counter = Counter()
    stacks: dict[str, Counter] = defaultdict(Counter)
    kinds_ms: dict[str, float] = defaultdict(float)
    matched = 0
    import bisect
    times = [s[0] for s in samples]
    starts = [e["ts"] for e in on_main]
    # Children of each long task, by containment.
    for task in long:
        a, b = task["ts"], task["ts"] + task["dur"]
        kids = []
        for e in on_main[bisect.bisect_left(starts, a):bisect.bisect_right(starts, b)]:
            if e is not task and e["ts"] + e["dur"] <= b:
                kids.append((0, e))
        slices = exclusive(task, kids)
        mine: dict[str, float] = defaultdict(float)
        for s_a, s_b, kind, name in slices:
            ms = (s_b - s_a) / 1000
            kinds_ms[kind] += ms
            if kind in ("script", "style-forced", "layout-forced", "other"):
                # Split by the samples in this slice; a forced style/layout run belongs to the script that forced it.
                j, k = bisect.bisect_left(times, s_a), bisect.bisect_right(times, s_b)
                owners: Counter = Counter()
                for i in range(j, k):
                    frames = stack_of(samples[i][1], by_id, parent)
                    if not frames or frames[0] in IDLE:
                        if kind == "script" or kind == "other":
                            continue
                    if frames:
                        owners[script_owner(frames)] += weight[i]
                        top = " < ".join(frames[:4])
                        stacks[script_owner(frames)][(kind, top)] += weight[i]
                if owners:
                    matched += 1
                    total = sum(owners.values())
                    for o, w in owners.items():
                        label = o if kind in ("script", "other") else f"{kind.split('-')[0]} forced by {o}"
                        mine[label] += ms * w / total
                    continue
                mine[f"{kind} ({name})" if kind == "other" else kind] += ms
            else:
                mine[kind] += ms
        for o, ms in mine.items():
            owner_ms[o] += ms
        if mine:
            dominates[max(mine, key=mine.get)] += 1
    return {"tasks": len(tasks), "long_tasks": len(long), "long_ms": sum(t["dur"] for t in long) / 1000,
            "all_task_ms": sum(t["dur"] for t in tasks) / 1000, "kinds_ms": dict(kinds_ms),
            "owner_ms": dict(owner_ms), "dominates": dict(dominates),
            "stacks": {o: [(k, s, w) for (k, s), w in c.most_common(5)] for o, c in stacks.items()},
            "samples_matched_slices": matched}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--min-ms", type=float, default=8.0)
    ap.add_argument("--json")
    a = ap.parse_args()
    runs = []
    for path in a.traces:
        with open(path, encoding="utf-8") as f:
            r = analyze(json.load(f), a.min_ms)
        r["file"] = path
        runs.append(r)
        if "error" in r:
            print(f"{path}: {r['error']}")
            continue
        print(f"== {path}: {r['long_tasks']} of {r['tasks']} main-thread tasks >= {a.min_ms} ms, "
              f"{r['long_ms']:.0f} of {r['all_task_ms']:.0f} task ms")
        print("   kinds (exclusive ms in long tasks): " +
              ", ".join(f"{k} {v:.0f}" for k, v in sorted(r["kinds_ms"].items(), key=lambda kv: -kv[1])))
    ok = [r for r in runs if "error" not in r]
    total: dict[str, float] = defaultdict(float)
    dom: Counter = Counter()
    stacks: dict[str, Counter] = defaultdict(Counter)
    for r in ok:
        for o, ms in r["owner_ms"].items():
            total[o] += ms
        dom.update(r["dominates"])
        for o, rows in r["stacks"].items():
            for kind, s, w in rows:
                stacks[o][(kind, s)] += w
    long_ms = sum(r["long_ms"] for r in ok) or 1
    print(f"\n== owners over {len(ok)} runs ({long_ms:.0f} ms in long tasks), by total ms")
    for o, ms in sorted(total.items(), key=lambda kv: -kv[1])[:15]:
        print(f"  {ms:8.0f} ms {100 * ms / long_ms:5.1f}%  dominates {dom.get(o, 0):4d} tasks  {o}")
    print("\n== owners by tasks dominated")
    for o, n in dom.most_common(8):
        print(f"  {n:4d} tasks  {total.get(o, 0):8.0f} ms  {o}")
    print("\n== hottest self-time stacks (innermost < callers) of the top owners")
    for o, _ in sorted(total.items(), key=lambda kv: -kv[1])[:6]:
        base = o.split(" forced by ")[-1]
        rows = stacks.get(base)
        if not rows:
            continue
        print(f"  {o}:")
        for (kind, s), w in rows.most_common(3):
            print(f"     {w:7.1f} ms [{kind}] {s}")
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(runs, f)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
