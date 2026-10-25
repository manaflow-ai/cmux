#!/usr/bin/env python3
"""Startup machine queues (plans/cmux-next/chrome-parity/p08-startup.md, section 6): each hit is one task.

Every mode reads saved files (any host, Linux included) or, with --app, launches the app N times on a fleet
Mac and reads what the launch recorded. Each hit names its queue and the task template that fixes it.

  blocking    Q5, template 038. Main-thread blocking sites (`debug.blocking`, a Debug or CMUX_BLOCKING_CHECKS +
              CMUX_BENCH_HOOKS build) first hit before --until-mark (default startup_complete). Any run counts.
  gaps        Q7, template 039. Gaps between consecutive launch marks of a bench-startup.py --json file whose
              median is >= --min-ms. Interrupted launches (`launch.interrupted`) are left out.
  profile     Q6, template 039. From trace.py launch recordings (trace.json.gz, or the directory holding it):
              app symbols with median >= --symbol-ms inclusive on main before --first-frame-mark; main turns
              >= --turn-ms before --until-mark; swift_once initializers and static initializers >= --once-ms.
  mainjobs    Q11, template 081. From `debug.startup`: each main-job enqueuer with a median >= --job-ms total
              or >= --job-count jobs before --first-frame-mark, and each main turn before --until-mark that ran
              outside a StartupScheduler task and the allowlist.
  globaljobs  Q12, template 083. From `debug.startup`: each caller of utility, background or unprioritized
              jobs enqueued before --until-mark that is not a BackgroundWork lane job.
  arms        Q13, template 086. From `debug.startup`: each timer, watcher and observer armed before
              --until-mark, with its median arm and first-fire times.

Usage:
  startup-queue.py gaps warm.json --min-ms 5 [--json out.json]
  startup-queue.py blocking raw.json                     analyze a saved capture (any host)
  startup-queue.py blocking --app "$NX_APP" --runs 5 --temperature warm|cold [--raw raw.json] [--json out.json]
  startup-queue.py profile run1/ run2/ ...               or --app: N `trace.py record --scenario launch-<temp>`
  startup-queue.py mainjobs|globaljobs|arms --app "$NX_APP" --runs 5

Fleet guard: --app runs only on the build fleet (`cmux-ci run` sets CMUX_CI_STEP_KEY, nx-remote sets
NX_ARTIFACTS, or a GitHub runner), never on a person's Mac; elsewhere it exits 2 before it starts anything.

--json writes {"mode", "queue", "template", "runs", "thresholds", "warnings", "hits": [...]} (`-` for stdout).
--check exits 1 when there is any hit. --raw saves the live runs, which the same mode reads back as input.

Input contract. All times are ms since process start (the launch-mark clock, LaunchMarkSink.swift).
  bench-startup.py --json: {tag: {mode: [{mark: ms, ...}, ...]}}.
  debug.blocking: {"mode", "overflow", "sites": [{"kind", "location", "count", "first_ms"?}]}.
  debug.startup (tasks 008, 080, 082, 085): {"milestones": {mark: ms}, "interrupted"?: bool,
    "main_jobs": [{"caller", "kind", "priority", "enqueued_ms", "run_ms"}],
    "main_turns": [{"start_ms", "duration_ms", "task": name or null, "allowlisted": bool, "site"}],
    "global_jobs": [{"caller", "priority": name or number or null, "lane": name or null, "enqueued_ms", "run_ms"}],
    "arms": [{"kind", "owner", "site", "armed_ms", "first_fire_ms": ms or null}]}.
  A saved capture (--raw): {"mode", "runs": [{"marks": {...}, "result": <method result>}]}; a bare result, a
  list of results or a control reply ({"result": ...}) are read too.
  trace.py: Chrome trace events; the app is the process named "app: ...", its main thread "Main Thread ...";
  stack samples are nested "cpu" slices; marks are instant events named for the mark (or with it as the
  signpost message); main turns are StartupTrace's "startup.main_turn" slices, else the main thread's on-CPU
  runs (off-CPU waits are Q5's). Chromium reference for the ordering: chrome/browser/after_startup_task_utils.cc.
"""

