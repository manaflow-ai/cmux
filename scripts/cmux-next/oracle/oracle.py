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
A session is one product process (one app launch); it runs up to --batch-limit cases.
A result is {"status": "Pass"|"Failure"|"Crash"|"Timeout", "checkpoints": [{"step": str,
"checkpoint": "before"|"turn"|"settled", "snapshot": <canonical snapshot (normalize.py)>,
optional "uncertain": true, optional "notComparable": [facet, ...]}], "message": str,
optional "step" (where a Crash or Timeout happened), optional "session_dirty": true (LeakedState
or a lost process: the next case gets a fresh session), optional "switch_hits": {name: {arm:
count}}}. This file hashes each snapshot (sha256 of its sorted-key compact JSON) and decides
flakiness by hashes; diff.py compares the snapshot values.

Run directory (`run --out DIR`; the format diff.py (014) reads, with the extra fields below):
    receipt.json       {"schema": "cmux-oracle-run-v1", "runId", "sha", "host": {"name", "os",
                        "osVersion", "arch"}, "platform", "product", "arm" (baseline arm or null),
                        "shards": [i], "seeds": {"i": seed}, "selection", "cases": {"<suite>/<case>":
                        {"suite", "result" (Flaky for a flaky case), "outcome", "flaky", "reasons",
                        "expected", "attempts", "checkpoints": N}}, "counts", ...}
    checkpoints.jsonl  one line per checkpoint of the case's first attempt (every attempt of a case
                        that is not flaky has the same hashes): {"case", "suite", "step", "index",
                        "checkpoint", "snapshot", "sha256", "attempt", "result"}
    events.jsonl       one line per attempt: phase, status, ms, message, checkpoint hashes
receipt.json also holds "nondeterminism": {"checkpoints", "nondeterministic", "rate"} (spec 4.6:
<= 1 %). `run --repeat 3 --flaky-out FILE` appends one cmux-oracle-flake-v1 line per flaky (case,
step, pointer) to FILE (MQ-flakes): "kind" (value, status, missing, declared), "target" in
Expectations syntax, "samples" [{"value", "runs"}] and "proposal" (normalize.flake_proposal: a rule
with its reason, or fix-at-source).
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
    linux_run.sh build REF -> last stdout line is the cmux-tui binary path          (024)
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
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

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
CAPABILITIES = frozenset({"resource_api", "actions", "keys", "gui", "chromium", "restart", "mcp", "tui"})
# WPT runs one suite against several products; a case runs on a product only when the
# product has every capability the case `requires`.
PRODUCTS: Dict[str, frozenset] = {
    "daemon": frozenset({"resource_api", "restart"}),
    "cli": frozenset({"resource_api", "restart"}),
    "mcp": frozenset({"resource_api", "actions", "mcp"}),
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


def load_expectations(root: Path, *, platform: str, arm: Optional[str], product: str, build: str) -> Optional[ExpectationStore]:
    module = load_sibling("expectations")
    if module is None:
        return None
    return ExpectationStore.load(module, root, platform=platform, arm=arm, product=product, build=build)


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
    # Snapshot rows are kept for the first attempt (the one checkpoints.jsonl holds) and, with
    # --flaky-out, for every attempt whose hashes differ from it (the samples of a flake line).
    rows: Tuple[Dict[str, Any], ...] = field(default=(), hash=False, compare=False)


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
    return {
        "status": status,
        "checkpoints": tuple(checkpoints),
        "rows": tuple(rows),
        "message": str(raw.get("message") or ""),
        "step": step if isinstance(step, str) else None,
        "session_dirty": bool(raw.get("session_dirty")),
        "switch_hits": raw.get("switch_hits") or {},
    }


def run_batch(works: Sequence[Work], open_session: SessionOpener, session_ctx: Dict[str, Any]) -> Tuple[list, list]:
    """Runs one batch in as few sessions as possible; a dirty session is replaced before the next case."""
    results = []
    errors = []
    session = None

    def close() -> None:
        try:
            session.close()
        except Exception as error:  # noqa: BLE001 - a teardown failure is reported, not raised
            errors.append(f"session close after {works[0].case.id}..: {error!r}")

    try:
        for work in works:
            start = time.monotonic()
            try:
                if session is None:
                    session = open_session(dict(session_ctx))
                result = coerce_result(session.run_case(work.case.data, dict(work.ctx)))
            except Exception as error:  # noqa: BLE001 - a driver failure fails this case only
                result = {**crash(f"driver error: {error!r}"), "session_dirty": True}
            results.append((work, result, int((time.monotonic() - start) * 1000)))
            if result.get("session_dirty") and session is not None:
                close()
                session = None
    finally:
        if session is not None:
            close()
    return results, errors


def run_phase(
    batches: Sequence[Sequence[Work]], open_session: SessionOpener, session_ctx: Dict[str, Any], jobs: int
) -> Tuple[list, list]:
    results: list = []
    errors: list = []
    if jobs <= 1 or len(batches) <= 1:
        outputs: Iterable = (run_batch(b, open_session, session_ctx) for b in batches)
        for batch_results, batch_errors in outputs:
            results.extend(batch_results)
            errors.extend(batch_errors)
        return results, errors
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(batches))) as pool:
        for batch_results, batch_errors in pool.map(lambda b: run_batch(b, open_session, session_ctx), batches):
            results.extend(batch_results)
            errors.extend(batch_errors)
    return results, errors


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


