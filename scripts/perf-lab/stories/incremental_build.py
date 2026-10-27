#!/usr/bin/env python3
"""Story incremental-build: the edit loop's rebuild after a one-line leaf edit (target row incremental-build).

A builder-host story (tier `builder`, never a lab host). At the checkout's commit it builds once (warm), then for each
leaf below appends a comment line, rebuilds and times that rebuild alone, puts the leaf's HEAD bytes back and rebuilds
again untimed, so the next leaf starts from a warm build of the pristine tree. Rounds interleave the leaves.

  compat_leaf     a CmuxNextCompat file (the bottom of the Swift graph: every module imports Compat)
  sidebar_view    a CmuxNextSidebar view
  app_handler     a CmuxNextApp action handler (the composition root, the biggest module)
  tui_crate_leaf  cmux-panic-log, a cmux-tui crate with no workspace dependency of its own

The Swift leaves build `swift build --target CmuxNextApp` (Debug: the developer's loop, p11-codebase.md F13) in a
new scratch path, so the warm build compiles every file and its log lists every slow type-check. The Rust leaf builds
`cargo build -p cmux-tui --bin cmux-tui`. Each build runs through scripts/ci/swiftpm_build_metrics.py's run_build:
its timer covers the build command alone, and its receipt and streamed log stay in OUT/builds/.

Metrics (result-v1, build.config debug):
  build.incremental.<leaf>_s                  one sample per round; target row incremental-build (p50 < 30 s)
  build.incremental.<leaf>.rebuilt_modules    modules (SwiftPM "Compiling"/"Emitting module" lines, cargo "Compiling"
                                              lines) the timed rebuild touched, one sample per round
  build.typecheck.slow_functions              function and closure bodies of 100 ms or more in the warm Swift build

Attachments (files in OUT, named by kind, digests in every result):
  rebuilt-modules          every timed rebuild's module list
  incremental-diagnostics  scripts/ci/swift_incremental_diagnostics.py per Swift rebuild (-driver-show-incremental)
  typecheck-queue          MQ15: function and closure bodies the compiler reports at 100 ms or more
                           (scripts/ci/swift_typecheck_diagnostics.py's pattern of swiftc's warnings), one task per
                           file, ordered by the slowest body then the path; the same log always gives the same bytes.
                           `lab.py queue typecheck --latest` reads it from the lab store after ingest (queues.py)

Every edited leaf is put back on exit, on an error and on SIGTERM/SIGINT/SIGHUP; `restore` does it from HEAD for the
fleet script's trap, and touches a leaf only when its bytes are HEAD's plus probe lines.

  scripts/measure/incremental-build.sh                      # the fleet entry (cmux-ci run --class exclusive)
  python3 scripts/perf-lab/stories/incremental_build.py leaves
  python3 scripts/perf-lab/stories/incremental_build.py restore
  python3 scripts/perf-lab/lab.py queue typecheck [--latest | --dir OUT | --log LOG]

The leaf list is fixed, so each series is the same edit on every commit; a commit without a leaf file measures the
other leaves, names the missing one in its errors and exits 1. Not a CI gate (Lawrence 2026-10-23).
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # loading scripts/ci helpers by path must not write __pycache__ into the checkout

import argparse
import collections
import contextlib
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from types import ModuleType
from typing import Callable, Dict, Iterator, List, Mapping, Optional, Sequence

HERE = Path(__file__).resolve().parent
PERF_LAB = HERE.parent
SCRIPTS = PERF_LAB.parent
CI = SCRIPTS / "ci"

STORY = "incremental-build"
TARGET_ROW = "incremental-build"
SESSION = "light"
SESSION_ENV = "PERF_LAB_SESSION"
CONFIG = "debug"  # the developer's edit loop; a builder story may say debug (stories.d/README.md)
MEASURE_VERSION = 1
DEFAULT_ROUNDS = 3
TYPECHECK_LIMIT_MS = 100
QUEUE_SCHEMA = "cmux-perf-lab-typecheck-queue/v1"
LAB_LABEL = "perf-lab"
POOL = PERF_LAB / "pool.json"

SWIFT, CARGO = "swift", "cargo"
SWIFT_PACKAGE = "Packages/macOS/CmuxNext"
SWIFT_TARGET = "CmuxNextApp"
CARGO_WORKSPACE = "cmux-tui"
CARGO_PACKAGE = "cmux-tui"
PROBE = "// incremental-build probe {round}\n"
PROBE_LINE = re.compile(rb"// incremental-build probe [0-9]+\n")

QUEUE_KIND = "typecheck-queue"
QUEUE_FILE = f"{QUEUE_KIND}.json"
MODULES_FILE = "rebuilt-modules.json"
DIAGNOSTICS_FILE = "incremental-diagnostics.json"
BUILDS_DIR = "builds"

SWIFTPM_WORK = re.compile(r"^\[\d+/\d+\] (?:Compiling|Emitting module) (?P<module>[A-Za-z_][A-Za-z0-9_]*)\b")
CARGO_WORK = re.compile(r"^\s*Compiling (?P<module>[A-Za-z0-9_-]+) v[0-9]")


@dataclass(frozen=True)
class Leaf:
    name: str
    kind: str
    path: str


LEAVES = (
    Leaf("compat_leaf", SWIFT, "Packages/macOS/CmuxNext/Sources/CmuxNextCompat/MacName.swift"),
    Leaf("sidebar_view", SWIFT, "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/PresenceDotsView.swift"),
    Leaf("app_handler", SWIFT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/AppearanceHandlers.swift"),
    Leaf("tui_crate_leaf", CARGO, "cmux-tui/crates/cmux-panic-log/src/lib.rs"),
)


class StoryError(RuntimeError):
    """The story cannot run here (a lab host, a dirty or missing leaf, an unreadable host)."""


class Interrupted(BaseException):
    """A termination signal; raised in the main thread so every `finally` puts the leaves back."""

    def __init__(self, signum: int) -> None:
        super().__init__(f"signal {signum}")
        self.signum = signum


def load_by_path(name: str, path: Path) -> ModuleType:
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


perf_result = load_by_path("perf_lab_incremental_build_perf_result", PERF_LAB / "perf_result.py")
store = load_by_path("perf_lab_incremental_build_store", PERF_LAB / "store.py")
incremental_diagnostics = load_by_path("perf_lab_swift_incremental_diagnostics", CI / "swift_incremental_diagnostics.py")
typecheck_diagnostics = load_by_path("perf_lab_swift_typecheck_diagnostics", CI / "swift_typecheck_diagnostics.py")


def swiftpm_build_metrics() -> ModuleType:
    """scripts/ci/swiftpm_build_metrics.py; it imports its sibling build_metrics by name."""
    if str(CI) not in sys.path:
        sys.path.insert(0, str(CI))
    return load_by_path("perf_lab_swiftpm_build_metrics", CI / "swiftpm_build_metrics.py")


# ---------------------------------------------------------------- builds

@dataclass(frozen=True)
class Build:
    role: str
    exit_code: int
    seconds: float
    log: Path


Builder = Callable[[str, Path, Sequence[str]], Build]


@contextlib.contextmanager
def working_directory(path: Path) -> Iterator[None]:
    previous = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


class MetricsBuilder:
    """One build through swiftpm_build_metrics.run_build: receipt and log in DIRECTORY, the command alone timed."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory

    def __call__(self, role: str, workdir: Path, command: Sequence[str]) -> Build:
        metrics = swiftpm_build_metrics()
        with working_directory(workdir):
            # Its own process group: on Interrupted, run_build stops the whole build (swift-frontend, rustc) and
            # reaps it before the leaf restore and the scratch removal run.
            exit_code = metrics.run_build(role, self.directory, list(command), own_process_group=True)
        receipt_path = self.directory / f"{role}.json"
        try:
            seconds = float(json.loads(receipt_path.read_text(encoding="utf-8"))["build_step_seconds"])
        except (OSError, ValueError, KeyError) as error:
            raise StoryError(f"{role}: run_build wrote no timed receipt at {receipt_path} ({error})") from None
        return Build(role, exit_code, seconds, self.directory / f"{role}.log")