from __future__ import annotations

import argparse
import collections
import functools
import gzip
import importlib.util
import json
import os
import platform
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FIRST_FRAME = "first_window_frame_committed"
COMPLETE = "startup_complete"
QUEUES = {
    "blocking": ("Q5", "038"), "gaps": ("Q7", "039"), "profile": ("Q6", "039"),
    "mainjobs": ("Q11", "081"), "globaljobs": ("Q12", "083"), "arms": ("Q13", "086"),
}
CENSUS_MODES = ("mainjobs", "globaljobs", "arms")
# Swift TaskPriority raw values (and their names) that Q12 names; 0 / None is an unprioritized job.
GLOBAL_PRIORITIES = {"utility": "utility", "low": "utility", 17: "utility", "background": "background",
                     9: "background", "unspecified": "unspecified", None: "unspecified", 0: "unspecified"}
# Initializer frames (the frame under swift_once names its owner; a C++ or ObjC static initializer).
STATIC_INIT = ("one-time initialization function for", "static initializer for", "_GLOBAL__sub_I",
               "__cxx_global_var_init", "globalinit_")


class QueueError(SystemExit):
    """A refusal or a bad input: the message, exit 2."""

    def __init__(self, message):
        print(f"startup-queue: {message}", file=sys.stderr)
        super().__init__(2)


# ---- fleet guard -------------------------------------------------------------------------------------------


def fleet_refusal(env, system):
    """Why a live run may not start on this host, or None on the fleet (the same rule as lib/fleet-only.sh)."""
    if system != "Darwin":
        return (f"--app launches the app on a macOS fleet host; this host runs {system}. "
                "Analyze saved files here instead (startup-queue.py MODE FILE...).")
    if env.get("CMUX_CI_STEP_KEY") or env.get("GITHUB_ACTIONS") == "true" or env.get("NX_ARTIFACTS"):
        return None
    return ("--app runs only on the build fleet (cmux-ci run or nx-remote), never on a person's Mac.\n"
            "Run it there:\n  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\\n"
            "    python3 scripts/cmux-next/startup-queue.py MODE --app \"$NX_APP\" --runs 5 "
            "--json \"$NX_ARTIFACTS/MODE.json\"")


# ---- small helpers -----------------------------------------------------------------------------------------


