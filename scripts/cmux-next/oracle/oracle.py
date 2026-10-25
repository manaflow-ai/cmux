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
- third_party/blink/web_tests/TestExpectations: several results on one line mean flaky, Skip
  never runs, Slow gives 5x the timeout.

Subcommands owned here: run, diff, merge, check, gen. These delegate to the sibling script
that owns them (`oracle.py <cmd> ARGS` runs `python3 -I <script> ARGS`): confirm, select,
bisect, rebaseline, report, minimize, switches, route, coverage, selftest.

Driver protocol (owned here; driver_<product>.py implements it):
    open_session(session_ctx: dict) -> session
    session.run_case(case: dict, case_ctx: dict) -> result dict
    session.close() -> None
A session is one product process (one app launch); it runs up to --batch-limit cases.
A result is {"status": "Pass"|"Failure"|"Crash"|"Timeout", "checkpoints": [{"step": str,
"checkpoint": "before"|"turn"|"settled", "hash": str}], "message": str, optional
"session_dirty": true (LeakedState or a lost process: the next case gets a fresh session),
optional "switch_hits": {name: {arm: count}}}. Hashes are the sha256 of the normalized
snapshot (normalize.py); this file compares hashes and never reads snapshot values.

Interfaces of dependencies this file calls (tasks 013-016 were not on perf/chrome-parity when
this was written; the calls follow their spec and are listed so those tasks match them):
    normalize.validate(instance, schema) -> list[str]                     (013)
    diff.py --a RUN_DIR --b RUN_DIR --cases FILE --out divergence.json   (014)
        divergence.json: {"refused": null|"host-mismatch", "cases": [{"case": id,
        "verdict": "divergent"|"explained", "first": {...}}]}
    expectations.load(repo) -> store; store.lookup(case_id, *, platform, arm, product,
        build) -> set of keywords (whole-case lines only); store.lint(case_ids, golden_ids)
        -> list[str]; store.stale(case_ids) -> list[str]                  (015)
    baselines.suite_class(suite) -> "golden"|"differential";
        baselines.expected_checkpoints(case_id, *, platform, arm, product) -> list|None (016)
    linux_run.sh build REF -> last stdout line is the cmux-tui binary path   (024)
    fleet.py diff ARGS: the app product's base/head and switch diffs        (050)
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import hashlib
import importlib
import itertools
import json
import platform as platform_mod
import random
import socket
import subprocess
import sys
import time
import urllib.parse
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_CORPUS = REPO / "tests" / "oracle" / "corpus"
SWITCH_REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
RESOURCE_OPERATIONS = REPO / "cmux-tui" / "spec" / "resource-operations-v2.json"
DEFAULT_OUT_BASE = Path("/tmp/oracle/runs")
# Spec 3G: state roots are /tmp/o/<run6>/<case6> so a daemon socket path stays under sun_path.
DEFAULT_STATE_BASE = Path("/tmp/o")

RESULTS = ("Pass", "Failure", "Crash", "Timeout")
EXPECTATION_KEYWORDS = frozenset(RESULTS) | {"Skip", "Slow"}
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

DELEGATES: Dict[str, Tuple[str, Tuple[str, ...], str]] = {
    "confirm": ("confirm.py", (), "p15-oracle-184"),
    "select": ("select.py", (), "p15-oracle-009"),
    "bisect": ("bisect.py", (), "p15-oracle-009"),
    "rebaseline": ("baselines.py", ("rebaseline",), "p15-oracle-016"),
    "report": ("report.py", (), "p15-oracle-116"),
    "minimize": ("minimize.py", (), "p15-oracle-098"),
    "switches": ("switches.py", (), "p15-oracle-018"),
    "route": ("route.py", (), "p15-oracle-118"),
    "coverage": ("coverage.py", (), "p15-oracle-190"),
    "selftest": ("selftest.py", (), "p15-oracle-019"),
}


class UsageError(Exception):
    """A bad argument or a missing tool: exit 2, nothing ran."""


def load_sibling(module: str) -> Any:
    """Imports scripts/cmux-next/oracle/<module>.py, or None when it is not on this branch.

    `python3 -I` does not put the script's directory on sys.path; this directory is ours.
    """
    if not (HERE / f"{module}.py").is_file():
        return None
    if str(HERE) not in sys.path:
        sys.path.insert(0, str(HERE))
    return importlib.import_module(module)


def current_platform() -> str:
    if sys.platform == "darwin":
        return "mac"
    if sys.platform.startswith("win"):
        return "windows"
    return "linux"


