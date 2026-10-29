#!/usr/bin/env python3
"""Story blocking-hangs: blocking-call sites and hang counts per thread role during the STRESS storm and each
corpus story, on a `--config bench-checks` build.

Each leg reads every source when its measured window opens and when it closes, and stores the difference, so
nothing is cleared:
  debug.blocking   the blocking detector's call sites (CMUX_BLOCKING_CHECKS), per context: main, pool, cpu-lane.
  debug.hangs      `count250` (main-thread work gaps of 250 ms or more), the stall records (the watchdog's hang
                   threshold is set to 250 ms for the storm, so each such stall carries its main-thread stack) and
                   `thread_hangs` (hang-watch scopes on other threads past their deadline: background lanes, IO,
                   renderers, pool workers, control handlers), each with its stack.

Chrome does the same split: `base/threading/scoped_blocking_call.h` and `thread_restrictions.h` find blocking calls
on threads that must not block (a DCHECK build, here bench-checks), and `base/threading/hang_watcher.h` counts hangs
per thread type (`HangWatcher.IsThreadHung.BrowserProcess.UIThread`, `.IOThread`, `.ThreadPool`).

Metrics of a leg (a corpus leg's names start with `corpus.<id>.`; each is a count, lower is better):
  main_blocking.sites              unique main-thread blocking sites hit in the window (target main-blocking-sites).
                                   When calls in the window overflowed the site table, those calls are at sites the
                                   table does not hold, so the value is the known sites plus one, a lower bound.
  blocking.sites.pool, blocking.sites.cpu_lane   the same for the shared pool and `.cpu` lane items.
  hangs.over_250ms.main            main-thread work gaps of 250 ms or more (target hangs.app).
  hang_watch.past_deadline.<role>  hang-watch scopes past their deadline per thread role, for the roles the app
                                   registers (REGISTERED_ROLES: lane) and any role a record shows; `unattributed` for
                                   records the 128-record ring dropped. Every other role is unseen. HangMonitor writes
                                   a record once, at the deadline, while the scope still runs, so the scope's length
                                   is not known and these are not called hangs over 250 ms.

A source the leg cannot read is never stored as 0. A build without the detector (`debug.blocking` `compiled_in` is
not true, or the bundle says another `CMUXBuildConfiguration`) fails the story with that reason before any leg is
measured (exit 1). A build without `debug.blocking` or `debug.hangs` is not-measurable (exit 4). A leg whose
watchdog is not running fails.

Results: one result-v1 file per leg in --out (BenchApp.record fills build, host and features), each result with the
leg's attachment (kind `blocking-hangs`: the window's sites with their counts and times, each main stall and thread
hang with its frames). The blob is uploaded to the lab's R2 bucket at
`perf-lab/attachments/sha256/<hex>.json` (configured as for trace_quest.py, CMUX_PERF_LAB_R2_*; without it the
story measures nothing, exit 1); a copy stays at --out/attachments/. Each launched app's full host validation
(`host-env-full-<pid>.json`) is copied under --out for the runner. blocking-hangs-summary.json says what each leg saw.

Legs: `storm` is trace.py's stress-storm scenario with no profiler; `corpus:<id>` replays each non-T2 corpus story
(perf-corpus/<id>.json, task 110) through scripts/perf-lab/corpus/play.py's `replay(manifest, *, app, out, window)`
(task 115; the hook's contract is in p12-perf-process.md 3.8): after its launch the player calls `window(bench)`
with its BenchApp once and plays the input track inside the context manager it returns. A checkout without the
corpus, a manifest or the player has no corpus half: the summary says why, and it does not fail the story. A player
without the hook, or one that fails, fails that leg; a failed launch (bench_launch.LaunchError) fails only its leg.

Usage (the story runner appends --app, --tag and --out):
  python3 -I scripts/perf-lab/stories/blocking_hangs.py --app APP --tag TAG --out DIR [--legs storm,corpus]
                                                         [--corpus all|ID,...] [--seconds 30]
Exit: 0 every leg that ran measured (with no corpus half, the storm alone); 1 a leg failed, or the build has no
detector; 2 usage; 4 not measurable; 128+N signal N.
"""
from __future__ import annotations

import argparse
import dataclasses
import glob
import hashlib
import importlib.util
import inspect
import json
import math
import os
import shutil
import socket
import subprocess
import sys
import tempfile
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_LAB = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(PERF_LAB))
CMUX_NEXT = os.path.join(ROOT, "scripts", "cmux-next")
TRACE = os.path.join(CMUX_NEXT, "trace.py")
BENCH_LAUNCH = os.path.join(CMUX_NEXT, "bench_launch.py")
PERF_RESULT = os.path.join(PERF_LAB, "perf_result.py")
TRACE_QUEST = os.path.join(PERF_LAB, "trace_quest.py")

