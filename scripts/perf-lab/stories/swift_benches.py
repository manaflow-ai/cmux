#!/usr/bin/env python3
"""Swift in-process benches as lab stories: one `swift test -c release --filter <Bench>` per story, on a builder.

A builder-host story (tier `builder`, p12-perf-process task 217). The benches under Packages/macOS/CmuxNext/Tests
(`git ls-files Packages/macOS/CmuxNext/Tests | rg -i 'bench|perf'`) record their raw samples through
PerfResultWriter (Tests/CmuxNextTestSupport/PerfResultWriter.swift) when CMUX_PERF_RESULT_DIR is set, and print
only their usual lines when it is not. Each bench has its own story file, `stories.d/swift-<bench>.json` (or the
story that already named it, `pane-bench.json`), whose command is this script:

  scripts/perf-lab/stories/swift_benches.py run --story ID --filter FILTER [--env NAME=VALUE ...]

`run` writes the result-v1 fields a test process cannot know (the story, a new run, the commit, the builder's host
block, engine none, session light, no features) to `<results>/perf-result-context.json`, runs
`scripts/ci/package-test-lane.sh suite Packages/macOS/CmuxNext FILTER` with CMUX_SWIFT_SUITE_CONFIGURATION=release
(the fleet's optimized suite build, `-c release` with DEBUG still defined for the test helpers), the bench's
enabling variables and CMUX_PERF_RESULT_DIR, then reads back every `.ndjson` the bench wrote with perf_result.py.
A file that is not valid result-v1, is not this run's, names a metric the story does not list, or names a metric
another file (or line) of the run also names (ingest refuses a metric recorded twice) moves to `<out>/rejected/`; the rest stay in `<out>/swift-results/`. Exit 0: the suite passed and wrote only valid results;
1: the suite failed or a file was rejected (the valid ones are kept); 2: refused (not a fleet step, a lab host,
a bad story) or nothing was written.

  cmux-ci run --class exclusive --script scripts/perf-lab/stories/swift_benches.py --ref SHA \\
    --arg=run --arg=--story=swift-lane-item --arg=--filter=LaneStatsBench --arg=--env=CMUX_LANE_ITEM_BENCH=1 \\
    --arg=--out=artifacts/swift-benches
  python3 -I scripts/perf-lab/stories/swift_benches.py check   # every bench file has a story (Linux, no build)
  python3 -I scripts/perf-lab/stories/swift_benches.py list

Builder timing is a builder's: the series key has its host class, so it is never compared with a lab Mac's. Chrome
runs its in-process microbenchmarks the same way, the test binary printing raw values and the harness owning the
format (`base/test/perf_test_suite.h`, `testing/perf/perf_result_reporter.h`). Not a CI gate (Lawrence 2026-10-23).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # loading the sibling story by path must not write __pycache__ into the checkout

import argparse
import importlib.util
import json
import os
import re
import shutil
import socket
import subprocess
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
REPO = PERF_LAB.parent.parent
STORIES_DIR = PERF_LAB / "stories.d"
SCRIPT = "scripts/perf-lab/stories/swift_benches.py"
PACKAGE = "Packages/macOS/CmuxNext"
TESTS = f"{PACKAGE}/Tests"
WRITER = f"{TESTS}/CmuxNextTestSupport/PerfResultWriter.swift"
LANE = "scripts/ci/package-test-lane.sh"

SESSION = "light"
ENGINE = "none"
CONFIG = "release"  # package-test-lane's CMUX_SWIFT_SUITE_CONFIGURATION=release: SwiftPM -c release
MEASURE_VERSION = 1
RESULT_DIR_VARIABLE = "CMUX_PERF_RESULT_DIR"  # PerfResultWriter.directoryVariable
CONTEXT_FILE = "perf-result-context.json"  # PerfResultWriter.contextFileName
# PerfResultWriter.contextKeys: result-v1 without the fields of one metric.
METRIC_KEYS = ("schema", "metric", "unit", "better", "samples", "target_ref")
RESULTS_DIR = "swift-results"
REJECTED_DIR = "rejected"
BENCH_FILE = re.compile(r"bench|perf", re.IGNORECASE)
ENV_ASSIGNMENT = re.compile(r"^[A-Z_][A-Z0-9_]*=.*$")
# The files the bench pattern matches that are behavior tests, not benches: they time nothing, so no story.
NOT_BENCHES: Dict[str, str] = {
    f"{TESTS}/CmuxNextAppTests/DebugSettingsBenchActivationTests.swift":
        "which bundles load the debug tunables in a bench build; measures nothing",
    f"{TESTS}/CmuxNextDesignTests/HoverCardMovesPerFrameTests.swift":
        "pointer moves per frame for a hover card (feature pointerFrameHover): counts checked, not a bench",
    f"{TESTS}/CmuxNextDesignTests/OverlayHoverPerFrameTests.swift":
        "overlay hover deliveries per frame (feature pointerFrameHover): counts checked, not a bench",
    f"{TESTS}/CmuxNextFeaturesTests/PerfLabProbesTests.swift":
        "the perf lab canary and kill probe features on a stepping clock: behavior, not a bench",
    f"{TESTS}/CmuxNextWakeupsTests/PerfResultWriterTests.swift": "the result writer's own tests",
}


class StoryError(RuntimeError):
    """The story cannot run here (not a fleet step, a lab host, a bad story, an unreadable host)."""


def load_by_path(name: str, path: Path) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


# The builder story's host block and lab-host refusal have one implementation: incremental-build's. Its perf_result
# is this story's too, so the Host it builds is the Result's own class.
builder_host = load_by_path("perf_lab_swift_benches_incremental_build", HERE / "incremental_build.py")
perf_result = builder_host.perf_result


# ---------------------------------------------------------------- stories

@dataclass(frozen=True)
class MetricPattern:
    name: str
    unit: str
    better: str

    def matches(self, metric: str, unit: str, better: str) -> bool:
        return re.fullmatch(self.name, metric) is not None and unit == self.unit and better == self.better


@dataclass(frozen=True)
class SwiftStory:
    id: str
    path: Path
    filter: str
    env: Tuple[Tuple[str, str], ...]
    bench_files: Tuple[str, ...]
    metrics: Tuple[MetricPattern, ...]

    def accepts(self, metric: str, unit: str, better: str) -> bool:
        return any(pattern.matches(metric, unit, better) for pattern in self.metrics)


def _command_options(command: Sequence[str]) -> Dict[str, List[str]]:
    """`--name VALUE` and `--name=VALUE` pairs after the subcommand, by name."""
    options: Dict[str, List[str]] = {}
    index = 2
    while index < len(command):
        arg = command[index]
        if arg.startswith("--") and "=" in arg:
            name, _, value = arg.partition("=")
            index += 1
        elif arg.startswith("--") and index + 1 < len(command):
            name, value = arg, command[index + 1]
            index += 2
        else:
            raise StoryError(f"command argument {arg!r} is not --name VALUE")
        options.setdefault(name, []).append(value)
    return options


def parse_env(assignments: Sequence[str]) -> Tuple[Tuple[str, str], ...]:
    parsed = []
    for assignment in assignments:
        if not ENV_ASSIGNMENT.match(assignment):
            raise StoryError(f"--env {assignment!r} is not NAME=VALUE")
        name, _, value = assignment.partition("=")
        if name == RESULT_DIR_VARIABLE:
            raise StoryError(f"--env may not set {RESULT_DIR_VARIABLE}: the runner owns it")
        parsed.append((name, value))
    return tuple(parsed)


def load_story(path: Path) -> Optional[SwiftStory]:
    """The swift bench story of a stories.d file, or None when its command is not this script."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    command = doc.get("command") or []
    if not command or command[0] != SCRIPT:
        return None
    if command[1:2] != ["run"]:
        raise StoryError(f"{path.name}: the command runs `{SCRIPT} run`")
    options = _command_options(command)
    stories, filters = options.get("--story", []), options.get("--filter", [])
    if stories != [doc.get("id")]:
        raise StoryError(f"{path.name}: --story must be the story's own id {doc.get('id')!r}, got {stories}")
    if len(filters) != 1 or not filters[0]:
        raise StoryError(f"{path.name}: the command needs exactly one --filter")
    unknown = sorted(set(options) - {"--story", "--filter", "--env"})
    if unknown:
        raise StoryError(f"{path.name}: unknown command options {unknown}")
    needs = doc.get("needs", [])
    if f"file:{WRITER}" not in needs:
        raise StoryError(f"{path.name}: needs must name file:{WRITER} (a commit without the writer is not measurable)")
    files = tuple(need[len("file:"):] for need in needs
                  if need.startswith(f"file:{TESTS}/") and need != f"file:{WRITER}")
    if not files:
        raise StoryError(f"{path.name}: needs names no bench file under {TESTS} (file:<path>)")
    metrics = tuple(MetricPattern(m["name"], m["unit"], m["better"]) for m in doc.get("metrics", []))
    return SwiftStory(id=doc["id"], path=path, filter=filters[0], env=parse_env(options.get("--env", [])),
                      bench_files=files, metrics=metrics)


