#!/usr/bin/env python3
"""cmux correctness oracle: one CLI over the corpus, the product drivers and the comparison.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D-3G and task 017.
Stdlib only, Python 3.9+ (fleet minis run the system python3), safe under `python3 -I`.

Chrome reference (chromium/src):
- base/test/launcher/test_launcher.cc: ShouldRunInCurrentShard() puts a test in shard
  PersistentHash(name) % total, so the shards cover each test once and a new test does not
  move the others. The retry limit defaults to 3 and is 0 for a local filtered run; retries
  run serially, one test per process. --test-launcher-jobs, --gtest_repeat, --gtest_shuffle
  with --gtest_random_seed (the seed is printed so the order can be replayed).
- base/test/launcher/unit_test_launcher.cc: kDefaultTestBatchLimit, 10 tests per process.
  Browser tests use a batch of 1 (WrapperTestLauncherDelegate::GetBatchSize()).
- base/test/launcher/test_results_tracker.cc and
  third_party/blink/tools/blinkpy/web_tests/models/test_run_results.py: a test that passes
  on retry is flaky; it does not fail the run.
- The CQ's "(retry shards with patch)": the first retry reruns the whole shard with the same
  config, so an order-dependent failure reproduces before the case runs alone.

Subcommands owned here: run, diff, merge, check, gen, rebaseline. These delegate to the
sibling script that owns them (`oracle.py <cmd> ARGS` runs `python3 -I <script> ARGS`):
confirm, select, bisect, report, minimize, switches, route, coverage, selftest.

Driver protocol (owned here; driver_<product>.py implements it):
    open_session(session_ctx: dict) -> session
    session.run_case(case: dict, case_ctx: dict) -> result dict
    session.close() -> None
    session.reset_state() -> JSON value (optional; task 189)
A session is one product process (one app launch); it runs up to --batch-limit cases.
A session with `reset_state` shares its process between cases: reset_state brings the product back
to its fixture and returns the reset snapshot (a JSON projection of the state a case may leave).
This file reads it once right after the launch (the fixture) and again after every case. A reset
snapshot that differs from the fixture, or a reset_state that raises (a refused reset action), is
LeakedState of the case that just ran: the launch is closed and the next case gets a fresh one
(base/test/test_suite.cc, CheckForLeakedGlobals: OnTestEnd fails the test that leaked global state,
by name). Two errors are not leaks: one with a true `unreachable` attribute (the product is gone)
makes the case a Crash at step "reset"; one with a `relaunch` reason (the reset has no action for
what the case changed) closes the launch with no finding. The check runs after the last case of a
launch too, so --batch-limit 1 and 10 find the same leaks. A launch whose fixture cannot be read is
an infra error of that launch, not a result of the case it was opened for (the case is retried, or
"not-run"). A session without reset_state isolates its cases itself (the daemon driver starts one
cmux-tui per case).
A result is {"status": "Pass"|"Failure"|"Crash"|"Timeout", "checkpoints": [{"step": str,
"checkpoint": "before"|"turn"|"settled", "snapshot": <canonical snapshot (normalize.py)>,
optional "uncertain": true, optional "notComparable": [facet, ...]}], "message": str,
optional "step" (where a Crash or Timeout happened), optional "session_dirty": true (a lost or
unusable process: the next case gets a fresh session, with no reset check), optional "switch_hits": {name: {arm:
count}}}. This file hashes each snapshot (sha256 of its sorted-key compact JSON) and decides
flakiness by hashes; diff.py compares the snapshot values.

Run directory (`run --out DIR`; the format diff.py (014) reads, with the extra fields below):
    receipt.json       {"schema": "cmux-oracle-run-v1", "runId", "sha", "host": {"name", "os",
                        "osVersion", "arch"}, "platform", "product", "arm" (baseline arm or null),
                        "shards": [i], "seeds": {"i": seed}, "selection", "isolation" (the run's case
                        isolation: "mode" asked, "kind" netns|none got, "reason", "uid"; merge refuses
                        shards of different kinds), "cases": {"<suite>/<case>": {"suite", "result"
                        (Flaky for a flaky case), "outcome", "flaky", "reasons", "expected", "attempts",
                        "checkpoints": N, "leaked_state": [leak], "environment" (the first attempt's
                        env and isolation, when the driver reports it)}},
                        "leaked_state": [case ids], "order" (the plan's case order), "sessions":
                        [{"session", "iteration", "attempt", "phase", "cases" (run order), "end"
                        (batch-end, dirty, leaked, relaunch or fixture-unreadable), "reason"}],
                        "counts", ...}
                        A leak is {"case", "pointers" (first differing RFC 6901 pointers; "" is
                        the whole snapshot), "count",
                        "error", "launch_order" (the cases that ran in its launch, up to it),
                        "session", "iteration", "attempt", "phase"}; any leak makes `ok` false.
    checkpoints.jsonl  one line per checkpoint of the case's first attempt (every attempt of a case
                        that is not flaky has the same hashes): {"case", "suite", "step", "index",
                        "checkpoint", "snapshot", "sha256", "attempt", "result"}
    events.jsonl       one line per attempt: phase, status, ms (the case alone), message,
                        checkpoint hashes, the session (launch) it ran in and its position there,
                        reset_ms (the reset check after it), its leak if any
`oracle.py rebaseline --run DIR [baselines.py options]` writes the golden cases of DIR in the
run format baselines.py (016) reads (a `cases` list, the case name without its suite) and runs
`baselines.py rebaseline` on it.

`diff` exit codes: 0 no unexplained divergence, 1 divergences, 2 bad input, 3 refused (host
mismatch, an incomplete or mismatched shard set, nothing compared), 4 diff.py internal error.

Sibling interfaces this file calls:
    diff.py A_DIR B_DIR --out divergence.json [--expected FILE] [--case GLOB]       (014)
    baselines.Store(root).read(suite, case, pdir, arm), platform_dir(platform, product),
        suite_class(suite), BaselineError; baselines.py rebaseline --run DIR         (016)
    expectations.Expectations.load_root(root), RunConfig, resolve, should_run, lint  (015)
    linux_run.sh run SHA [--suite S] [--arm A] [--side L] [--fresh] [-- RUN_OPTIONS]
        -> last stdout line is the run dir; every daemon run on the VM goes through it (007, 024)
    fleet.py diff ARGS: the app product's base/head and switch diffs                (050)
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import glob
import hashlib
import importlib
import itertools
import json
import os
import platform as platform_mod
import random
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_CORPUS = REPO / "tests" / "oracle" / "corpus"
DEFAULT_EXPECTATIONS_ROOT = REPO / "tests" / "oracle"
DEFAULT_BASELINES_ROOT = REPO / "tests" / "oracle" / "baselines"
SWITCH_REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
RESOURCE_OPERATIONS = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"
DEFAULT_OUT_BASE = Path("/tmp/oracle/runs")
# Spec 3G: state roots are /tmp/o/<run6>/<case6> so a daemon socket path stays under sun_path.
DEFAULT_STATE_BASE = Path("/tmp/o")

RUN_SCHEMA = "cmux-oracle-run-v1"
COMPARISON_SCHEMA = "cmux-oracle-comparison-v2"
RESULTS = ("Pass", "Failure", "Crash", "Timeout")
SLOW_MULTIPLIER = 5
CAPABILITIES = frozenset({"resource_api", "actions", "keys", "gui", "chromium", "restart", "mcp", "tui", "git_repo"})
# WPT runs one suite against several products; a case runs on a product only when the
# product has every capability the case `requires`. git_repo (a case with fixture.repo): the
# driver builds the repository with make_repo.build_for_case first; no driver does yet
# (p15-oracle-243), so no product has it.
PRODUCTS: Dict[str, frozenset] = {
    "daemon": frozenset({"resource_api", "restart"}),
    "cli": frozenset({"resource_api", "restart"}),
    # The VM mcp session is the daemon driver's case: its own daemon, which a restart step restarts.
    "mcp": frozenset({"resource_api", "actions", "mcp", "restart"}),
    "tui": frozenset({"resource_api", "keys", "tui"}),
    "headless": frozenset({"resource_api", "actions"}),
    "app": frozenset({"resource_api", "actions", "keys", "gui", "chromium", "restart", "mcp"}),
}
DRIVER_TASKS = {
    "daemon": "p15-oracle-023",
    "app": "p15-oracle-047",
    "cli": "p15-oracle-048",
    "mcp": "p15-oracle-209",
    "tui": "p15-oracle-234",
    "headless": "p15-oracle-161",
}
STEP_OPS = frozenset(
    {"resource.call", "action.run", "key", "cli", "mcp", "tui.key", "settle", "snapshot", "kill", "restart", "advance_clock"}
)
TARGETED_OPS = frozenset({"action.run", "key", "tui.key"})
CHECKPOINTS = frozenset({"before", "turn", "settled"})
CRASH_KINDS = frozenset({"renderer", "gpu", "browser", "utility", "daemon", "holder"})
PLATFORMS = ("linux", "mac", "windows")
BUILDS = ("debug", "bench", "asan", "tsan")
ARMS = ("old", "new")
LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})
DEFAULT_RETRY_LIMIT = 3
# The VM default is 200 jobs (spec 3G); a fleet mini runs one GUI app at a time.
DEFAULT_JOBS = {"app": 1}
VM_JOBS = 200
# One process per case like browser_tests; the app and headless hosts reuse a launch for
# kDefaultTestBatchLimit cases, with the driver's reset check between cases (task 189).
DEFAULT_BATCH_LIMIT = {"app": 10, "headless": 10}
DEFAULT_BUILD = {"app": "bench"}
# Products served by the cmux-tui binary that linux_run.sh builds per SHA.
RUST_PRODUCTS = frozenset({"daemon", "cli", "mcp", "tui"})

DIFF_OK, DIFF_DIVERGENT, DIFF_BAD_INPUT, DIFF_HOST_MISMATCH, DIFF_INTERNAL = 0, 1, 2, 3, 4
EXIT_REFUSED = 3

DELEGATES: Dict[str, Tuple[str, Tuple[str, ...], str]] = {
    "confirm": ("confirm.py", (), "p15-oracle-184"),
    "select": ("select.py", (), "p15-oracle-009"),
    "bisect": ("bisect.py", (), "p15-oracle-009"),
    "report": ("report.py", (), "p15-oracle-116"),
    "minimize": ("minimize.py", (), "p15-oracle-098"),
    "switches": ("switches.py", (), "p15-oracle-018"),
    "route": ("route.py", (), "p15-oracle-118"),
    "coverage": ("coverage.py", (), "p15-oracle-190"),
    "selftest": ("selftest.py", (), "p15-oracle-019"),
}


class UsageError(Exception):
    """A bad argument, a malformed input or a missing tool: exit 2."""


def load_sibling(module: str) -> Any:
    """Imports scripts/cmux-next/oracle/<module>.py, or None when it is not on this branch.

    `python3 -I` does not put the script's directory on sys.path; this directory is ours.
    """
    if not (HERE / f"{module}.py").is_file():
        return None
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return importlib.import_module(module)


def require_sibling(module: str, task: str) -> Any:
    loaded = load_sibling(module)
    if loaded is None:
        raise UsageError(f"{module}.py is not on this branch ({task})")
    return loaded


def current_platform() -> str:
    if sys.platform == "darwin":
        return "mac"
    if sys.platform.startswith("win"):
        return "windows"
    return "linux"


def host_info() -> Dict[str, str]:
    """The host keys diff.py checks (3F.1: base and head run on one host)."""
    return {
        "name": socket.gethostname(),
        "os": platform_mod.system(),
        "osVersion": platform_mod.mac_ver()[0] or platform_mod.release(),
        "arch": platform_mod.machine(),
    }


def digest(items: Iterable[str]) -> str:
    h = hashlib.sha256()
    for item in items:
        h.update(item.encode())
        h.update(b"\n")
    return h.hexdigest()


def snapshot_sha256(snapshot: Any) -> str:
    """Hash of a canonical snapshot; NaN or Infinity raise ValueError (not canonical JSON)."""
    text = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def base36(n: int, width: int = 6) -> str:
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while n:
        n, r = divmod(n, 36)
        out = chars[r] + out
    return out.rjust(width, "0")


def split_case_id(case_id: str) -> Tuple[str, str]:
    suite, _, name = case_id.partition("/")
    return suite, name


# ---------------------------------------------------------------------------------------
# Corpus


@dataclass(frozen=True)
class Case:
    id: str
    suite: str
    path: Path
    data: Dict[str, Any] = field(hash=False, compare=False)

    @property
    def requires(self) -> frozenset:
        return frozenset(self.data.get("requires") or ())

    @property
    def platforms(self) -> Tuple[str, ...]:
        return tuple(self.data.get("platforms") or PLATFORMS)

    @property
    def step_ids(self) -> Tuple[str, ...]:
        steps = self.data.get("steps") or ()
        return tuple(s["id"] for s in steps if isinstance(s, dict) and isinstance(s.get("id"), str))


def load_case(path: Path, case_id: str, *, check_id: bool = True) -> Tuple[Optional[Case], Optional[str]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return None, f"{case_id}: cannot read: {error}"
    if not isinstance(data, dict):
        return None, f"{case_id}: a case is a JSON object"
    suite, name = split_case_id(case_id)
    declared = data.get("id")
    if check_id and declared is not None and declared not in (case_id, name):
        return None, f"{case_id}: id {declared!r} does not match the file path"
    return Case(case_id, suite, path, data), None


def load_corpus(root: Path) -> Tuple[List[Case], List[str]]:
    """Every tests/oracle/corpus/<suite>/**/<case>.json; the id is the path without .json."""
    cases: List[Case] = []
    errors: List[str] = []
    if not root.is_dir():
        return cases, [f"{root}: no corpus directory"]
    for path in sorted(root.rglob("*.json")):
        rel = path.relative_to(root)
        if path.name == "coverage.json" or path.name.startswith("_"):
            continue
        if len(rel.parts) < 2:
            errors.append(f"{rel}: a case lives under <suite>/")
            continue
        case, error = load_case(path, rel.with_suffix("").as_posix())
        if error:
            errors.append(error)
        else:
            cases.append(case)
    return cases, errors


def parse_list(values: Optional[Sequence[str]]) -> List[str]:
    out: List[str] = []
    for value in values or ():
        out.extend(part.strip() for part in value.split(",") if part.strip())
    return out


def select_cases(
    cases: Sequence[Case], *, suites: Sequence[str], filters: Sequence[str], product: str, platform: str
) -> Tuple[List[Case], List[Case]]:
    """Returns (selected, not_applicable). `suites` empty or ["all"] means every suite."""
    wanted = None if not suites or "all" in suites else set(suites)
    caps = PRODUCTS[product]
    selected: List[Case] = []
    not_applicable: List[Case] = []
    for case in cases:
        if wanted is not None and case.suite not in wanted:
            continue
        if filters and not any(fnmatch.fnmatchcase(case.id, f) for f in filters):
            continue
        if case.requires <= caps and platform in case.platforms:
            selected.append(case)
        else:
            not_applicable.append(case)
    return selected, not_applicable


# ---------------------------------------------------------------------------------------
# Plan: shard, shuffle, batch


def shard_of(case_id: str, total: int) -> int:
    """Chrome's ShouldRunInCurrentShard: a stable hash of the name, modulo the shard count."""
    return int.from_bytes(hashlib.sha256(case_id.encode()).digest()[:8], "big") % total