STORY = "blocking-hangs"
ENGINE = "none"
CONFIG = "bench-checks"
# BlockingContext raw values (CmuxNextCompat/Threading/BlockingContext.swift) and their metric names.
CONTEXTS = (("main", "main_blocking.sites"), ("pool", "blocking.sites.pool"), ("cpu-lane", "blocking.sites.cpu_lane"))
# HangWatch.ThreadKind names (CmuxNextTrace/HangWatch.swift), as HangMonitor writes them into `thread_kind`.
THREAD_ROLES = ("main", "io", "lane", "renderer", "pool", "control")
# The kinds the app registers with HangWatch: only lanes (HangWatchedLane: LineTransport `daemon.line`,
# TerminalOutputLane `terminal.feed`, the BackgroundWork lanes); no code calls registerThread. Another role is
# measured only when a record of it shows its registration, else it is unseen, never 0.
REGISTERED_ROLES = ("lane",)
UNREGISTERED = "no thread of this kind is registered with HangWatch"
TARGETS = {"main_blocking.sites": "main-blocking-sites",
           "hangs.over_250ms.main": "hangs.app"}  # targets.json row ids; only the storm leg claims them
HANG_MS = 250  # the watchdog's stall threshold for the storm: each stall the count250 counter counts has a stack
ATTACHMENT_KIND = "blocking-hangs"
ATTACHMENT_SCHEMA = "cmux-blocking-hangs/v1"
ATTACHMENT_PREFIX = "perf-lab/attachments/sha256/"
SUMMARY = "blocking-hangs-summary.json"
HOST_CHECK_GLOB = "host-env-full-*.json"  # bench_launch.LAB_CHECK_PREFIX: the runner keeps a run's results only with it
# trace.py stages up to and including the measured window: an error there means the window was not the storm.
MEASURED_STAGES = ("preflight", "launch", "stress-build", "storm-setup", "recorders-start", "window")
TRACE_KEEP = ("SUMMARY.txt", "summary.json", "meta.json", "hangs.json")
# An `*_after` sequence past every record, so the reply leaves that list out. Below 1e15: JSONValue.intValue
# (CmuxNextSettings/JSONValue.swift) reads a larger number as nil, and debug.hangs then sends the whole list.
SKIP_RECORDS = 10 ** 15 - 1

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_NOT_MEASURABLE = 0, 1, 2, 4


class NotMeasurable(Exception):
    """The build lacks a method the story reads: its Change is not-measurable, never a regression."""


class NoDetector(Exception):
    """The build has no blocking detector (not bench-checks): the story fails, it never reads 0 sites."""


class LegError(Exception):
    """A leg ran but measured nothing it can store."""


def load_by_path(name: str, path: str):
    """The module at `path` as `name`, once per process (python3 -I puts no script folder on sys.path)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"{STORY}: no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def launch_error() -> type:
    """bench_launch.LaunchError, the shared copy trace.py and play.py raise. It is a SystemExit, so a leg catches
    it by name: a launch that fails ends that leg, not the story."""
    return load_by_path("bench_launch", BENCH_LAUNCH).LaunchError


# ---------------------------------------------------------------- readings


def check_reply(method: str, reply) -> dict:
    """The reply's object. NotMeasurable when the build has no such method; LegError for another failure."""
    if isinstance(reply, dict) and reply.get("error") is not None:
        error = reply["error"]
        if isinstance(error, dict) and error.get("code") in ("method_not_found", "not_allowed"):
            raise NotMeasurable(f"the build has no {method} ({error.get('code')})")
        raise LegError(f"{method} failed: {json.dumps(error)[:300]}")
    if not isinstance(reply, dict):
        raise LegError(f"{method} answered {json.dumps(reply)[:200]}")
    return reply


def _count(value, what: str) -> int:
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise LegError(f"{what} is not a count: {json.dumps(value)[:80]}")
    return value


@dataclasses.dataclass(frozen=True)
class Site:
    context: str
    kind: str
    seam_kind: str
    location: str
    count: int
    total_ms: float
    max_ms: float

    @property
    def key(self) -> Tuple[str, str, str, str]:
        return self.context, self.kind, self.seam_kind, self.location


@dataclasses.dataclass(frozen=True)
class BlockingReading:
    sites: Dict[Tuple[str, str, str, str], Site]
    overflow: Dict[str, int]  # per context: blocking calls not recorded as a site


NO_DETECTOR = ("the build has no blocking detector (debug.blocking compiled_in is not true): this story needs a "
               "`reload.sh --config bench-checks` build (CMUX_BLOCKING_CHECKS); a bench build would read as 0 sites")