def execute(plan: Plan, options: RunOptions, open_session: SessionOpener, expected: Dict[str, Expected]) -> Tuple[List[Attempt], List[str]]:
    """Runs every iteration of the plan with the retry policy of spec 3G.

    Retry 1 reruns the whole shard with the same order and batches; retries 2..limit run each
    still-failing case alone in a fresh session, serially. Keys for state roots are given out
    here, on one thread, before work is dispatched.
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
    }
    runnable = [tuple(c for c in batch if not expected[c.id].skip) for batch in plan.batches]
    runnable = [batch for batch in runnable if batch]
    attempts: List[Attempt] = []
    errors: List[str] = []
    first_checkpoints: Dict[str, Checkpoints] = {}
    keep_samples = options.flaky_out is not None

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

    def record(results: list, iteration: int, attempt: int, phase: str) -> Dict[str, Tuple[str, Optional[str]]]:
        statuses = {}
        for work, result, ms in results:
            first = iteration == 0 and attempt == 0
            if first:
                first_checkpoints[work.case.id] = result["checkpoints"]
            keep = first or (keep_samples and result["checkpoints"] != first_checkpoints.get(work.case.id))
            attempts.append(
                Attempt(
                    work.case.id, iteration, attempt, phase, result["status"], result.get("step"), result["checkpoints"],
                    result["message"], ms, result.get("switch_hits") or {}, result["rows"] if keep else (),
                )
            )
            statuses[work.case.id] = (result["status"], result.get("step"))
        return statuses

    for iteration in range(options.repeat):
        results, errs = run_phase([works(b, iteration, 0, "run") for b in runnable], open_session, session_ctx, options.jobs)
        errors.extend(errs)
        statuses = record(results, iteration, 0, "run")
        failing = [c for b in runnable for c in b if needs_retry(statuses[c.id], expected[c.id])]
        if failing and options.retry_limit >= 1:
            results, errs = run_phase(
                [works(b, iteration, 1, "shard-retry") for b in runnable], open_session, session_ctx, options.jobs
            )
            errors.extend(errs)
            statuses = record(results, iteration, 1, "shard-retry")
            failing = [c for c in failing if needs_retry(statuses[c.id], expected[c.id])]
        for attempt in range(2, options.retry_limit + 1):
            if not failing:
                break
            results, errs = run_phase(
                [works((c,), iteration, attempt, "alone-retry") for c in failing], open_session, session_ctx, 1
            )
            errors.extend(errs)
            statuses = record(results, iteration, attempt, "alone-retry")
            failing = [c for c in failing if needs_retry(statuses[c.id], expected[c.id])]
    return attempts, errors


def classify(attempts: Sequence[Attempt], expected: Expected) -> Dict[str, Any]:
    """One case's verdict over every iteration and attempt.

    Flaky (left out of every comparison, never fails the run): any attempt or repeat whose
    status or checkpoint hashes differ from the first one (a pass on retry is one such
    difference), or several expected results.
    """
    if expected.skip:
        return {"outcome": "skipped", "result": "Skip", "status": "Skip", "flaky": False, "reasons": [], "attempts": 0}
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


# ---------------------------------------------------------------------------------------
# Flakes (p15-oracle-117): the MQ-flakes queue, one line per (case, step, pointer)
#
# blinkpy keeps every result of a flaky test (test_run_results.py, `results` per retry) so the
# flakiness dashboard can show what changed; here the unit is the value: each line names the
# checkpoint and JSON pointer that differed and the canonical values each run saw there.

CheckpointKey = Tuple[str, str, int]
FLAKE_SCHEMA = "cmux-oracle-flake-v1"
SAMPLE_CHARS = 2048
STATUS_REASON = ("the case result changes between runs of one build: fix the cause at its source (a Timeout is a "
                 "wait that no state change ends: use waitFor or settle on the change)")
MISSING_REASON = "a checkpoint is reached in some runs only, with the same result: the step sequence depends on timing"
UNKEPT_REASON = "the differing snapshots were not kept, so no pointer can be named"
DECLARED_REASON = "Expectations list several results, and every run here gave the same one: the line may be stale"


def checkpoint_keys(checkpoints: Checkpoints) -> Dict[CheckpointKey, int]:
    """(step, checkpoint, occurrence) -> index: a repeated step lines up with its own occurrence."""
    seen: Dict[Tuple[str, str], int] = {}
    keys: Dict[CheckpointKey, int] = {}
    for index, (step, checkpoint, _) in enumerate(checkpoints):
        n = seen.get((step, checkpoint), 0)
        seen[(step, checkpoint)] = n + 1
        keys[(step, checkpoint, n)] = index
    return keys


def nondeterministic_checkpoints(attempts: Sequence[Attempt]) -> List[CheckpointKey]:
    """Checkpoints of the first run whose hash differs in another repeat or retry that reached them."""
    first = next((a for a in attempts if a.iteration == 0 and a.attempt == 0), None)
    if first is None:
        return []
    others = [(a, checkpoint_keys(a.checkpoints)) for a in attempts if a is not first]
    out = []
    for key, index in checkpoint_keys(first.checkpoints).items():
        sha = first.checkpoints[index][2]
        if any(key in theirs and a.checkpoints[theirs[key]][2] != sha for a, theirs in others):
            out.append(key)
    return out


def run_label(a: Attempt) -> Dict[str, Any]:
    return {"iteration": a.iteration, "attempt": a.attempt, "phase": a.phase}


def sample_value(value: Any) -> Any:
    text = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if len(text) <= SAMPLE_CHARS:
        return value
    return {"$truncated": text[:SAMPLE_CHARS], "chars": len(text), "sha256": hashlib.sha256(text.encode()).hexdigest()}


def covering_rule(rules: Sequence[Mapping[str, str]], case_id: str, step: Optional[str], pointer: Optional[str]) -> Optional[str]:
    """The reason of the Expectations pointer line (ExpectationStore.pointer_rules) that covers this value."""
    if step is None or pointer is None:
        return None
    for rule in rules:
        ptr = rule["pointer"]
        if (fnmatch.fnmatchcase(case_id, rule["case"]) and fnmatch.fnmatchcase(step, rule.get("step", "*"))
                and (ptr == "" or pointer == ptr or pointer.startswith(ptr + "/"))):
            return rule["reason"]
    return None


def flake_lines(case_id: str, attempts: Sequence[Attempt], expected: Expected, rules: Sequence[Mapping[str, str]],
                normalize: Any) -> List[Dict[str, Any]]:
    """One case's MQ-flakes lines: what differed between its runs, where, and the values each run saw.

    Kinds: `value` (a pointer inside one checkpoint, with the rule proposal of normalize.flake_pointers),
    `status` (the result changed), `missing` (a checkpoint some runs did not reach with the same result),
    `declared` (Expectations list several results; nothing differed here)."""
    runs = sorted(attempts, key=lambda a: (a.iteration, a.attempt))
    lines: List[Dict[str, Any]] = []

    def add(kind: str, key: Optional[CheckpointKey], pointer: Optional[str], samples: List[Dict[str, Any]],
            proposal: Mapping[str, Any], expected_by: Optional[str] = None) -> None:
        step, checkpoint, occurrence = key if key else (None, None, None)
        target = case_id if step is None else f"{case_id}/{step}"
        if pointer:
            target += f"#{pointer}"
        lines.append({"case": case_id, "kind": kind, "step": step, "checkpoint": checkpoint, "occurrence": occurrence,
                      "pointer": pointer, "target": target, "samples": samples, "proposal": dict(proposal),
                      "expected_by": expected_by})

    def fix(reason: str) -> Dict[str, Any]:
        return {"rule": None, "action": "fix-at-source", "reason": reason}

    outcomes: Dict[Tuple[str, Optional[str]], List[Attempt]] = {}
    for a in runs:
        outcomes.setdefault((a.status, a.step), []).append(a)
    declared = "Expectations: several results " + " ".join(sorted(expected.results)) if expected.declared_flaky else None
    if len(outcomes) > 1:
        add("status", None, None,
            [{"value": {"status": status, "step": step, "message": group[0].message[:200]},
              "runs": [run_label(a) for a in group]} for (status, step), group in outcomes.items()],
            fix(STATUS_REASON), declared)

    keyed = [(a, checkpoint_keys(a.checkpoints)) for a in runs]
    order: Dict[CheckpointKey, None] = {}
    for _, keys in keyed:
        order.update(dict.fromkeys(keys))
    for key in order:
        present = [(a, keys[key]) for a, keys in keyed if key in keys]
        if len(present) < len(runs) and len(outcomes) == 1:
            add("missing", key, None,
                [{"value": "reached", "runs": [run_label(a) for a, _ in present]},
                 {"value": "not reached", "runs": [run_label(a) for a, keys in keyed if key not in keys]}],
                fix(MISSING_REASON))
        by_hash: Dict[str, List[Tuple[Attempt, int]]] = {}
        for a, index in present:
            by_hash.setdefault(a.checkpoints[index][2], []).append((a, index))
        if len(by_hash) < 2:
            continue
        kept = [next(((a, i) for a, i in members if i < len(a.rows)), None) for members in by_hash.values()]
        if any(holder is None for holder in kept):
            add("value", key, None,
                [{"value": {"sha256": sha}, "runs": [run_label(a) for a, _ in members]} for sha, members in by_hash.items()],
                fix(UNKEPT_REASON))
            continue
        groups = [[run_label(a) for a, _ in members] for members in by_hash.values()]
        for entry in normalize.flake_pointers([a.rows[i]["snapshot"] for a, i in kept]):
            add("value", key, entry["pointer"],
                [{"value": sample_value(v), "runs": g} for v, g in zip(entry["values"], groups)],
                entry["proposal"], covering_rule(rules, case_id, key[0], entry["pointer"]))
    if not lines and declared:
        add("declared", None, None, [{"value": {"status": runs[0].status} if runs else None,
                                      "runs": [run_label(a) for a in runs]}],
            {"rule": None, "action": "check-expectation", "reason": DECLARED_REASON}, declared)
    return lines


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
    checkpoints = sum(int(r.get("checkpoints") or 0) for r in cases.values())
    varying = sum(int(r.get("nondeterministic_checkpoints") or 0) for r in cases.values())
    return {
        "counts": counts,
        # Spec 4.6: at most 1 % of checkpoints may differ between repeats and retries of one build.
        "nondeterminism": {"checkpoints": checkpoints, "nondeterministic": varying,
                           "rate": round(varying / checkpoints, 6) if checkpoints else 0.0},
        "flaky": sorted(cid for cid, r in cases.items() if r["flaky"]),
        "unexpected": unexpected,
        "unexpected_passes": sorted(cid for cid, r in cases.items() if r["outcome"] == "unexpected-pass"),
        "switch_hits": hits,
        "arm_exercised": arm_exercised,
        "ok": not unexpected and not infra_errors and arm_exercised is not False,
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


def perform_run(
    options: RunOptions,
    cases: Sequence[Case],
    open_session: Optional[SessionOpener],
    expectation: Optional[ExpectationFn],
    dependencies: Dict[str, str],
    pointer_rules: Sequence[Mapping[str, str]] = (),
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
    if not options.dry_run:
        if open_session is None:
            raise UsageError("no driver to run cases with")
        attempts, errors = execute(plan, options, open_session, expected)
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
        first = next((a for a in by_case[case.id] if a.iteration == 0 and a.attempt == 0), None)
        record.update(suite=case.suite, expected=sorted(exp.results), checkpoints=len(first.checkpoints) if first else 0,
                      nondeterministic_checkpoints=len(nondeterministic_checkpoints(by_case[case.id])))
        records[case.id] = record
        if first is not None:
            rows.extend(checkpoint_rows(case.id, first.rows, attempt=0, result=first.status))

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
        "dependencies": dependencies,
        "selection": {"count": len(plan.selection), "digest": digest(plan.selection)},
        "shards": [options.shard[0]],
        "seeds": {str(options.shard[0]): options.seed},
        "not_applicable": len(not_applicable),
        "order": [c.id for c in plan.order],
        "batches": len(plan.batches),
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
             "step": a.step, "ms": a.ms, "message": a.message, "sha256": [h for _, _, h in a.checkpoints]}
            for a in attempts
        ),
    )
    if options.flaky_out:
        receipt["flaky_out"] = {"path": str(options.flaky_out),
                                "lines": write_flaky_out(options, receipt, by_case, expected, pointer_rules)}
        write_json(options.out / "receipt.json", receipt)
    write_index(options, receipt)
    return receipt, 0 if receipt["ok"] else 1


def write_flaky_out(options: RunOptions, receipt: Mapping[str, Any], by_case: Mapping[str, Sequence[Attempt]],
                    expected: Mapping[str, Expected], pointer_rules: Sequence[Mapping[str, str]]) -> int:
    """Appends the run's MQ-flakes lines (cmux-oracle-flake-v1) to --flaky-out; returns how many."""
    if not receipt["flaky"]:
        return 0
    normalize = require_sibling("normalize", "p15-oracle-013")
    run = {"schema": FLAKE_SCHEMA, "run_id": options.run_id, "sha": options.ref or "", "product": options.product,
           "platform": options.platform, "build": options.build, "arm": options.arm, "switches": options.switches,
           "repeat": options.repeat, "retry_limit": options.retry_limit, "seed": options.seed}
    rows = []
    for cid in receipt["flaky"]:
        reasons = receipt["cases"][cid]["reasons"]
        for line in flake_lines(cid, by_case[cid], expected[cid], pointer_rules, normalize):
            rows.append({**run, **line, "suite": split_case_id(cid)[0], "reasons": reasons})
    options.flaky_out.parent.mkdir(parents=True, exist_ok=True)
    with options.flaky_out.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    return len(rows)


