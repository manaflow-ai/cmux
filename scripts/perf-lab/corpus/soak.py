#!/usr/bin/env python3
"""Corpus soak: one bench app plays the composed corpus stories in a loop with idle gaps (p12-perf-process.md 3.3
T2 and 3.8, task 122).

    python3 -I scripts/perf-lab/corpus/soak.py perf-corpus/long-day-soak.json --app APP --tag TAG --out DIR
    python3 -I scripts/perf-lab/corpus/soak.py perf-corpus/long-day-soak.json --app APP --out DIR --duration-ms 1800000

A soak manifest (`compose` in schemas/perf/corpus-story-v1.schema.json) names the stories it loops and the idle gap
between them; its `duration_ms` is the soak's length and its `layout.workspaces` is the workspace count between the
stories, where every footprint sample is taken. Chromium's long-running stories work the same way: one browser plays
a page's interactions and idle periods for hours, and the memory benchmark reads its dumps at equal points of each
iteration (tools/perf/page_sets/system_health/long_running_stories.py, tools/perf/benchmarks/memory.py
`memory.long_running_idle_gmail_tbmv2`).

  1. Before launch: the soak manifest is validated (manifest.py), each composed story is loaded by play.py's Player
     (validator, layout snapshot, tracks, sources), and each must be recorded. At most one composed story may have a
     Web Page Replay archive: the app's Chromium switches (wpr.py bench_switches) name one server for the whole
     launch. That server starts once, and every composed story's agent transcripts are installed once in the bench's
     acpmux home (agent_replay.py), so one launch environment serves every story.
  2. One BenchApp launch (`SharedBench`): each cycle is play.py's `Player.replay` of the next composed story into
     that same running app. Its launch call is a no-op that checks the app still runs, its stop is a no-op, and the
     replay's series stay in the cycle's summary: the soak writes only its own metrics. A cycle checks every
     checkpoint digest of its story as a single replay does, so every loop must reach the recorded states.
  3. After each cycle the app is reset to the state a fresh launch imports into (`reset`): a new workspace is made
     and shown, every other workspace is closed (closeWorkspace, confirmed), and the app must be back at one
     workspace with one terminal tab and the launch's window count.
  4. The idle gap: nothing is sent for `idle_gap_ms`. After GAP_SETTLE_S (at most half the gap) the app's processes
     (bench_memory.owned: the app, its Chromium and WebKit helpers, daemons, terminal hosts, acpmux) are read with
     proc_pid_rusage, and again at the gap's end: the idle wakeups per second over that part, as Chromium reads a
     process's package idle wakeups (base/process/process_metrics_mac.cc GetPackageIdleWakeupsPerSecond), and the
     phys_footprint at the gap's end. No socket call runs inside the measured part of the gap.
  5. After the gap: debug.hangs `count250` (main-thread hangs over 250 ms) and debug.crashes `chromium_total`
     (Chromium process failures of this launch, Chromium's renderer and child crash counts in
     components/metrics/stability_metrics_helper.cc) are read, cumulative since the launch.

The soak runs until `duration_ms` (or --duration-ms) has passed at a cycle's end. It writes result-v1 (BenchApp.record,
session corpus:<id>):

  corpus.<id>.hangs_over_250ms               count  main hangs over 250 ms in each hour (one sample per hour)
  corpus.<id>.footprint_growth_per_hour.total bytes  least-squares slope of the gap footprints of every process
  corpus.<id>.footprint_growth_per_hour.app   bytes  the same for the app process alone
  corpus.<id>.idle_wakeups                   per_s  wakeups per second of every process in each gap
  corpus.<id>.browser_crashes                count  Chromium process failures in each hour

Hours are buckets of HOUR_S from the first cycle's start, as many as full hours ran (a soak that ended early has fewer,
never an hour of zeros it did not run); a reading falls into the hour it was taken in, and the last bucket takes what
runs past the last full hour (a soak shorter than an hour has one bucket). The growth fit leaves out
the first pass over the composed stories (the warm-up: caches, the spare Chromium window, the first agent sessions)
and uses only gaps at the manifest's workspace count; with fewer than two such gaps it is unmeasured, never 0.

A cycle that fails (a digest mismatch, a refused event, a late schedule) is counted and the soak goes on after the
reset; MAX_CONSECUTIVE_FAILURES failures in a row, an app that exits, or a reset that does not reach the fresh state
end the soak. Whatever ended it, the metrics of the readings taken are written and soak-summary.json (in --out) says
what each cycle and gap saw.

Exit: 0 every cycle passed; 1 a cycle failed, the soak ended early, or it cannot run (a planned composed story, two
web archives); 2 usage; 4 not measurable (the build has no debug.hangs count250 or debug.crashes); 128+N signal N.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_corpus_soak.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import os
import signal
import sys
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Protocol

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]
NS_PER_S = 1_000_000_000

HOUR_S = 3600.0
GAP_SETTLE_S = 60.0           # the start of a gap the wakeup read leaves out: the reset's own work settles
MAX_CONSECUTIVE_FAILURES = 3  # cycles in a row that fail before the soak stops
RESET_TIMEOUT_S = 30.0
RESET_POLL_S = 0.1
RPC_TIMEOUT_S = 30
RESET_WORKSPACES = 1          # what a fresh launch has, and what the layout import needs (session_io._fresh)
# An `*_after` sequence past every record, so debug.hangs leaves its record lists out (blocking_hangs.py SKIP_RECORDS).
SKIP_RECORDS = 10 ** 15 - 1

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_NOT_MEASURABLE = 0, 1, 2, 4

# (series, unit) of the metrics the soak writes, as `corpus.<id>.<series>`.
SERIES = (("hangs_over_250ms", "count"), ("footprint_growth_per_hour.total", "bytes"),
          ("footprint_growth_per_hour.app", "bytes"), ("idle_wakeups", "per_s"), ("browser_crashes", "count"))


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


play = _load("perf_lab_corpus_play", HERE / "play.py")


class SoakError(play.PlayError):
    """The soak cannot run, or it ended early."""


class NotMeasurable(SoakError):
    """The build lacks a method the soak reads: its Change is not-measurable, never a regression."""


# ---------------------------------------------------------------- readings

@dataclass(frozen=True)
class ProcessReading:
    kind: str        # bench_memory.kind_of: app, cef-renderer, tui-daemon, terminal-host, webkit-web, ...
    footprint: int   # phys_footprint, bytes
    wakeups: int     # idle plus interrupt wakeups since the process started


class Processes(Protocol):
    def before_launch(self) -> None: ...

    def read(self, app_pid: int, app: str) -> dict[int, ProcessReading]: ...


class OwnedProcesses:
    """The app's processes through bench_memory (owned, usage: proc_pid_rusage), macOS only."""

    def __init__(self):
        self.memory = _load("bench_memory", REPO_ROOT / "scripts" / "cmux-next" / "bench_memory.py")

    def before_launch(self) -> None:
        self.memory.note_child_launch()  # WebKit processes that start after this and share the app's owner are its own

    def read(self, app_pid: int, app: str) -> dict[int, ProcessReading]:
        readings = {}
        for pid, (kind, _command) in self.memory.owned(app_pid, app).items():
            usage = self.memory.usage(pid)
            if usage is not None:
                readings[pid] = ProcessReading(kind, int(usage[1]), int(usage[4]))
        return readings