def swift_command(scratch: Path) -> List[str]:
    return ["swift", "build", "--target", SWIFT_TARGET, "--scratch-path", str(scratch),
            "-Xswiftc", "-Xfrontend", "-Xswiftc", f"-warn-long-function-bodies={TYPECHECK_LIMIT_MS}",
            "-Xswiftc", "-driver-show-incremental"]


def cargo_command(target: Path) -> List[str]:
    return ["env", f"CARGO_TARGET_DIR={target}", "cargo", "build", "--locked", "-p", CARGO_PACKAGE,
            "--bin", CARGO_PACKAGE]


def rebuilt_modules(log_text: str, kind: str) -> List[str]:
    """The modules (SwiftPM) or crates (cargo) one build's log says it compiled, sorted."""
    pattern = SWIFTPM_WORK if kind == SWIFT else CARGO_WORK
    found = set()
    for raw in log_text.splitlines():
        match = pattern.match(incremental_diagnostics.normalize_line(raw))
        if match:
            found.add(match["module"])
    return sorted(found)


# ---------------------------------------------------------------- MQ15: slow type-check functions

def _repo_relative(path: str, roots: Sequence[str]) -> Optional[str]:
    normal = os.path.normpath(path)
    if not os.path.isabs(normal):
        return normal
    for root in roots:
        if normal.startswith(root.rstrip("/") + "/"):
            return normal[len(root.rstrip("/")) + 1:]
    return None