def number(value):
    """A float for a JSON number, None for anything else (bools and strings included)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def p95(values):
    ordered = sorted(values)
    return ordered[max(0, -(-len(ordered) * 95 // 100) - 1)]


def median_over(per_run, runs):
    """The median over every run, a run without the key counting as 0."""
    return statistics.median(list(per_run) + [0.0] * (runs - len(per_run)))


def read_json(path):
    with open(path, "rb") as source:
        data = source.read()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    try:
        return json.loads(data)
    except ValueError as error:
        raise QueueError(f"{path}: not JSON ({error})") from None


def cutoff(marks, name):
    return number((marks or {}).get(name))


def interrupted(run):
    return bool(run["marks"].get("launch.interrupted") or run["result"].get("interrupted"))


# ---- input: captures ---------------------------------------------------------------------------------------


def capture_runs(data):
    """[{"marks", "result"}] from a saved capture, a list of results, one result or a control reply."""
    if isinstance(data, dict) and isinstance(data.get("runs"), list):
        items = data["runs"]
    elif isinstance(data, list):
        items = data
    else:
        items = [data]
    runs = []
    for item in items:
        if not isinstance(item, dict):
            continue
        result = item["result"] if isinstance(item.get("result"), dict) else item
        marks = dict(result.get("milestones") or {})
        marks.update(item.get("marks") or {})
        runs.append({"marks": marks, "result": result})
    return runs


def load_captures(paths):
    runs = []
    for path in paths:
        runs += capture_runs(read_json(path))
    return runs


# ---- Q5 blocking -------------------------------------------------------------------------------------------


def blocking_hits(runs, until_mark):
    """Each main-thread blocking site first hit before the mark, in any run; most runs first."""
    sites, warnings, used = {}, [], 0
    for index, run in enumerate(runs):
        if interrupted(run):
            warnings.append(f"run {index + 1}: interrupted launch, left out")
            continue
        used += 1
        limit = cutoff(run["marks"], until_mark)
        result = run["result"]
        if number(result.get("overflow")):
            warnings.append(f"run {index + 1}: {int(result['overflow'])} sites past the detector's table")
        for site in result.get("sites") or []:
            first = number(site.get("first_ms"))
            if first is not None and limit is not None and first > limit:
                continue
            key = (str(site.get("kind", "?")), str(site.get("location", "?")))
            entry = sites.setdefault(key, {"runs": 0, "count": 0})
            entry["runs"] += 1
            entry["count"] += int(number(site.get("count")) or 0)
    hits = [{"kind": kind, "location": location, "runs": entry["runs"], "count": entry["count"],
             "summary": f"{entry['runs']}/{used} runs, {entry['count']} calls: {kind} at {location}"}
            for (kind, location), entry in sites.items()]
    hits.sort(key=lambda hit: (-hit["runs"], -hit["count"], hit["location"]))
    return hits, warnings, used


# ---- Q7 gaps -----------------------------------------------------------------------------------------------


def numeric_marks(run):
    return {name: value for name, value in run.items() if number(value) is not None}


def mark_gaps(runs, min_ms, label):
    """Gaps between marks consecutive in median order, per run where both landed, kept at median >= min_ms."""
    marks = [numeric_marks(run) for run in runs]
    names = {name for run in marks for name in run}
    order = sorted(names, key=lambda name: statistics.median([run[name] for run in marks if name in run]))
    hits = []
    for before, after in zip(order, order[1:]):
        gaps = [run[after] - run[before] for run in marks if before in run and after in run]
        if not gaps or statistics.median(gaps) < min_ms:
            continue
        median = statistics.median(gaps)
        hits.append({"run_set": label, "from": before, "to": after, "p50_ms": round(median, 1),
                     "p95_ms": round(p95(gaps), 1), "max_ms": round(max(gaps), 1), "n": len(gaps),
                     "summary": f"{label}: {before} -> {after} p50 {median:.1f} ms, p95 {p95(gaps):.1f} ms, n {len(gaps)}"})
    return hits


def gaps_hits(paths, min_ms, only_mode):
    hits, warnings, used = [], [], 0
    for path in paths:
        data = read_json(path)
        if not isinstance(data, dict):
            raise QueueError(f"{path}: expected a bench-startup.py --json file ({{tag: {{mode: [runs]}}}})")
        for tag, modes in data.items():
            for mode, runs in (modes or {}).items():
                if only_mode and mode != only_mode:
                    continue
                kept = [run for run in runs if isinstance(run, dict) and not run.get("launch.interrupted")]
                if len(kept) < len(runs):
                    warnings.append(f"{tag} {mode}: {len(runs) - len(kept)} interrupted runs left out")
                used += len(kept)
                hits += mark_gaps(kept, min_ms, f"{tag} {mode}")
    hits.sort(key=lambda hit: -hit["p50_ms"])
    return hits, warnings, used


# ---- Q6 profile --------------------------------------------------------------------------------------------


@functools.cache
def frame_filter():
    """trace.py's `interesting` (one notion of a generic frame), loaded by path: `trace` is a stdlib name."""
    spec = importlib.util.spec_from_file_location("cmux_next_trace", os.path.join(HERE, "trace.py"))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, HERE)
    spec.loader.exec_module(module)
    return module.interesting


def trace_events(path):
    if os.path.isdir(path):
        path = os.path.join(path, "trace.json.gz")
    data = read_json(path)
    return data.get("traceEvents", []) if isinstance(data, dict) else data


def app_main_thread(events):
    """(pid, tid) of the app's main thread, from the process_name and thread_name metadata."""
    apps = {e.get("pid") for e in events if e.get("ph") == "M" and e.get("name") == "process_name"
            and str((e.get("args") or {}).get("name", "")).startswith("app:")}
    for e in events:
        if e.get("ph") == "M" and e.get("name") == "thread_name" and e.get("pid") in apps \
                and str((e.get("args") or {}).get("name", "")).startswith("Main Thread"):
            return e["pid"], e["tid"]
    return None