@dataclass
class Gap:
    cycle: int
    t_s: float                  # the gap's end, from the soak's start
    workspaces: int
    measured_s: float
    wakeups_per_s: float
    footprint: int
    app_footprint: int
    kinds: dict[str, int]       # footprint per process kind
    churned: int                # processes that started, ended or changed kind inside the measured part


def gap_reading(cycle: int, t_s: float, workspaces: int, before: Mapping[int, ProcessReading],
                after: Mapping[int, ProcessReading], measured_s: float) -> Gap:
    """The gap's wakeups per second over the processes that ran through its measured part (a pid whose kind changed
    is another process), and the footprint of every process at its end."""
    both = set(before) & set(after)
    kept = [pid for pid in sorted(both) if before[pid].kind == after[pid].kind
            and after[pid].wakeups >= before[pid].wakeups]
    wakeups = sum(after[pid].wakeups - before[pid].wakeups for pid in kept)
    kinds: dict[str, int] = {}
    for reading in after.values():
        kinds[reading.kind] = kinds.get(reading.kind, 0) + reading.footprint
    return Gap(cycle, round(t_s, 3), workspaces, round(measured_s, 3),
               round(wakeups / measured_s, 3) if measured_s > 0 else 0.0,
               sum(r.footprint for r in after.values()), kinds.get("app", 0), dict(sorted(kinds.items())),
               len(set(before) ^ set(after)) + len(both) - len(kept))