def parse_blocking(reply) -> BlockingReading:
    """A `debug.blocking` report (BlockingControl.swift). NoDetector unless `compiled_in` is true."""
    reply = check_reply("debug.blocking", reply)
    if reply.get("compiled_in") is not True:
        raise NoDetector(NO_DETECTOR)
    raw_sites = reply.get("sites")
    if not isinstance(raw_sites, list):
        raise LegError("debug.blocking has no sites list")
    sites = {}
    for item in raw_sites:
        if not isinstance(item, dict) or not isinstance(item.get("location"), str):
            raise LegError(f"debug.blocking site is not an object with a location: {json.dumps(item)[:200]}")
        site = Site(context=str(item.get("context") or "main"), kind=str(item.get("kind") or ""),
                    seam_kind=str(item.get("seam_kind") or ""), location=item["location"],
                    count=_count(item.get("count"), "a site's count"),
                    total_ms=_number(item.get("total_ms")), max_ms=_number(item.get("max_ms")))
        sites[site.key] = site
    total = _count(reply.get("overflow", 0), "debug.blocking overflow")
    contexts = reply.get("contexts")
    overflow = {}
    for context, _ in CONTEXTS:
        block = contexts.get(context) if isinstance(contexts, dict) else None
        # A report with no per-context split puts the total on every context: a lower bound is never too low.
        overflow[context] = _count(block.get("overflow"), f"{context} overflow") if isinstance(block, dict) else total
    return BlockingReading(sites, overflow)


def blocking_window(before: BlockingReading, after: BlockingReading) -> Dict[str, dict]:
    """Per context: the sites whose count grew in the window (a new site counts from 0), with their window counts,
    and the overflow calls of the window. LegError when a count went back (a reset or another app process)."""
    window = {context: {"sites": [], "overflow": 0} for context, _ in CONTEXTS}
    for key, site in after.sites.items():
        old = before.sites.get(key)
        delta = site.count - (old.count if old else 0)
        if delta < 0:
            raise LegError(f"debug.blocking count of {site.location} went back inside the window (reset?)")
        if delta and site.context in window:
            window[site.context]["sites"].append({
                "location": site.location, "kind": site.kind, "seam_kind": site.seam_kind, "count": delta,
                "total_ms": round(site.total_ms - (old.total_ms if old else 0.0), 3), "max_ms": site.max_ms})
    for context, _ in CONTEXTS:
        delta = after.overflow[context] - before.overflow[context]
        if delta < 0:
            raise LegError(f"debug.blocking {context} overflow went back inside the window (reset?)")
        window[context]["overflow"] = delta
        window[context]["sites"].sort(key=lambda s: (-s["count"], s["location"]))
    return window


def site_count(context_window: dict) -> Tuple[int, bool]:
    """(sites, lower_bound): the known sites, plus one when calls overflowed the table (they are at sites the
    table does not hold, so at least one more)."""
    known = len(context_window["sites"])
    return (known + 1, True) if context_window["overflow"] else (known, False)


@dataclasses.dataclass(frozen=True)
class HangsReading:
    threshold_ms: float
    count250: int
    stall_count: int
    last_stall: int  # newest record sequence of the main log (0: none)
    thread_hang_count: Optional[int]  # None: a build before the hang watch's `thread_hangs`
    last_thread_hang: int
    records: Tuple[dict, ...]
    thread_hangs: Tuple[dict, ...]


def parse_hangs(reply) -> HangsReading:
    """A `debug.hangs` report (ControlRouter+Diagnostics.swift). LegError when the watchdog does not run."""
    reply = check_reply("debug.hangs", reply)
    if reply.get("installed") is not True:
        raise LegError("the main-thread watchdog is not running (debug.hangs installed is not true): main hangs "
                       "cannot be counted")
    if "count250" not in reply:
        raise NotMeasurable("the build's debug.hangs has no count250 (no StallCounts)")
    records = reply.get("records") or []
    thread_hangs = reply.get("thread_hangs") or []
    if not isinstance(records, list) or not isinstance(thread_hangs, list):
        raise LegError("debug.hangs records or thread_hangs is not a list")
    has_threads = "thread_hang_count" in reply
    return HangsReading(
        threshold_ms=_number(reply.get("threshold_ms")), count250=_count(reply.get("count250"), "count250"),
        stall_count=_count(reply.get("count", 0), "debug.hangs count"), last_stall=_last_sequence(records),
        thread_hang_count=_count(reply.get("thread_hang_count"), "thread_hang_count") if has_threads else None,
        last_thread_hang=_last_sequence(thread_hangs), records=tuple(records), thread_hangs=tuple(thread_hangs))