def typecheck_queue(log_text: str, repo: Path, limit_ms: int = TYPECHECK_LIMIT_MS) -> dict:
    """MQ15 from one build log: every function and closure body swiftc reported at LIMIT_MS or more (it warns at
    elapsed >= the -warn-long-function-bodies limit), one task per repository file (a dependency's file is not ours to
    fix), files by their slowest body then path. Expression warnings are left out: they come only from
    -warn-long-expression-type-checking, which this build does not pass. A body reported twice keeps its larger
    time. The same log and repository give the same queue."""
    roots = sorted({str(repo), str(repo.resolve())})
    text = typecheck_diagnostics.ANSI_RE.sub("", log_text)
    slowest: Dict[tuple, float] = {}
    for match in typecheck_diagnostics.WARNING_RE.finditer(text):
        if match.group("kind") == "expression":
            continue
        milliseconds = float(match.group("milliseconds"))
        if milliseconds < limit_ms:
            continue
        path, line, column = match.group("location").strip().rsplit(":", 2)
        relative = _repo_relative(path, roots)
        if relative is None:
            continue
        declaration = match.group("decl_kind") or "closure"
        key = (relative, int(line), int(column), match.group("function") or "closure", declaration)
        slowest[key] = max(slowest.get(key, 0.0), milliseconds)
    by_file: Dict[str, list] = collections.defaultdict(list)
    for (relative, line, column, subject, declaration), milliseconds in slowest.items():
        by_file[relative].append({"line": line, "column": column, "subject": subject, "declaration": declaration,
                                  "ms": milliseconds})
    tasks = []
    for relative, functions in by_file.items():
        functions.sort(key=lambda f: (-f["ms"], f["line"], f["column"], f["subject"], f["declaration"]))
        tasks.append({"file": relative, "max_ms": functions[0]["ms"], "functions": functions})
    tasks.sort(key=lambda task: (-task["max_ms"], task["file"]))
    return {"schema": QUEUE_SCHEMA, "limit_ms": limit_ms,
            "functions": sum(len(task["functions"]) for task in tasks), "tasks": tasks}


# ---------------------------------------------------------------- leaf edits

def head_bytes(repo: Path, path: str) -> bytes:
    shown = subprocess.run(["git", "-C", str(repo), "show", f"HEAD:{path}"], capture_output=True)
    if shown.returncode != 0:
        raise StoryError(f"{path} is not in HEAD ({shown.stderr.decode(errors='replace').strip()}): the leaf list "
                         "names a file this commit does not have")
    return shown.stdout


def probe_only(current: bytes, original: bytes) -> bool:
    """CURRENT is ORIGINAL plus probe lines (and the newline a probe adds to a file without one)."""
    if not current.startswith(original):
        return False
    tail = current[len(original):]
    if not original.endswith(b"\n") and tail.startswith(b"\n"):
        tail = tail[1:]
    return bool(tail) and not PROBE_LINE.sub(b"", tail)


