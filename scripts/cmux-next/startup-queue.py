#!/usr/bin/env python3
"""Startup machine queues (plans/cmux-next/chrome-parity/p08-startup.md, section 6): each hit is one task.

Every mode reads saved files (any host, Linux included) or, with --app, launches the app N times on a fleet
Mac and reads what the launch recorded. Each hit names its queue and the task template that fixes it.

  blocking    Q5, template 038. Main-thread blocking sites (`debug.blocking`, a Debug or `reload.sh --config
              bench-checks` build) first hit before --until-mark (default startup_complete). Any run counts. A
              report without `compiled_in: true` (a `--config bench` app has no detector, so its sites are always
              empty) is refused, never read as a clean launch.
              debug.blocking has no per-site `first_ms` yet (BlockingDetector keeps no first-hit time): such a
              site is counted, and the output warns that the launch window is not proved.
  gaps        Q7, template 039. Gaps between consecutive time marks of each run of a bench-startup.py --json
              file, grouped by (from, to) across runs, kept at median >= --min-ms. VALUE_MARKS are not times.
              Interrupted launches (`launch.interrupted`) are left out.
  profile     Q6, template 039. From trace.py launch recordings (trace.json.gz, or the directory holding it):
              app symbols with median >= --symbol-ms inclusive on main before --first-frame-mark; main turns
              >= --turn-ms before --until-mark; swift_once initializers and static initializers >= --once-ms.
  mainjobs    Q11, template 081. From `debug.startup` and `debug.startup.main_jobs` (task 080; a live run arms
              the census with CMUX_NEXT_MAIN_JOB_CENSUS=1): each main-job enqueuer with a median >= --job-ms total
              or >= --job-count jobs before --first-frame-mark, and each main turn before --until-mark that ran
              outside a StartupScheduler task and the allowlist. A run whose census was not armed or whose hook
              did not install is left out with a warning; a ring that dropped jobs is a warning.
  globaljobs  Q12, template 083. From `debug.startup` and `debug.startup.global_jobs` (task 082; a live run arms
              the census with CMUX_NEXT_GLOBAL_JOB_CENSUS=1): each caller of utility, background or unprioritized
              tasks started on the cooperative pool before --until-mark that is not a BackgroundWork lane job. A
              BackgroundWork.task is listed: it starts at once, outside the launch fence. The census is Swift's global-enqueue hook: GCD blocks (`DispatchQueue.global()`) are not in it. A run
              whose census was not armed or whose hook did not install is left out with a warning; a task the
              census counted and did not keep is a warning.
  arms        Q13, template 086. From `debug.startup`: each timer, watcher and observer armed before
              --until-mark, with its median arm and first-fire times.

Usage:
  startup-queue.py gaps warm.json --min-ms 5 [--json out.json]
  startup-queue.py blocking raw.json                     analyze a saved capture (any host)
  startup-queue.py blocking --app "$NX_APP" --runs 5 --temperature warm|cold [--raw raw.json] [--json out.json]
  startup-queue.py profile run1/ run2/ ...               or --app: N `trace.py record --scenario launch-<temp>`
  startup-queue.py mainjobs|globaljobs|arms --app "$NX_APP" --runs 5

Fleet guard: --app runs only on macOS with a fleet marker, never on a person's Mac; elsewhere it exits 2 before it
starts anything. Markers: CMUX_CI_STEP_KEY (`cmux-ci run`) or GITHUB_ACTIONS=true (lib/fleet-only.sh's rule), and
NX_JOB_ID (an nx-remote job, the marker scripts/measure/blocking-probe.sh accepts), because a live launch needs the
GUI session of `nx-remote --needs gui`. Live launches are normal activated launches (CMUX_NEXT_NO_ACTIVATE=0): the
launch these queues measure. A noActivate launch is an interrupted launch (task 108).

--json writes {"mode", "queue", "template", "runs", "thresholds", "warnings", "hits": [...]} (`-` for stdout).
--check exits 1 when there is any hit. --raw saves the live runs, which the same mode reads back as input.

Input contract. All times are ms since process start (the launch-mark clock, LaunchMarkSink.swift).
  bench-startup.py --json: {tag: {mode: [{mark: ms, ...}, ...]}}.
  debug.blocking: {"compiled_in", "mode", "overflow", "contexts"?: {ctx: {"overflow", ...}},
    "sites": [{"context"?, "kind", "location", "count", "first_ms"?}]}. Q5 reads only `main` sites (a site with
    no `context` is a main one); a `pool` site already runs off the main thread.
  debug.startup (tasks 008, 080, 082, 085): {"milestones": {mark: ms}, "interrupted"?: bool,
    "main_jobs": [{"caller", "kind", "priority", "enqueued_ms", "run_ms"}],
    "main_turns": [{"start_ms", "duration_ms", "task": name or null, "allowlisted": bool, "site"}],
    "main_job_census": {"armed", "hook", "dropped_jobs", "dropped_turns", ...},
    "global_jobs": [{"caller", "priority": name or number or null, "lane": name or null, "via": name or null,
                     "enqueued_ms", "run_ms"}],
    "global_job_census": {"armed", "hook", "dropped_tasks", "untracked_tasks", "pending_tasks", ...},
    "arms": [{"kind", "owner", "site", "armed_ms", "first_fire_ms": ms or null}]}.
    Each census mode needs its arrays in a run (mainjobs: main_jobs and main_turns; globaljobs: global_jobs;
    arms: arms). A run without them is left out; no run with them exits 2. Task 080's census answers its three
    keys on its own method, `debug.startup.main_jobs` (main_jobs kinds: main_actor, main_delivery,
    run_loop_block, timer (caller `timer <owner>`), run_loop_sources, run_loop_wake; a caller of `unknown` is a
    job whose stack held no frame of its enqueuer); a live mainjobs run merges that reply into debug.startup's
    (which it may lack). Task 082's census answers its two keys
    on its own method, `debug.startup.global_jobs` (one record per task, at its first enqueue on the pool; no `lane`,
    because lane items do not reach the pool; `via` `background_work_task` for a task BackgroundWork.task started,
    which is still a hit; `run_ms` null: the hook sees the enqueue, not the run); a live globaljobs run
    merges that reply into debug.startup's (which it may lack). global_jobs' priority is null or 0 when
    the job has none (082); 21 / default / medium (what a Task.detached or a DispatchQueue.global()
    with no priority runs at) is counted as `default`.
  `launch.interrupted` (a mark, or the result's `interrupted`) means interrupted when present and not false or
  null; a mark at 0 ms counts.
  A saved capture (--raw): {"mode", "runs": [{"marks": {...}, "result": <method result>}]}; its mode must read the
  same method (blocking: debug.blocking; mainjobs, globaljobs, arms: debug.startup). A bare result, a list of
  results or a control reply ({"result": ...}) are read too.
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
import shutil
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
# The debug.startup arrays each census mode reads: a result without them has no census, not an empty one.
CENSUS_FIELDS = {"mainjobs": ("main_jobs", "main_turns"), "globaljobs": ("global_jobs",), "arms": ("arms",)}
# Swift TaskPriority raw values (and their names) that Q12 names. null / 0: no priority recorded; 21 / default /
# medium: what a Task.detached or a DispatchQueue.global() given no priority runs at.
GLOBAL_PRIORITIES = {"utility": "utility", "low": "utility", 17: "utility", "background": "background",
                     9: "background", "unspecified": "unspecified", None: "unspecified", 0: "unspecified",
                     21: "default", "default": "default", "medium": "default"}
# Numeric run keys that are values, not times (tasks 006, 007; p09-observability-034's run-loop page-ins): never
# ordered or paired as a gap. bench-startup.py's VALUE_MARKS.
VALUE_MARKS = frozenset({"launch.temperature", "launch.pageins_run_loop_start", "launch.pageins_first_frame",
                         "launch.main_cpu_ms", "launch.interrupted", "launch.sidebar_rows_built",
                         "launch.sidebar_rows_visible", "launch.views_built", "launch.first_frame_threads",
                         "launch.first_frame_runtime_threads", "launch.first_frame_ghostty_threads"})
INTERRUPTED = "launch.interrupted"
# A live launch takes its window as a person's launch does; a noActivate launch is interrupted (task 108).
LIVE_ENV = {"CMUX_NEXT_NO_ACTIVATE": "0"}
# What a census mode adds to a live run: the environment that arms its recorder and the method that answers it (task
# 080's main-job census and 082's global-job census are off unless armed, so the startup benches measure a launch
# without them).
MODE_ENV = {"mainjobs": {"CMUX_NEXT_MAIN_JOB_CENSUS": "1"}, "globaljobs": {"CMUX_NEXT_GLOBAL_JOB_CENSUS": "1"}}
MODE_METHOD = {"mainjobs": "debug.startup.main_jobs", "globaljobs": "debug.startup.global_jobs"}
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
    """Why a live run may not start on this host, or None on the fleet: lib/fleet-only.sh's markers
    (CMUX_CI_STEP_KEY, GITHUB_ACTIONS=true) and NX_JOB_ID, an nx-remote job (blocking-probe.sh's marker)."""
    if system != "Darwin":
        return (f"--app launches the app on a macOS fleet host; this host runs {system}. "
                "Analyze saved files here instead (startup-queue.py MODE FILE...).")
    if env.get("CMUX_CI_STEP_KEY") or env.get("GITHUB_ACTIONS") == "true" or env.get("NX_JOB_ID"):
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


def flagged(mapping, key):
    """A flag: present with any value but null or false (a mark at 0 ms is set)."""
    value = mapping.get(key)
    return value is not None and value is not False  # identity: 0 == False, yet a mark at 0 ms is set


def interrupted(run):
    return flagged(run["marks"], INTERRUPTED) or flagged(run["result"], "interrupted")


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


def method_of(mode):
    return "debug.blocking" if mode == "blocking" else "debug.startup"


def load_captures(paths, mode):
    """Every run of the files; a saved capture of the other method is refused (exit 2)."""
    runs = []
    for path in paths:
        data = read_json(path)
        saved = data.get("mode") if isinstance(data, dict) and isinstance(data.get("runs"), list) else None
        if saved in QUEUES and method_of(saved) != method_of(mode):
            raise QueueError(f"{path}: a {saved} capture ({method_of(saved)}); {mode} reads {method_of(mode)}")
        runs += capture_runs(data)
    return runs


# ---- Q5 blocking -------------------------------------------------------------------------------------------

# Why a debug.blocking report without the detector is refused: its empty sites would read as a clean launch.
NO_DETECTOR = ("the build has no blocking detector (debug.blocking compiled_in is not true; a `reload.sh --config "
               "bench` app always reports no sites): measure a `--config bench-checks` or Debug build")


def main_overflow(result):
    """The main thread's unrecorded blocking calls: `contexts.main.overflow`, else the total `overflow` (a result
    from before the detector split it by context)."""
    contexts = result.get("contexts")
    main = contexts.get("main") if isinstance(contexts, dict) else None
    if isinstance(main, dict) and number(main.get("overflow")) is not None:
        return int(number(main["overflow"]))
    return int(number(result.get("overflow")) or 0)


def blocking_hits(runs, until_mark):
    """Each main-thread blocking site first hit before the mark, in any run; most runs first."""
    sites, warnings, used, unproved = {}, [], 0, 0
    for index, run in enumerate(runs):
        result, limit = run["result"], cutoff(run["marks"], until_mark)
        if interrupted(run):
            warnings.append(f"run {index + 1}: interrupted launch, left out")
            continue
        if not isinstance(result.get("sites"), list):
            warnings.append(f"run {index + 1}: no sites (not a debug.blocking result), left out")
            continue
        if result.get("compiled_in") is not True:
            warnings.append(f"run {index + 1}: {NO_DETECTOR}, left out")
            continue
        if limit is None:
            warnings.append(f"run {index + 1}: no {until_mark} mark, left out (its launch window is unknown)")
            continue
        used += 1
        overflow = main_overflow(result)
        if overflow:
            warnings.append(f"run {index + 1}: {overflow} sites past the detector's table")
        for site in result["sites"]:
            if not isinstance(site, dict) or site.get("context", "main") != "main":
                continue
            first = number(site.get("first_ms"))
            if first is not None and first > limit:
                continue
            unproved += first is None
            key = (str(site.get("kind", "?")), str(site.get("location", "?")))
            entry = sites.setdefault(key, {"runs": 0, "count": 0, "proved": True})
            entry["runs"] += 1
            entry["count"] += int(number(site.get("count")) or 0)
            entry["proved"] = entry["proved"] and first is not None
    if unproved:
        warnings.append(f"{unproved} sites have no first_ms (debug.blocking keeps no first-hit time): counted, but "
                        f"they may first block after {until_mark}, so the launch window is not proved")
    hits = [{"kind": kind, "location": location, "runs": entry["runs"], "count": entry["count"],
             "first_ms_known": entry["proved"],
             "summary": f"{entry['runs']}/{used} runs, {entry['count']} calls: {kind} at {location}"
                        + ("" if entry["proved"] else " (no first_ms)")}
            for (kind, location), entry in sites.items()]
    hits.sort(key=lambda hit: (-hit["runs"], -hit["count"], hit["location"]))
    return hits, warnings, used


# ---- Q7 gaps -----------------------------------------------------------------------------------------------


def time_marks(run):
    """The run's time marks (numbers that are not VALUE_MARKS), in the order they landed."""
    marks = sorted((number(value), name) for name, value in run.items()
                   if name not in VALUE_MARKS and number(value) is not None)
    return [(name, value) for value, name in marks]


def mark_gaps(runs, min_ms, label):
    """Each run's gaps between its own consecutive time marks, grouped by (from, to) across runs, kept at median
    >= min_ms. A mark that lands in some runs only never hides the gap of the runs without it."""
    pairs = collections.defaultdict(list)
    for run in runs:
        marks = time_marks(run)
        for (before, start), (after, end) in zip(marks, marks[1:]):
            pairs[(before, after)].append(end - start)
    hits = []
    for (before, after), gaps in pairs.items():
        median = statistics.median(gaps)
        if median < min_ms:
            continue
        hits.append({"run_set": label, "from": before, "to": after, "p50_ms": round(median, 1),
                     "p95_ms": round(p95(gaps), 1), "max_ms": round(max(gaps), 1), "n": len(gaps),
                     "summary": f"{label}: {before} -> {after} p50 {median:.1f} ms, p95 {p95(gaps):.1f} ms, "
                                f"n {len(gaps)}/{len(runs)}"})
    return hits


def gaps_hits(paths, min_ms, only_mode):
    hits, warnings, used = [], [], 0
    for path in paths:
        data = read_json(path)
        if not isinstance(data, dict):
            raise QueueError(f"{path}: expected a bench-startup.py --json file ({{tag: {{mode: [runs]}}}})")
        for tag, modes in data.items():
            if not isinstance(modes, dict) or not all(isinstance(runs, list) for runs in modes.values()):
                raise QueueError(f"{path}: {tag}: expected {{mode: [runs]}} (a bench-startup.py --json file)")
            for mode, runs in modes.items():
                if only_mode and mode != only_mode:
                    continue
                if not all(isinstance(run, dict) for run in runs):
                    raise QueueError(f"{path}: {tag} {mode}: each run must be a {{mark: ms}} object "
                                     "(a bench-startup.py --json file)")
                kept = [run for run in runs if not flagged(run, INTERRUPTED)]
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


def census_runs(runs, marks_needed, fields):
    """The runs that can be classified (not interrupted, every needed mark and census array present), and why
    others were not. A result without the arrays comes from a build without the census, not a clean launch."""
    kept, warnings = [], []
    for index, run in enumerate(runs):
        missing = [name for name in marks_needed if cutoff(run["marks"], name) is None]
        absent = [field for field in fields if not isinstance(run["result"].get(field), list)]
        if interrupted(run):
            warnings.append(f"run {index + 1}: interrupted launch, left out")
        elif missing:
            warnings.append(f"run {index + 1}: no {', '.join(missing)} mark, left out")
        elif absent:
            warnings.append(f"run {index + 1}: no {', '.join(absent)} (a build without the census), left out")
        else:
            kept.append(run)
    return kept, warnings


def census_state(runs):
    """The runs whose main-job census recorded (task 080's `main_job_census`), and why others were left out. A result
    with no summary (a saved file from before it) is kept; one that says not armed, or a hook that did not install
    (no main-actor job recorded), is not a census."""
    kept, warnings = [], []
    for index, run in enumerate(runs):
        state = run["result"].get("main_job_census")
        if not isinstance(state, dict):
            kept.append(run)
        elif state.get("armed") is False:
            warnings.append(f"run {index + 1}: the main-job census was not armed (CMUX_NEXT_MAIN_JOB_CENSUS=1), left out")
        elif state.get("hook") not in (None, "installed"):
            warnings.append(f"run {index + 1}: main-actor job hook {state.get('hook')}, left out")
        else:
            for field, what in (("dropped_jobs", "jobs"), ("dropped_turns", "turns"), ("dropped_segments", "run-loop stretches")):
                if number(state.get(field)):
                    warnings.append(f"run {index + 1}: the census ring was full: {state[field]:g} {what} not recorded")
            kept.append(run)
    return kept, warnings


def mainjobs_hits(runs, first_frame_mark, until_mark, job_ms, job_count):
    armed, refused = census_state(runs)
    kept, warnings = census_runs(armed, (first_frame_mark, until_mark), CENSUS_FIELDS["mainjobs"])
    warnings = refused + warnings
    totals, counts = collections.defaultdict(list), collections.defaultdict(list)
    turns = collections.defaultdict(lambda: {"runs": 0, "durations": []})
    for run in kept:
        first_frame, complete = cutoff(run["marks"], first_frame_mark), cutoff(run["marks"], until_mark)
        run_ms, run_count = collections.defaultdict(float), collections.defaultdict(int)
        for job in run["result"]["main_jobs"]:
            if (number(job.get("enqueued_ms")) or 0.0) < first_frame:
                key = (str(job.get("kind", "?")), str(job.get("caller", "?")))
                run_ms[key] += number(job.get("run_ms")) or 0.0
                run_count[key] += 1
        for key in run_count:
            totals[key].append(run_ms[key])
            counts[key].append(run_count[key])
        seen = set()
        for turn in run["result"]["main_turns"]:
            if (number(turn.get("start_ms")) or 0.0) >= complete or turn.get("task") or turn.get("allowlisted"):
                continue
            site = str(turn.get("site", "?"))
            turns[site]["durations"].append(number(turn.get("duration_ms")) or 0.0)
            turns[site]["runs"] += site not in seen
            seen.add(site)
    jobs = []
    for (kind, caller), values in totals.items():
        ms, count = median_over(values, len(kept)), median_over(counts[(kind, caller)], len(kept))
        if ms >= job_ms or count >= job_count:
            jobs.append({"kind": kind, "caller": caller, "p50_ms": round(ms, 2), "p50_count": count,
                         "runs": len(values), "summary": f"{kind} jobs from {caller}: p50 {ms:.1f} ms, "
                                                         f"{count:g} jobs before {first_frame_mark}"})
    # A job hit's p50 is a per-run total, a turn hit's one turn's duration: each list ranks on its own.
    unscheduled = []
    for site, entry in turns.items():
        durations = entry["durations"]
        median, longest = statistics.median(durations), max(durations)
        unscheduled.append({"kind": "unscheduled_turn", "caller": site, "runs": entry["runs"],
                            "count": len(durations), "p50_ms": round(median, 2), "max_ms": round(longest, 2),
                            "summary": f"main turn outside a startup task at {site}: {entry['runs']}/{len(kept)} "
                                       f"runs, {len(durations)} turns before {until_mark}, p50 {median:.1f} ms, "
                                       f"max {longest:.1f} ms"})
    jobs.sort(key=lambda hit: (-hit["runs"], -hit["p50_ms"], hit["caller"]))
    unscheduled.sort(key=lambda hit: (-hit["runs"], -hit["p50_ms"], hit["caller"]))
    return jobs + unscheduled, warnings, len(kept)


def global_priority(value):
    return GLOBAL_PRIORITIES.get(value.lower() if isinstance(value, str) else value)


def global_census_state(runs):
    """The runs whose global-job census recorded (task 082's `global_job_census`), and why others were left out. A
    result with no summary (a saved file from before it) is kept; one that says not armed, or a hook that did not
    install (no task recorded), is not a census. What the census counted and did not keep is a warning."""
    kept, warnings = [], []
    for index, run in enumerate(runs):
        state = run["result"].get("global_job_census")
        if not isinstance(state, dict):
            kept.append(run)
        elif state.get("armed") is False:
            warnings.append(f"run {index + 1}: the global-job census was not armed (CMUX_NEXT_GLOBAL_JOB_CENSUS=1), "
                            "left out")
        elif state.get("hook") not in (None, "installed"):
            warnings.append(f"run {index + 1}: global-enqueue hook {state.get('hook')}, left out")
        else:
            for field, what in (("dropped_tasks", "tasks past the ring"), ("untracked_tasks", "tasks past the id bitmap"),
                                ("pending_tasks", "tasks still being written")):
                if number(state.get(field)):
                    warnings.append(f"run {index + 1}: the census did not keep {state[field]:g} {what}")
            kept.append(run)
    return kept, warnings


def globaljobs_hits(runs, until_mark):
    armed, refused = global_census_state(runs)
    kept, warnings = census_runs(armed, (until_mark,), CENSUS_FIELDS["globaljobs"])
    warnings = refused + warnings
    callers = {}
    for run in kept:
        complete = cutoff(run["marks"], until_mark)
        seen = set()
        for job in run["result"]["global_jobs"]:
            priority = global_priority(job.get("priority"))
            if job.get("lane") or priority is None or (number(job.get("enqueued_ms")) or 0.0) >= complete:
                continue
            caller = str(job.get("caller", "?"))
            entry = callers.setdefault(caller, {"runs": 0, "count": 0, "ms": 0.0, "priorities": set(), "via": set()})
            entry["count"] += 1
            entry["ms"] += number(job.get("run_ms")) or 0.0
            entry["priorities"].add(priority)
            if job.get("via"):
                entry["via"].add(str(job["via"]))
            entry["runs"] += caller not in seen
            seen.add(caller)
    hits = [{"caller": caller, "priorities": sorted(entry["priorities"]), "via": sorted(entry["via"]),
             "runs": entry["runs"], "count": entry["count"], "total_ms": round(entry["ms"], 2),
             "summary": f"{'/'.join(sorted(entry['priorities']))} jobs from {caller} outside a lane"
                        f"{''.join(f' (via {via})' for via in sorted(entry['via']))}: "
                        f"{entry['runs']}/{len(kept)} runs, {entry['count']} jobs before {until_mark}"}
            for caller, entry in callers.items()]
    hits.sort(key=lambda hit: (-hit["runs"], -hit["count"], hit["caller"]))
    return hits, warnings, len(kept)


def arms_hits(runs, until_mark):
    kept, warnings = census_runs(runs, (until_mark,), CENSUS_FIELDS["arms"])
    arms = {}
    for index, run in enumerate(kept):
        complete = cutoff(run["marks"], until_mark)
        for arm in run["result"]["arms"]:
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


def prepare(bench, tag, temperature, scratch, timeout, purge_cache, env=LIVE_ENV):
    """Cold: no daemon and an empty file cache. Warm: a priming launch leaves the daemon running."""
    if bench.app_pids(tag):
        raise QueueError(f"tag {tag} has an app running; quit it first (each measured launch starts its own app)")
    if temperature == "cold":
        bench.stop(bench.tag_pids(tag))
        purge_cache()
    elif not bench.tag_pids(tag):
        prime = bench.Launch(tag, scratch, extra_env=env)
        prime.wait_for([FIRST_FRAME, bench.FINAL_MARK], timeout, any_of=True)
        prime.quit()


def query(bench, tag, method, required=True):
    """`method`'s result; an optional method this build lacks reads as {}."""
    client = bench.app_client(tag)
    try:
        reply = client.call(method)
    finally:
        client.close()
    if not isinstance(reply.get("result"), dict) and not required:
        return {}
    if not isinstance(reply.get("result"), dict):
        raise QueueError(f"{method} answered {reply.get('error')!r}: the build needs CMUX_BENCH_HOOKS "
                         "(or Debug), and for debug.blocking `reload.sh --config bench-checks`")
    if method == "debug.blocking" and reply["result"].get("compiled_in") is not True:
        raise QueueError(f"{method}: {NO_DETECTOR}")
    return reply["result"]


def collect(bench, app, runs, temperature, until_mark, timeout, method, purge_cache=purge, extra_method=None,
            extra_env=None):
    """N launches; each is read with `method` once `until_mark` arrived on the mark pipe, then quit. With
    `extra_method` that method's result is merged in and `method` may be missing; `extra_env` is added to each launch.

    At the end it stops only the tag's processes it started (a warm daemon that ran before is left running; a
    cold run stops the daemon before each launch, as cold means) and removes its scratch folders."""
    tag = bench.app_tag(app)
    bench.APPS[tag] = os.path.abspath(app)
    captured, scratches = [], []
    before = set(bench.tag_pids(tag))
    try:
        for index in range(runs):
            scratch = tempfile.mkdtemp(prefix=f"startup-queue-{tag}-")
            scratches.append(scratch)
            with open(os.path.join(scratch, "cmux.json"), "w") as out:
                out.write("{}\n")
            env = {**LIVE_ENV, **(extra_env or {})}
            prepare(bench, tag, temperature, scratch, timeout, purge_cache, env)
            launch = bench.Launch(tag, scratch, extra_env=env)
            try:
                if not launch.wait_for(until_mark, timeout):
                    raise QueueError(f"run {index + 1}: {until_mark} never arrived within {timeout:g} s "
                                     "(pass --until-mark for a build without it)")
                result = query(bench, tag, method, required=extra_method is None)
                if extra_method:
                    result = {**result, **query(bench, tag, extra_method)}
            finally:
                launch.quit()
            captured.append({"index": index + 1, "temperature": temperature, "marks": dict(launch.marks),
                             "result": result})
            print(f"  run {index + 1}/{runs}: {until_mark} at {launch.marks[until_mark]:.0f} ms", file=sys.stderr)
    finally:
        bench.stop([pid for pid in bench.tag_pids(tag) if pid not in before])
        for scratch in scratches:
            shutil.rmtree(scratch, ignore_errors=True)
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
    runs = collect(bench, args.app, args.runs, args.temperature, args.until_mark, args.timeout, method_of(args.mode),
                   extra_method=MODE_METHOD.get(args.mode), extra_env=MODE_ENV.get(args.mode))
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
    runs = capture_runs(inputs) if args.app else load_captures(inputs, args.mode)
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