def parse_shard(text: str) -> Tuple[int, int]:
    try:
        index_text, total_text = text.split("/")
        index, total = int(index_text), int(total_text)
    except ValueError:
        raise UsageError(f"--shard takes INDEX/TOTAL with a 0-based index, got {text!r}") from None
    if total < 1 or not 0 <= index < total:
        raise UsageError(f"--shard {text}: need 0 <= INDEX < TOTAL")
    return index, total


@dataclass(frozen=True)
class Plan:
    selection: Tuple[str, ...]
    order: Tuple[Case, ...]
    batches: Tuple[Tuple[Case, ...], ...]
    shard: Tuple[int, int]
    seed: Optional[int]


def make_plan(selected: Sequence[Case], *, shard: Tuple[int, int], seed: Optional[int], batch_limit: int) -> Plan:
    index, total = shard
    mine = sorted((c for c in selected if shard_of(c.id, total) == index), key=lambda c: c.id)
    if seed is not None:
        random.Random(seed).shuffle(mine)
    batches = tuple(tuple(mine[i : i + batch_limit]) for i in range(0, len(mine), batch_limit))
    return Plan(tuple(sorted(c.id for c in selected)), tuple(mine), batches, shard, seed)


# ---------------------------------------------------------------------------------------
# Expectations


@dataclass(frozen=True)
class Expected:
    """One case's expectation: results per case and per step, Skip (or NeverFix), Slow, flaky."""

    results: frozenset
    skip: bool = False
    slow: bool = False
    flaky: bool = False
    by_step: Mapping[str, frozenset] = field(default_factory=dict, hash=False, compare=False)

    def accepts(self, status: str, step: Optional[str] = None) -> bool:
        return status in self.by_step.get(step, self.results) if step is not None else status in self.results

    @property
    def declared_flaky(self) -> bool:
        return self.flaky or len(self.results) > 1 or any(len(r) > 1 for r in self.by_step.values())


PASS_ONLY = Expected(frozenset({"Pass"}))
ExpectationFn = Callable[[Case], Expected]


def results_of(outcomes: Iterable[str]) -> frozenset:
    """Actual results a resolution allows; a Skip-only line leaves Pass (the case does not run)."""
    return (frozenset(outcomes) & frozenset(RESULTS)) or frozenset({"Pass"})


@dataclass(frozen=True)
class ExpectationStore:
    """expectations.py (015) with the run's tag values, behind the seams this file uses."""

    module: Any
    store: Any
    config: Any

    @classmethod
    def load(cls, module: Any, root: Path, *, platform: str, arm: Optional[str], product: str, build: str) -> "ExpectationStore":
        for name in ("Expectations", "RunConfig", "lint"):
            if not hasattr(module, name):
                raise UsageError(f"expectations.py has no {name} (p15-oracle-015 API)")
        config = module.RunConfig(platform=platform, arm=arm if arm in ARMS else None, product=product, build=build)
        return cls(module, module.Expectations.load_root(root), config)

    def expected(self, case: Case) -> Expected:
        suite, name = split_case_id(case.id)
        whole = self.store.resolve(suite, name, self.config)
        results = results_of(whole.outcomes)
        slow, flaky = whole.slow, whole.flaky
        by_step: Dict[str, frozenset] = {}
        for step in case.step_ids:
            resolved = self.store.resolve(suite, name, self.config, step)
            slow, flaky = slow or resolved.slow, flaky or resolved.flaky
            if results_of(resolved.outcomes) != results:
                by_step[step] = results_of(resolved.outcomes)
        return Expected(results, not self.store.should_run(suite, name, self.config), slow, flaky, by_step)

    def pointer_rules(self) -> List[Dict[str, str]]:
        """Pointer-scoped Failure lines as diff.py expected differences: only that value is excused."""
        rules = []
        for e in self.store.entries:
            if e.kind != "expectations" or e.pointer is None or e.case == "*" or "Failure" not in e.outcomes:
                continue
            if not e.matches(self.config):
                continue
            rule = {"pointer": e.pointer, "reason": f"Expectations {e.where}: {e.target}",
                    "case": glob.escape(f"{e.suite}/{e.case}"), "step": glob.escape(e.step) if e.step else "*"}
            if e.bug:
                rule["task"] = e.bug
            rules.append(rule)
        return rules


def expectation_arm(arm: Optional[str], registry: Mapping[str, Mapping[str, Any]]) -> Optional[str]:
    """The run's value in the expectations' arm tag group. A --switch run is on its arm. A run that sets no arm
    (None or default) runs every switch at its registry `default`: switches land at default old and flip to new
    only before their old path is deleted (refactor-switches/README.md), so that run is [ old ] while no default
    is new, [ new ] once every default is, and on no arm while they differ. launch-config mixes planned arms."""
    if arm in ARMS:
        return arm
    if arm not in (None, "default"):
        return None
    defaults = {entry.get("default", "old") for entry in registry.values()}
    if not defaults:
        return "old"
    return defaults.pop() if len(defaults) == 1 and defaults <= set(ARMS) else None


def load_expectations(root: Path, *, platform: str, arm: Optional[str], product: str, build: str,
                      registry: Optional[Mapping[str, Mapping[str, Any]]] = None) -> Optional[ExpectationStore]:
    module = load_sibling("expectations")
    if module is None:
        return None
    run_arm = expectation_arm(arm, load_switch_registry() if registry is None else registry)
    return ExpectationStore.load(module, root, platform=platform, arm=run_arm, product=product, build=build)


# ---------------------------------------------------------------------------------------
# Execution


SessionOpener = Callable[[Dict[str, Any]], Any]
Checkpoints = Tuple[Tuple[str, str, str], ...]


@dataclass(frozen=True)
class Attempt:
    case: str
    iteration: int
    attempt: int
    phase: str
    status: str
    step: Optional[str]
    checkpoints: Checkpoints
    message: str
    ms: int
    switch_hits: Dict[str, Dict[str, int]] = field(hash=False, compare=False)
    # Snapshot rows are kept for the first attempt only: it is the one checkpoints.jsonl holds.
    rows: Tuple[Dict[str, Any], ...] = field(default=(), hash=False, compare=False)
    # The launch the attempt ran in and its 0-based position there; the reset check's finding.
    session: Optional[int] = field(default=None, hash=False, compare=False)
    position: Optional[int] = field(default=None, hash=False, compare=False)
    leaked_state: Optional[Dict[str, Any]] = field(default=None, hash=False, compare=False)
    # The reset check's time after the case (ms holds the case alone); None with no check.
    reset_ms: Optional[int] = field(default=None, hash=False, compare=False)
    # The driver's `environment` (hermetic_env CaseEnv.receipt(): every variable and the isolation).
    environment: Optional[Dict[str, Any]] = field(default=None, hash=False, compare=False)


@dataclass(frozen=True)
class Work:
    case: Case
    ctx: Dict[str, Any] = field(hash=False, compare=False)


def crash(message: str) -> Dict[str, Any]:
    return {"status": "Crash", "checkpoints": (), "rows": (), "message": message, "step": None}


def coerce_result(raw: Any) -> Dict[str, Any]:
    """A malformed driver result is a Crash of that case, never a silent pass."""
    if not isinstance(raw, dict):
        return crash("driver returned a non-object result")
    status = raw.get("status")
    if status not in RESULTS:
        return crash(f"driver returned status {status!r}")
    checkpoints = []
    rows = []
    for cp in raw.get("checkpoints") or ():
        if not (isinstance(cp, dict) and isinstance(cp.get("step"), str) and cp["step"]
                and cp.get("checkpoint") in CHECKPOINTS and "snapshot" in cp):
            return crash(f"driver returned a malformed checkpoint {cp!r:.200}")
        try:
            sha = snapshot_sha256(cp["snapshot"])
        except (TypeError, ValueError) as error:
            return crash(f"driver returned a snapshot that is not canonical JSON: {error}")
        checkpoints.append((cp["step"], cp["checkpoint"], sha))
        row = {"step": cp["step"], "checkpoint": cp["checkpoint"], "snapshot": cp["snapshot"], "sha256": sha}
        for extra in ("uncertain", "notComparable"):
            if cp.get(extra):
                row[extra] = cp[extra]
        rows.append(row)
    step = raw.get("step")
    environment = raw.get("environment")
    return {
        "status": status,
        "checkpoints": tuple(checkpoints),
        "rows": tuple(rows),
        "message": str(raw.get("message") or ""),
        "step": step if isinstance(step, str) else None,
        "session_dirty": bool(raw.get("session_dirty")),
        "switch_hits": raw.get("switch_hits") or {},
        "environment": environment if isinstance(environment, dict) else None,
    }


# The first differing pointers a leak lists; `count` has them all.
LEAK_POINTERS = 20
# A session without reset_state: its cases are not reset-checked.
NO_RESET = object()


def state_differences(fixture: Any, now: Any, pointer: str = "") -> List[str]:
    """The JSON pointers (RFC 6901: "" is the whole document) where `now` differs from `fixture`, in
    sorted-key order.

    A key on one side only differs at that key; lists differ by index, and a length change at the
    list itself. Equal values give [].
    """
    if isinstance(fixture, dict) and isinstance(now, dict):
        out: List[str] = []
        for key in sorted(set(fixture) | set(now), key=str):
            child = f"{pointer}/{str(key).replace('~', '~0').replace('/', '~1')}"
            if key not in fixture or key not in now:
                out.append(child)
            else:
                out.extend(state_differences(fixture[key], now[key], child))
        return out
    if isinstance(fixture, list) and isinstance(now, list):
        out = []
        for index, (a, b) in enumerate(zip(fixture, now)):
            out.extend(state_differences(a, b, f"{pointer}/{index}"))
        if len(fixture) != len(now):
            out.append(pointer)
        return out
    if type(fixture) is not type(now) or fixture != now:
        return [pointer]
    return []


def read_fixture(session: Any) -> Any:
    """The fixture of a fresh launch (its first reset snapshot), or NO_RESET for a session with no reset_state."""
    reset_state = getattr(session, "reset_state", None)
    return NO_RESET if reset_state is None else reset_state()