def swift_stories(stories_dir: Path = STORIES_DIR) -> List[SwiftStory]:
    found = []
    for path in sorted(stories_dir.glob("*.json")):
        story = load_story(path)
        if story is not None:
            found.append(story)
    return found


def bench_files(repo: Path) -> List[str]:
    """The Tests files the task's pattern names: `git ls-files Packages/macOS/CmuxNext/Tests | rg -i 'bench|perf'`."""
    listed = subprocess.run(["git", "-C", str(repo), "ls-files", "--", TESTS], capture_output=True, text=True)
    if listed.returncode != 0:
        raise StoryError(f"git ls-files {TESTS} failed: {listed.stderr.strip()}")
    return sorted(path for path in listed.stdout.splitlines()
                  if path.endswith(".swift") and BENCH_FILE.search(path) and path != WRITER)


def coverage_problems(repo: Path, stories: Sequence[SwiftStory]) -> List[str]:
    """Every bench file has a story, every story's bench file exists and writes through PerfResultWriter."""
    problems = []
    claimed: Dict[str, str] = {}
    for story in stories:
        for path in story.bench_files:
            if path in claimed:
                problems.append(f"{path}: claimed by {claimed[path]} and {story.id}")
            claimed[path] = story.id
            file = repo / path
            if not file.is_file():
                problems.append(f"{story.id}: bench file {path} does not exist")
            elif "PerfResultWriter" not in file.read_text(encoding="utf-8", errors="replace"):
                problems.append(f"{story.id}: {path} writes no result (no PerfResultWriter)")
    for path in bench_files(repo):
        if path not in claimed and path not in NOT_BENCHES:
            problems.append(f"{path}: a bench with no story (add stories.d/swift-<bench>.json) "
                            "or a behavior test (add it to NOT_BENCHES with the reason)")
    for path in NOT_BENCHES:
        if path in claimed:
            problems.append(f"{path}: in NOT_BENCHES and claimed by {claimed[path]}")
    return problems