def hangs_window(before: HangsReading, after: HangsReading) -> dict:
    """The window's main hangs over 250 ms, its stall records of 250 ms or more (with frames), and its thread
    hangs per role (records the ring dropped go to `unattributed`)."""
    count250 = after.count250 - before.count250
    if count250 < 0 or after.stall_count < before.stall_count:
        raise LegError("debug.hangs counts went back inside the window (cleared, or another app process)")
    stalls = [r for r in after.records if _sequence(r) > before.last_stall and r.get("kind", "stall") == "stall"]
    window = {"over_250ms": count250, "threshold_ms": after.threshold_ms,
              "stalls": [r for r in stalls if _number(r.get("duration_ms")) >= 250],
              "stalls_dropped": max(0, after.stall_count - before.stall_count - len(stalls)),
              "roles": None, "thread_hangs": []}
    if before.thread_hang_count is None or after.thread_hang_count is None:
        return window
    total = after.thread_hang_count - before.thread_hang_count
    if total < 0:
        raise LegError("debug.hangs thread_hang_count went back inside the window")
    hangs = [r for r in after.thread_hangs if _sequence(r) > before.last_thread_hang]
    roles = {role: 0 for role in REGISTERED_ROLES}
    for record in hangs:
        role = str(record.get("thread_kind") or "")
        role = role if role in THREAD_ROLES else "unattributed"
        roles[role] = roles.get(role, 0) + 1
    if total > len(hangs):
        roles["unattributed"] = roles.get("unattributed", 0) + total - len(hangs)
    window["roles"], window["thread_hangs"] = roles, hangs
    return window


# readiness-soak.py loads this file by path for this request (its daemon socket reads).
def daemon_request(path: str, command: dict, timeout: float = 10) -> Optional[dict]:
    """One newline-JSON request on the daemon socket; its reply, or None when the socket does not answer."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({**command, "id": 1}) + "\n").encode())
            buffer = b""
            while True:
                while b"\n" not in buffer:
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        return None
                    buffer += chunk
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if isinstance(message, dict) and message.get("id") == 1 and ("ok" in message or "error" in message):
                    return message
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------- the window


@dataclasses.dataclass(frozen=True)
class Reading:
    blocking: BlockingReading
    hangs: HangsReading


class Window:
    """Reads every source when the measured window opens (`__enter__`) and when it closes (`__exit__`, only when the
    window ended normally). A failure is kept on `error` and raised, so the caller still sees it after a harness
    that catches its stage's exceptions."""

    def __init__(self, rpc: Callable):
        self.rpc = rpc
        self.before: Optional[Reading] = None
        self.after: Optional[Reading] = None
        self.error: Optional[Exception] = None

    def _keep(self, call: Callable):
        try:
            return call()
        except (NotMeasurable, NoDetector, LegError) as error:
            self.error = self.error or error
            raise

    def check(self) -> None:
        """The detector check right after the launch, before the minutes of the STRESS build."""
        self._keep(lambda: parse_blocking(self.rpc("debug.blocking", None, timeout=10)))

    def read(self, before: Optional[Reading] = None) -> Reading:
        def read() -> Reading:
            blocking = parse_blocking(self.rpc("debug.blocking", None, timeout=10))
            # Opening: the newest record of each log (limit 1) is the mark. Closing: every record after the mark,
            # and none of the over-budget list (each record is symbolicated on the way out).
            params = ({"limit": 1, "over_budget_after": SKIP_RECORDS} if before is None else
                      {"after": before.hangs.last_stall, "thread_hangs_after": before.hangs.last_thread_hang,
                       "over_budget_after": SKIP_RECORDS})
            hangs = parse_hangs(self.rpc("debug.hangs", params, timeout=30))
            return Reading(blocking, hangs)
        return self._keep(read)

    def __enter__(self) -> "Window":
        self.before = self.read()
        return self

    def __exit__(self, kind, error, _traceback) -> bool:
        if kind is None:
            self.after = self.read(self.before)
        return False

    def measured(self) -> dict:
        """The window's blocking and hangs parts."""
        if self.error is not None:
            raise self.error
        if self.before is None or self.after is None:
            raise LegError("the measured window did not finish: no reading at its end")
        return {"blocking": blocking_window(self.before.blocking, self.after.blocking),
                "hangs": hangs_window(self.before.hangs, self.after.hangs)}


# ---------------------------------------------------------------- results


@dataclasses.dataclass
class Leg:
    name: str  # storm or corpus:<id>
    session: str  # result-v1 session
    metric_prefix: str  # "" for the storm, "corpus.<id>." for a corpus story
    ok: bool = False
    reason: Optional[str] = None
    metrics: Dict[str, int] = dataclasses.field(default_factory=dict)
    unseen: Dict[str, str] = dataclasses.field(default_factory=dict)
    notes: List[str] = dataclasses.field(default_factory=list)
    results: Optional[str] = None
    attachment: Optional[str] = None

    def summary(self) -> dict:
        return dataclasses.asdict(self)