@dataclass(frozen=True)
class ResetOutcome:
    """What the reset check after a case found.

    `clean`: the reset snapshot is the fixture. `leaked`: it is not, or a reset action was refused
    (`leak`). `relaunch`: the reset says it has no action for what the case changed (`reason`; the
    driver's error has a `relaunch` attribute): a fresh launch, no leak. `unreachable`: the product
    is gone (the error has `unreachable`): a Crash of the case at step "reset".
    """

    kind: str
    leak: Optional[Dict[str, Any]] = None
    reason: Optional[str] = None


def reset_check(session: Any, fixture: Any) -> ResetOutcome:
    try:
        now = session.reset_state()
    except Exception as error:  # noqa: BLE001 - every reset failure is classified below
        if getattr(error, "unreachable", False):
            return ResetOutcome("unreachable", reason=f"{error}"[:500])
        relaunch = getattr(error, "relaunch", None)
        if relaunch:
            return ResetOutcome("relaunch", reason=str(relaunch)[:500])
        return ResetOutcome("leaked", leak={"pointers": [], "count": 0, "error": f"reset_state raised {error!r}"[:500]})
    pointers = state_differences(fixture, now)
    if not pointers:
        return ResetOutcome("clean")
    return ResetOutcome("leaked", leak={"pointers": pointers[:LEAK_POINTERS], "count": len(pointers), "error": None})


@dataclass(frozen=True)
class BatchOutput:
    """(work, result, ms, session number, position, reset ms) per case that ran, infra errors, one log per launch."""

    results: Tuple[Tuple[Work, Dict[str, Any], int, int, int, Optional[int]], ...]
    errors: Tuple[str, ...]
    sessions: Tuple[Dict[str, Any], ...]


def run_batch(works: Sequence[Work], open_session: SessionOpener, session_ctx: Dict[str, Any],
              numbers: Iterator[int]) -> BatchOutput:
    """Runs one batch in as few launches as possible, with the reset check after each case.

    A dirty session (lost process), a leak or a reset that asks for one closes the launch; the next
    case opens a fresh one. A launch whose fixture cannot be read is an infra error of that launch:
    the case it was opened for did not run (no result; execute retries it). `ms` is the case alone;
    the reset check's time is `reset ms`. `numbers` gives out session numbers (itertools.count: one
    atomic step per launch).
    """
    results = []
    errors: List[str] = []
    logs: List[Dict[str, Any]] = []
    session: Any = None
    fixture: Any = NO_RESET
    log: Dict[str, Any] = {}

    def end(reason: str, detail: Optional[str] = None) -> None:
        nonlocal session
        log["end"] = reason
        if detail:
            log["reason"] = detail
        logs.append(log)
        if session is None:
            return
        try:
            session.close()
        except Exception as error:  # noqa: BLE001 - a teardown failure is reported, not raised
            last = log["cases"][-1] if log["cases"] else "its launch"
            errors.append(f"session {log['session']} close after {last}: {error!r}")
        session = None

    try:
        for work in works:
            if not log or "end" in log:
                ctx = work.ctx
                log = {"session": next(numbers), "iteration": ctx.get("iteration"), "attempt": ctx.get("attempt"),
                       "phase": ctx.get("phase"), "cases": []}
            if session is None:
                try:
                    session = open_session(dict(session_ctx))
                except Exception as error:  # noqa: BLE001 - a launch that fails fails the case it was for
                    log["cases"].append(work.case.id)
                    results.append((work, {**crash(f"driver error: {error!r}"), "session_dirty": True}, 0, log["session"], 0, None))
                    end("dirty")
                    continue
                try:
                    fixture = read_fixture(session)
                except Exception as error:  # noqa: BLE001 - the launch is unusable; the case did not run
                    errors.append(f"session {log['session']}: fixture unreadable before {work.case.id}: {error!r}"[:500])
                    end("fixture-unreadable", f"{error!r}"[:500])
                    continue
            position = len(log["cases"])
            log["cases"].append(work.case.id)
            start = time.monotonic()
            try:
                result = coerce_result(session.run_case(work.case.data, dict(work.ctx)))
            except Exception as error:  # noqa: BLE001 - a driver failure fails this case only
                result = {**crash(f"driver error: {error!r}"), "session_dirty": True}
            ms = int((time.monotonic() - start) * 1000)
            reset_ms = None
            ending: Optional[Tuple[str, Optional[str]]] = ("dirty", None) if result.get("session_dirty") else None
            if ending is None and fixture is not NO_RESET:
                start = time.monotonic()
                outcome = reset_check(session, fixture)
                reset_ms = int((time.monotonic() - start) * 1000)
                if outcome.kind == "leaked":
                    leak = {"case": work.case.id, **(outcome.leak or {}), "launch_order": list(log["cases"]),
                            "session": log["session"]}
                    result = {**result, "leaked_state": leak, "session_dirty": True}
                    ending = ("leaked", None)
                elif outcome.kind == "unreachable":
                    result = {**result, "status": "Crash", "step": "reset", "session_dirty": True,
                              "message": f"the product was lost in the reset after the case: {outcome.reason}"}
                    ending = ("dirty", outcome.reason)
                elif outcome.kind == "relaunch":
                    ending = ("relaunch", outcome.reason)
            results.append((work, result, ms, log["session"], position, reset_ms))
            if ending is not None:
                end(*ending)
    finally:
        if log and "end" not in log:
            end("batch-end")
    return BatchOutput(tuple(results), tuple(errors), tuple(logs))


def run_phase(
    batches: Sequence[Sequence[Work]], open_session: SessionOpener, session_ctx: Dict[str, Any], jobs: int,
    numbers: Iterator[int],
) -> Tuple[list, list, list]:
    outputs: Iterable[BatchOutput]
    if jobs <= 1 or len(batches) <= 1:
        outputs = [run_batch(b, open_session, session_ctx, numbers) for b in batches]
    else:
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(batches))) as pool:
            outputs = list(pool.map(lambda b: run_batch(b, open_session, session_ctx, numbers), batches))
    results: list = []
    errors: list = []
    sessions: list = []
    for output in outputs:
        results.extend(output.results)
        errors.extend(output.errors)
        sessions.extend(output.sessions)
    return results, errors, sessions


@dataclass(frozen=True)
class RunOptions:
    product: str
    suites: Tuple[str, ...]
    filters: Tuple[str, ...]
    shard: Tuple[int, int]
    jobs: int
    batch_limit: int
    repeat: int
    retry_limit: int
    seed: Optional[int]
    platform: str
    build: str
    switch: Optional[str]
    arm: Optional[str]
    switches: Dict[str, str]
    ref: Optional[str]
    tag: Optional[str]
    binary: Optional[str]
    corpus: Path
    out: Path
    state_base: Path
    run_id: str
    dry_run: bool = False
    flaky_out: Optional[Path] = None
    expectations_root: Path = DEFAULT_EXPECTATIONS_ROOT
    # hermetic_env.ISOLATION_MODES: netns refuses a host without unprivileged user namespaces.
    isolation: str = "netns"

    @property
    def filtered(self) -> bool:
        return bool(self.filters) or (bool(self.suites) and "all" not in self.suites)

    @property
    def baseline_arm(self) -> Optional[str]:
        """The arm dir of baselines.py (`arm/<arm>/`): one per switch arm, or the launch config."""
        if self.switch and self.arm in ARMS:
            return f"{self.switch}={self.arm}"
        if self.arm == "launch-config":
            return "launch-config"
        return None

    def fingerprint(self) -> Dict[str, Any]:
        """What must be equal for shard receipts to merge.

        Not the index, jobs or binary path, and not the shuffle seed: a shuffle orders the cases
        inside one shard and never moves a case to another shard.
        """
        return {
            "product": self.product,
            "suites": sorted(self.suites),
            "filters": sorted(self.filters),
            "shard_total": self.shard[1],
            "batch_limit": self.batch_limit,
            "repeat": self.repeat,
            "retry_limit": self.retry_limit,
            "platform": self.platform,
            "build": self.build,
            "switch": self.switch,
            "arm": self.arm,
            "switches": dict(sorted(self.switches.items())),
            "ref": self.ref,
            "tag": self.tag,
        }


def needs_retry(attempt: Tuple[str, Optional[str]], expected: Expected) -> bool:
    """An unexpected result is retried; an unexpected pass is reported and not retried."""
    status, step = attempt
    return not expected.accepts(status, step) and status != "Pass"


def execute(plan: Plan, options: RunOptions, open_session: SessionOpener, expected: Dict[str, Expected],
            isolation: Mapping[str, Any]) -> Tuple[List[Attempt], List[str], List[Dict[str, Any]]]:
    """Runs every iteration of the plan with the retry policy of spec 3G.

    Retry 1 reruns the whole shard with the same order and batches; retries 2..limit run each
    still-failing case alone in a fresh session, serially. Keys for state roots are given out
    here, on one thread, before work is dispatched. `isolation` (resolve_isolation, probed once
    for the run) reaches every session as `isolation`, so no session probes the host again. Returns
    the attempts, the infra errors and one log per launch (the cases it ran, in order, and why it ended).
    """
    run_key = base36(int.from_bytes(hashlib.sha256(options.run_id.encode()).digest()[:4], "big"))[-6:]
    keys = itertools.count()
    session_ctx = {
        "run_id": options.run_id,
        "product": options.product,
        "platform": options.platform,
        "build": options.build,
        "switches": dict(options.switches),
        "arm": options.arm,
        "ref": options.ref,
        "tag": options.tag,
        "binary": options.binary,
        "out_dir": str(options.out),
        "isolation": dict(isolation),
    }
    runnable = [tuple(c for c in batch if not expected[c.id].skip) for batch in plan.batches]
    runnable = [batch for batch in runnable if batch]
    attempts: List[Attempt] = []
    errors: List[str] = []
    sessions: List[Dict[str, Any]] = []
    numbers = itertools.count()

    def phase_of(batches: Sequence[Sequence[Work]], jobs: int) -> list:
        results, errs, logs = run_phase(batches, open_session, session_ctx, jobs, numbers)
        errors.extend(errs)
        sessions.extend(logs)
        return results

    def works(batch: Sequence[Case], iteration: int, attempt: int, phase: str) -> Tuple[Work, ...]:
        out = []
        for case in batch:
            key = base36(next(keys))
            out.append(
                Work(
                    case,
                    {
                        "case_id": case.id,
                        "suite": case.suite,
                        "iteration": iteration,
                        "attempt": attempt,
                        "phase": phase,
                        "key": key,
                        "state_root": str(options.state_base / run_key / key),
                        "timeout_multiplier": SLOW_MULTIPLIER if expected[case.id].slow else 1,
                        "allow_crashes": list(case.data.get("allow_crashes") or ()),
                    },
                )
            )
        return tuple(out)

    kept_rows: set = set()

    def record(results: list, iteration: int, attempt: int, phase: str) -> Dict[str, Tuple[str, Optional[str]]]:
        """The attempts of one phase; a case missing from `results` did not run (its launch's fixture was
        unreadable) and is retried like a failure."""
        statuses = {}
        for work, result, ms, session, position, reset_ms in results:
            # The first attempt that ran keeps its rows: attempt 0 unless its launch never read a fixture.
            first = iteration == 0 and work.case.id not in kept_rows
            if first:
                kept_rows.add(work.case.id)
            leak = result.get("leaked_state")
            if leak is not None:
                leak = {**leak, "iteration": iteration, "attempt": attempt, "phase": phase}
            attempts.append(
                Attempt(
                    work.case.id, iteration, attempt, phase, result["status"], result.get("step"), result["checkpoints"],
                    result["message"], ms, result.get("switch_hits") or {}, result["rows"] if first else (),
                    session, position, leak, reset_ms, result.get("environment"),
                )
            )
            statuses[work.case.id] = (result["status"], result.get("step"))
        return statuses

    def not_settled(statuses: Dict[str, Tuple[str, Optional[str]]], case: Case) -> bool:
        status = statuses.get(case.id)
        return status is None or needs_retry(status, expected[case.id])

    for iteration in range(options.repeat):
        results = phase_of([works(b, iteration, 0, "run") for b in runnable], options.jobs)
        statuses = record(results, iteration, 0, "run")
        failing = [c for b in runnable for c in b if not_settled(statuses, c)]
        if failing and options.retry_limit >= 1:
            results = phase_of([works(b, iteration, 1, "shard-retry") for b in runnable], options.jobs)
            statuses = record(results, iteration, 1, "shard-retry")
            failing = [c for c in failing if not_settled(statuses, c)]
        for attempt in range(2, options.retry_limit + 1):
            if not failing:
                break
            results = phase_of([works((c,), iteration, attempt, "alone-retry") for c in failing], 1)
            statuses = record(results, iteration, attempt, "alone-retry")
            failing = [c for c in failing if not_settled(statuses, c)]
    sessions.sort(key=lambda log: log["session"])
    return attempts, errors, sessions


