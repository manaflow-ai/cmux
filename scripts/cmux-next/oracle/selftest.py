#!/usr/bin/env python3
"""Self test of the oracle tooling: normalize, diff, expectations, baselines and the shard math (p15-oracle-019).

Run on the VM or a fleet mini (stdlib only, safe under `python3 -I`, no network):

    python3 -I scripts/cmux-next/oracle/selftest.py [-v] [-k PATTERN]... [--seed N]
    python3 -I scripts/cmux-next/oracle/oracle.py selftest [...]

Not in tests/test-execution.toml and not in CI: agents run it themselves (CLAUDE.md, 2026-10-23).

Two layers:
- Each module's own self test, run in process: normalize.py property cases, diff.py synthetic runs,
  expectations.py parser cases, baselines.py store cases, case_checks.py (when jsonschema is
  installed) and oracle_cli_test.py (shards, retries, flaky handling, the run format).
- Contracts between the modules that no single module tests: normalize's sha256 is the hash
  oracle.py writes and baselines.py stores; snapshots that differ only in raw ids compare equal
  through diff.py; the case-v1 mutation table gives its layer's result through normalize's
  stdlib validator (what `oracle.py check` runs on a mini without jsonschema); the checked-in
  Expectations.d, NeverFix.d and baselines lint clean; shard assignment is pinned, process
  independent and stable when cases are added (base/test/launcher/test_launcher.cc,
  ShouldRunInCurrentShard), and the shard plans cover the selection once.

KNOWN_RED lists module self-test cases that fail on the current base, each with its bug. It works
like a Blink `[ Failure ]` expectation: the case still runs, the failure is printed, and a pass is
an unexpected pass that fails this run, so the line is removed with the fix.

Exit: 0 when every test passes (known-red failures aside), 1 otherwise, 2 bad usage.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import hashlib
import importlib
import io
import json
import re
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import baselines  # noqa: E402
import case_checks  # noqa: E402
import diff  # noqa: E402
import expectations  # noqa: E402
import normalize  # noqa: E402
import oracle  # noqa: E402

TASK = "p15-oracle-019"
DEFAULT_SEED = 13

# "<module>.<case>" -> the bug that makes it fail on the base. A pass fails the run (unexpected pass).
KNOWN_RED: Dict[str, str] = {
    "normalize.real_schema_example": "snapshot-v1.schema.json (4542383d8a5, p15-oracle-011) uses x-oracle-decimal, "
    "x-oracle-open-keys and x-oracle-id-unpatterned, which normalize.py (p15-oracle-013) refuses as unknown keywords",
}

HOST = {"name": "selftest-host", "os": "Linux", "osVersion": "6.0", "arch": "x86_64"}


# ---------------------------------------------------------------------------------------------- network


class NetworkRefused(RuntimeError):
    """The self test ran code that opened an IP connection or resolved a name."""


@contextlib.contextmanager
def no_network() -> Iterator[None]:
    """Refuses IP connects and name lookups in this process for the whole run (AF_UNIX stays allowed)."""

    real_connect, real_connect_ex = socket.socket.connect, socket.socket.connect_ex
    real_getaddrinfo, real_gethostbyname = socket.getaddrinfo, socket.gethostbyname

    def guarded(real: Callable[..., Any]) -> Callable[..., Any]:
        def connect(sock: socket.socket, address: Any) -> Any:
            if sock.family in (socket.AF_INET, socket.AF_INET6):
                raise NetworkRefused(f"selftest opened a network connection to {address!r}")
            return real(sock, address)

        return connect

    def lookup(*args: Any, **kwargs: Any) -> Any:
        raise NetworkRefused(f"selftest resolved a host name: {args[:1]!r}")

    socket.socket.connect, socket.socket.connect_ex = guarded(real_connect), guarded(real_connect_ex)
    socket.getaddrinfo = socket.gethostbyname = lookup
    try:
        yield
    finally:
        socket.socket.connect, socket.socket.connect_ex = real_connect, real_connect_ex
        socket.getaddrinfo, socket.gethostbyname = real_getaddrinfo, real_gethostbyname


# ------------------------------------------------------------------------------------------- inner counts


@dataclass
class Inner:
    """The result of one module self test that counts its own cases."""

    module: str
    passed: int = 0
    total: int = 0
    known_red: List[str] = field(default_factory=list)
    skipped: Optional[str] = None


INNER: Dict[str, Inner] = {}
SETTINGS = {"seed": DEFAULT_SEED}


def captured(fn: Callable[[], Any]) -> Tuple[Any, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        value = fn()
    return value, out.getvalue()


def judge_cases(test: unittest.TestCase, module: str, outcomes: Dict[str, Optional[str]], output: str) -> Inner:
    """outcomes: case name -> None (pass) or its failure text. Applies KNOWN_RED and records the counts."""
    inner = Inner(module, total=len(outcomes))
    unexpected: List[str] = []
    for name, failure in outcomes.items():
        key = f"{module}.{name}"
        if failure is None and key in KNOWN_RED:
            unexpected.append(f"{key} passed: remove its KNOWN_RED entry ({KNOWN_RED[key]})")
        elif failure is None:
            inner.passed += 1
        elif key in KNOWN_RED:
            inner.known_red.append(key)
        else:
            unexpected.append(f"{key}: {failure}")
    INNER[module] = inner
    if unexpected:
        test.fail("\n".join(unexpected) + "\n--- module output ---\n" + output[-4000:])
    return inner


def run_unittest_cases(cases: Sequence[type]) -> Tuple[unittest.TestResult, List[str], str]:
    loader = unittest.TestLoader()
    suite = unittest.TestSuite(loader.loadTestsFromTestCase(case) for case in cases)
    names = [test.id().rsplit(".", 1)[-1] for test in _flatten(suite)]
    stream = io.StringIO()
    with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    return result, names, stream.getvalue()


def unittest_outcomes(result: unittest.TestResult, names: Sequence[str]) -> Dict[str, Optional[str]]:
    """Per test method: None when it passed or was skipped, else its traceback."""
    failed = {test.id().rsplit(".", 1)[-1]: text for test, text in (*result.failures, *result.errors)}
    return {name: failed.get(name) for name in names}


def runner_outcomes(output: str) -> Dict[str, Optional[str]]:
    """Per test of a module that runs its own TextTestRunner: from its `Ran N` and `FAIL:`/`ERROR:` lines."""
    ran = re.search(r"^Ran (\d+) tests?", output, re.MULTILINE)
    if ran is None:
        return {}
    failed = re.findall(r"^(?:FAIL|ERROR): (\w+)", output, re.MULTILINE)
    outcomes: Dict[str, Optional[str]] = {f"passed-{i}": None for i in range(int(ran.group(1)) - len(failed))}
    outcomes.update({name: "failed" for name in failed})
    return outcomes


# -------------------------------------------------------------------------------------- module self tests


class ModuleSelftests(unittest.TestCase):
    """Each module's own self test, in this process, with its own case count."""

    def test_normalize_property_cases(self) -> None:
        code, output = captured(lambda: normalize.selftest(SETTINGS["seed"], sys.stdout))
        outcomes: Dict[str, Optional[str]] = {}
        for line in output.splitlines():
            ok = re.match(r"^ok \d+ (\w+)$", line)
            bad = re.match(r"^FAIL \d+ (\w+): (.*)$", line)
            if ok:
                outcomes[ok.group(1)] = None
            elif bad:
                outcomes[bad.group(1)] = bad.group(2)
        self.assertRegex(output, r"\d+/\d+ property cases passed", output[-2000:])
        self.assertGreaterEqual(len(outcomes), 30, "normalize.py promises at least 30 property cases")
        judge_cases(self, "normalize", outcomes, output)
        if not INNER["normalize"].known_red:
            self.assertEqual(code, 0, output[-2000:])

    def test_diff_synthetic_runs(self) -> None:
        result, names, output = run_unittest_cases([diff.DiffSelfTest])
        judge_cases(self, "diff", unittest_outcomes(result, names), output)
        self.assertEqual(result.testsRun, INNER["diff"].total)

    def test_expectations_parser_and_verdicts(self) -> None:
        code, output = captured(expectations._selftest)
        summary = re.search(r"expectations selftest: (\d+)/(\d+) passed", output)
        self.assertIsNotNone(summary, output[-2000:])
        failed = re.findall(r"^FAIL (.+)$", output, re.MULTILINE)
        passed, total = int(summary.group(1)), int(summary.group(2))
        outcomes: Dict[str, Optional[str]] = {f"passed-{i}": None for i in range(passed)}
        outcomes.update({name.replace(" ", "_"): "failed" for name in failed})
        self.assertEqual(len(outcomes), total, output[-2000:])
        judge_cases(self, "expectations", outcomes, output)
        self.assertEqual(code, 0 if not failed else 1)

    def test_baselines_store(self) -> None:
        code, output = captured(baselines.selftest)
        outcomes = runner_outcomes(output)
        self.assertTrue(outcomes, output[-2000:])
        judge_cases(self, "baselines", outcomes, output)
        self.assertEqual(code, 0, output[-2000:])

    def test_oracle_cli(self) -> None:
        cli = importlib.import_module("oracle_cli_test")
        cases = [value for value in vars(cli).values()
                 if isinstance(value, type) and issubclass(value, unittest.TestCase) and value.__module__ == cli.__name__]
        self.assertTrue(cases)
        result, names, output = run_unittest_cases(cases)
        judge_cases(self, "oracle_cli_test", unittest_outcomes(result, names), output)
        self.assertEqual(result.testsRun, INNER["oracle_cli_test"].total)

    def test_case_checks_with_jsonschema(self) -> None:
        try:
            importlib.import_module("jsonschema")
        except ImportError:
            INNER["case_checks"] = Inner("case_checks", skipped="jsonschema is not installed")
            self.skipTest("jsonschema is not installed; CaseSchemaContract covers the table with the stdlib validator")
        schema = json.loads(case_checks.SCHEMA.read_text(encoding="utf-8"))
        code, output = captured(lambda: case_checks.selftest(schema, case_checks.Rules(schema)))
        summary = re.search(r"selftest: (\d+)/(\d+) pass", output)
        self.assertIsNotNone(summary, output[-2000:])
        INNER["case_checks"] = Inner("case_checks", int(summary.group(1)), int(summary.group(2)))
        self.assertEqual(code, 0, output[-2000:])