def trace_marks(events, pid):
    """The first time (µs) of each instant event of the app, by name and by signpost message."""
    marks = {}
    for e in events:
        if e.get("pid") != pid or e.get("ph") not in ("i", "I", "R", "n") or number(e.get("ts")) is None:
            continue
        message = str((e.get("args") or {}).get("message") or "").split(" ")[0]
        for name in {str(e.get("name", "")), message} - {""}:
            marks[name] = min(marks.get(name, e["ts"]), e["ts"])
    return marks


def union_ms(intervals, end):
    """Covered time (ms) of [start, stop) intervals clipped at `end` (µs); nested calls of one symbol count once."""
    total, reach = 0.0, None
    for start, stop in sorted(intervals):
        stop = min(stop, end)
        if stop <= start:
            continue
        if reach is None or start >= reach:
            total += stop - start
            reach = stop
        elif stop > reach:
            total += stop - reach
            reach = stop
    return total / 1000.0


def slices_on(events, key, category=None):
    return [e for e in events if (e.get("pid"), e.get("tid")) == key and e.get("ph") == "X"
            and number(e.get("dur")) is not None and (category is None or e.get("cat") == category)]


def main_turns(events, key, interesting):
    """StartupTrace's turn slices (task 004) when the trace has them, else the main thread's on-CPU runs."""
    explicit = [e for e in events if e.get("pid") == key[0] and e.get("ph") == "X"
                and e.get("cat") == "startup.main_turn" and number(e.get("dur")) is not None]
    if explicit:
        return [(e["ts"], e["dur"], str((e.get("args") or {}).get("site") or e.get("name", "?"))) for e in explicit]
    cpu = sorted(slices_on(events, key, "cpu"), key=lambda e: (e["ts"], -e["dur"]))
    turns, reach = [], None
    for e in cpu:
        if reach is None or e["ts"] >= reach:
            turns.append([e["ts"], e["dur"], [e]])
            reach = e["ts"] + e["dur"]
        else:
            turns[-1][2].append(e)
    return [(ts, dur, heaviest_frame(children, dur, interesting)) for ts, dur, children in turns]


def heaviest_frame(frames, turn_dur, interesting):
    """The deepest non-generic frame that covers at least half of a turn (its owner), else the turn's root."""
    covering = [e for e in frames if e["dur"] * 2 >= turn_dur and interesting(str(e.get("name", "")))]
    return str((covering[-1] if covering else frames[0]).get("name", "?"))


def profile_run(events, first_frame_mark, until_mark):
    """One trace: {symbol: inclusive ms} on main before the first frame; main turns and {initializer: ms} before the mark."""
    key = app_main_thread(events)
    if key is None:
        raise ValueError("no app main thread (process `app: ...`, thread `Main Thread ...`)")
    marks = trace_marks(events, key[0])
    missing = [name for name in (first_frame_mark, until_mark) if name not in marks]
    if missing:
        raise ValueError(f"mark {', '.join(missing)} not in the trace")
    base = marks.get("process_start", marks.get("main_start", 0.0))
    first_frame, complete = marks[first_frame_mark], marks[until_mark]
    interesting = frame_filter()
    cpu = slices_on(events, key, "cpu")
    by_name = collections.defaultdict(list)
    for e in cpu:
        by_name[str(e.get("name", "?"))].append((e["ts"], e["ts"] + e["dur"]))
    symbols = {name: union_ms(spans, first_frame) for name, spans in by_name.items() if interesting(name)}
    turns = [{"at_ms": round((ts - base) / 1000.0, 1), "ms": dur / 1000.0, "site": site}
             for ts, dur, site in main_turns(events, key, interesting) if ts < complete]
    inits = {name: union_ms(spans, complete) for name, spans in by_name.items()
             if any(marker in name for marker in STATIC_INIT)}
    return symbols, turns, inits


