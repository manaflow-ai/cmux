#!/usr/bin/env python3
"""Story qos-inversions: runtime QoS inversions during the STRESS storm and each corpus story, on a
`--config bench-checks` build.

An inversion is a waiting seam (`DispatchQueue.blockingSync`) whose calling thread's QoS (`qos_class_self()`) is
above the QoS of the queue it waits on: the higher-priority thread waits behind work the system schedules below it
(Xcode's Thread Performance Checker reports the same case; Chrome's rule is that work a higher-priority sequence
waits for is not posted below it, base/task/task_traits.h). The blocking detector (CMUX_BLOCKING_CHECKS) counts them
per call site on every thread, and `debug.blocking` reports them under `inversions` (task p12-perf-process-230).

Each leg reads `debug.blocking` when its measured window opens and when it closes, and stores the difference, so
nothing is cleared. Metric of a leg (a corpus leg's name starts with `corpus.<id>.`; a count, lower is better):
  qos.inversions   inversions in the window: the recorded sites' count plus the inversions the site table could
                   not hold (`overflow`), so a full table never hides one (target qos.inversions, storm leg only).

A source the leg cannot read is never stored as 0: a build without the detector (`compiled_in` is not true, or the
bundle says another `CMUXBuildConfiguration`) fails the story before any leg is measured (exit 1); a build whose
`debug.blocking` has no `inversions` (before task 230) or no `debug.blocking` at all is not-measurable (exit 4).

The window, the storm (trace.py's stress-storm with no profiler), the corpus legs (play.py's `window=` hook), the
attachment store and the exits are blocking_hangs.py's (task 037); this story reads only the inversions. Each leg's
result carries an attachment (kind `qos-inversions`: the window's sites with their waiter and target QoS and their
counts), uploaded to the lab's R2 bucket as blocking-hangs does (CMUX_PERF_LAB_R2_*; without it, exit 1), with a
copy under --out/attachments/. qos-inversions-summary.json says what each leg saw.

Usage (the story runner appends --app, --tag and --out):
  python3 -I scripts/perf-lab/stories/qos_inversions.py --app APP --tag TAG --out DIR [--legs storm,corpus]
                                                        [--corpus all|ID,...] [--seconds 30]
Exit: 0 every leg that ran measured; 1 a leg failed, or the build has no detector; 2 usage; 4 not measurable;
128+N signal N.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
BLOCKING_HANGS = os.path.join(HERE, "blocking_hangs.py")


def _load(name: str, path: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"no module at {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


bh = _load("perf_lab_blocking_hangs", BLOCKING_HANGS)
NotMeasurable, NoDetector, LegError = bh.NotMeasurable, bh.NoDetector, bh.LegError

STORY = "qos-inversions"
ENGINE = "none"
CONFIG = bh.CONFIG  # bench-checks
METRIC = "qos.inversions"
TARGET = "qos.inversions"  # targets.json row id; only the storm leg claims it
ATTACHMENT_KIND = "qos-inversions"
ATTACHMENT_SCHEMA = "cmux-qos-inversions/v1"
SUMMARY = "qos-inversions-summary.json"
NO_INVERSIONS = ("the build's debug.blocking has no `inversions` (it predates p12-perf-process-230): its QoS "
                 "inversions cannot be counted")


# ---------------------------------------------------------------- readings


@dataclasses.dataclass(frozen=True)
class InversionSite:
    location: str
    waiter: str
    target: str
    count: int


@dataclasses.dataclass(frozen=True)
class InversionReading:
    sites: Dict[str, InversionSite]  # by location
    overflow: int  # inversions not recorded as a site, since launch


def parse_inversions(reply) -> InversionReading:
    """The `inversions` of a `debug.blocking` report (BlockingControl.swift). NoDetector unless `compiled_in` is
    true; NotMeasurable when the build reports no inversions."""
    reply = bh.check_reply("debug.blocking", reply)
    if reply.get("compiled_in") is not True:
        raise NoDetector(bh.NO_DETECTOR)
    block = reply.get("inversions")
    if block is None:
        raise NotMeasurable(NO_INVERSIONS)
    if not isinstance(block, dict) or not isinstance(block.get("sites"), list):
        raise LegError(f"debug.blocking inversions is not an object with sites: {json.dumps(block)[:200]}")
    sites = {}
    for item in block["sites"]:
        if not isinstance(item, dict) or not isinstance(item.get("location"), str):
            raise LegError(f"debug.blocking inversion site has no location: {json.dumps(item)[:200]}")
        site = InversionSite(location=item["location"], waiter=str(item.get("waiter") or ""),
                             target=str(item.get("target") or ""),
                             count=bh._count(item.get("count"), "an inversion site's count"))
        sites[site.location] = site
    return InversionReading(sites, bh._count(block.get("overflow", 0), "debug.blocking inversions overflow"))


def inversions_window(before: InversionReading, after: InversionReading) -> dict:
    """{"count", "overflow", "sites"}: the window's inversions (sites' growth plus overflow growth), the overflow
    growth, and the sites whose count grew (a new site counts from 0). LegError when a count went back (a reset or
    another app process)."""
    sites = []
    for location, site in after.sites.items():
        old = before.sites.get(location)
        delta = site.count - (old.count if old else 0)
        if delta < 0:
            raise LegError(f"debug.blocking inversion count of {location} went back inside the window (reset?)")
        if delta:
            sites.append({"location": location, "waiter": site.waiter, "target": site.target, "count": delta})
    overflow = after.overflow - before.overflow
    if overflow < 0:
        raise LegError("debug.blocking inversions overflow went back inside the window (reset?)")
    sites.sort(key=lambda s: (-s["count"], s["location"]))
    return {"count": sum(s["count"] for s in sites) + overflow, "overflow": overflow, "sites": sites}


class Window:
    """Reads the inversions when the measured window opens (`__enter__`) and when it closes (`__exit__`, only when
    the window ended normally). A failure is kept on `error` and raised, so the caller still sees it after a
    harness that catches its stage's exceptions."""

    def __init__(self, rpc: Callable):
        self.rpc = rpc
        self.before: Optional[InversionReading] = None
        self.after: Optional[InversionReading] = None
        self.error: Optional[Exception] = None

    def read(self) -> InversionReading:
        try:
            return parse_inversions(self.rpc("debug.blocking", None, timeout=10))
        except (NotMeasurable, NoDetector, LegError) as error:
            self.error = self.error or error
            raise

    def check(self) -> None:
        """The detector check right after the launch, before the minutes of the STRESS build."""
        self.read()

    def __enter__(self) -> "Window":
        self.before = self.read()
        return self

    def __exit__(self, kind, error, _traceback) -> bool:
        if kind is None:
            self.after = self.read()
        return False

    def measured(self) -> dict:
        if self.error is not None:
            raise self.error
        if self.before is None or self.after is None:
            raise LegError("the measured window did not finish: no reading at its end")
        return inversions_window(self.before, self.after)