class LeafEdits:
    """Appends one probe line to a leaf and puts HEAD's bytes back. Every leaf HEAD has must equal HEAD at the start,
    so a restore can never drop someone's edit; a leaf HEAD does not have is in `missing` and is never edited."""

    def __init__(self, repo: Path, leaves: Sequence[Leaf]) -> None:
        self.repo = repo
        self.originals: Dict[str, bytes] = {}
        self.missing: List[Leaf] = []
        for leaf in leaves:
            try:
                self.originals[leaf.path] = head_bytes(repo, leaf.path)
            except StoryError:
                self.missing.append(leaf)
        for path, original in self.originals.items():
            file = repo / path
            if not file.is_file() or file.read_bytes() != original:
                raise StoryError(f"{path} differs from HEAD: the story edits only a clean leaf")

    @contextlib.contextmanager
    def edited(self, leaf: Leaf, round_index: int) -> Iterator[None]:
        original = self.originals[leaf.path]
        separator = b"" if original.endswith(b"\n") or not original else b"\n"
        try:
            (self.repo / leaf.path).write_bytes(original + separator + PROBE.format(round=round_index).encode())
            yield
        finally:
            self.restore(leaf.path)

    def restore(self, path: str) -> None:
        file = self.repo / path
        if file.read_bytes() != self.originals[path]:
            file.write_bytes(self.originals[path])

    def restore_all(self) -> None:
        for path in self.originals:
            self.restore(path)


def restore_from_head(repo: Path, leaves: Sequence[Leaf] = LEAVES) -> List[str]:
    """The trap's restore: a leaf whose bytes are HEAD's plus probe lines gets HEAD's bytes back. One line per leaf."""
    lines = []
    for leaf in leaves:
        file = repo / leaf.path
        try:
            original = head_bytes(repo, leaf.path)
        except StoryError:
            lines.append(f"{leaf.path}: not in HEAD")
            continue
        current = file.read_bytes() if file.is_file() else None
        if current == original:
            lines.append(f"{leaf.path}: clean")
        elif current is not None and probe_only(current, original):
            file.write_bytes(original)
            lines.append(f"{leaf.path}: restored")
        else:
            lines.append(f"{leaf.path}: left alone (not HEAD plus probe lines)")
    return lines