def profile_hits(paths, first_frame_mark, until_mark, symbol_ms, turn_ms, once_ms):
    runs, warnings = [], []
    for path in paths:
        try:
            runs.append(profile_run(trace_events(path), first_frame_mark, until_mark))
        except ValueError as error:
            warnings.append(f"{path}: {error}, left out")
    hits = []
    for name, values in per_key([run[0] for run in runs]).items():
        median = median_over(values, len(runs))
        if median >= symbol_ms:
            hits.append({"kind": "symbol", "site": name, "p50_ms": round(median, 1), "runs": len(values),
                         "summary": f"symbol {name}: p50 {median:.1f} ms inclusive on main before {first_frame_mark}"})
    turn_groups = collections.defaultdict(list)
    for run in runs:
        for turn in run[1]:
            if turn["ms"] >= turn_ms:
                turn_groups[turn["site"]].append(turn)
    for site, turns in turn_groups.items():
        longest = max(turn["ms"] for turn in turns)
        hits.append({"kind": "turn", "site": site, "max_ms": round(longest, 1), "count": len(turns),
                     "at_ms": [turn["at_ms"] for turn in turns],
                     "summary": f"main turn {site}: {len(turns)} turns >= {turn_ms:g} ms, longest {longest:.1f} ms"})
    for name, values in per_key([run[2] for run in runs]).items():
        median = median_over(values, len(runs))
        if median >= once_ms:
            hits.append({"kind": "static_init", "site": name, "p50_ms": round(median, 1), "runs": len(values),
                         "summary": f"static init {name}: p50 {median:.1f} ms before {until_mark}"})
    hits.sort(key=lambda hit: -hit.get("p50_ms", hit.get("max_ms", 0)))
    return hits, warnings, len(runs)


def per_key(dicts):
    merged = collections.defaultdict(list)
    for values in dicts:
        for name, value in values.items():
            merged[name].append(value)
    return merged


# ---- Q11 / Q12 / Q13 census --------------------------------------------------------------------------------


def census_runs(runs, marks_needed):
    """The runs that can be classified (not interrupted, every needed mark present), and why others were not."""
    kept, warnings = [], []
    for index, run in enumerate(runs):
        missing = [name for name in marks_needed if cutoff(run["marks"], name) is None]
        if interrupted(run):
            warnings.append(f"run {index + 1}: interrupted launch, left out")
        elif missing:
            warnings.append(f"run {index + 1}: no {', '.join(missing)} mark, left out")
        else:
            kept.append(run)
    return kept, warnings


def mainjobs_hits(runs, first_frame_mark, until_mark, job_ms, job_count):
    kept, warnings = census_runs(runs, (first_frame_mark, until_mark))
    totals, counts = collections.defaultdict(list), collections.defaultdict(list)
    turns = collections.defaultdict(lambda: {"runs": 0, "count": 0, "ms": 0.0})
    for run in kept:
        first_frame, complete = cutoff(run["marks"], first_frame_mark), cutoff(run["marks"], until_mark)
        run_ms, run_count = collections.defaultdict(float), collections.defaultdict(int)
        for job in run["result"].get("main_jobs") or []:
            if (number(job.get("enqueued_ms")) or 0.0) < first_frame:
                key = (str(job.get("kind", "?")), str(job.get("caller", "?")))
                run_ms[key] += number(job.get("run_ms")) or 0.0
                run_count[key] += 1
        for key in run_count:
            totals[key].append(run_ms[key])
            counts[key].append(run_count[key])
        seen = set()
        for turn in run["result"].get("main_turns") or []:
            if (number(turn.get("start_ms")) or 0.0) >= complete or turn.get("task") or turn.get("allowlisted"):
                continue
            site = str(turn.get("site", "?"))
            turns[site]["count"] += 1
            turns[site]["ms"] += number(turn.get("duration_ms")) or 0.0
            turns[site]["runs"] += site not in seen
            seen.add(site)
    hits = []
    for (kind, caller), values in totals.items():
        ms, count = median_over(values, len(kept)), median_over(counts[(kind, caller)], len(kept))
        if ms >= job_ms or count >= job_count:
            hits.append({"kind": kind, "caller": caller, "p50_ms": round(ms, 2), "p50_count": count,
                         "runs": len(values), "summary": f"{kind} jobs from {caller}: p50 {ms:.1f} ms, "
                                                         f"{count:g} jobs before {first_frame_mark}"})
    for site, entry in turns.items():
        hits.append({"kind": "unscheduled_turn", "caller": site, "runs": entry["runs"], "count": entry["count"],
                     "p50_ms": round(entry["ms"] / entry["count"], 2),
                     "summary": f"main turn outside a startup task at {site}: {entry['runs']}/{len(kept)} runs, "
                                f"{entry['count']} turns before {until_mark}"})
    hits.sort(key=lambda hit: (-hit["runs"], -hit["p50_ms"]))
    return hits, warnings, len(kept)