def leg_metrics(leg: Leg, measured: dict) -> Dict[str, int]:
    """{metric: count} of the window; what the leg could not see goes to `leg.unseen`, never into a metric."""
    metrics = {}
    for context, name in CONTEXTS:
        value, lower_bound = site_count(measured["blocking"][context])
        metrics[f"{leg.metric_prefix}{name}"] = value
        if lower_bound:
            leg.notes.append(f"{name}: {measured['blocking'][context]['overflow']} calls overflowed the site table; "
                             f"{value} is a lower bound")
    hangs = measured["hangs"]
    metrics[f"{leg.metric_prefix}hangs.over_250ms.main"] = hangs["over_250ms"]
    if hangs["threshold_ms"] > 250:
        leg.notes.append(f"the watchdog threshold is {hangs['threshold_ms']:g} ms: stalls from 250 ms up to it are "
                         "counted with no stack")
    if hangs["stalls_dropped"]:
        leg.notes.append(f"{hangs['stalls_dropped']} stall records left the ring before the read: counted, no stack")
    if hangs["roles"] is None:
        leg.unseen["hang_watch"] = "the build's debug.hangs has no thread_hangs (no hang watch)"
    else:
        for role, count in sorted(hangs["roles"].items()):
            metrics[f"{leg.metric_prefix}hang_watch.past_deadline.{role}"] = count
        for role in THREAD_ROLES:
            if role not in hangs["roles"]:
                leg.unseen[f"hang_watch.{role}"] = UNREGISTERED
    return metrics


def attachment_key(digest: str) -> str:
    """The R2 key of a `sha256:<hex>` attachment digest (the digest of the stored bytes)."""
    if not digest.startswith("sha256:") or len(digest) != 71:
        raise ValueError(f"{digest!r} is not sha256:<64 hex>")
    return f"{ATTACHMENT_PREFIX}{digest[7:]}.json"


def attachment_store():
    """The lab's R2 bucket (trace_quest.R2BlobStore from CMUX_PERF_LAB_R2_*); raises when it is not configured."""
    return load_by_path("perf_lab_trace_quest", TRACE_QUEST).R2BlobStore.from_env()