@contextlib.contextmanager
def signals_raise() -> Iterator[None]:
    """SIGTERM, SIGINT and SIGHUP raise Interrupted, so a cancelled step still runs every restore."""
    def handler(signum, _frame):
        raise Interrupted(signum)

    previous = {signum: signal.signal(signum, handler) for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    try:
        yield
    finally:
        for signum, old in previous.items():
            signal.signal(signum, old)


# ---------------------------------------------------------------- hosts

def lab_host_refusal(environ: Mapping[str, str], hostname: str, pool: Path = POOL) -> Optional[str]:
    """Why this host must not run the story (a perf-lab host measures, it never builds), or None."""
    labels = {label.strip() for label in environ.get("CMUX_CI_LABELS", "").split(",")}
    if LAB_LABEL in labels:
        return f"this worker has the {LAB_LABEL} label; lab hosts measure, builders build"
    try:
        hosts = json.loads(pool.read_text(encoding="utf-8"))["hosts"]
        names = {str(host["name"]).lower() for host in hosts}
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise StoryError(f"{pool}: cannot read the lab hosts ({error}), so a lab host cannot be excluded") from None
    short = hostname.split(".")[0].lower()
    if short in names:
        return f"{short} is a perf-lab host in {pool.name}; lab hosts measure, builders build"
    return None


def read_host_facts() -> dict:
    def out(*command: str) -> str:
        try:
            return subprocess.run(command, capture_output=True, text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.TimeoutExpired):
            return ""

    memory = out("/usr/sbin/sysctl", "-n", "hw.memsize")
    return {"chip": out("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string") or None,
            "memory_bytes": int(memory) if memory.isdigit() else None,
            "macos": out("/usr/bin/sw_vers", "-productVersion") or None,
            "macos_build": out("/usr/bin/sw_vers", "-buildVersion") or None}


def host_block(facts: Mapping) -> "perf_result.Host":
    """A builder's result-v1 host: chip and memory decide build time, a display does not, so the class is
    store.host_class with 0 Hz and display_hz is null."""
    if not facts.get("chip") or not facts.get("memory_bytes"):
        raise StoryError("this host's chip or memory could not be read: a zero would start a series of its own")
    memory_gb = round(facts["memory_bytes"] / 2 ** 30)
    identity = "\0".join(str(facts.get(key)) for key in ("chip", "macos_build", "memory_bytes"))
    return perf_result.Host(fingerprint=hashlib.sha256(identity.encode()).hexdigest(),
                            host_class=store.host_class(chip=facts["chip"], memory_gb=memory_gb, display_hz=0),
                            chip=facts["chip"], macos=facts.get("macos"), macos_build=facts.get("macos_build"),
                            display_hz=None)


# ---------------------------------------------------------------- the run

@dataclass
class Sample:
    leaf: str
    round: int
    seconds: float
    exit_code: int
    modules: List[str]


@dataclass
class Outcome:
    sha: str
    rounds: int
    leaves: Sequence[Leaf]
    samples: List[Sample] = field(default_factory=list)
    diagnostics: List[dict] = field(default_factory=list)
    queue: Optional[dict] = None
    errors: List[str] = field(default_factory=list)

    def ok_samples(self, leaf: str) -> List[Sample]:
        return [s for s in self.samples if s.leaf == leaf and s.exit_code == 0]

    @property
    def complete(self) -> bool:
        return not self.errors and all(len(self.ok_samples(leaf.name)) == self.rounds for leaf in self.leaves)


def measure(repo: Path, leaves: Sequence[Leaf], rounds: int, builder: Builder, scratch: Path,
            cargo_target: Path) -> Outcome:
    """Warm builds, then ROUNDS interleaved rounds of edit, timed rebuild, restore, untimed rebuild."""
    sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True,
                         check=True).stdout.strip()
    outcome = Outcome(sha, rounds, leaves)
    edits = LeafEdits(repo, leaves)
    outcome.errors.extend(f"{leaf.path}: not in HEAD, so {leaf.name} is not measured" for leaf in edits.missing)
    leaves = [leaf for leaf in leaves if leaf not in edits.missing]
    workdirs = {SWIFT: repo / SWIFT_PACKAGE, CARGO: repo / CARGO_WORKSPACE}
    commands = {SWIFT: swift_command(scratch), CARGO: cargo_command(cargo_target)}
    kinds = [kind for kind in (SWIFT, CARGO) if any(leaf.kind == kind for leaf in leaves)]
    broken = set()
    try:
        for kind in kinds:
            warm = builder(f"warm-{kind}", workdirs[kind], commands[kind])
            if warm.exit_code != 0:
                broken.add(kind)
                outcome.errors.append(f"warm {kind} build exited {warm.exit_code} (log {warm.log})")
            elif kind == SWIFT:
                outcome.queue = typecheck_queue(warm.log.read_text(encoding="utf-8", errors="replace"), repo)
        for round_index in range(rounds):
            for leaf in leaves:
                if leaf.kind in broken:
                    continue
                role = f"{leaf.name}-r{round_index}"
                with edits.edited(leaf, round_index):
                    timed = builder(role, workdirs[leaf.kind], commands[leaf.kind])
                text = timed.log.read_text(encoding="utf-8", errors="replace") if timed.log.is_file() else ""
                outcome.samples.append(Sample(leaf.name, round_index, timed.seconds, timed.exit_code,
                                              rebuilt_modules(text, leaf.kind)))
                if leaf.kind == SWIFT and timed.log.is_file():
                    parsed = incremental_diagnostics.parse_log(timed.log)
                    outcome.diagnostics.append({"leaf": leaf.name, "round": round_index,
                                                **{k: v for k, v in parsed.items() if k not in ("source", "log")}})
                if timed.exit_code != 0:
                    outcome.errors.append(f"{role}: rebuild exited {timed.exit_code} (log {timed.log})")
                settle = builder(f"{role}-restored", workdirs[leaf.kind], commands[leaf.kind])
                if settle.exit_code != 0:
                    broken.add(leaf.kind)
                    outcome.errors.append(f"{role}-restored: the pristine rebuild exited {settle.exit_code}; "
                                          f"no more {leaf.kind} leaves this run (log {settle.log})")
    finally:
        edits.restore_all()
    return outcome