def classify(attempts: Sequence[Attempt], expected: Expected) -> Dict[str, Any]:
    """One case's verdict over every iteration and attempt.

    Flaky (left out of every comparison, never fails the run): any attempt or repeat whose
    status or checkpoint hashes differ from the first one (a pass on retry is one such
    difference), or several expected results.
    """
    if expected.skip:
        return {"outcome": "skipped", "result": "Skip", "status": "Skip", "flaky": False, "reasons": [], "attempts": 0}
    if not attempts:
        # No launch read its fixture for it (an infra error of each launch, which fails the run).
        return {"outcome": "not-run", "result": None, "status": None, "flaky": False, "reasons": [], "attempts": 0}
    by_iteration: Dict[int, List[Attempt]] = {}
    for a in attempts:
        by_iteration.setdefault(a.iteration, []).append(a)
    reasons: List[str] = []
    outcomes: List[str] = []
    firsts: List[Attempt] = []
    for iteration in sorted(by_iteration):
        runs = sorted(by_iteration[iteration], key=lambda a: a.attempt)
        first = runs[0]
        firsts.append(first)
        first_ok = expected.accepts(first.status, first.step)
        if first_ok:
            outcomes.append("expected")
        elif first.status == "Pass":
            outcomes.append("unexpected-pass")
        else:
            outcomes.append("unexpected")
        later = next((a for a in runs[1:] if (a.status, a.checkpoints) != (first.status, first.checkpoints)), None)
        if later is not None:
            kind = "pass-on-retry" if not first_ok and expected.accepts(later.status, later.step) else "nondeterministic"
            reasons.append(f"{kind}: iteration {iteration} attempt {later.attempt} ({later.phase}) differs")
    for later in firsts[1:]:
        if (later.status, later.checkpoints) != (firsts[0].status, firsts[0].checkpoints):
            reasons.append(f"repeat-differs: iteration {later.iteration}")
            break
    if expected.declared_flaky:
        reasons.append("declared: several expected results " + " ".join(sorted(expected.results)))
    if reasons:
        outcome = "flaky"
    elif "unexpected" in outcomes:
        outcome = "unexpected"
    elif "unexpected-pass" in outcomes:
        outcome = "unexpected-pass"
    else:
        outcome = "expected"
    first = firsts[0]
    return {
        "outcome": outcome,
        "result": "Flaky" if reasons else first.status,
        "status": first.status,
        "flaky": bool(reasons),
        "reasons": reasons,
        "attempts": len(attempts),
    }


def sum_switch_hits(hit_maps: Iterable[Mapping[str, Mapping[str, int]]]) -> Dict[str, Dict[str, int]]:
    total: Dict[str, Dict[str, int]] = {}
    for hits in hit_maps:
        for name, arms in (hits or {}).items():
            for arm, count in (arms or {}).items():
                total.setdefault(name, {}).setdefault(arm, 0)
                total[name][arm] += int(count)
    return total


def run_summary(cases: Mapping[str, Mapping[str, Any]], *, hits: Dict[str, Dict[str, int]], config: Mapping[str, Any],
                dry_run: bool, infra_errors: Sequence[str]) -> Dict[str, Any]:
    """The receipt fields that follow from its cases; one function for a shard and a merge."""
    arm_exercised: Optional[bool] = None
    switch, arm = config.get("switch"), config.get("arm")
    if switch and arm and not dry_run and any(r["attempts"] for r in cases.values()):
        arm_exercised = hits.get(switch, {}).get(arm, 0) > 0
    counts: Dict[str, int] = {}
    for record in cases.values():
        counts[record["outcome"]] = counts.get(record["outcome"], 0) + 1
    unexpected = sorted(cid for cid, r in cases.items() if r["outcome"] == "unexpected")
    leaked = sorted(cid for cid, r in cases.items() if r.get("leaked_state"))
    return {
        "counts": counts,
        "leaked_state": leaked,
        "flaky": sorted(cid for cid, r in cases.items() if r["flaky"]),
        "unexpected": unexpected,
        "unexpected_passes": sorted(cid for cid, r in cases.items() if r["outcome"] == "unexpected-pass"),
        "switch_hits": hits,
        "arm_exercised": arm_exercised,
        "ok": not unexpected and not leaked and not infra_errors and arm_exercised is not False,
    }