def global_priority(value):
    return GLOBAL_PRIORITIES.get(value.lower() if isinstance(value, str) else value)


def globaljobs_hits(runs, until_mark):
    kept, warnings = census_runs(runs, (until_mark,))
    callers = {}
    for run in kept:
        complete = cutoff(run["marks"], until_mark)
        seen = set()
        for job in run["result"].get("global_jobs") or []:
            priority = global_priority(job.get("priority"))
            if job.get("lane") or priority is None or (number(job.get("enqueued_ms")) or 0.0) >= complete:
                continue
            caller = str(job.get("caller", "?"))
            entry = callers.setdefault(caller, {"runs": 0, "count": 0, "ms": 0.0, "priorities": set()})
            entry["count"] += 1
            entry["ms"] += number(job.get("run_ms")) or 0.0
            entry["priorities"].add(priority)
            entry["runs"] += caller not in seen
            seen.add(caller)
    hits = [{"caller": caller, "priorities": sorted(entry["priorities"]), "runs": entry["runs"],
             "count": entry["count"], "total_ms": round(entry["ms"], 2),
             "summary": f"{'/'.join(sorted(entry['priorities']))} jobs from {caller} outside a lane: "
                        f"{entry['runs']}/{len(kept)} runs, {entry['count']} jobs before {until_mark}"}
            for caller, entry in callers.items()]
    hits.sort(key=lambda hit: (-hit["runs"], -hit["count"], hit["caller"]))
    return hits, warnings, len(kept)


def arms_hits(runs, until_mark):
    kept, warnings = census_runs(runs, (until_mark,))
    arms = {}
    for index, run in enumerate(kept):
        complete = cutoff(run["marks"], until_mark)
        for arm in run["result"].get("arms") or []:
            armed = number(arm.get("armed_ms"))
            if armed is None or armed >= complete:
                continue
            key = (str(arm.get("kind", "?")), str(arm.get("owner", "?")), str(arm.get("site", "?")))
            entry = arms.setdefault(key, {"armed": [], "fires": [], "runs": set()})
            entry["armed"].append(armed)
            entry["runs"].add(index)
            fire = number(arm.get("first_fire_ms"))
            if fire is not None:
                entry["fires"].append(fire)
    hits = []
    for (kind, owner, site), entry in arms.items():
        armed = statistics.median(entry["armed"])
        fire = round(statistics.median(entry["fires"]), 1) if entry["fires"] else None
        hits.append({"kind": kind, "owner": owner, "site": site, "runs": len(entry["runs"]),
                     "count": len(entry["armed"]), "p50_armed_ms": round(armed, 1), "p50_first_fire_ms": fire,
                     "summary": f"{kind} {owner} at {site}: armed p50 {armed:.0f} ms, first fire "
                                f"{'never' if fire is None else f'p50 {fire:.0f} ms'}, {len(entry['runs'])}/{len(kept)} runs"})
    hits.sort(key=lambda hit: (-hit["runs"], hit["p50_armed_ms"]))
    return hits, warnings, len(kept)


# ---- live runs (fleet only) --------------------------------------------------------------------------------


def load_bench_startup():
    """bench-startup.py's launch helpers (the mark pipe, the tag's processes, the control client)."""
    spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "bench-startup.py"))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, HERE)
    spec.loader.exec_module(module)
    return module