def _write_json(path: Path, document: dict) -> "perf_result.Attachment":
    data = (json.dumps(document, indent=1, sort_keys=True) + "\n").encode("utf-8")
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)
    return perf_result.Attachment(digest=f"sha256:{hashlib.sha256(data).hexdigest()}",
                                  kind=path.name[:-len(".json")])


def results(outcome: Outcome, host, attachments: Sequence, run=None) -> list:
    run = run or perf_result.Run.start()
    build = perf_result.Build(sha=outcome.sha, config=CONFIG, measure_version=MEASURE_VERSION)

    def result(metric: str, unit: str, samples: List[float], target: Optional[str] = None):
        return perf_result.Result(story=STORY, metric=metric, unit=unit, better="lower", samples=samples, build=build,
                                  host=host, engine="none", session=SESSION, run=run,
                                  target_ref=perf_result.TargetRef(target=target) if target else None,
                                  attachments=list(attachments))

    found = []
    for leaf in outcome.leaves:
        samples = outcome.ok_samples(leaf.name)
        if samples:
            found.append(result(f"build.incremental.{leaf.name}_s", "s", [s.seconds for s in samples], TARGET_ROW))
            found.append(result(f"build.incremental.{leaf.name}.rebuilt_modules", "count",
                                [len(s.modules) for s in samples]))
    if outcome.queue is not None:
        found.append(result("build.typecheck.slow_functions", "count", [outcome.queue["functions"]]))
    return found


def write(outcome: Outcome, out: Path, host, repo: Path) -> Optional[Path]:
    """The attachments into OUT, then one result-v1 file naming their digests (None when nothing was measured)."""
    attachments = [_write_json(out / MODULES_FILE, {
        "schema": "cmux-perf-lab-rebuilt-modules/v1", "sha": outcome.sha,
        "rebuilds": [{"leaf": s.leaf, "round": s.round, "seconds": s.seconds, "exit_code": s.exit_code,
                      "modules": s.modules} for s in outcome.samples]})]
    if outcome.diagnostics:
        attachments.append(_write_json(out / DIAGNOSTICS_FILE, {"sha": outcome.sha, "rebuilds": outcome.diagnostics}))
    if outcome.queue is not None:
        attachments.append(_write_json(out / QUEUE_FILE, outcome.queue))
    found = results(outcome, host, attachments)
    return perf_result.write_ndjson(out, found, repo_root=repo) if found else None


def default_cargo_target(environ: Mapping[str, str], scratch: Path) -> Path:
    """The builder's shared cache keeps cargo's target warm across runs; the Swift scratch is new every run (the warm
    build must compile every file for the type-check queue)."""
    shared = environ.get("CI_SHARED_CACHE_DIR", "").strip()
    return Path(shared) / "incremental-build" / "cargo-target" if shared else scratch / "cargo-target"


def run(args: argparse.Namespace, environ: Mapping[str, str], builder: Optional[Builder] = None,
        host_facts: Callable[[], dict] = read_host_facts, hostname: Optional[str] = None,
        catalog: Sequence[Leaf] = LEAVES) -> int:
    session = args.session or environ.get(SESSION_ENV) or SESSION
    if session != SESSION:
        print(f"{STORY}: session {session!r}: this story runs only {SESSION!r}", file=sys.stderr)
        return 2
    repo = repo_root(args.repo)
    leaves = [leaf for leaf in catalog if not args.leaf or leaf.name in args.leaf]
    unknown = set(args.leaf or ()) - {leaf.name for leaf in catalog}
    if unknown or not leaves or args.rounds < 1:
        print(f"{STORY}: --leaf takes {', '.join(leaf.name for leaf in catalog)} and --rounds >= 1", file=sys.stderr)
        return 2
    try:
        refusal = lab_host_refusal(environ, hostname or socket.gethostname())
        if refusal:
            raise StoryError(f"refused: {refusal}")
        host = host_block(host_facts())
        out = args.out.resolve()
        out.mkdir(parents=True, exist_ok=True)
        own_scratch = args.scratch is None
        scratch = Path(tempfile.mkdtemp(prefix="incremental-build.")) if own_scratch else args.scratch.resolve()
        cargo_target = args.cargo_target.resolve() if args.cargo_target else default_cargo_target(environ, scratch)
        builder = builder or MetricsBuilder(out / BUILDS_DIR)
        try:
            with signals_raise():
                outcome = measure(repo, leaves, args.rounds, builder, scratch / "swiftpm", cargo_target)
        finally:
            if own_scratch:
                shutil.rmtree(scratch, ignore_errors=True)
        written = write(outcome, out, host, repo)
    except StoryError as error:
        print(f"{STORY}: {error}", file=sys.stderr)
        return 2
    except Interrupted as interrupted:
        print(f"{STORY}: stopped by signal {interrupted.signum}; every leaf is back to HEAD", file=sys.stderr)
        return 128 + interrupted.signum
    for error in outcome.errors:
        print(f"{STORY}: {error}", file=sys.stderr)
    for leaf in leaves:
        seconds = [f"{s.seconds:.1f}" for s in outcome.ok_samples(leaf.name)]
        print(f"{STORY}: {leaf.name} {', '.join(seconds) or 'no sample'} s  ({leaf.path})")
    if outcome.queue is not None:
        print(f"{STORY}: {outcome.queue['functions']} bodies of {TYPECHECK_LIMIT_MS} ms or more in "
              f"{len(outcome.queue['tasks'])} files ({out / QUEUE_FILE})")
    if written is None:
        print(f"{STORY}: nothing measured", file=sys.stderr)
        return 2
    print(f"{STORY}: wrote {written}")
    return 0 if outcome.complete else 1