def check_out_dir(out: Path) -> None:
    resolved = out.resolve()
    if resolved == REPO or REPO in resolved.parents:
        raise UsageError(f"--out {out}: run output stays outside the checkout (spec 3G)")


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, rows: Iterable[Dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def checkpoint_rows(case_id: str, rows: Sequence[Mapping[str, Any]], *, attempt: int, result: Optional[str]) -> List[Dict[str, Any]]:
    """diff.py rows: a step's index is its order of first use in the case's checkpoint stream."""
    suite, _ = split_case_id(case_id)
    indexes: Dict[str, int] = {}
    out = []
    for row in rows:
        index = indexes.setdefault(str(row["step"]), len(indexes))
        out.append({**row, "step": str(row["step"]), "case": case_id, "suite": suite, "index": index,
                    "attempt": attempt, "result": result})
    return out


def resolve_isolation(mode: str) -> Dict[str, Any]:
    """The case isolation of a run (hermetic_env.py), probed once on this host for the whole run.

    netns refuses a host without unprivileged user namespaces here, before any case runs, instead
    of every session failing its cases; auto falls back to none and the receipt says why.
    """
    hermetic = require_sibling("hermetic_env", "p15-oracle-200")
    try:
        isolation = hermetic.isolation_for(mode, current_platform())
    except hermetic.HermeticError as error:
        raise UsageError(f"--isolation {mode}: {error}. Or run with --isolation auto or none; "
                         "the receipt records the isolation every case got") from None
    return {"mode": mode, **isolation.describe()}


def perform_run(
    options: RunOptions,
    cases: Sequence[Case],
    open_session: Optional[SessionOpener],
    expectation: Optional[ExpectationFn],
    dependencies: Dict[str, str],
    *,
    isolate: Callable[[str], Dict[str, Any]] = resolve_isolation,
) -> Tuple[Dict[str, Any], int]:
    """Selects, shards, runs and writes receipt.json, checkpoints.jsonl, events.jsonl, index.md."""
    started = time.time()
    check_out_dir(options.out)
    selected, not_applicable = select_cases(
        cases, suites=options.suites, filters=options.filters, product=options.product, platform=options.platform
    )
    plan = make_plan(selected, shard=options.shard, seed=options.seed, batch_limit=options.batch_limit)
    expected = {c.id: expectation(c) if expectation else PASS_ONLY for c in plan.order}
    options.out.mkdir(parents=True, exist_ok=True)

    attempts: List[Attempt] = []
    errors: List[str] = []
    sessions: List[Dict[str, Any]] = []
    isolation: Dict[str, Any] = {"mode": options.isolation, "kind": None, "reason": "dry run: nothing ran"}
    if not options.dry_run:
        if open_session is None:
            raise UsageError("no driver to run cases with")
        isolation = isolate(options.isolation)
        attempts, errors, sessions = execute(plan, options, open_session, expected, isolation)
    by_case: Dict[str, List[Attempt]] = {c.id: [] for c in plan.order}
    for a in attempts:
        by_case[a.case].append(a)

    records: Dict[str, Dict[str, Any]] = {}
    rows: List[Dict[str, Any]] = []
    for case in plan.order:
        exp = expected[case.id]
        if options.dry_run:
            record = {"outcome": "skipped" if exp.skip else "planned", "result": "Skip" if exp.skip else None,
                      "status": "Skip" if exp.skip else None, "flaky": False, "reasons": [], "attempts": 0}
        else:
            record = classify(by_case[case.id], exp)
        first = min((a for a in by_case[case.id] if a.iteration == 0), key=lambda a: a.attempt, default=None)
        record.update(suite=case.suite, expected=sorted(exp.results), checkpoints=len(first.checkpoints) if first else 0)
        leaks = [a.leaked_state for a in by_case[case.id] if a.leaked_state]
        if leaks:
            record["leaked_state"] = leaks
        if first is not None and first.environment is not None:
            record["environment"] = first.environment
        records[case.id] = record
        if first is not None:
            rows.extend(checkpoint_rows(case.id, first.rows, attempt=first.attempt, result=first.status))

    config = {**options.fingerprint(), "seed": options.seed, "shard_index": options.shard[0], "jobs": options.jobs,
              "binary": options.binary}
    receipt = {
        "schema": RUN_SCHEMA,
        "runId": options.run_id,
        "sha": options.ref or "",
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "duration_s": round(time.time() - started, 3),
        "dry_run": options.dry_run,
        "platform": options.platform,
        "product": options.product,
        "arm": options.baseline_arm,
        "config": config,
        "fingerprint": digest([json.dumps(options.fingerprint(), sort_keys=True)]),
        "host": host_info(),
        "isolation": isolation,
        "dependencies": dependencies,
        "selection": {"count": len(plan.selection), "digest": digest(plan.selection)},
        "shards": [options.shard[0]],
        "seeds": {str(options.shard[0]): options.seed},
        "not_applicable": len(not_applicable),
        "order": [c.id for c in plan.order],
        "batches": len(plan.batches),
        "sessions": sessions,
        "cases": records,
        "infra_errors": errors,
        **run_summary(records, hits=sum_switch_hits(a.switch_hits for a in attempts), config=config,
                      dry_run=options.dry_run, infra_errors=errors),
    }
    write_json(options.out / "receipt.json", receipt)
    write_jsonl(options.out / "checkpoints.jsonl", rows)
    write_jsonl(
        options.out / "events.jsonl",
        (
            {"case": a.case, "iteration": a.iteration, "attempt": a.attempt, "phase": a.phase, "status": a.status,
             "step": a.step, "ms": a.ms, "message": a.message, "sha256": [h for _, _, h in a.checkpoints],
             "session": a.session, "position": a.position, "reset_ms": a.reset_ms, "leaked_state": a.leaked_state}
            for a in attempts
        ),
    )
    write_index(options, receipt)
    if options.flaky_out and receipt["flaky"]:
        options.flaky_out.parent.mkdir(parents=True, exist_ok=True)
        with options.flaky_out.open("a", encoding="utf-8") as handle:
            for cid in receipt["flaky"]:
                handle.write(json.dumps({"case": cid, "run_id": options.run_id, "product": options.product,
                                         "arm": options.arm, "switches": options.switches,
                                         "reasons": records[cid]["reasons"]}, sort_keys=True) + "\n")
    return receipt, 0 if receipt["ok"] else 1


def leak_line(leak: Mapping[str, Any]) -> str:
    """One leak for a person: the leaking case, what differs, and the launch order that reproduces it."""
    where = ", ".join(pointer or '"" (the whole snapshot)' for pointer in leak["pointers"][:5])
    what = leak.get("error") or f"{leak['count']} differences at {where}"
    return (f"{leak['case']} left the product unlike its fixture ({what}); launch {leak['session']} ran "
            f"{' -> '.join(leak['launch_order'])}")


def write_index(options: RunOptions, receipt: Dict[str, Any]) -> None:
    lines = [
        f"# oracle run {receipt['runId']}",
        "",
        f"- product {options.product}, platform {options.platform}, build {options.build}",
        f"- shard {options.shard[0]}/{options.shard[1]}: {len(receipt['order'])} of {receipt['selection']['count']} selected cases",
        f"- seed {options.seed}, batch limit {options.batch_limit}, jobs {options.jobs}, repeat {options.repeat}, "
        f"retry limit {options.retry_limit}",
        f"- isolation {receipt['isolation'].get('kind')} (asked {options.isolation}): {receipt['isolation'].get('reason')}",
        "- outcomes: " + ", ".join(f"{k} {v}" for k, v in sorted(receipt["counts"].items())),
        f"- flaky (left out of comparisons): {len(receipt['flaky'])}",
        f"- launches: {len(receipt['sessions'])} ({sum(1 for s in receipt['sessions'] if s.get('end') == 'relaunch')} "
        f"relaunched for state the reset cannot put back); LeakedState: {len(receipt['leaked_state'])}",
        f"- ok: {receipt['ok']}",
    ]
    for cid in receipt["leaked_state"][:50]:
        lines.append(f"  - LeakedState: {leak_line(receipt['cases'][cid]['leaked_state'][0])}")
    for cid in receipt["unexpected"][:50]:
        lines.append(f"  - unexpected: {cid} ({receipt['cases'][cid]['status']})")
    (options.out / "index.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------------------
# Loading and merging runs


@dataclass(frozen=True)
class RunView:
    """One side of a comparison: a run directory, or several shard directories merged."""

    receipt: Dict[str, Any]
    directories: Tuple[Path, ...]
    shards: Tuple[int, ...]
    total: int
    complete: bool
    seeds: Dict[str, Optional[int]]


def read_receipt(directory: Path) -> Dict[str, Any]:
    try:
        receipt = json.loads((directory / "receipt.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise UsageError(f"{directory}: no readable receipt.json ({error})") from None
    if not isinstance(receipt, dict) or receipt.get("schema") != RUN_SCHEMA:
        raise UsageError(f"{directory}/receipt.json: not a {RUN_SCHEMA} receipt (written by `oracle.py run`)")
    return receipt


def merge_runs(directories: Sequence[Path], *, require_complete: bool) -> Tuple[RunView, List[str]]:
    """Merges shard receipts; refuses a different config, a repeated shard or a case in two shards."""
    if not directories:
        raise UsageError("no run directories given")
    loaded = [read_receipt(d) for d in directories]
    first = loaded[0]
    errors: List[str] = []
    if len({r["fingerprint"] for r in loaded}) > 1:
        errors.append("shard receipts have different configs: " + ", ".join(str(d) for d in directories))
    if len({r["selection"]["digest"] for r in loaded}) > 1:
        errors.append("shard receipts select different cases (corpus or filter changed between shards)")
    kinds = {str(d): (r.get("isolation") or {}).get("kind") for d, r in zip(directories, loaded)}
    if len(set(kinds.values())) > 1:
        errors.append("shard receipts ran with different case isolation: "
                      + ", ".join(f"{kind} in {d}" for d, kind in kinds.items()))
    total = first["config"]["shard_total"]
    owner: Dict[int, Path] = {}
    seen: Dict[str, Path] = {}
    seeds: Dict[str, Optional[int]] = {}
    hosts = {json.dumps(r.get("host"), sort_keys=True) for r in loaded}
    cases: Dict[str, Dict[str, Any]] = {}
    for directory, receipt in zip(directories, loaded):
        mine = set(receipt["shards"])
        repeated = sorted(i for i in mine if i in owner)
        if repeated:
            errors.append(f"shard {repeated[0]}/{total} appears twice: {owner[repeated[0]]} and {directory}")
            continue
        for index in mine:
            owner[index] = directory
        seeds.update(receipt.get("seeds") or {})
        for cid, record in receipt["cases"].items():
            if cid in seen:
                errors.append(f"{cid} is in two shards: {seen[cid]} and {directory}")
            if shard_of(cid, total) not in mine:
                errors.append(f"{cid} ran in shard {sorted(mine)} but belongs to shard {shard_of(cid, total)}/{total}")
            seen[cid] = directory
            cases[cid] = {**record, "host": receipt.get("host")} if len(hosts) > 1 else record
    complete = sorted(owner) == list(range(total))
    if complete and not errors and digest(sorted(seen)) != first["selection"]["digest"]:
        errors.append("the shards do not cover the selection: the union of shard cases differs from it")
    if not complete and require_complete:
        missing = sorted(set(range(total)) - set(owner))
        errors.append(f"shards missing: {', '.join(f'{i}/{total}' for i in missing)}")
    if len(loaded) == 1:
        return RunView(first, tuple(directories), tuple(sorted(owner)), total, complete, seeds), errors

    infra = [e for r in loaded for e in r.get("infra_errors", [])]
    config = {**first["config"], "shard_index": None, "seed": None, "jobs": None}
    dry_run = any(r.get("dry_run") for r in loaded)
    merged = {
        **first,
        "runId": "merged-" + digest(sorted(r["runId"] for r in loaded))[:12],
        "created": min(r["created"] for r in loaded),
        "duration_s": None,
        "dry_run": dry_run,
        "config": config,
        "host": first.get("host") if len(hosts) == 1 else None,
        "shards": sorted(owner),
        "seeds": seeds,
        "shard_runs": [{"runId": r["runId"], "dir": str(d), "duration_s": r.get("duration_s"), "host": r.get("host")}
                       for d, r in zip(directories, loaded)],
        "order": [cid for r in loaded for cid in r["order"]],
        "batches": sum(r["batches"] for r in loaded),
        "sessions": [{**log, "runId": r["runId"]} for r in loaded for log in r.get("sessions") or ()],
        "cases": cases,
        "infra_errors": infra,
        **run_summary(cases, hits=sum_switch_hits(r.get("switch_hits") or {} for r in loaded), config=config,
                      dry_run=dry_run, infra_errors=infra),
    }
    merged["ok"] = merged["ok"] and complete and not errors
    return RunView(merged, tuple(directories), tuple(sorted(owner)), total, complete, seeds), errors


def write_merged(view: RunView, out: Path) -> Path:
    """Writes a merged run directory (receipt, checkpoints and events of every shard)."""
    if len(view.directories) == 1:
        return view.directories[0]
    check_out_dir(out)
    out.mkdir(parents=True, exist_ok=True)
    write_json(out / "receipt.json", view.receipt)
    for name in ("checkpoints.jsonl", "events.jsonl"):
        with (out / name).open("w", encoding="utf-8") as target:
            for directory in view.directories:
                path = directory / name
                if path.is_file():
                    with path.open(encoding="utf-8") as source:
                        for line in source:
                            target.write(line)
    return out


# ---------------------------------------------------------------------------------------
# Comparing runs through diff.py


# What an order-parity comparison lets differ: the order (seed), the launch sharing (batch limit)
# and what never takes part in a merge fingerprint either.
ORDER_KEYS = frozenset({"seed", "batch_limit", "shard_index", "jobs", "binary"})


def comparability(a: RunView, b: RunView, *, partial: bool, order_parity: bool = False) -> Optional[str]:
    """Why two sides cannot be compared as a full (or, with --partial, a shard-subset) result.

    `order_parity` compares one config run in two orders or launch sharings (task 189: two shuffle
    seeds and --batch-limit 1 give the batched verdicts): the seeds and batch limits may differ,
    every other config key must not.
    """
    if a.receipt.get("dry_run") or b.receipt.get("dry_run"):
        return "a dry run has no results"
    if order_parity:
        mine, theirs = ({k: v for k, v in side.receipt["config"].items() if k not in ORDER_KEYS} for side in (a, b))
        if mine != theirs:
            keys = sorted(k for k in set(mine) | set(theirs) if mine.get(k) != theirs.get(k))
            return f"order parity compares one config in two orders; these differ: {', '.join(keys)}"
    if a.total != b.total:
        return f"shard totals differ: {a.total} vs {b.total}"
    if a.shards != b.shards:
        return f"shard sets differ: {list(a.shards)} vs {list(b.shards)}"
    if a.receipt["selection"]["digest"] != b.receipt["selection"]["digest"]:
        return "the two sides select different cases (corpus, suites, filters or product differ)"
    if not order_parity and a.seeds != b.seeds and any(s is not None for s in (*a.seeds.values(), *b.seeds.values())):
        return f"shuffle seeds differ per shard: {a.seeds} vs {b.seeds}"
    if not partial and not (a.complete and b.complete):
        return (f"incomplete: shards {list(b.shards)} of {b.total}; merge every shard, "
                "or pass --partial to compare only these shards")
    return None


def run_diff_py(a_dir: Path, b_dir: Path, out: Path, expected: Sequence[Path]) -> Tuple[int, Dict[str, Any]]:
    script = require_sibling("diff", "p15-oracle-014")
    command = [sys.executable, "-I", str(Path(script.__file__)), str(a_dir), str(b_dir), "--out", str(out)]
    for path in expected:
        command += ["--expected", str(path)]
    proc = subprocess.run(command, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        document = json.loads(out.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise UsageError(f"diff.py exited {proc.returncode} without a readable {out}: {proc.stderr.strip()[-500:]}") from None
    if proc.returncode == DIFF_BAD_INPUT:
        raise UsageError(f"diff.py refused its input: {document.get('error')}")
    if proc.returncode not in (DIFF_OK, DIFF_DIVERGENT, DIFF_HOST_MISMATCH, DIFF_INTERNAL):
        raise UsageError(f"diff.py exited {proc.returncode}: {proc.stderr.strip()[-500:]}")
    return proc.returncode, document


def compare_views(a: RunView, b: RunView, *, a_dir: Path, b_dir: Path, out: Path, labels: Tuple[str, str],
                  partial: bool, expected: Sequence[Path], rules: Sequence[Dict[str, str]],
                  not_comparable: Optional[Dict[str, str]] = None, refused: Optional[str] = None,
                  as_json: bool = False, order_parity: bool = False) -> int:
    """Checks that the sides are comparable, then hands every comparison to diff.py.

    diff.py owns the host check, the first divergence per case and expected differences, so an
    all-match comparison from two hosts is refused like a divergent one. Flaky cases are
    reported as flaky by diff.py and never count as compared. With `order_parity`, a case that
    leaked state on one side only is a divergence too: its leak depends on the order.
    """
    target = out / "divergence.json"
    target.unlink(missing_ok=True)
    refused = refused or comparability(a, b, partial=partial, order_parity=order_parity)
    document: Dict[str, Any] = {}
    code = None
    if refused is None:
        files = list(expected)
        if rules:
            write_json(out / "expectation-rules.json", list(rules))
            files.append(out / "expectation-rules.json")
        code, document = run_diff_py(a_dir, b_dir, target, files)
        if code == DIFF_HOST_MISMATCH:
            refused = "host-mismatch: " + "; ".join(f"{k}: {', '.join(v)}" for k, v in sorted(document["mismatched"].items()))
    summary = document.get("summary") or {}
    statuses = {row["case"]: row["status"] for row in document.get("cases", [])}
    compared = sum(summary.get(k, 0) for k in ("equal", "explained", "divergent"))
    if refused is None and code == DIFF_OK and compared == 0:
        # Every case flaky or skipped is no evidence; it must not read as a pass.
        refused = "nothing compared"
    divergent = sorted(cid for cid, s in statuses.items() if s == "divergent")
    leaks = {"a": sorted(a.receipt.get("leaked_state") or ()), "b": sorted(b.receipt.get("leaked_state") or ())}
    leaks_differ = sorted(set(leaks["a"]) ^ set(leaks["b"])) if order_parity else []
    comparison = {
        "schema": COMPARISON_SCHEMA,
        "a": labels[0],
        "b": labels[1],
        "shards": list(b.shards),
        "shard_total": b.total,
        "complete": a.complete and b.complete,
        "partial": partial and not (a.complete and b.complete),
        "refused": refused,
        "diff_exit": code,
        "summary": summary,
        "compared": compared,
        "divergent": divergent,
        "explained": sorted(cid for cid, s in statuses.items() if s == "explained"),
        "flaky_excluded": sorted(cid for cid, s in statuses.items() if s == "flaky"),
        "not_comparable": dict(sorted((not_comparable or {}).items())),
        "divergence": str(target) if target.is_file() else None,
        "order_parity": order_parity,
        "leaked_state": leaks,
        "leaks_differ": leaks_differ,
        "ok": refused is None and code == DIFF_OK and not leaks_differ,
    }
    write_json(out / "comparison.json", comparison)
    if as_json:
        print(json.dumps(comparison, indent=1, sort_keys=True))
    else:
        print(f"oracle diff {labels[0]} vs {labels[1]}: compared {compared}, equal {summary.get('equal', 0)}, "
              f"explained {summary.get('explained', 0)}, divergent {len(divergent)}, "
              f"flaky (excluded) {summary.get('flaky', 0)}, skipped {summary.get('skipped', 0)}, "
              f"not comparable {len(comparison['not_comparable'])}")
        for item in document.get("divergences", [])[:20]:
            print(f"  divergent: {item['journey']} step={item['step']} checkpoint={item['checkpoint']} "
                  f"pointer={item['pointer']} a={json.dumps(item['a'], sort_keys=True)} b={json.dumps(item['b'], sort_keys=True)}")
        for cid in leaks_differ:
            side = "a" if cid in leaks["a"] else "b"
            print(f"  LeakedState on side {side} only (order-dependent): {cid}")
        if refused:
            print(f"  refused: {refused}")
        if comparison["partial"]:
            print(f"  partial: shards {comparison['shards']} of {b.total} only")
        print(f"  comparison: {out / 'comparison.json'}")
    if code == DIFF_INTERNAL:
        return DIFF_INTERNAL
    if refused is not None:
        return EXIT_REFUSED
    return 0 if comparison["ok"] else 1


# ---------------------------------------------------------------------------------------
# Baselines


def nothing_left(run_dir: Path) -> Optional[str]:
    return None if read_receipt(run_dir)["cases"] else "nothing compared: no golden case has a reviewed baseline"


def golden_class(baselines: Any, suite: str) -> bool:
    try:
        return baselines.suite_class(suite) == baselines.GOLDEN
    except baselines.BaselineError as error:
        raise UsageError(str(error)) from None


def write_baseline_sides(head: RunView, head_dir: Path, out: Path, root: Path) -> Tuple[Path, Path, Dict[str, str]]:
    """Writes the head's golden cases that have a reviewed baseline as two run directories.

    `out/baselines` holds the baselines (they hold no host: the platform is in their fallback
    path, so each case takes the head's host); `out/head-golden` holds the same cases of the
    head. Returns both directories and the golden cases that have no baseline yet.
    """
    baselines = require_sibling("baselines", "p15-oracle-016")
    store = baselines.Store(root)
    receipt = head.receipt
    try:
        pdir = baselines.platform_dir(receipt["platform"], receipt["product"])
    except baselines.BaselineError as error:
        raise UsageError(str(error)) from None
    base_cases: Dict[str, Dict[str, Any]] = {}
    base_rows: List[Dict[str, Any]] = []
    missing: Dict[str, str] = {}
    for cid, record in sorted(receipt["cases"].items()):
        suite, name = split_case_id(cid)
        if not golden_class(baselines, suite):
            continue
        try:
            data = store.read(suite, name, pdir, receipt.get("arm"))
        except baselines.BaselineError as error:
            raise UsageError(f"{cid}: {error}") from None
        if data is None:
            missing[cid] = "no reviewed baseline"
            continue
        lines = [json.loads(line) for line in data.decode("utf-8").splitlines() if line.strip()]
        if any(line.get("checkpoint") not in CHECKPOINTS for line in lines):
            raise UsageError(f"{cid}: a baseline line has no before/turn/settled checkpoint")
        # The reviewed side holds the result the head was expected to give.
        result = record["result"] if record["outcome"] in ("expected", "skipped") else "Pass"
        base_cases[cid] = {"result": result, **({"host": record["host"]} if "host" in record else {})}
        base_rows.extend(checkpoint_rows(cid, [{k: line[k] for k in ("step", "checkpoint", "snapshot", "sha256")}
                                               for line in lines], attempt=0, result=result))
    base_dir, golden_dir = out / "baselines", out / "head-golden"
    for directory in (base_dir, golden_dir):
        directory.mkdir(parents=True, exist_ok=True)
    write_json(base_dir / "receipt.json", {"schema": "cmux-oracle-baselines-v1", "runId": "baselines", "sha": str(root),
                                           "host": receipt.get("host"), "cases": base_cases})
    write_jsonl(base_dir / "checkpoints.jsonl", base_rows)
    write_json(golden_dir / "receipt.json",
               {**receipt, "cases": {cid: r for cid, r in receipt["cases"].items() if cid in base_cases}})
    with (head_dir / "checkpoints.jsonl").open(encoding="utf-8") as source, \
            (golden_dir / "checkpoints.jsonl").open("w", encoding="utf-8") as target:
        for line in source:
            if line.strip() and json.loads(line)["case"] in base_cases:
                target.write(line)
    return base_dir, golden_dir, missing


def write_rebaseline_run(run: Path, target: Path) -> int:
    """Writes the golden cases of an oracle run in the run format of baselines.py; returns cases left out."""
    baselines = require_sibling("baselines", "p15-oracle-016")
    receipt = read_receipt(run)
    if receipt.get("dry_run"):
        raise UsageError(f"{run}: a dry run has no checkpoints to rebaseline")
    keep: Dict[str, Dict[str, Any]] = {}
    left_out = 0
    for cid, record in sorted(receipt["cases"].items()):
        suite, name = split_case_id(cid)
        if suite in baselines.SUITE_CLASSES and baselines.SUITE_CLASSES[suite] != baselines.GOLDEN:
            left_out += 1
            continue
        keep[cid] = {"suite": suite, "case": name, "result": record["result"],
                     "checkpoints": record["checkpoints"], "flaky": bool(record["flaky"])}
    target.mkdir(parents=True, exist_ok=True)
    write_json(target / "receipt.json", {"platform": receipt["platform"], "product": receipt["product"],
                                         "arm": receipt.get("arm"), "cases": list(keep.values())})
    with (run / "checkpoints.jsonl").open(encoding="utf-8") as source, (target / "checkpoints.jsonl").open("w", encoding="utf-8") as out:
        for line in source:
            if not line.strip():
                continue
            row = json.loads(line)
            if row["case"] in keep:
                out.write(json.dumps({**row, "case": split_case_id(row["case"])[1]}, sort_keys=True) + "\n")
    return left_out


def cmd_rebaseline(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="oracle.py rebaseline",
                                     epilog="Other options go to baselines.py rebaseline (--only-changed, --platform, --no-optimize).")
    parser.add_argument("--run", type=Path, required=True, help="oracle run directory (a shard or a merge)")
    parser.add_argument("--root", type=Path, default=DEFAULT_BASELINES_ROOT, help="baseline tree (default tests/oracle/baselines)")
    args, rest = parser.parse_known_args(argv)
    script = Path(require_sibling("baselines", "p15-oracle-016").__file__)
    with tempfile.TemporaryDirectory(prefix="oracle-rebaseline-") as tmp:
        left_out = write_rebaseline_run(args.run, Path(tmp))
        if left_out:
            print(f"rebaseline: {left_out} differential cases left out (their base run is the oracle)", file=sys.stderr)
        return subprocess.run([sys.executable, "-I", str(script), "--root", str(args.root), "rebaseline", "--run", tmp, *rest], check=False).returncode


# ---------------------------------------------------------------------------------------
# Switch registry


def load_switch_registry(root: Path = SWITCH_REGISTRY) -> Dict[str, Dict[str, Any]]:
    """One plans/cmux-next/refactor-switches/<name>.json per switch."""
    entries: Dict[str, Dict[str, Any]] = {}
    if root.is_dir():
        for path in sorted(root.glob("*.json")):
            entries[path.stem] = json.loads(path.read_text(encoding="utf-8"))
    return entries


def switch_expected_files(registry: Dict[str, Dict[str, Any]], names: Iterable[str], root: Path = SWITCH_REGISTRY) -> List[Path]:
    """Registry files whose expected_differences diff.py applies (`--expected`)."""
    return [root / f"{name}.json" for name in sorted(set(names)) if registry.get(name, {}).get("expected_differences")]


def resolve_switches(registry: Dict[str, Dict[str, Any]], switch: Optional[str], arm: Optional[str]) -> Dict[str, str]:
    if switch:
        if switch not in registry:
            raise UsageError(f"--switch {switch}: no plans/cmux-next/refactor-switches/{switch}.json")
        if arm not in ARMS:
            raise UsageError(f"--switch {switch} needs --arm old or --arm new")
        return {switch: arm}
    if arm == "launch-config":
        missing = sorted(name for name, entry in registry.items() if entry.get("planned") not in ARMS)
        if missing:
            raise UsageError("switches without a planned arm: " + ", ".join(missing))
        return {name: entry["planned"] for name, entry in sorted(registry.items())}
    if arm not in (None, "default"):
        raise UsageError(f"--arm {arm} without --switch: use launch-config or default")
    return {}


# ---------------------------------------------------------------------------------------
# CLI: run and diff


def add_selection_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--product", choices=sorted(PRODUCTS), default="daemon")
    parser.add_argument("--suite", action="append", help="suite names, comma separated, or all (default all)")
    parser.add_argument("--filter", action="append", help="case id globs, comma separated (a filtered run)")
    parser.add_argument("--shard", default="0/1", help="INDEX/TOTAL, 0-based (default 0/1)")
    parser.add_argument("--jobs", type=int, help=f"parallel sessions (default {VM_JOBS}, app 1)")
    parser.add_argument("--batch-limit", type=int, help="cases per session (default 1, app and headless 10)")
    parser.add_argument("--repeat", type=int, default=1, help="run the selection N times; any difference is flaky")
    parser.add_argument("--retry-limit", type=int, help="default 0 for a filtered run, else 3")
    parser.add_argument("--shuffle", action="store_true", help="shuffle the shard's order (seed printed and recorded)")
    parser.add_argument("--seed", type=int, help="shuffle seed (implies --shuffle)")
    parser.add_argument("--platform", choices=PLATFORMS, default=current_platform())
    parser.add_argument("--build", choices=BUILDS, help="expectation build modifier (default debug, app bench)")
    parser.add_argument("--binary", help="product binary for the driver (daemon: cmux-tui)")
    parser.add_argument("--tag", help="tagged app build for the app driver")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--expectations-root", type=Path, default=DEFAULT_EXPECTATIONS_ROOT,
                        help="dir with Expectations.d and NeverFix.d (default tests/oracle)")
    parser.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
    parser.add_argument("--isolation", choices=require_sibling("hermetic_env", "p15-oracle-200").ISOLATION_MODES,
                        default="netns",
                        help="case network isolation, probed once per run: netns (Linux, refuses a host without "
                             "unprivileged user namespaces; default), auto (netns when the host allows it) or none")
    parser.add_argument("--flaky-out", type=Path, help="append flaky cases as JSON lines (MQ-flakes)")
    parser.add_argument("--dry-run", action="store_true", help="plan and write the receipt; run nothing")
    parser.add_argument("--run-id", help="default: UTC time plus 6 random characters")
    parser.add_argument("--json", action="store_true", help="print the receipt or comparison as JSON")


def launch_kind(product: str, binary: Optional[str]) -> str:
    """The product whose launch defaults (jobs, batch limit, build) a run takes: the mcp product against a tagged
    app bundle (driver_mcp.py fleet mode) launches the app, so it runs as the app product does."""
    if product == "mcp" and isinstance(binary, str) and binary.rstrip("/").endswith(".app"):
        return "app"
    return product


def new_run_id() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + base36(random.SystemRandom().randrange(36**6))


def new_seed() -> int:
    return random.SystemRandom().randrange(1, 2**31)


def options_from_args(args: argparse.Namespace, *, retry_default: Optional[int], out: Path, run_id: str,
                      switch: Optional[str], arm: Optional[str], switches: Dict[str, str],
                      ref: Optional[str], binary: Optional[str]) -> RunOptions:
    suites = tuple(parse_list(args.suite)) or ("all",)
    filters = tuple(parse_list(args.filter))
    seed = args.seed
    if args.shuffle and seed is None:
        seed = new_seed()
    product = args.product
    launch = launch_kind(product, binary)
    for name in ("jobs", "batch_limit", "repeat"):
        value = getattr(args, name)
        if value is not None and value < 1:
            raise UsageError(f"--{name.replace('_', '-')} must be >= 1")
    if args.retry_limit is not None and args.retry_limit < 0:
        raise UsageError("--retry-limit must be >= 0")
    options = RunOptions(
        product=product,
        suites=suites,
        filters=filters,
        shard=parse_shard(args.shard),
        jobs=args.jobs or DEFAULT_JOBS.get(launch, VM_JOBS),
        batch_limit=args.batch_limit or DEFAULT_BATCH_LIMIT.get(launch, 1),
        repeat=args.repeat,
        retry_limit=0,
        seed=seed,
        platform=args.platform,
        build=args.build or DEFAULT_BUILD.get(launch, "debug"),
        switch=switch,
        arm=arm,
        switches=switches,
        ref=ref,
        tag=args.tag,
        binary=binary,
        corpus=args.corpus,
        out=out,
        state_base=args.state_base,
        run_id=run_id,
        dry_run=args.dry_run,
        flaky_out=args.flaky_out,
        expectations_root=args.expectations_root,
        isolation=args.isolation,
    )
    if args.retry_limit is not None:
        retry = args.retry_limit
    elif retry_default is not None:
        retry = retry_default
    else:
        retry = 0 if options.filtered else DEFAULT_RETRY_LIMIT
    return replace(options, retry_limit=retry)


def run_expectations(options: RunOptions) -> Optional[ExpectationStore]:
    return load_expectations(options.expectations_root, platform=options.platform, arm=options.arm,
                             product=options.product, build=options.build)


def run_one(options: RunOptions, *, open_session: Optional[SessionOpener] = None) -> Tuple[Dict[str, Any], int]:
    cases, errors = load_corpus(options.corpus)
    if errors:
        raise UsageError("corpus errors (run `oracle.py check`):\n  " + "\n  ".join(errors[:20]))
    store = run_expectations(options)
    deps = {
        "expectations": "used" if store else "absent (p15-oracle-015): every case expects Pass",
        "normalize": "present" if (HERE / "normalize.py").is_file() else "absent (p15-oracle-013): drivers send canonical snapshots",
    }
    if open_session is None and not options.dry_run:
        driver = load_sibling(f"driver_{options.product}")
        # driver_daemon.py has the facet capture (021) before its case runner (023).
        open_session = getattr(driver, "open_session", None)
        if open_session is None:
            raise UsageError(f"driver_{options.product}.py runs no cases on this branch yet ({DRIVER_TASKS[options.product]})")
    return perform_run(options, cases, open_session, store.expected if store else None, deps)


def print_run(receipt: Dict[str, Any], options: RunOptions, as_json: bool) -> None:
    if as_json:
        print(json.dumps(receipt, indent=1, sort_keys=True))
        return
    index, total = options.shard
    print(f"oracle run {receipt['runId']}: shard {index}/{total}, {len(receipt['order'])} of "
          f"{receipt['selection']['count']} cases, {receipt['batches']} batches, seed {options.seed}")
    print("  outcomes: " + (", ".join(f"{k} {v}" for k, v in sorted(receipt["counts"].items())) or "none"))
    if receipt["flaky"]:
        print(f"  flaky, left out of comparisons: {len(receipt['flaky'])}")
    for cid in receipt["unexpected"][:20]:
        print(f"  unexpected: {cid} ({receipt['cases'][cid]['status']})")
    for cid in receipt["leaked_state"][:20]:
        print(f"  LeakedState: {leak_line(receipt['cases'][cid]['leaked_state'][0])}")
    if receipt["arm_exercised"] is False:
        print(f"  arm-not-exercised: {options.switch}={options.arm} had 0 hits")
    for error in receipt["infra_errors"][:10]:
        print(f"  infra: {error}")
    print(f"  receipt: {options.out / 'receipt.json'}")


# The Linux VM runs every cmux-tui suite run in the runnerd queue (p15-oracle-007, spec 3G): one
# quota scope, request joining and receipt reuse. This process is a runnerd job when RUNNERD_JOB is set.
QUEUE_HINT = ("on the Linux VM cmux-tui suite runs go through the runnerd queue: `linux_run.sh run REF "
              "[--suite S] [--arm A] [-- RUN_OPTIONS]`, or `oracle.py diff` with --base/--head, or with "
              "--switch or --arm launch-config and --ref")


def outside_vm_queue(product: str) -> bool:
    """True for a cmux-tui suite run on the Linux VM that is not itself a runnerd job."""
    return sys.platform.startswith("linux") and product in RUST_PRODUCTS and not os.environ.get("RUNNERD_JOB")


def cmd_run(args: argparse.Namespace) -> int:
    if outside_vm_queue(args.product) and not args.dry_run:
        raise UsageError(f"{QUEUE_HINT}; `oracle.py run` itself runs only inside a runnerd job")
    run_id = args.run_id or new_run_id()
    out = args.out or DEFAULT_OUT_BASE / run_id
    switches = resolve_switches(load_switch_registry(), args.switch, args.arm)
    options = options_from_args(args, retry_default=None, out=out, run_id=run_id, switch=args.switch, arm=args.arm,
                                switches=switches, ref=args.ref, binary=args.binary)
    receipt, code = run_one(options)
    print_run(receipt, options, args.json)
    return code


@dataclass(frozen=True)
class Side:
    label: str
    switch: Optional[str]
    arm: Optional[str]
    switches: Dict[str, str]
    ref: Optional[str]
    binary: Optional[str]


def diff_sides(args: argparse.Namespace, registry: Dict[str, Dict[str, Any]]) -> Tuple[Tuple[Side, Side], List[Path]]:
    """The two sides to run and the expected-differences files that apply to them."""
    if args.base or args.head:
        if not (args.base and args.head):
            raise UsageError("--base and --head go together")
        if args.product not in RUST_PRODUCTS:
            raise UsageError(f"--product {args.product}: base/head builds on the VM are the cmux-tui products {sorted(RUST_PRODUCTS)}")
        # On the VM, queued_diff builds the refs; elsewhere the caller brings the binaries.
        return (Side("base", None, None, {}, args.base, args.base_binary),
                Side("head", None, None, {}, args.head, args.head_binary)), []
    if args.switch:
        sides = tuple(Side(arm, args.switch, arm, resolve_switches(registry, args.switch, arm), args.ref, args.binary) for arm in ARMS)
        return sides, switch_expected_files(registry, [args.switch])  # type: ignore[return-value]
    if args.arm == "launch-config":
        planned = resolve_switches(registry, None, "launch-config")
        return (
            Side("default", None, "default", {}, args.ref, args.binary),
            Side("launch-config", None, "launch-config", planned, args.ref, args.binary),
        ), switch_expected_files(registry, planned)
    raise UsageError("diff needs --base/--head, --switch NAME, --arm launch-config, --base-run/--head-run or --baselines")


def comparison_rules(view: RunView, root: Path) -> List[Dict[str, str]]:
    """Pointer-scoped Expectations lines of the B side's configuration, as diff.py rules."""
    receipt = view.receipt
    config = receipt["config"]
    store = load_expectations(root, platform=receipt["platform"], arm=config.get("arm"), product=receipt["product"],
                              build=config["build"])
    return store.pointer_rules() if store else []


def cmd_diff(args: argparse.Namespace) -> int:
    if args.order_parity and not (args.base_run and args.head_run and not args.baselines):
        raise UsageError("--order-parity compares two existing runs: give --base-run and --head-run")
    out = args.out or DEFAULT_OUT_BASE / ("diff-" + new_run_id())
    check_out_dir(out)
    out.mkdir(parents=True, exist_ok=True)
    if args.head_run:
        head, head_errors = merge_runs(args.head_run, require_complete=False)
        if args.baselines:
            if head_errors:
                raise UsageError("; ".join(head_errors))
            base_dir, golden_dir, missing = write_baseline_sides(head, write_merged(head, out / "head-merged"), out,
                                                                 args.baselines_root)
            return compare_views(head, head, a_dir=base_dir, b_dir=golden_dir, out=out, labels=("baselines", "head"),
                                 partial=args.partial, expected=[], rules=comparison_rules(head, args.expectations_root),
                                 not_comparable=missing, refused=nothing_left(golden_dir),
                                 as_json=args.json)
        if not args.base_run:
            raise UsageError("--head-run needs --base-run or --baselines")
        base, base_errors = merge_runs(args.base_run, require_complete=False)
        if base_errors or head_errors:
            raise UsageError("; ".join(base_errors + head_errors))
        return compare_views(base, head, a_dir=write_merged(base, out / "a-merged"), b_dir=write_merged(head, out / "b-merged"),
                             out=out, labels=("base", "head"), partial=args.partial, expected=[],
                             rules=comparison_rules(head, args.expectations_root), as_json=args.json,
                             order_parity=args.order_parity)
    if args.product == "app":
        fleet = HERE / "fleet.py"
        if not fleet.is_file():
            raise UsageError("app diffs run on the fleet through fleet.py, not on this branch yet (p15-oracle-050)")
        return subprocess.run([sys.executable, "-I", str(fleet), "diff", *args.raw_argv], check=False).returncode
    registry = load_switch_registry()
    sides, expected = diff_sides(args, registry)
    if args.switch and not args.suite:
        minimum = registry[args.switch].get("minimum_suites")
        if minimum:
            args.suite = [",".join(minimum)]
    if args.shuffle and args.seed is None:
        args.seed = new_seed()  # one seed for both sides: they must run the same order
    if outside_vm_queue(args.product) and not args.dry_run:
        return queued_diff(args, sides, expected, out)
    if args.base and not args.dry_run and not (args.base_binary and args.head_binary):
        raise UsageError("--base/--head are built on the Linux VM (linux_run.sh, in its queue); "
                         "elsewhere pass --base-binary and --head-binary")
    run_id = args.run_id or new_run_id()
    views = []
    for side in sides:
        options = options_from_args(args, retry_default=DEFAULT_RETRY_LIMIT, out=out / side.label,
                                    run_id=f"{run_id}-{side.label}", switch=side.switch,
                                    arm=side.arm, switches=side.switches,
                                    ref=side.ref, binary=side.binary)
        receipt, _ = run_one(options)
        print_run(receipt, options, False)
        if receipt["arm_exercised"] is False:
            print(f"arm-not-exercised: {side.switch}={side.arm}")
            return EXIT_REFUSED
        view, errors = merge_runs([options.out], require_complete=False)
        if errors:
            raise UsageError("; ".join(errors))
        views.append(view)
    return compare_views(views[0], views[1], a_dir=out / sides[0].label, b_dir=out / sides[1].label, out=out,
                         labels=(sides[0].label, sides[1].label), partial=args.partial, expected=expected,
                         rules=comparison_rules(views[1], args.expectations_root), as_json=args.json)


def resolve_commit(ref: str) -> str:
    proc = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                          check=False, stdout=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise UsageError(f"{ref}: not a commit in {REPO}")
    return proc.stdout.strip()


def side_arm(side: Side) -> str:
    """The side's arm as `linux_run.sh run --arm` takes it."""
    return f"{side.switch}={side.arm}" if side.switch else side.arm or "-"


def queued_run_args(args: argparse.Namespace) -> List[str]:
    """The diff's selection as `oracle.py run` options, defaults left out so that an identical
    `linux_run.sh run` request has the same key and joins the same queued job."""
    run_args: List[str] = []
    if args.product != "daemon":
        run_args += ["--product", args.product]
    for value in parse_list(args.filter):
        run_args += ["--filter", value]
    if args.shard != "0/1":
        run_args += ["--shard", args.shard]
    for name in ("jobs", "batch_limit", "seed", "build", "tag"):
        if getattr(args, name) is not None:
            run_args += ["--" + name.replace("_", "-"), str(getattr(args, name))]
    if args.repeat != 1:
        run_args += ["--repeat", str(args.repeat)]
    # A diff retries DEFAULT_RETRY_LIMIT times by default; a run does so only for an unfiltered selection.
    retry = DEFAULT_RETRY_LIMIT if args.retry_limit is None else args.retry_limit
    filtered = bool(parse_list(args.filter)) or "all" not in (parse_list(args.suite) or ["all"])
    if retry != (0 if filtered else DEFAULT_RETRY_LIMIT):
        run_args += ["--retry-limit", str(retry)]
    if args.platform != current_platform():
        run_args += ["--platform", args.platform]
    for name, default in (("corpus", DEFAULT_CORPUS), ("expectations_root", DEFAULT_EXPECTATIONS_ROOT),
                          ("state_base", DEFAULT_STATE_BASE)):
        if getattr(args, name).resolve() != default.resolve():
            run_args += ["--" + name.replace("_", "-"), str(getattr(args, name).resolve())]
    if args.flaky_out:
        run_args += ["--flaky-out", str(args.flaky_out.resolve())]
    return run_args


def queued_diff(args: argparse.Namespace, sides: Tuple[Side, Side], expected: List[Path], out: Path) -> int:
    """Both sides as `linux_run.sh run` jobs in parallel (built, run and joined in the runnerd queue),
    then the comparison here: it is light, and it keeps --partial, --json and the expectation rules."""
    for side in sides:
        if side.binary:
            raise UsageError(f"{QUEUE_HINT}; a prebuilt --base-binary, --head-binary or --binary cannot run in it")
        if not side.ref:
            raise UsageError(f"{QUEUE_HINT}; --switch and --arm launch-config need --ref to build")
    shas = [resolve_commit(side.ref) for side in sides]
    # One SHA and arm on both sides (a determinism check) must run twice, not join one job.
    same = shas[0] == shas[1] and side_arm(sides[0]) == side_arm(sides[1])
    suites = ",".join(parse_list(args.suite)) or "all"
    run_args = queued_run_args(args)
    procs = []
    for side, sha in zip(sides, shas):
        command = ["bash", str(HERE / "linux_run.sh"), "run", sha, "--suite", suites, "--arm", side_arm(side)]
        command += ["--side", side.label] if same else []
        command += ["--fresh"] if args.fresh else []
        command += ["--", *run_args]
        command += ["--run-id", f"{args.run_id}-{side.label}"] if args.run_id else []
        procs.append(subprocess.Popen(command, stdout=subprocess.PIPE, text=True))
    finished = [(proc.communicate()[0], proc.returncode) for proc in procs]
    views, dirs = [], []
    for side, (stdout, code) in zip(sides, finished):
        lines = [line.strip() for line in stdout.splitlines() if line.strip()]
        run_dir = Path(lines[-1]) if lines else None
        if run_dir is None or not (run_dir / "receipt.json").is_file():
            raise UsageError(f"the {side.label} run of {side.ref} wrote no receipt (linux_run.sh exit {code})")
        print(f"{side.label}: {side.ref} run {run_dir} (oracle.py run exit {code})")
        if read_receipt(run_dir)["arm_exercised"] is False:
            print(f"arm-not-exercised: {side.switch}={side.arm}")
            return EXIT_REFUSED
        view, errors = merge_runs([run_dir], require_complete=False)
        if errors:
            raise UsageError("; ".join(errors))
        views.append(view)
        dirs.append(run_dir)
    return compare_views(views[0], views[1], a_dir=dirs[0], b_dir=dirs[1], out=out,
                         labels=(sides[0].label, sides[1].label), partial=args.partial, expected=expected,
                         rules=comparison_rules(views[1], args.expectations_root), as_json=args.json)


def cmd_merge(args: argparse.Namespace) -> int:
    view, errors = merge_runs(args.dirs, require_complete=True)
    for error in errors:
        print(f"merge: {error}", file=sys.stderr)
    if errors:
        return 1
    if len(args.dirs) == 1:
        raise UsageError("merge needs two or more shard directories")
    write_merged(view, args.out)
    print(f"merged {len(args.dirs)} shards, {len(view.receipt['cases'])} cases, each in one shard: {args.out / 'receipt.json'}")
    return 0 if view.receipt["ok"] else 1


# ---------------------------------------------------------------------------------------
# CLI: check and gen


def mutation_operations() -> frozenset:
    try:
        spec = json.loads(RESOURCE_OPERATIONS.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return frozenset()
    return frozenset(name for name, op in spec.get("operations", {}).items() if op.get("class") == "mutation")


def walk_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_strings(item)


def non_loopback_urls(case: Dict[str, Any]) -> List[str]:
    bad = []
    for text in walk_strings(case):
        for token in text.split():
            parsed = urllib.parse.urlparse(token)
            if parsed.scheme in ("http", "https", "ws", "wss") and parsed.netloc:
                host = parsed.hostname or ""
                if host not in LOOPBACK_HOSTS and not token.startswith("$WEB"):
                    bad.append(token)
    return bad


def check_case(case: Case, mutations: frozenset) -> List[str]:
    """Semantic rules the JSON schema cannot state (task 012's acceptance)."""
    errors = []
    data = case.data
    for cap in sorted(case.requires - CAPABILITIES):
        errors.append(f"{case.id}: unknown capability {cap!r} in requires")
    for plat in data.get("platforms") or ():
        if plat not in PLATFORMS:
            errors.append(f"{case.id}: unknown platform {plat!r}")
    for entry in data.get("allow_crashes") or ():
        # case-v1 $defs/allowCrash: {kind, reason, steps, max}.
        kind = entry.get("kind") if isinstance(entry, dict) else entry
        if not isinstance(kind, str) or kind not in CRASH_KINDS:
            errors.append(f"{case.id}: unknown crash kind {kind!r} in allow_crashes")
    steps = data.get("steps")
    if not isinstance(steps, list) or not steps:
        errors.append(f"{case.id}: no steps")
        steps = []
    seen: Dict[str, int] = {}
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            errors.append(f"{case.id}: step {index} is not an object")
            continue
        sid = step.get("id")
        label = f"step {sid!r}" if sid is not None else f"step {index}"
        if not isinstance(sid, str) or not sid:
            errors.append(f"{case.id}: step {index} has no id")
        elif sid in seen:
            errors.append(f"{case.id}: duplicate step id {sid!r} (steps {seen[sid]} and {index})")
        else:
            seen[sid] = index
        op = step.get("op")
        if op not in STEP_OPS:
            errors.append(f"{case.id}: {label} has unknown op {op!r}")
        args = step.get("args") if isinstance(step.get("args"), dict) else {}
        operation = args.get("method") or args.get("operation")  # case-v1 argsResourceCall names it method
        mutating = op in TARGETED_OPS or (op == "resource.call" and operation in mutations)
        if mutating and not step.get("target"):
            what = f"{op} {operation}" if op == "resource.call" else op
            errors.append(f"{case.id}: {label} mutates ({what}) without a target")
        # case-v1: checkpoint is an array of checkpoint names.
        checkpoints = step.get("checkpoint", [])
        for checkpoint in checkpoints if isinstance(checkpoints, list) else [checkpoints]:
            if not isinstance(checkpoint, str) or checkpoint not in CHECKPOINTS:
                errors.append(f"{case.id}: {label} has unknown checkpoint {checkpoint!r}")
    for url in non_loopback_urls(data):
        errors.append(f"{case.id}: non-loopback URL {url!r} (offline fixtures use loopback or $WEB)")
    return errors


def coverage_lines(corpus: Path) -> Tuple[List[str], List[str]]:
    lines, errors = [], []
    for suite_dir in sorted(p for p in corpus.iterdir() if p.is_dir()) if corpus.is_dir() else []:
        path = suite_dir / "coverage.json"
        if not path.is_file():
            errors.append(f"{suite_dir.name}: no coverage.json from its generator")
            continue
        cov = json.loads(path.read_text(encoding="utf-8"))
        covered, total = int(cov.get("covered", 0)), int(cov.get("total", 0))
        excluded = cov.get("excluded") or {}
        unreasoned = sorted(k for k, v in excluded.items() if not v)
        lines.append(f"{suite_dir.name}: {covered}/{total}" + (f" ({len(excluded)} excluded with a reason)" if excluded else ""))
        if covered + len(excluded) < total:
            errors.append(f"{suite_dir.name}: {total - covered - len(excluded)} uncovered: " + ", ".join(cov.get("missing", [])[:10]))
        for key in unreasoned:
            errors.append(f"{suite_dir.name}: {key} is excluded without a reason")
    return lines, errors


def read_verdict_records(paths: Sequence[Path]) -> List[Dict[str, Any]]:
    records = []
    for path in paths:
        try:
            records.extend(json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip())
        except (OSError, ValueError) as error:
            raise UsageError(f"--stale {path}: {error}") from None
    return records


def cmd_check(args: argparse.Namespace) -> int:
    errors: List[str] = []
    if args.paths:
        cases = []
        for path in args.paths:
            case, error = load_case(path, f"{path.parent.name}/{path.stem}", check_id=False)
            if error:
                errors.append(error)
            elif case:
                cases.append(case)
    else:
        cases, errors = load_corpus(args.corpus)
    by_id: Dict[str, Case] = {}
    for case in cases:
        if case.id in by_id:
            errors.append(f"{case.id}: defined twice ({by_id[case.id].path} and {case.path})")
        by_id[case.id] = case
    normalize = load_sibling("normalize")
    if normalize is None or not CASE_SCHEMA.is_file():
        errors.append("schema: case validation needs normalize.py (p15-oracle-013) and case-v1.schema.json (p15-oracle-012)")
    else:
        schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
        for case in cases:
            errors.extend(f"{case.id}: {e}" for e in normalize.validate(case.data, schema))
    mutations = mutation_operations()
    for case in cases:
        errors.extend(check_case(case, mutations))
    baselines = load_sibling("baselines")
    if baselines is not None:
        for suite in sorted({c.suite for c in cases}):
            try:
                baselines.suite_class(suite)
            except baselines.BaselineError as error:
                errors.append(f"suite {suite}: {error}")
    store = load_expectations(args.expectations_root, platform=current_platform(), arm=None, product="daemon", build="debug")
    if store is not None:
        records = read_verdict_records(args.stale or ())
        for diagnostic in store.module.lint(store.store, corpus=args.corpus, results=records):
            if diagnostic.severity == "error":
                errors.append(f"expectations: {diagnostic.render()}")
            else:
                print(f"expectations: {diagnostic.render()}")
    elif args.stale:
        errors.append("--stale needs expectations.py (p15-oracle-015)")
    if args.coverage:
        lines, cov_errors = coverage_lines(args.corpus)
        for line in lines:
            print(f"coverage {line}")
        errors.extend(cov_errors)
    for error in errors:
        print(error)
    print(f"oracle check: {len(cases)} cases, {len(errors)} errors")
    return 1 if errors else 0


def cmd_gen(args: argparse.Namespace, rest: List[str]) -> int:
    suites = parse_list(args.suite)
    if not suites:
        raise UsageError("gen needs --suite NAME[,NAME]")
    code = 0
    for suite in suites:
        script = HERE / f"gen_{suite.replace('-', '_')}.py"
        if not script.is_file():
            print(f"gen: {script.name} is not on this branch yet", file=sys.stderr)
            code = 2
            continue
        result = subprocess.run([sys.executable, "-I", str(script), "--out", str(args.corpus / suite), *rest], check=False)
        code = code or result.returncode
    return code


def delegate(command: str, argv: List[str]) -> int:
    script, prefix, task = DELEGATES[command]
    path = HERE / script
    if not path.is_file():
        print(f"oracle {command}: {script} is not on this branch yet ({task})", file=sys.stderr)
        return 2
    return subprocess.run([sys.executable, "-I", str(path), *prefix, *argv], check=False).returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="oracle.py",
        description="cmux correctness oracle (plans/cmux-next/chrome-parity/p15-oracle.md).",
        epilog="rebaseline --run DIR [baselines.py options]. Delegated subcommands: "
               + ", ".join(f"{k} ({v[0]})" for k, v in DELEGATES.items()),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="run a selection of the corpus on one product and arm")
    add_selection_args(run)
    run.add_argument("--switch", help="refactor switch name (plans/cmux-next/refactor-switches)")
    run.add_argument("--arm", help="old or new with --switch; launch-config or default without")
    run.add_argument("--ref", help="source ref recorded in the receipt")
    run.add_argument("--out", type=Path, help=f"run directory (default {DEFAULT_OUT_BASE}/<run id>)")
    run.set_defaults(func=cmd_run)

    diff = sub.add_parser("diff", help="run two sides and compare them through diff.py; flaky cases are left out")
    add_selection_args(diff)
    diff.add_argument("--base", help="base ref (on the Linux VM: built and run in the runnerd queue)")
    diff.add_argument("--head", help="head ref")
    diff.add_argument("--base-binary", help="prebuilt base binary instead of building --base")
    diff.add_argument("--head-binary", help="prebuilt head binary instead of building --head")
    diff.add_argument("--switch", help="same build, arm old against arm new")
    diff.add_argument("--arm", choices=["launch-config"], help="every switch at its planned arm against all default")
    diff.add_argument("--ref", help="source ref recorded for --switch and --arm runs")
    diff.add_argument("--base-run", type=Path, action="append", help="existing run directory (repeat for shards)")
    diff.add_argument("--head-run", type=Path, action="append", help="existing run directory (repeat for shards)")
    diff.add_argument("--baselines", action="store_true", help="compare --head-run golden cases with reviewed baselines")
    diff.add_argument("--baselines-root", type=Path, default=DEFAULT_BASELINES_ROOT)
    diff.add_argument("--partial", action="store_true", help="compare a shard subset; the result says partial")
    diff.add_argument("--order-parity", action="store_true",
                      help="with --base-run/--head-run: one config run in two orders or batch limits (shuffle "
                           "seeds, --batch-limit 1); every verdict and every LeakedState must match")
    diff.add_argument("--fresh", action="store_true",
                      help="on the VM, rerun both sides even when the queue has a receipt (confirm, flake checks)")
    diff.add_argument("--out", type=Path, help="comparison directory")
    diff.set_defaults(func=cmd_diff)

    merge = sub.add_parser("merge", help="merge shard run directories; refuses a gap or an overlap")
    merge.add_argument("dirs", type=Path, nargs="+")
    merge.add_argument("--out", type=Path, required=True)
    merge.set_defaults(func=cmd_merge)

    check = sub.add_parser("check", help="schema, semantic, suite class and expectations lint of the corpus")
    check.add_argument("paths", type=Path, nargs="*", help="case files (default: the whole corpus)")
    check.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    check.add_argument("--expectations-root", type=Path, default=DEFAULT_EXPECTATIONS_ROOT)
    check.add_argument("--coverage", action="store_true", help="per-suite coverage from each generator's coverage.json")
    check.add_argument("--stale", type=Path, action="append",
                       help="verdict records (JSON lines); lines that passed in 3 or more runs are stale")
    check.set_defaults(func=cmd_check)

    gen = sub.add_parser("gen", help="run suite generators (gen_<suite>.py) into the corpus")
    gen.add_argument("--suite", action="append")
    gen.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    gen.set_defaults(func=None)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] in DELEGATES:
        return delegate(argv[0], argv[1:])
    parser = build_parser()
    try:
        if argv and argv[0] == "rebaseline":
            return cmd_rebaseline(argv[1:])
        if argv and argv[0] == "gen":
            args, rest = parser.parse_known_args(argv)
            return cmd_gen(args, rest)
        args = parser.parse_args(argv)
        args.raw_argv = argv[1:]
        return args.func(args)
    except UsageError as error:
        print(f"oracle: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