# --------------------------------------------------------------------------------------------- shard math


def case_ids(count: int, prefix: str = "") -> List[str]:
    suites = ("daemon-ops", "actions", "journeys", "terminal", "streams")
    return [f"{suites[i % len(suites)]}/{prefix}case-{i:05d}" for i in range(count)]


def make_cases(ids: Sequence[str]) -> List[Any]:
    return [oracle.Case(cid, oracle.split_case_id(cid)[0], Path(f"{cid}.json"), {"id": cid}) for cid in ids]


class ShardMath(unittest.TestCase):
    """oracle.py's shard assignment and plans (Chrome's PersistentHash(name) % total)."""

    # A change here moves cases between shards, so shard receipts of two oracle.py versions stop merging.
    PINNED = {
        "daemon-ops/workspace/create": (1, 2, 3, 5, 3, 3, 23),
        "actions/palette/open": (0, 2, 2, 2, 6, 14, 6),
        "journeys/split/basic": (1, 1, 3, 1, 7, 7, 43),
        "terminal/vt-00": (1, 0, 3, 3, 7, 15, 55),
        "streams/events/fold": (1, 1, 3, 1, 3, 3, 19),
    }
    TOTALS = (2, 3, 4, 6, 8, 16, 100)

    def test_assignment_is_pinned(self) -> None:
        for cid, expected in self.PINNED.items():
            self.assertEqual(tuple(oracle.shard_of(cid, total) for total in self.TOTALS), expected, cid)

    def test_one_shard_takes_everything(self) -> None:
        self.assertEqual({oracle.shard_of(cid, 1) for cid in case_ids(500)}, {0})

    def test_every_case_lands_in_one_valid_shard(self) -> None:
        ids = case_ids(3000)
        for total in range(1, 33):
            shards = [oracle.shard_of(cid, total) for cid in ids]
            self.assertTrue(all(0 <= s < total for s in shards), total)
            groups = [{cid for cid, s in zip(ids, shards) if s == index} for index in range(total)]
            self.assertEqual(sum(map(len, groups)), len(ids), total)
            self.assertEqual(set().union(*groups), set(ids), total)

    def test_adding_cases_moves_no_other_case(self) -> None:
        old = case_ids(1000)
        grown = old + case_ids(300, prefix="new-")
        for total in (3, 8, 13):
            before = {cid: oracle.shard_of(cid, total) for cid in old}
            after = {cid: oracle.shard_of(cid, total) for cid in grown}
            self.assertEqual({cid: after[cid] for cid in old}, before, total)

    def test_shards_are_balanced(self) -> None:
        ids = case_ids(20000)
        for total in (4, 8, 16):
            sizes = [0] * total
            for cid in ids:
                sizes[oracle.shard_of(cid, total)] += 1
            mean = len(ids) / total
            self.assertLess(max(abs(size - mean) for size in sizes) / mean, 0.10, (total, sizes))

    def test_assignment_does_not_depend_on_the_process(self) -> None:
        # `python3 -I` randomizes str hashes per process; the shard must not follow them.
        ids = case_ids(64)
        program = ("import json, sys; sys.path.insert(0, sys.argv[1]); import oracle; "
                   "print(json.dumps([oracle.shard_of(c, 7) for c in json.loads(sys.argv[2])]))")
        here = [oracle.shard_of(cid, 7) for cid in ids]
        for _ in range(2):
            proc = subprocess.run([sys.executable, "-I", "-c", program, str(HERE), json.dumps(ids)],
                                  check=True, capture_output=True, text=True, timeout=60)
            self.assertEqual(json.loads(proc.stdout), here)

    def test_plans_over_all_shards_cover_the_selection_once(self) -> None:
        selected = make_cases(case_ids(257))
        for total in (1, 4, 7):
            for seed in (None, 99):
                plans = [oracle.make_plan(selected, shard=(index, total), seed=None if seed is None else seed + index,
                                          batch_limit=5)
                         for index in range(total)]
                orders = [[case.id for case in plan.order] for plan in plans]
                flat = [cid for order in orders for cid in order]
                self.assertEqual(len(flat), len(set(flat)), (total, seed))
                self.assertEqual(set(flat), {case.id for case in selected}, (total, seed))
                for index, plan in enumerate(plans):
                    self.assertEqual(plan.selection, tuple(sorted(case.id for case in selected)))
                    self.assertTrue(all(oracle.shard_of(cid, total) == index for cid in orders[index]))
                    self.assertTrue(all(1 <= len(batch) <= 5 for batch in plan.batches))
                    self.assertEqual([case.id for batch in plan.batches for case in batch], orders[index])
                    if seed is None:
                        self.assertEqual(orders[index], sorted(orders[index]))

    def test_shuffle_is_seeded_per_shard(self) -> None:
        selected = make_cases(case_ids(200))
        plan = lambda seed: [c.id for c in oracle.make_plan(selected, shard=(1, 3), seed=seed, batch_limit=10).order]  # noqa: E731
        self.assertEqual(plan(7), plan(7))
        self.assertNotEqual(plan(7), plan(8))
        self.assertEqual(sorted(plan(7)), plan(None))

    def test_more_shards_than_cases(self) -> None:
        selected = make_cases(case_ids(3))
        plans = [oracle.make_plan(selected, shard=(index, 50), seed=None, batch_limit=10) for index in range(50)]
        self.assertEqual(sum(len(plan.order) for plan in plans), 3)
        self.assertTrue(all(plan.batches == () for plan in plans if not plan.order))

    def test_shard_argument_bounds(self) -> None:
        self.assertEqual(oracle.parse_shard("0/1"), (0, 1))
        self.assertEqual(oracle.parse_shard("99/100"), (99, 100))
        for bad in ("1/1", "100/100", "-1/2", "0/-1", "1/2/3", "", "x/2"):
            with self.assertRaises(oracle.UsageError, msg=bad):
                oracle.parse_shard(bad)