def write_attachment(out: str, blobs, leg: Leg, measured: dict, metrics: Dict[str, int]) -> str:
    """Uploads the leg's sites and stacks to `blobs` by sha256 (attachment_key), keeps a copy under out/attachments/,
    and returns `sha256:<hex>`."""
    doc = {"schema": ATTACHMENT_SCHEMA, "story": STORY, "leg": leg.name, "session": leg.session,
           "metrics": dict(sorted(metrics.items())), "unseen": dict(sorted(leg.unseen.items())),
           "blocking": measured["blocking"],
           "hangs": {"main_stalls": measured["hangs"]["stalls"], "thread_hangs": measured["hangs"]["thread_hangs"],
                     "threshold_ms": measured["hangs"]["threshold_ms"]}}
    data = (json.dumps(doc, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    digest = f"sha256:{hashlib.sha256(data).hexdigest()}"
    blobs.put(attachment_key(digest), data, "application/json")
    folder = os.path.join(out, "attachments")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"sha256-{digest[7:]}.json")
    if not os.path.exists(path):
        temporary = path + ".tmp"
        with open(temporary, "wb") as f:
            f.write(data)
        os.replace(temporary, path)
    return digest


def record_leg(bench, writer, blobs, leg: Leg, window: Window, out: str) -> None:
    """Writes the leg's results into `out`: BenchApp.record stages each result (it fills build, host and features),
    then they are written again as one file with the attachment, as trace_quest.with_traces adds trace attachments."""
    measured = window.measured()
    metrics = leg_metrics(leg, measured)
    digest = write_attachment(out, blobs, leg, measured, metrics)
    bench.perf_session = leg.session
    bench.build_config = CONFIG
    staged = []
    try:
        for metric, value in sorted(metrics.items()):
            target = TARGETS.get(metric)
            staged.append(bench.record(STORY, metric, "count", [value], "lower", ENGINE, target_ref=target))
        attachment = writer.Attachment(digest=digest, kind=ATTACHMENT_KIND)
        results = [dataclasses.replace(result, attachments=[*result.attachments, attachment])
                   for path in staged for result in writer.read_file(path)]
        leg.results = os.path.relpath(str(writer.write_ndjson(out, results, repo_root=ROOT)), out)
    finally:
        for path in staged:
            _unlink(str(path))
    leg.metrics, leg.attachment, leg.ok = dict(sorted(metrics.items())), digest, True


# ---------------------------------------------------------------- the storm leg


def storm_recording(trace):
    """trace.py's Recording with the detector check right after the launch and the readings around its window."""

    class StormRecording(trace.Recording):
        window: Optional[Window] = None

        def build_stress(self):
            self.window = Window(self.rpc)
            self.window.check()  # NoDetector or NotMeasurable here ends the run before the STRESS build
            return super().build_stress()

        def run_window(self):
            self.window = Window(self.rpc)
            with self.window:
                super().run_window()

    return StormRecording


def trace_options(app: str, out: str, seconds: float):
    """trace.py `record --scenario stress-storm` options with no profiler and the watchdog threshold at 250 ms."""
    return argparse.Namespace(app=app, bundle=None, socket=None, out=out, scenario="stress-storm", seconds=seconds,
                              seconds_cap=600, recorder="none", system_trace=False, no_cef=True, cdp_port=0,
                              hang_ms=HANG_MS, storm_hz=10, key_interval=0.12, chord_every=10, keep=False,
                              keep_recording=False, command=[])


def measured_stage_problems(meta: dict) -> List[str]:
    """Why trace.py's window is not the STRESS storm (a stage error, a session off the STRESS shape, a storm that
    sent nothing, a window that was not key); trace.py only warns about the last ones."""
    problems = [f"{e.get('stage')}: {e.get('error')}" for e in meta.get("errors") or []
                if e.get("stage") in MEASURED_STAGES]
    problems += [f"{stage}: passed its bound" for stage in meta.get("timed_out") or [] if stage in MEASURED_STAGES]
    stress = meta.get("stress")
    if not isinstance(stress, dict):
        problems.append("no STRESS session was built")
    elif stress.get("shape_error"):
        problems.append(f"not the STRESS shape: {stress['shape_error']}")
    if not sum((meta.get("storm_ops") or {}).values()):
        problems.append("the CLI storm sent no op in the window")
    if str(meta.get("scenario_label") or "").endswith("-inactive"):
        problems.append("the app's window was not key (a GUI job took it)")
    return problems


def run_storm(opts, work: str, writer, blobs) -> Tuple[Leg, Optional[int]]:
    """The storm leg and the exit code of a signal that ended trace.py's run (else None). NotMeasurable and
    NoDetector leave (the whole story refuses); any other failure is the leg's reason."""
    leg = Leg(name="storm", session="stress", metric_prefix="")
    trace_dir = tempfile.mkdtemp(prefix="blocking-hangs-storm-", dir=work)
    try:
        trace = load_by_path("cmux_next_trace", TRACE)
        topts = trace_options(opts.app, trace_dir, opts.seconds)
        bundle = os.path.realpath(opts.app).rstrip("/")
        meta = {"host": os.uname().nodename, "macos": _macos_version(), "bundle": bundle, "scenario": topts.scenario,
                "seconds": topts.seconds, "argv": sys.argv[1:], "recorder": topts.recorder, "sources": {},
                "warnings": []}
        recording = storm_recording(trace)(topts, trace_dir, meta, trace.Stages(meta), bundle, topts.recorder)
        try:
            recording.record()
        finally:
            _keep_files(trace_dir, os.path.join(opts.out, "storm-trace"))
        if recording.terminated is not None:
            leg.reason = f"stopped by a signal (exit {recording.terminated})"
            return leg, recording.terminated
        window = recording.window
        if window is not None and window.error is not None:
            raise window.error
        problems = measured_stage_problems(meta)
        if problems:
            raise LegError("; ".join(problems)[:600])
        if window is None:
            raise LegError("trace.py never reached its measured window")
        record_leg(recording.app.bench, writer, blobs, leg, window, opts.out)
    except (NotMeasurable, NoDetector):
        raise
    except LegError as error:
        leg.reason = str(error)
    except launch_error() as error:
        leg.reason = str(error)[:600]
    except Exception as error:  # noqa: BLE001 - the leg's reason; the other legs and the summary still run
        leg.reason = f"{type(error).__name__}: {error}"[:600]
    return leg, None


# ---------------------------------------------------------------- the corpus legs


def corpus_manifests(root: str, wanted: str) -> List[Tuple[str, str]]:
    """[(id, manifest)] to replay: `all` is every manifest whose tier is not T2, else the comma-separated ids."""
    found = {}
    for path in sorted(glob.glob(os.path.join(root, "perf-corpus", "*.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("id"), str):
            found[doc["id"]] = (path, doc.get("tier"))
    if wanted == "all":
        return [(story_id, path) for story_id, (path, tier) in sorted(found.items()) if tier != "T2"]
    picked = []
    for story_id in [s for s in wanted.split(",") if s]:
        if story_id not in found:
            raise LegError(f"no corpus manifest {story_id} in perf-corpus/")
        picked.append((story_id, found[story_id][0]))
    return picked


def takes_window(replay) -> bool:
    """Whether `replay` takes the `window=` hook as a keyword (p12-perf-process.md 3.8)."""
    try:
        parameters = inspect.signature(replay).parameters.values()
    except (TypeError, ValueError):
        return False
    return any((p.name == "window" and p.kind in (p.POSITIONAL_OR_KEYWORD, p.KEYWORD_ONLY))
               or p.kind is p.VAR_KEYWORD for p in parameters)


def run_corpus(play, story_id: str, manifest: str, opts, work: str, writer, blobs) -> Leg:
    """One corpus leg: play.replay with a window hook that checks the detector and opens a Window on the replay's
    BenchApp. NotMeasurable and NoDetector leave; any other failure is the leg's reason."""
    leg = Leg(name=f"corpus:{story_id}", session=f"corpus:{story_id}", metric_prefix=f"corpus.{story_id}.")
    opened: Dict[str, object] = {}

    def window(bench):
        made = Window(bench.rpc)
        opened["bench"], opened["window"] = bench, made
        made.check()
        return made

    replay_out = tempfile.mkdtemp(prefix=f"blocking-hangs-{story_id}-", dir=work)
    try:
        replay = getattr(play, "replay", None)
        if not callable(replay) or not takes_window(replay):
            raise LegError("scripts/perf-lab/corpus/play.py has no replay(manifest, app=, out=, window=) hook "
                           "(p12-perf-process.md 3.8)")
        try:
            replay(manifest, app=opts.app, out=replay_out, window=window)
        finally:
            _keep_files(replay_out, os.path.join(opts.out, f"corpus-{story_id}"), names=())
        made = opened.get("window")
        if made is None:
            raise LegError("the replay never opened its measured window")
        if made.error is not None:
            raise made.error
        record_leg(opened["bench"], writer, blobs, leg, made, opts.out)
    except (NotMeasurable, NoDetector):
        raise
    except LegError as error:
        leg.reason = str(error)
    except launch_error() as error:
        leg.reason = str(error)[:600]
    except Exception as error:  # noqa: BLE001 - the leg's reason; the other legs and the summary still run
        leg.reason = f"{type(error).__name__}: {error}"[:600]
    return leg


def corpus_legs(opts, work: str, writer, blobs, root: Optional[str] = None) -> Tuple[List[Leg], Optional[str]]:
    """The corpus legs, or none and why the checkout has no corpus half to measure (no corpus, no manifest, no
    player): that half is not measured, and the storm's result stands. A player that is there but fails, or a
    manifest asked for that is not there, fails its leg."""
    root = root or ROOT
    if not os.path.isdir(os.path.join(root, "perf-corpus")):
        return [], "no perf-corpus/ in this checkout (p12-perf-process-110)"
    try:
        manifests = corpus_manifests(root, opts.corpus)
    except LegError as error:
        return [Leg(name="corpus", session="corpus:none", metric_prefix="", reason=str(error))], None
    if not manifests:
        return [], "perf-corpus/ has no manifest to replay"
    play_path = os.path.join(root, "scripts", "perf-lab", "corpus", "play.py")
    if not os.path.isfile(play_path):
        return [], "no scripts/perf-lab/corpus/play.py (p12-perf-process-115)"
    try:
        play = load_by_path("perf_lab_corpus_play", play_path)
    except Exception as error:  # noqa: BLE001 - a player that does not load fails the corpus half, not the story
        return [Leg(name="corpus", session="corpus:none", metric_prefix="",
                    reason=f"play.py does not load: {type(error).__name__}: {error}"[:600])], None
    return [run_corpus(play, story_id, path, opts, work, writer, blobs) for story_id, path in manifests], None


# ---------------------------------------------------------------- main


def stamped_config_problem(app: str) -> Optional[str]:
    """Why the bundle cannot be bench-checks by its own Info.plist stamp (bench_launch BUILD_CONFIG_KEY), else None.
    An unstamped bundle is checked after its launch by `debug.blocking` `compiled_in`."""
    bench_launch = load_by_path("bench_launch", BENCH_LAUNCH)
    stamped = bench_launch.info_plist(app).get(bench_launch.BUILD_CONFIG_KEY)
    if stamped is not None and stamped != CONFIG:
        return (f"{app} was built with --config {stamped}, which has no CMUX_BLOCKING_CHECKS: this story needs "
                f"--config {CONFIG}")
    return None


def parse_args(argv: Optional[Sequence[str]]):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True, help="the bench-checks `cmux DEV <tag>.app` (not running)")
    p.add_argument("--tag", help="the app's tag (the runner passes it; the bundle names its own tag)")
    p.add_argument("--out", required=True, help="the run folder: result-v1 files, attachments, summary")
    p.add_argument("--legs", default="storm,corpus", help="storm, corpus, or both (comma-separated)")
    p.add_argument("--corpus", default="all", help="all (every non-T2 manifest) or corpus story ids")
    p.add_argument("--seconds", type=float, default=30, help="the storm's measured window")
    opts = p.parse_args(argv)
    legs = {leg for leg in opts.legs.split(",") if leg}
    if not legs or legs - {"storm", "corpus"}:
        p.error(f"--legs takes storm and corpus, not {opts.legs!r}")
    opts.legs = legs
    if opts.seconds <= 0:
        p.error("--seconds must be positive")
    return opts


def main(argv: Optional[Sequence[str]] = None, blobs=None, config_problem: Callable = stamped_config_problem) -> int:
    opts = parse_args(argv)
    opts.out = os.path.abspath(opts.out)
    os.makedirs(opts.out, exist_ok=True)
    load_by_path("bench_launch", BENCH_LAUNCH)  # the one copy trace.py, play.py and BenchApp.record share
    writer = load_by_path("perf_result", PERF_RESULT)
    problem = config_problem(opts.app)
    if problem:
        return fail(opts.out, problem)
    if blobs is None:
        try:
            blobs = attachment_store()
        except Exception as error:  # noqa: BLE001 - not configured: said, and nothing is launched
            return fail(opts.out, f"the attachments cannot be published: {type(error).__name__}: {error}"[:600])
    work = tempfile.mkdtemp(prefix="blocking-hangs-")
    legs: List[Leg] = []
    corpus = None
    signalled = None
    try:
        if "storm" in opts.legs:
            leg, signalled = run_storm(opts, work, writer, blobs)
            legs.append(leg)
        if "corpus" in opts.legs and signalled is None:
            ran, unmeasured = corpus_legs(opts, work, writer, blobs)
            legs += ran
            corpus = {"measured": unmeasured is None, "reason": unmeasured}
    except NotMeasurable as error:
        return refuse(opts.out, str(error))
    except NoDetector as error:
        return fail(opts.out, str(error))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if signalled is not None:
        code = signalled
    elif not legs or any(not leg.ok for leg in legs):
        code = EXIT_FAILED
    else:
        code = EXIT_OK
    write_summary(opts.out, {"story": STORY, "refusal": None, "legs": [leg.summary() for leg in legs],
                             "corpus": corpus, "exit": code})
    for leg in legs:
        shown = ", ".join(f"{name} {value}" for name, value in leg.metrics.items() if value)
        print(f"{STORY}: {leg.name}: " + (f"ok ({shown or 'all 0'})" if leg.ok else f"FAILED: {leg.reason}"))
        for role, why in leg.unseen.items():
            print(f"{STORY}: {leg.name}: {role} unseen: {why}")
        for line in leg.notes:
            print(f"{STORY}: {leg.name}: {line}")
    if corpus is not None and not corpus["measured"]:
        print(f"{STORY}: corpus: not measured: {corpus['reason']}", file=sys.stderr)
    return code


def fail(out: str, reason: str) -> int:
    """The story cannot measure this build or host (no detector, no attachment store): nothing stored."""
    write_summary(out, {"story": STORY, "refusal": {"kind": "failed", "reason": reason}, "legs": [], "corpus": None,
                        "exit": EXIT_FAILED})
    print(f"{STORY}: FAILED: {reason}", file=sys.stderr)
    return EXIT_FAILED


def refuse(out: str, reason: str) -> int:
    """Not measurable: nothing stored, one reason line (stderr and the summary)."""
    write_summary(out, {"story": STORY, "refusal": {"kind": "not-measurable", "reason": reason}, "legs": [],
                        "corpus": None, "exit": EXIT_NOT_MEASURABLE})
    print(f"{STORY}: not-measurable: {reason}", file=sys.stderr)
    return EXIT_NOT_MEASURABLE


def write_summary(out: str, summary: dict) -> None:
    with open(os.path.join(out, SUMMARY), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")


def _keep_files(source: str, dest: str, names: Sequence[str] = TRACE_KEEP) -> None:
    """Copies `names` from `source` and every launched app's full host validation (anywhere under `source`) into
    `dest` in the run folder. No *.ndjson: the runner reads those as results."""
    os.makedirs(dest, exist_ok=True)
    paths = [os.path.join(source, name) for name in names]
    paths += sorted(glob.glob(os.path.join(source, "**", HOST_CHECK_GLOB), recursive=True))
    for path in paths:
        if os.path.isfile(path):
            shutil.copy2(path, os.path.join(dest, os.path.basename(path)))


def _macos_version() -> str:
    try:
        return subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    except OSError:
        return ""


def _sequence(record) -> int:
    value = record.get("sequence") if isinstance(record, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def _last_sequence(records) -> int:
    return max((_sequence(r) for r in records), default=0)


def _number(value) -> float:
    finite = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    return float(value) if finite else 0.0


def _unlink(path: str) -> None:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


if __name__ == "__main__":
    sys.exit(main())