def purge():
    """Empties the file cache for a cold run; a refusal stops the run (sudo -n never prompts)."""
    done = subprocess.run(["sudo", "-n", "purge"], capture_output=True, text=True)
    if done.returncode != 0:
        raise QueueError(f"cold run refused: `sudo -n purge` failed: {done.stderr.strip() or done.returncode}")


def prepare(bench, tag, temperature, scratch, timeout, purge_cache):
    """Cold: no daemon and an empty file cache. Warm: a priming launch leaves the daemon running."""
    if bench.app_pids(tag):
        raise QueueError(f"tag {tag} has an app running; quit it first (this tool only stops what it starts)")
    if temperature == "cold":
        bench.stop(bench.tag_pids(tag))
        purge_cache()
    elif not bench.tag_pids(tag):
        prime = bench.Launch(tag, scratch)
        prime.wait_for([FIRST_FRAME, bench.FINAL_MARK], timeout, any_of=True)
        prime.quit()


def query(bench, tag, method):
    client = bench.app_client(tag)
    try:
        reply = client.call(method)
    finally:
        client.close()
    if not isinstance(reply.get("result"), dict):
        raise QueueError(f"{method} answered {reply.get('error')!r}: the build needs CMUX_BENCH_HOOKS "
                         "(or Debug), and for debug.blocking also CMUX_BLOCKING_CHECKS")
    return reply["result"]


def collect(bench, app, runs, temperature, until_mark, timeout, method, purge_cache=purge):
    """N launches; each is read with `method` once `until_mark` arrived on the mark pipe, then quit."""
    tag = bench.app_tag(app)
    bench.APPS[tag] = os.path.abspath(app)
    captured = []
    try:
        for index in range(runs):
            scratch = tempfile.mkdtemp(prefix=f"startup-queue-{tag}-")
            with open(os.path.join(scratch, "cmux.json"), "w") as out:
                out.write("{}\n")
            prepare(bench, tag, temperature, scratch, timeout, purge_cache)
            launch = bench.Launch(tag, scratch)
            try:
                if not launch.wait_for(until_mark, timeout):
                    raise QueueError(f"run {index + 1}: {until_mark} never arrived within {timeout:g} s "
                                     "(pass --until-mark for a build without it)")
                result = query(bench, tag, method)
            finally:
                launch.quit()
            captured.append({"index": index + 1, "temperature": temperature, "marks": dict(launch.marks),
                             "result": result})
            print(f"  run {index + 1}/{runs}: {until_mark} at {launch.marks[until_mark]:.0f} ms", file=sys.stderr)
    finally:
        bench.stop(bench.tag_pids(tag))
    return captured


def record_profiles(app, runs, temperature, out_dir):
    """N trace.py launch recordings (task 005's launch-warm / launch-cold scenarios); their directories."""
    folders = []
    for index in range(runs):
        folder = os.path.join(out_dir, f"profile-{temperature}-{index + 1}")
        done = subprocess.run([sys.executable, os.path.join(HERE, "trace.py"), "record", "--app", app,
                               "--out", folder, "--scenario", f"launch-{temperature}"])
        if done.returncode not in (0, 3):
            raise QueueError(f"trace.py record (run {index + 1}) exited {done.returncode}")
        folders.append(folder)
    return folders


# ---- CLI ---------------------------------------------------------------------------------------------------


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=sorted(QUEUES))
    parser.add_argument("inputs", nargs="*", help="saved files to analyze (with no --app)")
    parser.add_argument("--app", help="a staged `cmux DEV <tag>.app`: launch it --runs times (fleet only)")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--temperature", choices=["warm", "cold"], default="warm")
    parser.add_argument("--timeout", type=float, default=60.0, help="seconds per launch to reach --until-mark")
    parser.add_argument("--until-mark", default=COMPLETE)
    parser.add_argument("--first-frame-mark", default=FIRST_FRAME)
    parser.add_argument("--mode-filter", help="gaps: only this bench-startup mode (cold, warm, ...)")
    parser.add_argument("--min-ms", type=float, default=5.0, help="gaps: the smallest median gap kept")
    parser.add_argument("--symbol-ms", type=float, default=2.0)
    parser.add_argument("--turn-ms", type=float, default=4.0)
    parser.add_argument("--once-ms", type=float, default=1.0)
    parser.add_argument("--job-ms", type=float, default=1.0)
    parser.add_argument("--job-count", type=float, default=5.0)
    parser.add_argument("--raw", help="write the live runs here (the mode reads it back as an input)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.gettempdir(),
                        help="profile --app: where the trace recordings go")
    parser.add_argument("--json", help="write the hits here (`-` for stdout)")
    parser.add_argument("--check", action="store_true", help="exit 1 when there is any hit")
    args = parser.parse_args(argv)
    if bool(args.app) == bool(args.inputs):
        parser.error("give saved input files or --app, not both and not neither")
    if args.app and args.mode == "gaps":
        parser.error("gaps reads bench-startup.py --json files (run bench-startup.py for new ones)")
    return args