def repo_root(repo: Optional[Path]) -> Path:
    if repo is not None:
        return repo.resolve()
    found = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return Path(found.stdout.strip()) if found.returncode == 0 else SCRIPTS.parent


def parse_args(argv: Optional[List[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=None, help="the checkout (default: the one holding the cwd)")
    commands = parser.add_subparsers(dest="command", metavar="COMMAND")

    measure_parser = commands.add_parser("run", help="measure every leaf (the fleet script runs this)")
    measure_parser.add_argument("--out", type=Path, required=True, help="result-v1, attachments and build logs")
    measure_parser.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS, help="timed rebuilds per leaf")
    measure_parser.add_argument("--leaf", action="append", help="measure only this leaf (repeatable)")
    measure_parser.add_argument("--scratch", type=Path, default=None,
                                help="the run's scratch folder (default: a new temporary one, removed after)")
    measure_parser.add_argument("--cargo-target", type=Path, default=None,
                                help="cargo's target folder (default: $CI_SHARED_CACHE_DIR/incremental-build/"
                                     "cargo-target, else in the scratch folder)")
    runner = measure_parser.add_argument_group("story runner", "what the runner passes (stories.d/README.md)")
    runner.add_argument("--app", default=None, help="unused: this story builds the checkout, it runs no app")
    runner.add_argument("--tag", default=None, help="unused")
    runner.add_argument("--session", default=None, help=f"the session (default ${SESSION_ENV}); only {SESSION}")
    runner.add_argument("session_word", nargs="?", default=None, metavar="SESSION", help="the session, as a word")

    commands.add_parser("check-host", help="exit 2 on a perf-lab host")
    commands.add_parser("restore", help="put every leaf that holds only probe lines back to HEAD's bytes")
    commands.add_parser("leaves", help="list the leaves")
    args = parser.parse_args(argv)
    if args.command is None:
        parser.error("a command is required")
    if args.command == "run":
        sessions = {s for s in (args.session, args.session_word) if s is not None}
        if len(sessions) > 1:
            parser.error(f"two sessions: {', '.join(sorted(sessions))}")
        args.session = sessions.pop() if sessions else None
    return args


def main(argv: Optional[List[str]] = None, environ: Optional[Mapping[str, str]] = None) -> int:
    args = parse_args(argv)
    environ = os.environ if environ is None else environ
    if args.command == "run":
        return run(args, environ)
    if args.command == "leaves":
        for leaf in LEAVES:
            print(f"{leaf.name}\t{leaf.kind}\t{leaf.path}")
        return 0
    if args.command == "restore":
        for line in restore_from_head(repo_root(args.repo)):
            print(f"{STORY}: {line}")
        return 0
    try:
        refusal = lab_host_refusal(environ, socket.gethostname())
    except StoryError as error:
        print(f"{STORY}: {error}", file=sys.stderr)
        return 2
    if refusal:
        print(f"{STORY}: refused: {refusal}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