# ---------------------------------------------------------------- the run

def context(story: str, run, build, host) -> dict:
    """The context object PerfResultWriter merges into each record: a valid result-v1 minus one metric's fields."""
    template = perf_result.Result(story=story, metric="context", unit="count", better="lower", samples=[0],
                                  build=build, host=host, engine=ENGINE, session=SESSION, run=run)
    template.validate()
    fields = template.to_dict()
    return {key: value for key, value in fields.items() if key not in METRIC_KEYS}


def lane_command(repo: Path, story: SwiftStory) -> List[str]:
    return [str(repo / LANE), "suite", PACKAGE, story.filter]


def lane_env(environ: Mapping[str, str], story: SwiftStory, results: Path) -> Dict[str, str]:
    env = dict(environ)
    env.update(dict(story.env))
    env["CMUX_SWIFT_SUITE_CONFIGURATION"] = CONFIG
    env[RESULT_DIR_VARIABLE] = str(results)
    return env


@dataclass
class Collected:
    kept: List[Path]
    rejected: List[Tuple[Path, str]]


def _reject(path: Path, rejected_dir: Path) -> None:
    rejected_dir.mkdir(parents=True, exist_ok=True)
    shutil.move(str(path), str(rejected_dir / path.name))


def collect(results: Path, rejected_dir: Path, story: SwiftStory, expected: dict) -> Collected:
    """Keeps each result file of this run whose metrics the story lists and no other file repeats; moves every other
    one to rejected_dir. A metric written twice in one run is ingest's refusal of the whole run (ingest.py
    _store_records), so every file that names it is rejected: which copy is right is unknown."""
    kept, rejected = [], []
    metrics: Dict[Path, List[str]] = {}
    for path in sorted(results.glob("*.ndjson")):
        try:
            found = perf_result.read_file(path)
            reason = None
        except perf_result.ResultError as error:
            found, reason = [], str(error)
        for result in found:
            fields = result.to_dict()
            other = sorted(key for key, value in expected.items() if fields.get(key) != value)
            if other:
                reason = f"{result.metric}: {', '.join(other)} differ from this run's context"
            elif not story.accepts(result.metric, result.unit, result.better):
                reason = (f"{result.metric} ({result.unit}, {result.better}) matches no metric of "
                          f"{story.path.name}")
            if reason:
                break
        if reason is None and not found:
            reason = "no result in the file"
        if reason is None:
            kept.append(path)
            metrics[path] = [result.metric for result in found]
        else:
            _reject(path, rejected_dir)
            rejected.append((path, reason))
    files: Dict[str, List[Path]] = {}
    for path in kept:
        for metric in metrics[path]:
            files.setdefault(metric, []).append(path)
    repeated: Dict[Path, str] = {}
    for metric, paths in sorted(files.items()):
        if len(paths) > 1:
            names = ", ".join(sorted({p.name for p in paths}))
            for path in paths:
                repeated.setdefault(path, f"metric {metric} is recorded twice in this run ({names}); "
                                          "ingest refuses the run")
    for path in kept:
        if path in repeated:
            _reject(path, rejected_dir)
            rejected.append((path, repeated[path]))
    return Collected([path for path in kept if path not in repeated], rejected)