def live_inputs(args, env, system):
    """Runs the app on the fleet and returns what the mode reads: trace folders or capture runs."""
    refusal = fleet_refusal(env, system)
    if refusal:
        raise QueueError(refusal)
    if args.mode == "profile":
        return record_profiles(args.app, args.runs, args.temperature, args.out)
    bench = load_bench_startup()
    bench.require_gui_session("startup-queue")
    method = "debug.blocking" if args.mode == "blocking" else "debug.startup"
    runs = collect(bench, args.app, args.runs, args.temperature, args.until_mark, args.timeout, method)
    if args.raw:
        with open(args.raw, "w") as out:
            json.dump({"mode": args.mode, "app": os.path.basename(args.app), "runs": runs}, out, indent=1)
    return runs


def analyze(args, inputs):
    """(hits, warnings, runs used, thresholds) of the mode over its inputs."""
    if args.mode == "gaps":
        return (*gaps_hits(inputs, args.min_ms, args.mode_filter), {"min_ms": args.min_ms})
    if args.mode == "profile":
        thresholds = {"symbol_ms": args.symbol_ms, "turn_ms": args.turn_ms, "once_ms": args.once_ms}
        return (*profile_hits(inputs, args.first_frame_mark, args.until_mark, **thresholds), thresholds)
    runs = capture_runs(inputs) if args.app else load_captures(inputs)
    if args.mode == "blocking":
        return (*blocking_hits(runs, args.until_mark), {"until_mark": args.until_mark})
    if args.mode == "mainjobs":
        found = mainjobs_hits(runs, args.first_frame_mark, args.until_mark, args.job_ms, args.job_count)
        return (*found, {"job_ms": args.job_ms, "job_count": args.job_count})
    if args.mode == "globaljobs":
        return (*globaljobs_hits(runs, args.until_mark), {"until_mark": args.until_mark})
    return (*arms_hits(runs, args.until_mark), {"until_mark": args.until_mark})


def report(args, hits, warnings, used, thresholds):
    queue, template = QUEUES[args.mode]
    document = {"mode": args.mode, "queue": queue, "template": template, "runs": used,
                "temperature": args.temperature if args.app else None, "thresholds": thresholds,
                "warnings": warnings, "hits": hits}
    for line in warnings:
        print(f"warning: {line}", file=sys.stderr)
    stream = sys.stderr if args.json == "-" else sys.stdout
    print(f"{queue} {args.mode}: {len(hits)} hits over {used} runs (template {template})", file=stream)
    for hit in hits:
        print(f"  {hit['summary']}", file=stream)
    if args.json == "-":
        json.dump(document, sys.stdout, indent=1)
        print()
    elif args.json:
        with open(args.json, "w") as out:
            json.dump(document, out, indent=1)
    return document


def main(argv=None, env=None, system=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    inputs = args.inputs
    if args.app:
        inputs = live_inputs(args, os.environ if env is None else env, system or platform.system())
    hits, warnings, used, thresholds = analyze(args, inputs)
    if used == 0:
        raise QueueError("no usable run in the input" + (f": {warnings[-1]}" if warnings else ""))
    report(args, hits, warnings, used, thresholds)
    return 1 if args.check and hits else 0


if __name__ == "__main__":
    sys.exit(main())