def nondeterminism_line(receipt: Mapping[str, Any]) -> str:
    n = receipt["nondeterminism"]
    return (f"- nondeterministic checkpoints: {n['nondeterministic']} of {n['checkpoints']} "
            f"({n['rate'] * 100:.2f} %, bound 1 %)")


def write_index(options: RunOptions, receipt: Dict[str, Any]) -> None:
    lines = [
        f"# oracle run {receipt['runId']}",
        "",
        f"- product {options.product}, platform {options.platform}, build {options.build}",
        f"- shard {options.shard[0]}/{options.shard[1]}: {len(receipt['order'])} of {receipt['selection']['count']} selected cases",
        f"- seed {options.seed}, batch limit {options.batch_limit}, jobs {options.jobs}, repeat {options.repeat}, "
        f"retry limit {options.retry_limit}",
        "- outcomes: " + ", ".join(f"{k} {v}" for k, v in sorted(receipt["counts"].items())),
        f"- flaky (left out of comparisons): {len(receipt['flaky'])}",
        nondeterminism_line(receipt),
        f"- ok: {receipt['ok']}",
    ]
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


def comparability(a: RunView, b: RunView, *, partial: bool) -> Optional[str]:
    """Why two sides cannot be compared as a full (or, with --partial, a shard-subset) result."""
    if a.receipt.get("dry_run") or b.receipt.get("dry_run"):
        return "a dry run has no results"
    if a.total != b.total:
        return f"shard totals differ: {a.total} vs {b.total}"
    if a.shards != b.shards:
        return f"shard sets differ: {list(a.shards)} vs {list(b.shards)}"
    if a.receipt["selection"]["digest"] != b.receipt["selection"]["digest"]:
        return "the two sides select different cases (corpus, suites, filters or product differ)"
    if a.seeds != b.seeds and any(s is not None for s in (*a.seeds.values(), *b.seeds.values())):
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
                  as_json: bool = False) -> int:
    """Checks that the sides are comparable, then hands every comparison to diff.py.

    diff.py owns the host check, the first divergence per case and expected differences, so an
    all-match comparison from two hosts is refused like a divergent one. Flaky cases are
    reported as flaky by diff.py and never count as compared.
    """
    target = out / "divergence.json"
    target.unlink(missing_ok=True)
    refused = refused or comparability(a, b, partial=partial)
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
        "ok": refused is None and code == DIFF_OK,
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
        if refused:
            print(f"  refused: {refused}")
        if comparison["partial"]:
            print(f"  partial: shards {comparison['shards']} of {b.total} only")
        print(f"  comparison: {out / 'comparison.json'}")
    if code == DIFF_INTERNAL:
        return DIFF_INTERNAL
    if refused is not None:
        return EXIT_REFUSED
    return 0 if code == DIFF_OK else 1


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
    parser.add_argument("--flaky-out", type=Path,
                        help="append one JSON line per (case, step, pointer) that differed between runs, with the "
                        "values each run saw and a rule proposal (MQ-flakes; use with --repeat 3)")
    parser.add_argument("--dry-run", action="store_true", help="plan and write the receipt; run nothing")
    parser.add_argument("--run-id", help="default: UTC time plus 6 random characters")
    parser.add_argument("--json", action="store_true", help="print the receipt or comparison as JSON")


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
        jobs=args.jobs or DEFAULT_JOBS.get(product, VM_JOBS),
        batch_limit=args.batch_limit or DEFAULT_BATCH_LIMIT.get(product, 1),
        repeat=args.repeat,
        retry_limit=0,
        seed=seed,
        platform=args.platform,
        build=args.build or DEFAULT_BUILD.get(product, "debug"),
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
        if driver is None:
            raise UsageError(f"driver_{options.product}.py is not on this branch yet ({DRIVER_TASKS[options.product]})")
        open_session = driver.open_session
    return perform_run(options, cases, open_session, store.expected if store else None, deps,
                       store.pointer_rules() if store else ())


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
    if options.repeat > 1 or receipt["nondeterminism"]["nondeterministic"]:
        print("  " + nondeterminism_line(receipt)[2:])
    if receipt.get("flaky_out"):
        print(f"  flake lines: {receipt['flaky_out']['lines']} appended to {receipt['flaky_out']['path']}")
    for cid in receipt["unexpected"][:20]:
        print(f"  unexpected: {cid} ({receipt['cases'][cid]['status']})")
    if receipt["arm_exercised"] is False:
        print(f"  arm-not-exercised: {options.switch}={options.arm} had 0 hits")
    for error in receipt["infra_errors"][:10]:
        print(f"  infra: {error}")
    print(f"  receipt: {options.out / 'receipt.json'}")