def fleet_refusal(environ: Mapping[str, str]) -> Optional[str]:
    """scripts/cmux-next/lib/fleet-only.sh's rule: swift test runs only as a fleet step or on a GitHub runner."""
    if environ.get("CMUX_CI_STEP_KEY") or environ.get("GITHUB_ACTIONS") == "true":
        return None
    return (f"{SCRIPT} runs swift test, so only on the build fleet: cmux-ci run --class exclusive --script {SCRIPT} "
            "--ref SHA --arg=run --arg=--story=ID ...")


Runner = Callable[[List[str], Dict[str, str], Path], int]


def run_lane(command: List[str], env: Dict[str, str], cwd: Path) -> int:
    return subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL).returncode


def run(args: argparse.Namespace, environ: Mapping[str, str], runner: Runner = run_lane,
        host_facts: Callable[[], dict] = builder_host.read_host_facts, hostname: Optional[str] = None,
        stories_dir: Path = STORIES_DIR, repo: Path = REPO) -> int:
    name = f"swift-benches {args.story}"
    session = args.session or environ.get("PERF_LAB_SESSION") or SESSION
    if session != SESSION:
        print(f"{name}: session {session!r}: these stories run only {SESSION!r}", file=sys.stderr)
        return 2
    try:
        path = stories_dir / f"{args.story}.json"
        story = load_story(path) if path.is_file() else None
        if story is None:
            raise StoryError(f"{path} is not a {SCRIPT} story")
        if story.filter != args.filter or story.env != parse_env(args.env or []):
            raise StoryError(f"--filter and --env differ from {path.name}'s command")
        refusal = fleet_refusal(environ) or builder_host.lab_host_refusal(environ, hostname or socket.gethostname())
        if refusal:
            raise StoryError(f"refused: {refusal}")
        host = builder_host.host_block(host_facts())
        sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True,
                             check=True).stdout.strip()
        expected = context(story.id, perf_result.Run.start(),
                           perf_result.Build(sha=sha, config=CONFIG, measure_version=MEASURE_VERSION), host)
    except (StoryError, builder_host.StoryError, perf_result.ResultError, subprocess.CalledProcessError) as error:
        print(f"{name}: {error}", file=sys.stderr)
        return 2
    out = args.out.resolve()
    results = out / RESULTS_DIR
    if results.exists():
        shutil.rmtree(results)
    results.mkdir(parents=True)
    (results / CONTEXT_FILE).write_text(json.dumps(expected, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    status = runner(lane_command(repo, story), lane_env(environ, story, results), repo)
    collected = collect(results, out / REJECTED_DIR, story, expected)
    for path, reason in collected.rejected:
        print(f"{name}: rejected {path.name}: {reason}", file=sys.stderr)
    print(f"{name}: suite exit {status}, {len(collected.kept)} result files in {results}")
    if not collected.kept:
        print(f"{name}: the bench wrote no result (was it skipped? its enabling variable: "
              f"{', '.join(n for n, _ in story.env) or 'none'})", file=sys.stderr)
        return 2
    return 0 if status == 0 and not collected.rejected else 1


# ---------------------------------------------------------------- commands

def parse_args(argv: Optional[List[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", metavar="COMMAND")
    run_parser = commands.add_parser("run", help="run one bench story (a fleet step)")
    run_parser.add_argument("--story", required=True, help="the story id (stories.d/<id>.json)")
    run_parser.add_argument("--filter", required=True, help="the swift test filter of the bench")
    run_parser.add_argument("--env", action="append", help="NAME=VALUE that enables the bench (repeatable)")
    run_parser.add_argument("--out", type=Path, required=True, help="the results folder")
    runner = run_parser.add_argument_group("story runner", "what the runner passes (stories.d/README.md)")
    runner.add_argument("--app", default=None, help="unused: the bench runs in the test process, not an app")
    runner.add_argument("--tag", default=None, help="unused")
    runner.add_argument("--session", default=None, help=f"the session (default $PERF_LAB_SESSION); only {SESSION}")
    commands.add_parser("check", help="every bench file under Tests has a story that names it (no build)")
    commands.add_parser("list", help="the swift bench stories: id, filter, enabling variables, bench files")
    args = parser.parse_args(argv)
    if args.command is None:
        parser.error("a command is required")
    return args


def main(argv: Optional[List[str]] = None, environ: Optional[Mapping[str, str]] = None) -> int:
    args = parse_args(argv)
    environ = os.environ if environ is None else environ
    if args.command == "run":
        return run(args, environ)
    try:
        stories = swift_stories()
        if args.command == "list":
            for story in stories:
                env = " ".join(f"{n}={v}" for n, v in story.env) or "-"
                print(f"{story.id}\t{story.filter}\t{env}\t{' '.join(story.bench_files)}")
            return 0
        problems = coverage_problems(REPO, stories)
    except StoryError as error:
        print(f"swift-benches: {error}", file=sys.stderr)
        return 2
    for problem in problems:
        print(f"swift-benches: {problem}", file=sys.stderr)
    print(f"swift-benches: {len(stories)} stories, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