# ------------------------------------------------------------------------------- normalize, diff, baselines


def selftest_schema() -> Any:
    return normalize.Schema(normalize.SELFTEST_SCHEMA, "<selftest schema>", contract=True)


def raw_snapshot(ids: Dict[str, str], order: Sequence[str] = ("a", "b"), reverse_keys: bool = False) -> Dict[str, Any]:
    """A two-pane workspace in the selftest schema's shape with raw ids; only `order` is behavior."""
    panes = {ids[name]: {"workspace": ids["s"], "title": title} for name, title in (("a", "Ünïcødé ✓"), ("b", "plain"))}
    doc = {"windows": [{"id": ids["w"], "workspaces": [{"id": ids["s"], "panes": [ids[name] for name in order]}]}],
           "panes": panes}
    if reverse_keys:
        doc = json.loads(json.dumps(doc), object_pairs_hook=lambda pairs: dict(reversed(pairs)))
    return doc


IDS_A = {"w": "w-1", "s": "s-1", "a": "p-1", "b": "p-2"}
IDS_B = {"w": "w-zz", "s": "s-9f", "a": "p-77", "b": "p-03"}


def write_diff_run(root: Path, name: str, cases: Dict[str, List[Tuple[str, str, Any]]]) -> Path:
    """A run directory in diff.py's format from canonical (step, checkpoint, Result) checkpoints."""
    run = root / name
    run.mkdir(parents=True)
    rows = []
    for cid, points in cases.items():
        steps: List[str] = []
        for step, checkpoint, result in points:
            if step not in steps:
                steps.append(step)
            rows.append({"case": cid, "step": step, "index": steps.index(step), "checkpoint": checkpoint,
                         "snapshot": result.value, "sha256": result.sha256})
    receipt = {"runId": name, "sha": f"{name}-sha", "host": HOST, "cases": {cid: {"result": "Pass"} for cid in cases}}
    (run / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
    (run / "checkpoints.jsonl").write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
    return run


def run_diff(a: Path, b: Path, out: Path) -> Tuple[int, Dict[str, Any]]:
    code, _ = captured(lambda: diff.main([str(a), str(b), "--out", str(out)]))
    return code, json.loads(out.read_text(encoding="utf-8"))


class CanonicalDriver:
    """oracle.py driver protocol: every case returns the given canonical checkpoints."""

    def __init__(self, checkpoints: List[Dict[str, Any]]) -> None:
        self.checkpoints = checkpoints

    def open_session(self, ctx: Dict[str, Any]) -> "CanonicalDriver":
        return self

    def run_case(self, case: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
        return {"status": "Pass", "checkpoints": copy.deepcopy(self.checkpoints)}

    def close(self) -> None:
        pass


def run_options(tmp: Path, out: Path) -> Any:
    return oracle.RunOptions(
        product="daemon", suites=("all",), filters=(), shard=(0, 1), jobs=2, batch_limit=1, repeat=1, retry_limit=0,
        seed=None, platform="linux", build="debug", switch=None, arm=None, switches={}, ref=None, tag=None, binary=None,
        corpus=tmp / "corpus", out=out, state_base=Path("/tmp/o"), run_id="selftest", expectations_root=tmp / "none",
    )


class HashAndDiffContract(unittest.TestCase):
    """normalize.py output is what oracle.py hashes, diff.py compares and baselines.py stores."""

    def setUp(self) -> None:
        self.schema = selftest_schema()
        holder = tempfile.TemporaryDirectory(prefix="oracle-selftest-")
        self.addCleanup(holder.cleanup)
        self.tmp = Path(holder.name)

    def norm(self, doc: Any) -> Any:
        return normalize.canonicalize(doc, self.schema)

    def test_normalize_hash_is_the_runner_hash(self) -> None:
        for doc in (raw_snapshot(IDS_A), raw_snapshot(IDS_B, order=("b", "a")), {"windows": [], "panes": {}}):
            result = self.norm(doc)
            self.assertEqual(result.text, normalize.canonical_json(result.value))
            self.assertEqual(result.sha256, hashlib.sha256(result.text.encode("utf-8")).hexdigest())
            self.assertEqual(result.sha256, oracle.snapshot_sha256(result.value))
            self.assertEqual(json.loads(result.text), result.value)

    def test_raw_ids_and_key_order_do_not_reach_the_hash(self) -> None:
        a = self.norm(raw_snapshot(IDS_A))
        b = self.norm(raw_snapshot(IDS_B, reverse_keys=True))
        self.assertEqual(a.sha256, b.sha256)
        self.assertNotEqual(a.sha256, self.norm(raw_snapshot(IDS_A, order=("b", "a"))).sha256)

    def test_renamed_ids_compare_equal_through_diff(self) -> None:
        steps = lambda ids, order: [("create", "before", self.norm({"windows": [], "panes": {}})),  # noqa: E731
                                    ("split", "settled", self.norm(raw_snapshot(ids, order)))]
        base = write_diff_run(self.tmp, "base", {"journeys/split/basic": steps(IDS_A, ("a", "b"))})
        head = write_diff_run(self.tmp, "head", {"journeys/split/basic": steps(IDS_B, ("a", "b"))})
        code, report = run_diff(base, head, self.tmp / "same.json")
        self.assertEqual((code, report["verdict"], report["summary"]["equal"]), (diff.EXIT_OK, "pass", 1), report)

        moved = write_diff_run(self.tmp, "moved", {"journeys/split/basic": steps(IDS_B, ("b", "a"))})
        code, report = run_diff(base, moved, self.tmp / "moved.json")
        self.assertEqual((code, report["verdict"]), (diff.EXIT_DIVERGENT, "divergent"), report)
        first = report["divergences"][0]
        self.assertEqual((first["step"], first["checkpoint"]), ("split", "settled"), first)
        self.assertTrue(first["pointer"].startswith("/windows/0/workspaces/0/panes/"), first)

    def test_oracle_run_and_rebaseline_keep_the_normalize_hash(self) -> None:
        settled = self.norm(raw_snapshot(IDS_A))
        before = self.norm({"windows": [], "panes": {}})
        driver = CanonicalDriver([{"step": "create", "checkpoint": "before", "snapshot": before.value},
                                  {"step": "split", "checkpoint": "settled", "snapshot": settled.value}])
        corpus = self.tmp / "corpus" / "journeys" / "split"
        corpus.mkdir(parents=True)
        (corpus / "basic.json").write_text(json.dumps({"id": "journeys/split/basic", "steps": []}), encoding="utf-8")
        cases, errors = oracle.load_corpus(self.tmp / "corpus")
        self.assertEqual(errors, [])
        run = self.tmp / "run"
        captured(lambda: oracle.perform_run(run_options(self.tmp, run), cases, driver.open_session, None, {}))
        rows = [json.loads(line) for line in (run / "checkpoints.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual([row["sha256"] for row in rows], [before.sha256, settled.sha256])

        # The two steps of `oracle.py rebaseline`, in process.
        root, converted = self.tmp / "baselines", self.tmp / "rebaseline-run"
        self.assertEqual(oracle.write_rebaseline_run(run, converted), 0)
        written = baselines.rebaseline(baselines.Store(root), converted, only_changed=False, platform=None)
        self.assertEqual((written["written"], written["refused"]), (["journeys/split/basic"], []), written)
        found = baselines.Store(root).lookup("journeys", "split/basic", baselines.platform_dir("linux", "daemon"), None)
        self.assertIsNotNone(found)
        stored = [json.loads(line) for line in found[1].read_text(encoding="utf-8").splitlines()]
        self.assertEqual([(line["sha256"], line["snapshot"]) for line in stored],
                         [(before.sha256, before.value), (settled.sha256, settled.value)])
        self.assertEqual(baselines.check(baselines.Store(root))["errors"], [])


class CaseSchemaContract(unittest.TestCase):
    """case-v1 through normalize's stdlib validator plus case_checks: what `oracle.py check` runs with no jsonschema."""

    def test_mutation_table_without_jsonschema(self) -> None:
        schema = json.loads(case_checks.SCHEMA.read_text(encoding="utf-8"))
        rules = case_checks.Rules(schema)
        table = json.loads(case_checks.MUTATIONS.read_text(encoding="utf-8"))
        bases: Dict[str, Any] = {}
        for name in sorted({m["base"] for m in table["mutations"]}):
            bases[name] = json.loads((case_checks.MUTATIONS.parent / name).read_text(encoding="utf-8"))
            self.assertEqual(normalize.validate(bases[name], schema), [], name)
            self.assertEqual([f.message for f in case_checks.check_case(bases[name], rules)], [], name)
        layers: Dict[str, int] = {}
        for mutation in table["mutations"]:
            with self.subTest(mutation["name"]):
                case = case_checks.apply_patch(bases[mutation["base"]], mutation["patch"])
                errors = normalize.validate(case, schema)
                messages = [f.message for f in case_checks.check_case(case, rules)]
                layer = mutation["layer"]
                layers[layer] = layers.get(layer, 0) + 1
                if layer == "valid":
                    self.assertEqual((errors, messages), ([], []))
                elif layer == "schema":
                    pointer = mutation["pointer"]
                    self.assertTrue(any(e == pointer or e.startswith(f"{pointer}:") or e.startswith(f"{pointer}/")
                                        for e in errors), (pointer, errors))
                else:
                    self.assertEqual((errors, messages), ([], [mutation["error"]]))
        self.assertEqual(set(layers), {"valid", "schema", "x-oracle"}, layers)
        INNER["case-v1 table"] = Inner("case-v1 table", len(table["mutations"]) + len(bases),
                                       len(table["mutations"]) + len(bases))

    def test_duplicate_step_id_error_names_the_step(self) -> None:
        schema = json.loads(case_checks.SCHEMA.read_text(encoding="utf-8"))
        case = json.loads((case_checks.MUTATIONS.parent / "case-example-app.json").read_text(encoding="utf-8"))
        case["steps"][1]["id"] = case["steps"][0]["id"]
        step = case["steps"][0]["id"]
        self.assertEqual([f.message for f in case_checks.check_case(case, case_checks.Rules(schema))],
                         [f'duplicate step id "{step}": /steps/1/id repeats /steps/0/id'])


class CheckedInData(unittest.TestCase):
    """The repository's expectations and baselines lint clean with the tools that read them."""

    def test_expectations_and_neverfix_lint_clean(self) -> None:
        loaded = expectations.Expectations.load_root(expectations.DEFAULT_ROOT)
        corpus = expectations.DEFAULT_ROOT / "corpus"
        errors = [d.render() for d in expectations.lint(loaded, corpus if corpus.is_dir() else None)
                  if d.severity == "error"]
        self.assertEqual(errors, [])

    def test_baselines_check_clean(self) -> None:
        self.assertEqual(baselines.check(baselines.Store(baselines.DEFAULT_ROOT))["errors"], [])

    def test_every_baseline_suite_is_golden(self) -> None:
        for suite, kind in baselines.SUITE_CLASSES.items():
            if kind == baselines.DIFFERENTIAL:
                self.assertFalse((baselines.DEFAULT_ROOT / suite).exists(), f"{suite} is differential: no baselines")


class NoNetwork(unittest.TestCase):
    def test_the_guard_refuses_ip_connections(self) -> None:
        with self.assertRaises(NetworkRefused):
            socket.create_connection(("127.0.0.1", 9), timeout=1)
        with self.assertRaises(NetworkRefused):
            socket.getaddrinfo("example.com", 443)


# -------------------------------------------------------------------------------------------------- runner


GROUPS: Tuple[type, ...] = (ModuleSelftests, ShardMath, HashAndDiffContract, CaseSchemaContract, CheckedInData, NoNetwork)


def build_suite(patterns: Sequence[str]) -> unittest.TestSuite:
    loader = unittest.TestLoader()
    if patterns:
        loader.testNamePatterns = [p if "*" in p else f"*{p}*" for p in patterns]
    return unittest.TestSuite(loader.loadTestsFromTestCase(group) for group in GROUPS)


def report(result: unittest.TestResult, tests: Sequence[unittest.TestCase], spent: float) -> None:
    bad = {test.id() for test, _ in (*result.failures, *result.errors)}
    skipped = {test.id() for test, _ in result.skipped}
    print(f"\noracle selftest ({TASK})")
    for group in GROUPS:
        ids = [t.id() for t in tests if type(t) is group]
        if ids:
            failed = sum(i in bad for i in ids)
            skip = sum(i in skipped for i in ids)
            print(f"  {group.__name__:<22} {len(ids) - failed - skip:>3} passed  {failed:>2} failed  {skip:>2} skipped")
    if INNER:
        print("  inner cases:")
        for inner in INNER.values():
            if inner.skipped:
                print(f"    {inner.module:<18} skipped ({inner.skipped})")
            else:
                red = f", {len(inner.known_red)} known red" if inner.known_red else ""
                print(f"    {inner.module:<18} {inner.passed}/{inner.total} passed{red}")
    known = [key for inner in INNER.values() for key in inner.known_red]
    for key in known:
        print(f"  KNOWN RED {key}: {KNOWN_RED[key]}")
    inner_total = sum(inner.total for inner in INNER.values())
    print(f"selftest: {result.testsRun} tests ({inner_total} inner cases), {len(bad)} failed, {len(skipped)} skipped, "
          f"{len(known)} known red, {spent:.1f} s")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Self test of the oracle tooling (stdlib, no network).")
    parser.add_argument("-v", "--verbose", action="store_true", help="print each test")
    parser.add_argument("-k", dest="patterns", action="append", default=[], help="only tests matching this pattern")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="normalize.py property-case seed")
    args = parser.parse_args(argv)
    SETTINGS["seed"] = args.seed
    INNER.clear()
    suite = build_suite(args.patterns)
    tests = list(_flatten(suite))
    if not tests:
        print(f"selftest: no test matches {args.patterns}", file=sys.stderr)
        return 2
    began = time.monotonic()
    with no_network():
        result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2 if args.verbose else 1).run(suite)
    report(result, tests, time.monotonic() - began)
    return 0 if result.wasSuccessful() else 1


def _flatten(suite: unittest.TestSuite) -> Iterator[unittest.TestCase]:
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from _flatten(item)
        else:
            yield item


if __name__ == "__main__":
    sys.exit(main())