def cmd_run(args: argparse.Namespace) -> int:
    run_id = args.run_id or new_run_id()
    out = args.out or DEFAULT_OUT_BASE / run_id
    switches = resolve_switches(load_switch_registry(), args.switch, args.arm)
    options = options_from_args(args, retry_default=None, out=out, run_id=run_id, switch=args.switch, arm=args.arm,
                                switches=switches, ref=args.ref, binary=args.binary)
    receipt, code = run_one(options)
    print_run(receipt, options, args.json)
    return code


def build_daemon(ref: str) -> str:
    script = HERE / "linux_run.sh"
    if not script.is_file():
        raise UsageError("linux_run.sh is not on this branch yet (p15-oracle-024); pass --base-run/--head-run")
    proc = subprocess.run(["bash", str(script), "build", ref], check=False, stdout=subprocess.PIPE, text=True)
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    if proc.returncode != 0 or not lines:
        raise UsageError(f"linux_run.sh build {ref} failed (exit {proc.returncode})")
    return lines[-1].strip()


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
        base_bin = args.base_binary or build_daemon(args.base)
        head_bin = args.head_binary or build_daemon(args.head)
        return (Side("base", None, None, {}, args.base, base_bin), Side("head", None, None, {}, args.head, head_bin)), []
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
                             rules=comparison_rules(head, args.expectations_root), as_json=args.json)
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
    for kind in data.get("allow_crashes") or ():
        if kind not in CRASH_KINDS:
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
        operation = (step.get("args") or {}).get("operation") if isinstance(step.get("args"), dict) else None
        mutating = op in TARGETED_OPS or (op == "resource.call" and operation in mutations)
        if mutating and not step.get("target"):
            what = f"{op} {operation}" if op == "resource.call" else op
            errors.append(f"{case.id}: {label} mutates ({what}) without a target")
        checkpoint = step.get("checkpoint")
        if checkpoint is not None and checkpoint not in CHECKPOINTS:
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
    diff.add_argument("--base", help="base ref (daemon: built by linux_run.sh)")
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