# ---------------------------------------------------------------- results


@dataclasses.dataclass
class Leg:
    name: str  # storm or corpus:<id>
    session: str  # result-v1 session
    metric_prefix: str  # "" for the storm, "corpus.<id>." for a corpus story
    ok: bool = False
    reason: Optional[str] = None
    metrics: Dict[str, int] = dataclasses.field(default_factory=dict)
    sites: List[dict] = dataclasses.field(default_factory=list)
    results: Optional[str] = None
    attachment: Optional[str] = None

    def summary(self) -> dict:
        return dataclasses.asdict(self)


def write_attachment(out: str, blobs, leg: Leg, measured: dict) -> str:
    """Uploads the leg's inversion sites to `blobs` by sha256, keeps a copy under out/attachments/, and returns
    `sha256:<hex>`."""
    doc = {"schema": ATTACHMENT_SCHEMA, "story": STORY, "leg": leg.name, "session": leg.session,
           "inversions": measured}
    data = (json.dumps(doc, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    digest = f"sha256:{hashlib.sha256(data).hexdigest()}"
    blobs.put(bh.attachment_key(digest), data, "application/json")
    folder = os.path.join(out, "attachments")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"sha256-{digest[7:]}.json")
    if not os.path.exists(path):
        with open(path + ".tmp", "wb") as f:
            f.write(data)
        os.replace(path + ".tmp", path)
    return digest


def record_leg(bench, writer, blobs, leg: Leg, window: Window, out: str) -> None:
    """Writes the leg's result into `out`: BenchApp.record stages it (build, host and features), then it is written
    again with the attachment, as blocking_hangs.record_leg does."""
    measured = window.measured()
    metric = f"{leg.metric_prefix}{METRIC}"
    digest = write_attachment(out, blobs, leg, measured)
    bench.perf_session = leg.session
    bench.build_config = CONFIG
    staged = bench.record(STORY, metric, "count", [measured["count"]], "lower", ENGINE,
                          target_ref=TARGET if not leg.metric_prefix else None)
    try:
        attachment = writer.Attachment(digest=digest, kind=ATTACHMENT_KIND)
        results = [dataclasses.replace(result, attachments=[*result.attachments, attachment])
                   for result in writer.read_file(staged)]
        leg.results = os.path.relpath(str(writer.write_ndjson(out, results, repo_root=bh.ROOT)), out)
    finally:
        bh._unlink(str(staged))
    leg.metrics, leg.sites, leg.attachment, leg.ok = {metric: measured["count"]}, measured["sites"], digest, True


def _run_leg(leg: Leg, body: Callable[[], None]) -> Leg:
    """Runs one leg's body; NotMeasurable and NoDetector leave (the whole story refuses), any other failure is the
    leg's reason."""
    try:
        body()
    except (NotMeasurable, NoDetector):
        raise
    except LegError as error:
        leg.reason = str(error)
    except bh.launch_error() as error:
        leg.reason = str(error)[:600]
    except Exception as error:  # noqa: BLE001 - the leg's reason; the other legs and the summary still run
        leg.reason = f"{type(error).__name__}: {error}"[:600]
    return leg


# ---------------------------------------------------------------- legs


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


def run_storm(opts, work: str, writer, blobs) -> Tuple[Leg, Optional[int]]:
    """The storm leg and the exit code of a signal that ended trace.py's run (else None)."""
    leg = Leg(name="storm", session="stress", metric_prefix="")
    signalled: List[int] = []

    def body() -> None:
        trace_dir = tempfile.mkdtemp(prefix="qos-inversions-storm-", dir=work)
        trace = bh.load_by_path("cmux_next_trace", bh.TRACE)
        topts = bh.trace_options(opts.app, trace_dir, opts.seconds)
        bundle = os.path.realpath(opts.app).rstrip("/")
        meta = {"host": os.uname().nodename, "macos": bh._macos_version(), "bundle": bundle,
                "scenario": topts.scenario, "seconds": topts.seconds, "argv": sys.argv[1:],
                "recorder": topts.recorder, "sources": {}, "warnings": []}
        recording = storm_recording(trace)(topts, trace_dir, meta, trace.Stages(meta), bundle, topts.recorder)
        try:
            recording.record()
        finally:
            bh._keep_files(trace_dir, os.path.join(opts.out, "storm-trace"))
        if recording.terminated is not None:
            signalled.append(recording.terminated)
            raise LegError(f"stopped by a signal (exit {recording.terminated})")
        window = recording.window
        if window is not None and window.error is not None:
            raise window.error
        problems = bh.measured_stage_problems(meta)
        if problems:
            raise LegError("; ".join(problems)[:600])
        if window is None:
            raise LegError("trace.py never reached its measured window")
        record_leg(recording.app.bench, writer, blobs, leg, window, opts.out)

    _run_leg(leg, body)
    return leg, (signalled[0] if signalled else None)


def run_corpus(play, story_id: str, manifest: str, opts, work: str, writer, blobs) -> Leg:
    """One corpus leg: play.replay with a window hook that checks the detector and opens a Window on the replay's
    BenchApp."""
    leg = Leg(name=f"corpus:{story_id}", session=f"corpus:{story_id}", metric_prefix=f"corpus.{story_id}.")
    opened: Dict[str, object] = {}

    def window(bench):
        made = Window(bench.rpc)
        opened["bench"], opened["window"] = bench, made
        made.check()
        return made

    def body() -> None:
        replay_out = tempfile.mkdtemp(prefix=f"qos-inversions-{story_id}-", dir=work)
        replay = getattr(play, "replay", None)
        if not callable(replay) or not bh.takes_window(replay):
            raise LegError("scripts/perf-lab/corpus/play.py has no replay(manifest, app=, out=, window=) hook "
                           "(p12-perf-process.md 3.8)")
        try:
            replay(manifest, app=opts.app, out=replay_out, window=window)
        finally:
            bh._keep_files(replay_out, os.path.join(opts.out, f"corpus-{story_id}"), names=())
        made = opened.get("window")
        if made is None:
            raise LegError("the replay never opened its measured window")
        if made.error is not None:
            raise made.error
        record_leg(opened["bench"], writer, blobs, leg, made, opts.out)

    return _run_leg(leg, body)


def corpus_legs(opts, work: str, writer, blobs, root: Optional[str] = None) -> Tuple[List[Leg], Optional[str]]:
    """The corpus legs, or none and why the checkout has no corpus half to measure (blocking_hangs.corpus_legs's
    rules: a missing corpus or player is said, not failed; a player that fails, or a missing asked-for manifest,
    fails its leg)."""
    root = root or bh.ROOT
    if not os.path.isdir(os.path.join(root, "perf-corpus")):
        return [], "no perf-corpus/ in this checkout (p12-perf-process-110)"
    try:
        manifests = bh.corpus_manifests(root, opts.corpus)
    except LegError as error:
        return [Leg(name="corpus", session="corpus:none", metric_prefix="", reason=str(error))], None
    if not manifests:
        return [], "perf-corpus/ has no manifest to replay"
    play_path = os.path.join(root, "scripts", "perf-lab", "corpus", "play.py")
    if not os.path.isfile(play_path):
        return [], "no scripts/perf-lab/corpus/play.py (p12-perf-process-115)"
    try:
        play = bh.load_by_path("perf_lab_corpus_play", play_path)
    except Exception as error:  # noqa: BLE001 - a player that does not load fails the corpus half, not the story
        return [Leg(name="corpus", session="corpus:none", metric_prefix="",
                    reason=f"play.py does not load: {type(error).__name__}: {error}"[:600])], None
    return [run_corpus(play, story_id, path, opts, work, writer, blobs) for story_id, path in manifests], None


# ---------------------------------------------------------------- main


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


def main(argv: Optional[Sequence[str]] = None, blobs=None,
         config_problem: Callable = bh.stamped_config_problem) -> int:
    opts = parse_args(argv)
    opts.out = os.path.abspath(opts.out)
    os.makedirs(opts.out, exist_ok=True)
    bh.load_by_path("bench_launch", bh.BENCH_LAUNCH)  # the one copy trace.py, play.py and BenchApp.record share
    writer = bh.load_by_path("perf_result", bh.PERF_RESULT)
    problem = config_problem(opts.app)
    if problem:
        return fail(opts.out, problem)
    if blobs is None:
        try:
            blobs = bh.attachment_store()
        except Exception as error:  # noqa: BLE001 - not configured: said, and nothing is launched
            return fail(opts.out, f"the attachments cannot be published: {type(error).__name__}: {error}"[:600])
    work = tempfile.mkdtemp(prefix="qos-inversions-")
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
        code = bh.EXIT_FAILED
    else:
        code = bh.EXIT_OK
    write_summary(opts.out, {"story": STORY, "refusal": None, "legs": [leg.summary() for leg in legs],
                             "corpus": corpus, "exit": code})
    for leg in legs:
        if not leg.ok:
            print(f"{STORY}: {leg.name}: FAILED: {leg.reason}")
            continue
        shown = ", ".join(f"{s['location']} ({s['waiter']} on {s['target']}) x{s['count']}" for s in leg.sites)
        print(f"{STORY}: {leg.name}: ok ({METRIC} {sum(leg.metrics.values())}{': ' + shown if shown else ''})")
    if corpus is not None and not corpus["measured"]:
        print(f"{STORY}: corpus: not measured: {corpus['reason']}", file=sys.stderr)
    return code


def fail(out: str, reason: str) -> int:
    """The story cannot measure this build or host (no detector, no attachment store): nothing stored."""
    write_summary(out, {"story": STORY, "refusal": {"kind": "failed", "reason": reason}, "legs": [], "corpus": None,
                        "exit": bh.EXIT_FAILED})
    print(f"{STORY}: FAILED: {reason}", file=sys.stderr)
    return bh.EXIT_FAILED


def refuse(out: str, reason: str) -> int:
    """Not measurable: nothing stored, one reason line (stderr and the summary)."""
    write_summary(out, {"story": STORY, "refusal": {"kind": "not-measurable", "reason": reason}, "legs": [],
                        "corpus": None, "exit": bh.EXIT_NOT_MEASURABLE})
    print(f"{STORY}: not-measurable: {reason}", file=sys.stderr)
    return bh.EXIT_NOT_MEASURABLE


def write_summary(out: str, summary: dict) -> None:
    with open(os.path.join(out, SUMMARY), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