def host_info() -> Dict[str, str]:
    return {
        "name": socket.gethostname(),
        "os": platform_mod.system(),
        "release": platform_mod.mac_ver()[0] or platform_mod.release(),
        "machine": platform_mod.machine(),
    }


def digest(items: Iterable[str]) -> str:
    h = hashlib.sha256()
    for item in items:
        h.update(item.encode())
        h.update(b"\n")
    return h.hexdigest()


def base36(n: int, width: int = 6) -> str:
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    out = ""
    while n:
        n, r = divmod(n, 36)
        out = chars[r] + out
    return out.rjust(width, "0")


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


def load_case(path: Path, case_id: str, *, check_id: bool = True) -> Tuple[Optional[Case], Optional[str]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return None, f"{case_id}: cannot read: {error}"
    if not isinstance(data, dict):
        return None, f"{case_id}: a case is a JSON object"
    suite, _, name = case_id.partition("/")
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
    results: frozenset
    skip: bool = False
    slow: bool = False

    @property
    def declared_flaky(self) -> bool:
        return len(self.results) > 1


PASS_ONLY = Expected(frozenset({"Pass"}))
Lookup = Callable[[str], Iterable[str]]


def expected_for(lookup: Optional[Lookup], case_id: str) -> Expected:
    keywords = frozenset(lookup(case_id)) if lookup else frozenset()
    unknown = keywords - EXPECTATION_KEYWORDS
    if unknown:
        raise UsageError(f"{case_id}: unknown expectation keyword(s) {sorted(unknown)}")
    results = keywords & frozenset(RESULTS)
    return Expected(results or frozenset({"Pass"}), "Skip" in keywords, "Slow" in keywords)


def expectations_lookup(module: Any, *, platform: str, arm: Optional[str], product: str, build: str) -> Optional[Lookup]:
    if module is None:
        return None
    store = module.load(REPO)
    return lambda case_id: store.lookup(case_id, platform=platform, arm=arm, product=product, build=build)


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
    checkpoints: Checkpoints
    message: str
    ms: int
    switch_hits: Dict[str, Dict[str, int]] = field(hash=False, compare=False)


@dataclass(frozen=True)
class Work:
    case: Case
    ctx: Dict[str, Any] = field(hash=False, compare=False)


def coerce_result(raw: Any) -> Dict[str, Any]:
    """A malformed driver result is a Crash of that case, never a silent pass."""
    if not isinstance(raw, dict):
        return {"status": "Crash", "checkpoints": (), "message": "driver returned a non-object result"}
    status = raw.get("status")
    if status not in RESULTS:
        return {"status": "Crash", "checkpoints": (), "message": f"driver returned status {status!r}"}
    checkpoints = []
    for cp in raw.get("checkpoints") or ():
        if not (isinstance(cp, dict) and isinstance(cp.get("hash"), str) and cp.get("checkpoint") in CHECKPOINTS):
            return {"status": "Crash", "checkpoints": (), "message": f"driver returned a malformed checkpoint {cp!r}"}
        checkpoints.append((str(cp.get("step")), cp["checkpoint"], cp["hash"]))
    return {
        "status": status,
        "checkpoints": tuple(checkpoints),
        "message": str(raw.get("message") or ""),
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
                result = {"status": "Crash", "checkpoints": (), "message": f"driver error: {error!r}", "session_dirty": True}
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

    @property
    def filtered(self) -> bool:
        return bool(self.filters) or (bool(self.suites) and "all" not in self.suites)

    def fingerprint(self) -> Dict[str, Any]:
        """What must be equal for shard receipts to merge (not the index, jobs or binary path)."""
        return {
            "product": self.product,
            "suites": sorted(self.suites),
            "filters": sorted(self.filters),
            "shard_total": self.shard[1],
            "batch_limit": self.batch_limit,
            "repeat": self.repeat,
            "retry_limit": self.retry_limit,
            "seed": self.seed,
            "platform": self.platform,
            "build": self.build,
            "switch": self.switch,
            "arm": self.arm,
            "switches": dict(sorted(self.switches.items())),
            "ref": self.ref,
            "tag": self.tag,
        }


def needs_retry(status: str, expected: Expected) -> bool:
    """An unexpected result is retried; an unexpected pass is reported and not retried."""
    return status not in expected.results and status != "Pass"


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

    def record(results: list, iteration: int, attempt: int, phase: str) -> Dict[str, str]:
        statuses = {}
        for work, result, ms in results:
            attempts.append(
                Attempt(
                    work.case.id, iteration, attempt, phase, result["status"], result["checkpoints"],
                    result["message"], ms, result.get("switch_hits") or {},
                )
            )
            statuses[work.case.id] = result["status"]
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

    Flaky (left out of every comparison, never fails the run): a pass on retry, a checkpoint
    hash or status that differs between attempts or repeats, or several expected results.
    """
    if expected.skip:
        return {"outcome": "skipped", "status": "Skip", "flaky": False, "reasons": [], "checkpoints": ()}
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
        if first.status in expected.results:
            outcomes.append("expected")
            for later in runs[1:]:
                if (later.status, later.checkpoints) != (first.status, first.checkpoints):
                    reasons.append(f"nondeterministic: iteration {iteration} attempt {later.attempt} ({later.phase}) differs")
                    break
        elif first.status == "Pass":
            outcomes.append("unexpected-pass")
        else:
            passed = next((a for a in runs[1:] if a.status in expected.results), None)
            if passed is not None:
                reasons.append(f"pass-on-retry: iteration {iteration} attempt {passed.attempt} ({passed.phase})")
            outcomes.append("unexpected")
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
        "status": first.status,
        "flaky": bool(reasons),
        "reasons": reasons,
        "checkpoints": first.checkpoints,
        "attempts": len(attempts),
    }


def sum_switch_hits(attempts: Iterable[Attempt]) -> Dict[str, Dict[str, int]]:
    total: Dict[str, Dict[str, int]] = {}
    for a in attempts:
        for name, arms in a.switch_hits.items():
            for arm, count in (arms or {}).items():
                total.setdefault(name, {}).setdefault(arm, 0)
                total[name][arm] += int(count)
    return total


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


def checkpoint_rows(cps: Checkpoints) -> List[Dict[str, str]]:
    return [{"step": s, "checkpoint": c, "hash": h} for s, c, h in cps]


def perform_run(
    options: RunOptions,
    cases: Sequence[Case],
    open_session: Optional[SessionOpener],
    lookup: Optional[Lookup],
    dependencies: Dict[str, str],
) -> Tuple[Dict[str, Any], int]:
    """Selects, shards, runs and writes receipt.json, checkpoints.jsonl, events.jsonl, index.md."""
    started = time.time()
    check_out_dir(options.out)
    selected, not_applicable = select_cases(
        cases, suites=options.suites, filters=options.filters, product=options.product, platform=options.platform
    )
    plan = make_plan(selected, shard=options.shard, seed=options.seed, batch_limit=options.batch_limit)
    expected = {c.id: expected_for(lookup, c.id) for c in plan.order}
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
    for case in plan.order:
        if options.dry_run:
            exp = expected[case.id]
            records[case.id] = {"outcome": "skipped" if exp.skip else "planned", "status": "Skip" if exp.skip else None,
                                "flaky": False, "reasons": [], "checkpoints": (), "attempts": 0}
        else:
            records[case.id] = classify(by_case[case.id], expected[case.id])
        records[case.id]["expected"] = sorted(expected[case.id].results)

    hits = sum_switch_hits(attempts)
    arm_exercised: Optional[bool] = None
    if options.switch and options.arm and not options.dry_run and any(r["attempts"] for r in records.values()):
        arm_exercised = hits.get(options.switch, {}).get(options.arm, 0) > 0
    counts: Dict[str, int] = {}
    for record in records.values():
        counts[record["outcome"]] = counts.get(record["outcome"], 0) + 1
    flaky = sorted(cid for cid, r in records.items() if r["flaky"])
    unexpected = sorted(cid for cid, r in records.items() if r["outcome"] == "unexpected")
    ok = not unexpected and not errors and arm_exercised is not False

    receipt = {
        "schema": "cmux-oracle-run-v1",
        "run_id": options.run_id,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
        "duration_s": round(time.time() - started, 3),
        "dry_run": options.dry_run,
        "config": {**options.fingerprint(), "shard_index": options.shard[0], "jobs": options.jobs, "binary": options.binary},
        "fingerprint": digest([json.dumps(options.fingerprint(), sort_keys=True)]),
        "host": host_info(),
        "dependencies": dependencies,
        "selection": {"count": len(plan.selection), "digest": digest(plan.selection)},
        "not_applicable": len(not_applicable),
        "order": [c.id for c in plan.order],
        "batches": len(plan.batches),
        "cases": {
            cid: {k: v for k, v in r.items() if k != "checkpoints"} for cid, r in records.items()
        },
        "counts": counts,
        "flaky": flaky,
        "unexpected": unexpected,
        "unexpected_passes": sorted(cid for cid, r in records.items() if r["outcome"] == "unexpected-pass"),
        "switch_hits": hits,
        "arm_exercised": arm_exercised,
        "infra_errors": errors,
        "ok": ok,
    }
    write_json(options.out / "receipt.json", receipt)
    finals = {(cid, 0, 0) for cid in records}
    write_jsonl(
        options.out / "checkpoints.jsonl",
        (
            {"case": a.case, "iteration": a.iteration, "attempt": a.attempt, "status": a.status,
             "checkpoints": checkpoint_rows(a.checkpoints), "final": (a.case, a.iteration, a.attempt) in finals}
            for a in attempts
        ),
    )
    write_jsonl(
        options.out / "events.jsonl",
        (
            {"case": a.case, "iteration": a.iteration, "attempt": a.attempt, "phase": a.phase, "status": a.status,
             "ms": a.ms, "message": a.message}
            for a in attempts
        ),
    )
    write_index(options, receipt)
    if options.flaky_out and flaky:
        options.flaky_out.parent.mkdir(parents=True, exist_ok=True)
        with options.flaky_out.open("a", encoding="utf-8") as handle:
            for cid in flaky:
                handle.write(json.dumps({"case": cid, "run_id": options.run_id, "product": options.product,
                                         "arm": options.arm, "switches": options.switches,
                                         "reasons": records[cid]["reasons"]}, sort_keys=True) + "\n")
    return receipt, 0 if ok else 1


def write_index(options: RunOptions, receipt: Dict[str, Any]) -> None:
    lines = [
        f"# oracle run {receipt['run_id']}",
        "",
        f"- product {options.product}, platform {options.platform}, build {options.build}",
        f"- shard {options.shard[0]}/{options.shard[1]}: {len(receipt['order'])} of {receipt['selection']['count']} selected cases",
        f"- seed {options.seed}, batch limit {options.batch_limit}, jobs {options.jobs}, repeat {options.repeat}, "
        f"retry limit {options.retry_limit}",
        f"- outcomes: " + ", ".join(f"{k} {v}" for k, v in sorted(receipt["counts"].items())),
        f"- flaky (left out of comparisons): {len(receipt['flaky'])}",
        f"- ok: {receipt['ok']}",
    ]
    for cid in receipt["unexpected"][:50]:
        lines.append(f"  - unexpected: {cid} ({receipt['cases'][cid]['status']})")
    (options.out / "index.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------------------
# Loading, merging and comparing runs


@dataclass(frozen=True)
class CaseView:
    status: Optional[str]
    outcome: str
    flaky: bool
    checkpoints: Checkpoints


@dataclass(frozen=True)
class RunView:
    receipt: Dict[str, Any]
    cases: Dict[str, CaseView]
    shards: Tuple[int, ...]
    complete: bool


def read_run(directory: Path) -> Tuple[Dict[str, Any], Dict[str, Checkpoints]]:
    try:
        receipt = json.loads((directory / "receipt.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise UsageError(f"{directory}: no readable receipt.json ({error})") from None
    finals: Dict[str, Checkpoints] = {}
    path = directory / "checkpoints.jsonl"
    if path.is_file():
        for line in path.read_text(encoding="utf-8").splitlines():
            row = json.loads(line)
            if row.get("final"):
                finals[row["case"]] = tuple((c["step"], c["checkpoint"], c["hash"]) for c in row["checkpoints"])
    return receipt, finals


def merge_runs(directories: Sequence[Path], *, require_complete: bool) -> Tuple[RunView, List[str], Dict[str, Checkpoints]]:
    """Merges shard receipts; refuses a different config, a repeated shard or a case in two shards."""
    if not directories:
        raise UsageError("no run directories given")
    loaded = [read_run(d) for d in directories]
    errors: List[str] = []
    fingerprints = {r["fingerprint"] for r, _ in loaded}
    if len(fingerprints) > 1:
        errors.append("shard receipts have different configs: " + ", ".join(str(d) for d in directories))
    total = loaded[0][0]["config"]["shard_total"]
    owner: Dict[int, Path] = {}
    seen: Dict[str, Path] = {}
    cases: Dict[str, CaseView] = {}
    finals: Dict[str, Checkpoints] = {}
    for directory, (receipt, run_finals) in zip(directories, loaded):
        index = receipt["config"]["shard_index"]
        if index in owner:
            errors.append(f"shard {index}/{total} appears twice: {owner[index]} and {directory}")
            continue
        owner[index] = directory
        for cid, record in receipt["cases"].items():
            if cid in seen:
                errors.append(f"{cid} is in two shards: {seen[cid]} and {directory}")
            if shard_of(cid, total) != index:
                errors.append(f"{cid} ran in shard {index} but belongs to shard {shard_of(cid, total)}/{total}")
            seen[cid] = directory
            cps = run_finals.get(cid, ())
            finals[cid] = cps
            cases[cid] = CaseView(record.get("status"), record["outcome"], bool(record["flaky"]), cps)
    complete = sorted(owner) == list(range(total))
    if complete:
        selection_digest = loaded[0][0]["selection"]["digest"]
        if digest(sorted(seen)) != selection_digest:
            errors.append("the shards do not cover the selection: the union of shard cases differs from it")
    elif require_complete:
        missing = sorted(set(range(total)) - set(owner))
        errors.append(f"shards missing: {', '.join(f'{i}/{total}' for i in missing)}")
    merged = dict(loaded[0][0])
    merged["config"] = {**merged["config"], "shard_index": None}
    merged["merged_from"] = [str(d) for d in directories]
    merged["cases"] = {cid: rec for r, _ in loaded for cid, rec in r["cases"].items()}
    merged["order"] = [cid for r, _ in loaded for cid in r["order"]]
    merged["flaky"] = sorted(cid for cid, v in cases.items() if v.flaky)
    merged["unexpected"] = sorted(cid for cid, v in cases.items() if v.outcome == "unexpected")
    merged["infra_errors"] = [e for r, _ in loaded for e in r.get("infra_errors", [])]
    merged["ok"] = all(r["ok"] for r, _ in loaded) and not errors and complete
    return RunView(merged, cases, tuple(sorted(owner)), complete), errors, finals


def write_merged(view: RunView, finals: Dict[str, Checkpoints], out: Path) -> None:
    check_out_dir(out)
    out.mkdir(parents=True, exist_ok=True)
    receipt = dict(view.receipt)
    write_json(out / "receipt.json", receipt)
    write_jsonl(
        out / "checkpoints.jsonl",
        ({"case": cid, "iteration": 0, "attempt": 0, "status": view.cases[cid].status,
          "checkpoints": checkpoint_rows(cps), "final": True} for cid, cps in sorted(finals.items()) if cps or view.cases[cid].status),
    )


def first_difference(a: CaseView, b: CaseView) -> Dict[str, Any]:
    if a.status != b.status:
        return {"status": [a.status, b.status]}
    for index, (x, y) in enumerate(itertools.zip_longest(a.checkpoints, b.checkpoints)):
        if x != y:
            return {"index": index, "a": list(x) if x else None, "b": list(y) if y else None}
    return {}


def compare(a: RunView, b: RunView) -> Dict[str, Any]:
    """Case verdicts by status and checkpoint hashes. A flaky case on either side is never a match."""
    verdicts: Dict[str, Dict[str, Any]] = {}
    for cid in sorted(set(a.cases) | set(b.cases)):
        ca, cb = a.cases.get(cid), b.cases.get(cid)
        if ca is None or cb is None:
            verdicts[cid] = {"verdict": "not-comparable", "reason": "missing on " + ("a" if ca is None else "b")}
        elif "skipped" in (ca.outcome, cb.outcome) or "planned" in (ca.outcome, cb.outcome):
            verdicts[cid] = {"verdict": "not-comparable", "reason": f"outcomes {ca.outcome}/{cb.outcome}"}
        elif ca.flaky or cb.flaky:
            verdicts[cid] = {"verdict": "flaky", "side": "+".join(s for s, v in (("a", ca), ("b", cb)) if v.flaky)}
        elif (ca.status, ca.checkpoints) != (cb.status, cb.checkpoints):
            verdicts[cid] = {"verdict": "divergent", "first": first_difference(ca, cb)}
        else:
            verdicts[cid] = {"verdict": "match"}
    return verdicts


def summarize(verdicts: Dict[str, Dict[str, Any]], refused: Optional[str], shards: Tuple[Tuple[int, ...], bool]) -> Dict[str, Any]:
    counts: Dict[str, int] = {}
    for v in verdicts.values():
        counts[v["verdict"]] = counts.get(v["verdict"], 0) + 1
    divergent = sorted(cid for cid, v in verdicts.items() if v["verdict"] == "divergent")
    compared = counts.get("match", 0) + counts.get("explained", 0) + len(divergent)
    if compared == 0 and verdicts:
        # Every case flaky or not comparable is no evidence; it must not read as a pass.
        refused = refused or "nothing compared"
    return {
        "counts": counts,
        "compared": compared,
        "divergent": divergent,
        "flaky_excluded": sorted(cid for cid, v in verdicts.items() if v["verdict"] == "flaky"),
        "refused": refused,
        "shards": list(shards[0]),
        "complete": shards[1],
        "ok": refused is None and not divergent,
    }


def explain_with_diff_py(a_dir: Path, b_dir: Path, verdicts: Dict[str, Dict[str, Any]], out: Path) -> Tuple[Optional[str], str]:
    """Hands the divergent cases (never flaky ones) to diff.py for the first pointer and expected_differences."""
    script = HERE / "diff.py"
    if not script.is_file():
        return None, "absent (p15-oracle-014): divergences carry the first differing checkpoint only"
    cases_file = out / "divergent-cases.txt"
    cases_file.write_text("".join(cid + "\n" for cid, v in verdicts.items() if v["verdict"] == "divergent"), encoding="utf-8")
    target = out / "divergence.json"
    proc = subprocess.run(
        [sys.executable, "-I", str(script), "--a", str(a_dir), "--b", str(b_dir), "--cases", str(cases_file), "--out", str(target)],
        check=False,
    )
    if not target.is_file():
        raise UsageError(f"diff.py exited {proc.returncode} without writing {target}")
    report = json.loads(target.read_text(encoding="utf-8"))
    for row in report.get("cases", []):
        if verdicts.get(row["case"], {}).get("verdict") == "divergent":
            verdicts[row["case"]] = {"verdict": row["verdict"], "first": row.get("first")}
    return report.get("refused"), "used"


# ---------------------------------------------------------------------------------------
# Switch registry


def load_switch_registry(root: Path = SWITCH_REGISTRY) -> Dict[str, Dict[str, Any]]:
    entries: Dict[str, Dict[str, Any]] = {}
    if root.is_dir():
        for path in sorted(root.glob("*.json")):
            data = json.loads(path.read_text(encoding="utf-8"))
            entries[data.get("name", path.stem)] = data
    return entries


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
    parser.add_argument("--state-base", type=Path, default=DEFAULT_STATE_BASE)
    parser.add_argument("--flaky-out", type=Path, help="append flaky cases as JSON lines (MQ-flakes)")
    parser.add_argument("--dry-run", action="store_true", help="plan and write the receipt; run nothing")
    parser.add_argument("--run-id", help="default: UTC time plus 6 random characters")
    parser.add_argument("--json", action="store_true", help="print the receipt or comparison as JSON")


def new_run_id() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + base36(random.SystemRandom().randrange(36**6))


def options_from_args(args: argparse.Namespace, *, retry_default: Optional[int], out: Path, run_id: str,
                      switch: Optional[str], arm: Optional[str], switches: Dict[str, str],
                      ref: Optional[str], binary: Optional[str]) -> RunOptions:
    suites = tuple(parse_list(args.suite)) or ("all",)
    filters = tuple(parse_list(args.filter))
    seed = args.seed
    if args.shuffle and seed is None:
        seed = random.SystemRandom().randrange(1, 2**31)
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
    )
    if args.retry_limit is not None:
        retry = args.retry_limit
    elif retry_default is not None:
        retry = retry_default
    else:
        retry = 0 if options.filtered else DEFAULT_RETRY_LIMIT
    return replace(options, retry_limit=retry)


def dependency_state() -> Tuple[Dict[str, str], Any]:
    expectations = load_sibling("expectations")
    deps = {
        "expectations": "used" if expectations else "absent (p15-oracle-015): every case expects Pass",
        "diff": "present" if (HERE / "diff.py").is_file() else "absent (p15-oracle-014)",
    }
    return deps, expectations


def run_one(options: RunOptions, *, open_session: Optional[SessionOpener] = None) -> Tuple[Dict[str, Any], int]:
    cases, errors = load_corpus(options.corpus)
    if errors:
        raise UsageError("corpus errors (run `oracle.py check`):\n  " + "\n  ".join(errors[:20]))
    deps, expectations = dependency_state()
    lookup = expectations_lookup(expectations, platform=options.platform, arm=options.arm if options.arm in ARMS else None,
                                 product=options.product, build=options.build)
    if open_session is None and not options.dry_run:
        driver = load_sibling(f"driver_{options.product}")
        if driver is None:
            raise UsageError(f"driver_{options.product}.py is not on this branch yet ({DRIVER_TASKS[options.product]})")
        open_session = driver.open_session
    return perform_run(options, cases, open_session, lookup, deps)


def print_run(receipt: Dict[str, Any], options: RunOptions, as_json: bool) -> None:
    if as_json:
        print(json.dumps(receipt, indent=1, sort_keys=True))
        return
    index, total = options.shard
    print(f"oracle run {receipt['run_id']}: shard {index}/{total}, {len(receipt['order'])} of "
          f"{receipt['selection']['count']} cases, {receipt['batches']} batches, seed {options.seed}")
    print("  outcomes: " + (", ".join(f"{k} {v}" for k, v in sorted(receipt["counts"].items())) or "none"))
    if receipt["flaky"]:
        print(f"  flaky, left out of comparisons: {len(receipt['flaky'])}")
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


def diff_sides(args: argparse.Namespace, registry: Dict[str, Dict[str, Any]]) -> Tuple[Side, Side]:
    if args.base or args.head:
        if not (args.base and args.head):
            raise UsageError("--base and --head go together")
        if args.product not in RUST_PRODUCTS:
            raise UsageError(f"--product {args.product}: base/head builds on the VM are the cmux-tui products {sorted(RUST_PRODUCTS)}")
        base_bin = args.base_binary or build_daemon(args.base)
        head_bin = args.head_binary or build_daemon(args.head)
        return (Side("base", None, None, {}, args.base, base_bin), Side("head", None, None, {}, args.head, head_bin))
    if args.switch:
        return tuple(  # type: ignore[return-value]
            Side(arm, args.switch, arm, resolve_switches(registry, args.switch, arm), args.ref, args.binary) for arm in ARMS
        )
    if args.arm == "launch-config":
        return (
            Side("default", None, "default", {}, args.ref, args.binary),
            Side("launch-config", None, "launch-config", resolve_switches(registry, None, "launch-config"), args.ref, args.binary),
        )
    raise UsageError("diff needs --base/--head, --switch NAME, --arm launch-config, --base-run/--head-run or --baselines")


def baseline_view(head: RunView) -> RunView:
    baselines = load_sibling("baselines")
    if baselines is None:
        raise UsageError("baselines.py is not on this branch yet (p15-oracle-016)")
    config = head.receipt["config"]
    cases: Dict[str, CaseView] = {}
    for cid in head.cases:
        if baselines.suite_class(cid.split("/", 1)[0]) != "golden":
            continue
        cps = baselines.expected_checkpoints(cid, platform=config["platform"], arm=config.get("arm"), product=config["product"])
        if cps is not None:
            cases[cid] = CaseView("Pass", "expected", False, tuple((c["step"], c["checkpoint"], c["hash"]) for c in cps))
    return RunView({"config": config}, cases, head.shards, head.complete)


def finish_compare(a_view: RunView, b_view: RunView, a_dir: Optional[Path], b_dir: Optional[Path], out: Path,
                   labels: Tuple[str, str], as_json: bool) -> int:
    verdicts = compare(a_view, b_view)
    refused, diff_state = (None, "not used")
    if a_dir is not None and b_dir is not None and any(v["verdict"] == "divergent" for v in verdicts.values()):
        refused, diff_state = explain_with_diff_py(a_dir, b_dir, verdicts, out)
    if a_view.shards != b_view.shards:
        refused = refused or f"shard sets differ: {list(a_view.shards)} vs {list(b_view.shards)}"
    summary = summarize(verdicts, refused, (b_view.shards, a_view.complete and b_view.complete))
    comparison = {"schema": "cmux-oracle-comparison-v1", "a": labels[0], "b": labels[1], "diff_py": diff_state,
                  **summary, "verdicts": verdicts}
    write_json(out / "comparison.json", comparison)
    if diff_state != "used":
        write_json(out / "divergence.json", {"refused": refused, "cases": [
            {"case": cid, "verdict": v["verdict"], "first": v.get("first")} for cid, v in verdicts.items()
            if v["verdict"] == "divergent"]})
    if as_json:
        print(json.dumps(comparison, indent=1, sort_keys=True))
    else:
        counts = summary["counts"]
        print(f"oracle diff {labels[0]} vs {labels[1]}: compared {summary['compared']}, match {counts.get('match', 0)}, "
              f"explained {counts.get('explained', 0)}, divergent {len(summary['divergent'])}, "
              f"flaky (excluded) {len(summary['flaky_excluded'])}, not comparable {counts.get('not-comparable', 0)}")
        for cid in summary["divergent"][:20]:
            print(f"  divergent: {cid} {json.dumps(verdicts[cid].get('first'), sort_keys=True)}")
        if refused:
            print(f"  refused: {refused}")
        print(f"  comparison: {out / 'comparison.json'}")
    return 0 if summary["ok"] else 1


def cmd_diff(args: argparse.Namespace) -> int:
    out = args.out or DEFAULT_OUT_BASE / ("diff-" + new_run_id())
    check_out_dir(out)
    out.mkdir(parents=True, exist_ok=True)
    if args.head_run:
        head, head_errors, head_finals = merge_runs(args.head_run, require_complete=False)
        if args.baselines:
            if head_errors:
                raise UsageError("; ".join(head_errors))
            return finish_compare(baseline_view(head), head, None, None, out, ("baselines", "head"), args.json)
        if not args.base_run:
            raise UsageError("--head-run needs --base-run or --baselines")
        base, base_errors, base_finals = merge_runs(args.base_run, require_complete=False)
        if base_errors or head_errors:
            raise UsageError("; ".join(base_errors + head_errors))
        a_dir, b_dir = (args.base_run[0], args.head_run[0])
        if len(args.base_run) > 1 or len(args.head_run) > 1:
            a_dir, b_dir = out / "a-merged", out / "b-merged"
            write_merged(base, base_finals, a_dir)
            write_merged(head, head_finals, b_dir)
        return finish_compare(base, head, a_dir, b_dir, out, ("base", "head"), args.json)
    if args.product == "app":
        fleet = HERE / "fleet.py"
        if not fleet.is_file():
            raise UsageError("app diffs run on the fleet through fleet.py, not on this branch yet (p15-oracle-050)")
        return subprocess.run([sys.executable, "-I", str(fleet), "diff", *args.raw_argv], check=False).returncode
    registry = load_switch_registry()
    sides = diff_sides(args, registry)
    if args.switch and not args.suite:
        minimum = registry[args.switch].get("minimum_suites")
        if minimum:
            args.suite = [",".join(minimum)]
    run_id = args.run_id or new_run_id()
    views = []
    for side in sides:
        options = options_from_args(args, retry_default=DEFAULT_RETRY_LIMIT, out=out / side.label,
                                    run_id=f"{run_id}-{side.label}", switch=side.switch,
                                    arm=side.arm, switches=side.switches,
                                    ref=side.ref, binary=side.binary)
        receipt, _ = run_one(options)
        print_run(receipt, options, False)
        view, errors, _ = merge_runs([options.out], require_complete=False)
        if errors:
            raise UsageError("; ".join(errors))
        if receipt["arm_exercised"] is False:
            print(f"arm-not-exercised: {side.switch}={side.arm}")
            return 1
        views.append(view)
    return finish_compare(views[0], views[1], out / sides[0].label, out / sides[1].label, out,
                          (sides[0].label, sides[1].label), args.json)


def cmd_merge(args: argparse.Namespace) -> int:
    view, errors, finals = merge_runs(args.dirs, require_complete=True)
    for error in errors:
        print(f"merge: {error}", file=sys.stderr)
    if errors:
        return 1
    write_merged(view, finals, args.out)
    print(f"merged {len(args.dirs)} shards, {len(view.cases)} cases, each in one shard: {args.out / 'receipt.json'}")
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
    expectations = load_sibling("expectations")
    baselines = load_sibling("baselines")
    ids = set(by_id)
    if expectations is not None:
        store = expectations.load(REPO)
        golden = {cid for cid in ids if baselines and baselines.suite_class(cid.split("/", 1)[0]) == "golden"}
        errors.extend(f"expectations: {e}" for e in store.lint(ids, golden))
        if args.stale:
            errors.extend(f"stale: {e}" for e in store.stale(ids))
    elif args.stale:
        errors.append("stale: needs expectations.py (p15-oracle-015)")
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
        epilog="Delegated subcommands: " + ", ".join(f"{k} ({v[0]})" for k, v in DELEGATES.items()),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="run a selection of the corpus on one product and arm")
    add_selection_args(run)
    run.add_argument("--switch", help="refactor switch name (plans/cmux-next/refactor-switches)")
    run.add_argument("--arm", help="old or new with --switch; launch-config or default without")
    run.add_argument("--ref", help="source ref recorded in the receipt")
    run.add_argument("--out", type=Path, help=f"run directory (default {DEFAULT_OUT_BASE}/<run id>)")
    run.set_defaults(func=cmd_run)

    diff = sub.add_parser("diff", help="run two sides and compare them; flaky cases are left out")
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
    diff.add_argument("--out", type=Path, help="comparison directory")
    diff.set_defaults(func=cmd_diff)

    merge = sub.add_parser("merge", help="merge shard run directories; refuses a gap or an overlap")
    merge.add_argument("dirs", type=Path, nargs="+")
    merge.add_argument("--out", type=Path, required=True)
    merge.set_defaults(func=cmd_merge)

    check = sub.add_parser("check", help="schema, semantic and expectations lint of the corpus")
    check.add_argument("paths", type=Path, nargs="*", help="case files (default: the whole corpus)")
    check.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    check.add_argument("--coverage", action="store_true", help="per-suite coverage from each generator's coverage.json")
    check.add_argument("--stale", action="store_true", help="expectation lines that name no case")
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