def slope_per_hour(points: Sequence[tuple[float, float]]) -> float | None:
    """Least-squares slope of [(seconds, value)] in value per hour; None under two distinct times."""
    if len(points) < 2:
        return None
    mean_x = sum(x for x, _ in points) / len(points)
    mean_y = sum(y for _, y in points) / len(points)
    sxx = sum((x - mean_x) ** 2 for x, _ in points)
    if sxx == 0:
        return None
    return sum((x - mean_x) * (y - mean_y) for x, y in points) / sxx * HOUR_S


def per_hour(readings: Sequence[tuple[float, int]], buckets: int) -> list[int]:
    """Counts per hour bucket from cumulative readings [(seconds, total)], the first one the start: each bucket is its
    last reading minus the bucket before it (a bucket with no reading counts 0); later readings than the last bucket
    go into it."""
    start = readings[0][1]
    ends: list[int | None] = [None] * buckets
    for t_s, total in readings[1:]:
        ends[min(int(t_s // HOUR_S), buckets - 1)] = total
    counts, previous = [], start
    for end in ends:
        end = previous if end is None else end
        counts.append(end - previous)
        previous = end
    return counts


def check_reply(method: str, reply: Any, first: bool) -> dict[str, Any]:
    """The reply's object. NotMeasurable when the build has no such method (at the first read); SoakError otherwise."""
    if isinstance(reply, dict) and reply.get("error") is not None:
        error = reply["error"]
        if first and isinstance(error, dict) and error.get("code") in ("method_not_found", "not_allowed"):
            raise NotMeasurable(f"the build has no {method} ({error.get('code')})")
        raise SoakError(f"{method} failed: {json.dumps(error)[:300]}")
    if not isinstance(reply, dict):
        raise SoakError(f"{method} answered {json.dumps(reply)[:200]}")
    return reply


def _count(reply: Mapping[str, Any], key: str, method: str) -> int:
    value = reply[key]
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise SoakError(f"{method} {key} is not a count: {json.dumps(value)[:80]}")
    return value


def read_counters(rpc: Callable[..., Any], first: bool = False) -> tuple[int, int]:
    """(main hangs over 250 ms, Chromium process failures), both since the launch."""
    hangs = check_reply("debug.hangs", rpc("debug.hangs", {"limit": 1, "over_budget_after": SKIP_RECORDS,
                                                           "thread_hangs_after": SKIP_RECORDS}, RPC_TIMEOUT_S), first)
    if hangs.get("installed") is not True:
        raise SoakError("the main-thread watchdog is not running (debug.hangs installed is not true)")
    if "count250" not in hangs:
        raise NotMeasurable("the build's debug.hangs has no count250 (no StallCounts)")
    crashes = check_reply("debug.crashes", rpc("debug.crashes", None, RPC_TIMEOUT_S), first)
    if "chromium_total" not in crashes:
        raise NotMeasurable("the build's debug.crashes has no chromium_total")
    return _count(hangs, "count250", "debug.hangs"), _count(crashes, "chromium_total", "debug.crashes")


# ---------------------------------------------------------------- the reset

def _topology(rpc: Callable[..., Any]) -> dict[str, Any]:
    reply = rpc("snapshot.get", None, RPC_TIMEOUT_S)
    topology = reply.get("topology") if isinstance(reply, dict) else None
    if not isinstance(topology, dict):
        raise SoakError(f"snapshot.get answered {json.dumps(reply)[:200]}")
    return topology


def _workspaces(topology: Mapping[str, Any]) -> list[dict[str, Any]]:
    return [w for w in topology.get("workspaces") or [] if isinstance(w, dict) and w.get("id")]


def _tabs(workspace: Mapping[str, Any]) -> list[dict[str, Any]]:
    return [t for s in workspace.get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")
            for t in p.get("tabs") or []]


def fresh_problem(topology: Mapping[str, Any], windows: int) -> str | None:
    """Why the app is not in a fresh launch's state: one workspace with one terminal tab, shown, in `windows` windows."""
    workspaces = _workspaces(topology)
    if len(workspaces) != RESET_WORKSPACES:
        return f"{len(workspaces)} workspaces, not {RESET_WORKSPACES}"
    kinds = [t.get("kind") for t in _tabs(workspaces[0])]
    if kinds != ["terminal"]:
        return f"the workspace has tabs {kinds}, not one terminal"
    shown = [w.get("workspace") for w in topology.get("windows") or []]
    if len(shown) != windows:
        return f"{len(shown)} windows, the launch had {windows}"
    if workspaces[0]["id"] not in shown:
        return "no window shows the workspace"
    return None


def reset(rpc: Callable[..., Any], clock: Any, windows: int) -> None:
    """Back to a fresh launch's state: a new workspace, shown, and every other workspace closed. SoakError when the
    app does not get there within RESET_TIMEOUT_S."""

    def action(name: str, args: Mapping[str, Any], target: str | None = None, focus: bool = True) -> None:
        params: dict[str, Any] = {"action": name, "args": dict(args), "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        reply = rpc("action.run", params, RPC_TIMEOUT_S)
        if isinstance(reply, dict) and reply.get("error") is not None:
            raise SoakError(f"reset: {name} refused: {json.dumps(reply['error'])[:200]}")

    def until(what: str, done: Callable[[dict[str, Any]], bool]) -> dict[str, Any]:
        deadline = clock.now_ns() + round(RESET_TIMEOUT_S * NS_PER_S)
        while True:
            topology = _topology(rpc)
            if done(topology):
                return topology
            if clock.now_ns() >= deadline:
                raise SoakError(f"reset: {what} within {RESET_TIMEOUT_S:g} s")
            clock.sleep_until(clock.now_ns() + round(RESET_POLL_S * NS_PER_S))  # the reset's own wait for the app

    old = [w["id"] for w in _workspaces(_topology(rpc))]
    action("workspace.newAtBottom", {})
    made = [w["id"] for w in _workspaces(until("no new workspace appeared",
                                               lambda t: any(w["id"] not in old for w in _workspaces(t))))
            if w["id"] not in old][0]
    action("goToWorkspace", {"workspace": made})
    until(f"workspace {made} never showed",
          lambda t: any(w.get("workspace") == made for w in t.get("windows") or []))
    for workspace in old:
        action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
    topology = until("the old workspaces did not close", lambda t: [w["id"] for w in _workspaces(t)] == [made])
    problem = fresh_problem(topology, windows)
    if problem:
        raise SoakError(f"reset: the app is not in a fresh launch's state: {problem}")


# ---------------------------------------------------------------- one launch for every cycle

class SharedBench:
    """One BenchApp for every cycle: the first launch() launches it, the later ones check that it still runs; stop()
    leaves it running (close() ends it); record() keeps a cycle's series for the summary instead of a result."""

    def __init__(self, bench: Any, processes: Processes):
        self.bench, self.processes = bench, processes
        self.launched, self.held = False, []

    def __getattr__(self, name: str) -> Any:
        return getattr(self.bench, name)

    def alive_problem(self) -> str | None:
        code = self.bench.process.poll()
        return None if code is None else f"the app exited (code {code})"

    def launch(self) -> None:
        if self.launched:
            problem = self.alive_problem()
            if problem:
                raise SoakError(problem)
            return
        self.processes.before_launch()
        self.bench.launch()  # bench_launch.LaunchError when the app does not come up
        self.launched = True

    def stop(self) -> None:
        pass

    def close(self) -> None:
        self.bench.stop()

    def record(self, story: str, metric: str, unit: str, samples: Sequence[float], better: str, engine: str) -> str:
        self.held.append({"metric": metric, "unit": unit, "samples": len(samples)})
        return "held in soak-summary.json"

    def record_result(self, story: str, metric: str, unit: str, samples: Sequence[float], better: str,
                      engine: str) -> str:
        return str(self.bench.record(story, metric, unit, samples, better, engine))


class StartedWebReplay:
    """The soak's one Web Page Replay server stands for each cycle's: require() is the real check, and a cycle's call
    yields nothing new, since the app was launched with the server's switches."""

    def __init__(self, real: Any):
        self.real, self.spki = real, None

    def require(self) -> None:
        self.real.require()

    @contextlib.contextmanager
    def __call__(self, archive: Path, spki: str, out: Path, app: str) -> Iterator[dict[str, str]]:
        if spki != self.spki:
            raise SoakError(f"a cycle's web archive (spki {spki}) is not the one the soak serves ({self.spki})")
        yield {}


class InstalledAgents:
    """Every composed story's transcripts were installed before the launch: require() is the real check, and a
    cycle's call only checks its transcripts are among them."""

    def __init__(self, real: Any):
        self.real, self.transcripts = real, frozenset()

    def require(self) -> None:
        self.real.require()

    def __call__(self, out: Path, agents: Sequence[Mapping[str, Any]], fetch: Callable[[Mapping[str, Any]], Path],
                 app: str) -> dict[str, str | None]:
        missing = [a["transcript"]["sha256"] for a in agents if a["transcript"]["sha256"] not in self.transcripts]
        if missing:
            raise SoakError(f"transcripts {', '.join(m[:12] for m in missing)} were not installed at the launch")
        return {}


# ---------------------------------------------------------------- the soak

@dataclass
class Cycle:
    index: int
    story: str
    start_s: float
    ok: bool
    reason: str | None = None
    replay: dict[str, Any] | None = None


@dataclass
class SoakReport:
    story: str
    duration_ms: int
    cycles: list[Cycle] = field(default_factory=list)
    gaps: list[Gap] = field(default_factory=list)
    readings: list[dict[str, float]] = field(default_factory=list)
    metrics: dict[str, list[float]] = field(default_factory=dict)
    results: list[str] = field(default_factory=list)
    unmeasured: list[str] = field(default_factory=list)
    ended: str | None = None   # why the soak stopped before its duration

    @property
    def ok(self) -> bool:
        return self.ended is None and bool(self.cycles) and all(cycle.ok for cycle in self.cycles)

    def summary(self) -> dict[str, Any]:
        return {"story": self.story, "duration_ms": self.duration_ms, "ok": self.ok, "ended": self.ended,
                "cycles": [asdict(c) for c in self.cycles], "gaps": [asdict(g) for g in self.gaps],
                "readings": self.readings, "metrics": self.metrics, "results": self.results,
                "unmeasured": self.unmeasured}


def default_bench(app: str, *, out: Path, env: Mapping[str, str | None], session: str):
    return play.bench_launch().BenchApp(app, out=str(out), env=dict(env), perf_session=session)


class Soak:
    """The soak with its seams: tests pass the clock, the bench, the process reads, the web replay and agent install
    (the real ones run once, before the launch) and the Player's own seams (`player_options`)."""

    def __init__(self, *, root: Path = REPO_ROOT, clock: Any = None, make_bench: Callable[..., Any] = default_bench,
                 processes: Processes | None = None, web_replay: Any = None, agents: Any = None,
                 player_options: Mapping[str, Any] | None = None, log: Callable[[str], None] | None = None):
        self.root, self.clock = Path(root), clock or play.HostClock()
        self.make_bench, self.processes = make_bench, processes
        self.web, self.agents = web_replay or play.WebReplay(), agents or play.AgentTracks()
        self.started_web, self.installed_agents = StartedWebReplay(self.web), InstalledAgents(self.agents)
        self.shared: SharedBench | None = None
        self.player = play.Player(root=self.root, clock=self.clock, make_bench=self._cycle_bench,
                                  web_replay=self.started_web, agents=self.installed_agents,
                                  **dict(player_options or {}))
        self.log = log or (lambda line: print(line, file=sys.stderr, flush=True))

    def _cycle_bench(self, app: str, *, out: Path, env: Mapping[str, str | None], session: str) -> SharedBench:
        return self.shared

    def _now_s(self, origin_ns: int) -> float:
        return (self.clock.now_ns() - origin_ns) / NS_PER_S

    # Loading.

    def load(self, manifest: str | os.PathLike, scratch: Path) -> tuple[dict[str, Any], list[Any]]:
        """The soak manifest and its composed stories (play.Story), each recorded; SoakError before any launch."""
        corpus = play.corpus_manifest()
        path = Path(manifest)
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SoakError(f"{path}: {error}") from error
        known = frozenset(p.stem for p in play.corpus_paths(self.root))
        errors = corpus.validation_errors(doc, root=self.root, stories=known)
        if errors:
            raise SoakError(f"{doc.get('id', path)}: invalid manifest: " + "; ".join(errors[:6]))
        if "compose" not in doc:
            raise SoakError(f"{doc['id']} composes no stories: play.py plays it")
        if doc["layout"]["workspaces"] != RESET_WORKSPACES:
            raise SoakError(f"{doc['id']}: layout.workspaces is the count between its stories, where the footprint is "
                            f"read: {RESET_WORKSPACES}, as a fresh launch has (not {doc['layout']['workspaces']})")
        stories = []
        for name in doc["compose"]["stories"]:
            try:
                stories.append(self.player.load(self.root / play.CORPUS_DIR / f"{name}.json", scratch))
            except play.PlayError as error:
                raise SoakError(f"{doc['id']}: composed story {name}: {error}") from error
        archives = [s for s in stories if s.manifest["web_archive"] is not None]
        if len({s.manifest["web_archive"]["spki"] for s in archives}) > 1 or \
                len({s.manifest["web_archive"]["wprgo"]["sha256"] for s in archives}) > 1:
            raise SoakError(f"{doc['id']}: {', '.join(s.id for s in archives)} each have a web archive; one launch's "
                            "Chromium switches name one Web Page Replay server")
        return doc, stories

    # The run.

    def run(self, manifest: str | os.PathLike, *, app: str, out: str | os.PathLike,
            duration_ms: int | None = None, story_name: str | None = None) -> SoakReport:
        out = Path(out)
        out.mkdir(parents=True, exist_ok=True)
        doc, stories = self.load(manifest, out)
        name = story_name or os.environ.get("PERF_LAB_STORY") or doc["id"]
        report = SoakReport(doc["id"], duration_ms or doc["duration_ms"])
        processes = self.processes or OwnedProcesses()
        bundle = os.path.realpath(app).rstrip("/")
        engine = next((e for e in ("chromium", "webkit") if any(s.engine == e for s in stories)), "none")
        try:
            with contextlib.ExitStack() as stack:
                env: dict[str, str | None] = {}
                archived = next((s for s in stories if s.manifest["web_archive"] is not None), None)
                if archived is not None:
                    archive = archived.manifest["web_archive"]
                    env.update(stack.enter_context(self.web(self.player.fetch(archive["wprgo"]), archive["spki"],
                                                            out / "wpr", app)))
                    self.started_web.spki = archive["spki"]
                agents = list({a["transcript"]["sha256"]: a for s in stories for a in s.manifest["agents"]}.values())
                if agents:
                    env.update(self.agents(out / "agents", agents, self.player.fetch, app))
                    self.installed_agents.transcripts = frozenset(a["transcript"]["sha256"] for a in agents)
                self.shared = SharedBench(self.make_bench(app, out=out, env=env, session=f"corpus:{doc['id']}"),
                                          processes)
                stack.callback(self.shared.close)
                self.shared.launch()
                self.loop(doc, stories, report, app=app, bundle=bundle, out=out)
                self.write(report, doc, stories, name, engine)
        finally:
            (out / "soak-summary.json").write_text(json.dumps(report.summary(), indent=1), encoding="utf-8")
        return report

    def loop(self, doc: Mapping[str, Any], stories: Sequence[Any], report: SoakReport, *, app: str, bundle: str,
             out: Path) -> None:
        bench = self.shared
        windows = len(_topology(bench.rpc).get("windows") or [])
        problem = fresh_problem(_topology(bench.rpc), windows)
        if problem:
            raise SoakError(f"the launched app is not fresh: {problem}")
        hangs, crashes = read_counters(bench.rpc, first=True)
        origin = self.clock.now_ns()
        report.readings.append({"t_s": 0.0, "hangs_over_250ms": hangs, "browser_crashes": crashes})
        gap_s = doc["compose"]["idle_gap_ms"] / 1000
        failures = 0
        index = 0
        while self._now_s(origin) * 1000 < report.duration_ms:
            story = stories[index % len(stories)]
            cycle = Cycle(index, story.id, round(self._now_s(origin), 3), ok=True)
            report.cycles.append(cycle)
            self.log(f"soak: cycle {index} {story.id} at {cycle.start_s / 60:.1f} min")
            try:
                replay = self.player.replay(story.path, app=app, out=out / f"cycle-{index:03d}-{story.id}")
                cycle.replay = replay.summary()
                failures = 0
            except play.PlayError as error:
                cycle.ok, cycle.reason = False, str(error)[:600]
                failures += 1
            problem = bench.alive_problem()
            if problem:
                report.ended = f"cycle {index} ({story.id}): {problem}"
                return
            if failures >= MAX_CONSECUTIVE_FAILURES:
                report.ended = f"{failures} cycles in a row failed; the last: {cycle.reason}"
                return
            try:
                reset(bench.rpc, self.clock, windows)
                report.gaps.append(self.gap(index, origin, gap_s, bench, bundle))
                hangs, crashes = read_counters(bench.rpc)
            except SoakError as error:
                report.ended = f"after cycle {index} ({story.id}): {error}"
                return
            report.readings.append({"t_s": round(self._now_s(origin), 3), "hangs_over_250ms": hangs,
                                    "browser_crashes": crashes})
            index += 1

    def gap(self, cycle: int, origin: int, gap_s: float, bench: SharedBench, bundle: str) -> Gap:
        """The idle gap after a cycle's reset: nothing is sent; the processes are read after the settle and at the end."""
        start = self.clock.now_ns()
        self.clock.sleep_until(start + round(min(GAP_SETTLE_S, gap_s / 2) * NS_PER_S))  # the idle gap itself
        pid = bench.process.pid
        before, begun = bench.processes.read(pid, bundle), self.clock.now_ns()
        self.clock.sleep_until(start + round(gap_s * NS_PER_S))
        after = bench.processes.read(pid, bundle)
        measured_s = (self.clock.now_ns() - begun) / NS_PER_S
        workspaces = len(_workspaces(_topology(bench.rpc)))
        return gap_reading(cycle, self._now_s(origin), workspaces, before, after, measured_s)

    def write(self, report: SoakReport, doc: Mapping[str, Any], stories: Sequence[Any], name: str,
              engine: str) -> None:
        """The soak's series from its readings and gaps; a series with nothing to write is listed as unmeasured."""
        buckets = max(1, int(report.readings[-1]["t_s"] // HOUR_S)) if report.readings else 1  # hours that ran
        series: dict[str, list[float]] = {}
        if len(report.readings) > 1:
            for key in ("hangs_over_250ms", "browser_crashes"):
                series[key] = [float(n) for n in per_hour([(r["t_s"], r[key]) for r in report.readings], buckets)]
        steady = [g for g in report.gaps if g.cycle >= len(stories) and g.workspaces == doc["layout"]["workspaces"]]
        for key, attribute in (("footprint_growth_per_hour.total", "footprint"),
                               ("footprint_growth_per_hour.app", "app_footprint")):
            slope = slope_per_hour([(g.t_s, getattr(g, attribute)) for g in steady])
            if slope is not None:
                series[key] = [round(slope, 1)]
        if report.gaps:
            series["idle_wakeups"] = [g.wakeups_per_s for g in report.gaps]
        prefix = f"corpus.{play.metric_id(doc['id'])}."
        for key, unit in SERIES:
            metric = prefix + key
            spec = play.declared(doc, metric)
            if key not in series or spec is None:
                report.unmeasured.append(metric)
                continue
            report.metrics[metric] = series[key]
            report.results.append(self.shared.record_result(name, metric, unit, series[key], spec["better"], engine))


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None, soak: Soak | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("manifest", type=Path, help="a perf-corpus soak manifest (one with `compose`)")
    parser.add_argument("--app", required=True, help="a bench `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--tag", help="the app's tag (the lab runner passes it; the bundle names its own)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--duration-ms", type=int, help="the soak's length instead of the manifest's duration_ms")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    opts = parser.parse_args(argv)
    if opts.duration_ms is not None and opts.duration_ms < 1:
        parser.error("--duration-ms is at least 1")
    for number in (signal.SIGTERM, signal.SIGHUP):  # exit through the finally blocks, which stop the app
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    soak = soak or Soak(root=opts.root)
    try:
        report = soak.run(opts.manifest, app=opts.app, out=opts.out, duration_ms=opts.duration_ms)
    except NotMeasurable as error:
        print(f"soak: not measurable: {error}", file=sys.stderr)
        return EXIT_NOT_MEASURABLE
    except (play.PlayError, play.bench_launch().LaunchError) as error:
        print(f"soak: {error}", file=sys.stderr)
        return EXIT_FAILED
    failed = [c for c in report.cycles if not c.ok]
    print("CORPUS-SOAK " + json.dumps({"story": report.story, "ok": report.ok, "cycles": len(report.cycles),
                                        "failed": len(failed), "ended": report.ended, "metrics": report.metrics,
                                        "unmeasured": report.unmeasured}), flush=True)
    return EXIT_OK if report.ok else EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
