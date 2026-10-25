#!/usr/bin/env python3
"""Oracle baseline store: Blink two-pass fallback, rebaseline from a run, optimize, suite classes.

Stdlib only and safe under `python3 -I` (fleet minis have no third-party packages).
Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D and 3E, task 016.

Chrome reference:
  third_party/blink/web_tests/ and docs/testing/web_test_baseline_fallback.md (two passes: the virtual
  name along the platform path, then the base name along the platform path);
  third_party/blink/tools/blinkpy/common/checkout/baseline_optimizer.py (`blink_tool.py optimize-baselines`:
  drop a baseline when every configuration that reads it reads the same bytes without it);
  third_party/blink/tools/blinkpy/tool/commands/rebaseline.py (`rebaseline-cl` copies actual results).

Layout under tests/oracle/baselines (the Blink web_tests root layout, `virtual/<v>` renamed `arm/<arm>`):
  <suite>/<case>.expected.jsonl                              generic
  platform/<p>/<suite>/<case>.expected.jsonl                 platform, or platform-product (`mac-app`)
  arm/<arm>/<suite>/<case>.expected.jsonl                    arm (switch arm, `motion-on`, ...)
  platform/<p>/arm/<arm>/<suite>/<case>.expected.jsonl       platform arm
A platform dir is `<platform>` or `<platform>-<product>`; `mac-app` falls back to `mac`.
Lookup for (platform-product, arm) on one case:
  pass 1: platform/mac-app/arm/A -> platform/mac/arm/A -> arm/A
  pass 2: platform/mac-app       -> platform/mac       -> <generic>
so a generic arm baseline beats a platform base baseline, as in Blink.

Suite classes (3D). Differential suites compare base == head (or arm == arm, product == product): the base
run is the oracle, so they never get a reviewed baseline. `rebaseline` refuses them, `lookup` raises and
`check` reports any baseline file under one.

Run directory read by `rebaseline --run DIR` (written by oracle.py run, task 017):
  receipt.json       {"platform": "linux", "product": "daemon", "arm": null | "NAME",
                      "cases": [{"suite": S, "case": C, "flaky": bool}, ...]}   (cases optional)
  checkpoints.jsonl  one object per checkpoint, in step order:
                      {"suite", "case", "step", "checkpoint", "result", "sha256", "snapshot",
                       "attempt"?, "uncertain"?, "notComparable"?: [facet, ...]}
  `snapshot` is already canonical (normalize.py, task 013, computes `sha256` over its canonical JSON); this
  store compares by that hash and never re-canonicalizes.
A case is written only when every checkpoint is certain: result Pass or Failure (Failure is a mismatch with the
current baseline, which is what a rebaseline replaces), a snapshot and a sha256, not flagged uncertain, no
not-comparable facet, not flaky in the receipt, and every attempt of it gives the same hashes. Timeout, Crash,
Skip, Slow-without-snapshot and anything else refuse the whole case, so a baseline never holds a partial run.

Usage:
  baselines.py lookup SUITE CASE [--platform P] [--product X] [--arm A]
  baselines.py rebaseline --run DIR [--only-changed] [--platform [DIR]]
  baselines.py optimize [--suite S] [--dry-run]
  baselines.py check
  baselines.py selftest
Every command takes --root (default tests/oracle/baselines of this checkout) and prints one JSON report.
Exit: 0 ok; 1 refused cases or check errors; 2 bad usage or a malformed run.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_ROOT = REPO_ROOT / "tests" / "oracle" / "baselines"
SUFFIX = ".expected.jsonl"

GOLDEN = "golden"
DIFFERENTIAL = "differential"

# Section 3D of the spec. One table; a new suite is classified here before it can have baselines.
SUITE_CLASSES: dict[str, str] = {
    "daemon-ops": DIFFERENTIAL,
    "reads": DIFFERENTIAL,
    "streams": DIFFERENTIAL,
    "api-compat": DIFFERENTIAL,
    "cli": DIFFERENTIAL,
    "mcp": DIFFERENTIAL,
    "actions": DIFFERENTIAL,
    "entrypoints": DIFFERENTIAL,
    "tui": DIFFERENTIAL,
    "walks": DIFFERENTIAL,
    "crash": DIFFERENTIAL,
    "fuzz": DIFFERENTIAL,
    "config": DIFFERENTIAL,
    "journals": DIFFERENTIAL,
    "upgrades": GOLDEN,
    "terminal": GOLDEN,
    "pane-protocol": GOLDEN,
    "journeys": GOLDEN,
    "tours": GOLDEN,
    "e2e": GOLDEN,
    "live": GOLDEN,
    "tla": GOLDEN,
    "ax": GOLDEN,
}

PLATFORMS = ("linux", "mac", "windows")
PRODUCTS = ("daemon", "app", "cli", "headless", "tui", "mcp")
CERTAIN_RESULTS = ("Pass", "Failure")
RESERVED_TOP = ("platform", "arm")

_SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._=+-]*$")
_ARM = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._=+-]*$")


class BaselineError(Exception):
    """A usage or input error: bad name, unknown suite, differential suite, malformed run."""


# --------------------------------------------------------------------------------------------- names


def suite_class(suite: str) -> str:
    cls = SUITE_CLASSES.get(suite)
    if cls is None:
        raise BaselineError(f"unknown suite {suite!r}: classify it in SUITE_CLASSES first")
    return cls


def require_golden(suite: str) -> None:
    if suite_class(suite) == DIFFERENTIAL:
        raise BaselineError(f"suite {suite!r} is differential: the base run is the oracle, no reviewed baseline")


def check_case_name(case: str) -> None:
    parts = case.split("/")
    if not case or any(not _SEGMENT.match(p) or p in (".", "..") or p.endswith(SUFFIX) for p in parts):
        raise BaselineError(f"bad case name {case!r}")


def check_arm(arm: str | None) -> None:
    if arm is not None and not _ARM.match(arm):
        raise BaselineError(f"bad arm name {arm!r}")


def platform_dir(platform: str, product: str | None = None) -> str:
    if platform not in PLATFORMS:
        raise BaselineError(f"unknown platform {platform!r}: one of {', '.join(PLATFORMS)}")
    if product is None:
        return platform
    if product not in PRODUCTS:
        raise BaselineError(f"unknown product {product!r}: one of {', '.join(PRODUCTS)}")
    return f"{platform}-{product}"


def platform_chain(pdir: str | None) -> list[str]:
    """Most specific first: `mac-app` -> [`mac-app`, `mac`]; None -> []."""
    if pdir is None:
        return []
    platform, _, product = pdir.partition("-")
    platform_dir(platform, product or None)
    return [pdir, platform] if product else [pdir]


# ------------------------------------------------------------------------------------------ locations


@dataclass(frozen=True)
class Location:
    """One baseline slot: platform dir (or None) and arm (or None)."""

    platform: str | None
    arm: str | None

    def relative(self, suite: str, case: str) -> Path:
        path = Path()
        if self.platform is not None:
            path = path / "platform" / self.platform
        if self.arm is not None:
            path = path / "arm" / self.arm
        return path / suite / (case + SUFFIX)

    def label(self) -> str:
        parts = []
        if self.platform is not None:
            parts.append(f"platform/{self.platform}")
        if self.arm is not None:
            parts.append(f"arm/{self.arm}")
        return "/".join(parts) or "generic"


def fallback_order(pdir: str | None, arm: str | None) -> list[Location]:
    """Blink two-pass order: the arm along the platform path, then the base along the platform path."""
    chain = platform_chain(pdir)
    check_arm(arm)
    order: list[Location] = []
    if arm is not None:
        order += [Location(p, arm) for p in chain]
        order.append(Location(None, arm))
    order += [Location(p, None) for p in chain]
    order.append(Location(None, None))
    return order


class Store:
    """The baseline tree. All reads and writes go through here; `root` is injected for tests."""

    def __init__(self, root: Path):
        self.root = root

    def path(self, loc: Location, suite: str, case: str) -> Path:
        return self.root / loc.relative(suite, case)

    def lookup(self, suite: str, case: str, pdir: str | None = None, arm: str | None = None):
        """Return (Location, Path) of the baseline this configuration reads, or None."""
        require_golden(suite)
        check_case_name(case)
        for loc in fallback_order(pdir, arm):
            path = self.path(loc, suite, case)
            if path.is_file():
                return loc, path
        return None

    def read(self, suite: str, case: str, pdir: str | None = None, arm: str | None = None) -> bytes | None:
        found = self.lookup(suite, case, pdir, arm)
        return found[1].read_bytes() if found else None

    def write(self, loc: Location, suite: str, case: str, data: bytes) -> bool:
        """Atomic write; False when the slot already holds these bytes."""
        path = self.path(loc, suite, case)
        if path.is_file() and path.read_bytes() == data:
            return False
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=SUFFIX)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
            os.replace(tmp, path)
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise
        return True

    def parse(self, path: Path):
        parts = list(path.relative_to(self.root).parts)
        pdir = arm = None
        if parts and parts[0] == "platform":
            if len(parts) < 4:
                raise BaselineError(f"{path}: platform baseline without suite/case")
            pdir = parts[1]
            platform_chain(pdir)
            parts = parts[2:]
        if parts and parts[0] == "arm":
            if len(parts) < 4:
                raise BaselineError(f"{path}: arm baseline without suite/case")
            arm = parts[1]
            check_arm(arm)
            parts = parts[2:]
        if len(parts) < 2 or parts[0] in RESERVED_TOP:
            raise BaselineError(f"{path}: not <suite>/<case>{SUFFIX}")
        suite = parts[0]
        case = "/".join(parts[1:])[: -len(SUFFIX)]
        suite_class(suite)
        check_case_name(case)
        return Location(pdir, arm), suite, case


# ---------------------------------------------------------------------------------------------- runs


def encode(lines: list[dict]) -> bytes:
    """Baseline bytes: one sorted-key compact JSON object per checkpoint."""
    out = []
    for line in lines:
        record = {
            "step": line["step"],
            "checkpoint": line.get("checkpoint"),
            "sha256": line["sha256"],
            "snapshot": line["snapshot"],
        }
        out.append(json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
    return ("\n".join(out) + "\n").encode("utf-8")


def uncertain_reason(line: dict) -> str | None:
    result = line.get("result")
    if result not in CERTAIN_RESULTS:
        return f"result {result!r}"
    if line.get("uncertain"):
        return "checkpoint marked uncertain"
    if line.get("notComparable"):
        return "not-comparable facets " + ",".join(map(str, line["notComparable"]))
    if "snapshot" not in line or line["snapshot"] is None:
        return "no snapshot"
    if not isinstance(line.get("sha256"), str) or not line["sha256"]:
        return "no sha256 (snapshot not normalized)"
    return None


@dataclass
class RunCase:
    suite: str
    case: str
    lines: list[dict] | None
    refused: str | None


def load_run(run: Path) -> tuple[dict, list[RunCase]]:
    try:
        receipt = json.loads((run / "receipt.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BaselineError(f"{run}/receipt.json: {error}") from error
    if not isinstance(receipt, dict):
        raise BaselineError(f"{run}/receipt.json: not an object")
    flaky = {
        (c.get("suite"), c.get("case"))
        for c in receipt.get("cases") or []
        if isinstance(c, dict) and c.get("flaky")
    }
    grouped: dict[tuple[str, str], dict[int, list[dict]]] = {}
    try:
        text = (run / "checkpoints.jsonl").read_text(encoding="utf-8")
    except OSError as error:
        raise BaselineError(f"{run}/checkpoints.jsonl: {error}") from error
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        try:
            line = json.loads(raw)
        except ValueError as error:
            raise BaselineError(f"checkpoints.jsonl:{number}: {error}") from error
        if not isinstance(line, dict) or not isinstance(line.get("suite"), str) or not isinstance(line.get("case"), str):
            raise BaselineError(f"checkpoints.jsonl:{number}: needs string suite and case")
        if "step" not in line:
            raise BaselineError(f"checkpoints.jsonl:{number}: needs step")
        attempt = line.get("attempt", 0)
        grouped.setdefault((line["suite"], line["case"]), {}).setdefault(attempt, []).append(line)

    cases = []
    for (suite, case), attempts in sorted(grouped.items()):
        cases.append(RunCase(suite, case, *_judge(suite, case, attempts, (suite, case) in flaky)))
    return receipt, cases


def _judge(suite: str, case: str, attempts: dict[int, list[dict]], flaky: bool):
    try:
        require_golden(suite)
        check_case_name(case)
    except BaselineError as error:
        return None, str(error)
    if flaky:
        return None, "flaky in receipt"
    for attempt, lines in attempts.items():
        for line in lines:
            reason = uncertain_reason(line)
            if reason:
                return None, f"attempt {attempt} step {line.get('step')!r}: {reason}"
    signatures = {tuple((l["step"], l.get("checkpoint"), l["sha256"]) for l in lines) for lines in attempts.values()}
    if len(signatures) > 1:
        return None, "attempts disagree (flaky)"
    first = attempts[min(attempts)]
    keys = [(l["step"], l.get("checkpoint")) for l in first]
    if len(set(keys)) != len(keys):
        return None, "duplicate (step, checkpoint)"
    return first, None


def rebaseline(store: Store, run: Path, only_changed: bool, platform: str | bool | None) -> dict:
    """Write certain golden cases of a run. `platform`: None/False generic, True the run's platform, or a dir."""
    receipt, cases = load_run(run)
    run_platform = receipt.get("platform")
    run_product = receipt.get("product")
    arm = receipt.get("arm")
    check_arm(arm)
    if run_platform is None:
        raise BaselineError("receipt.json has no platform")
    run_pdir = platform_dir(run_platform, run_product)
    chain = platform_chain(run_pdir)
    if platform is True:
        target_pdir = run_platform
    elif platform:
        if platform not in chain:
            raise BaselineError(f"--platform {platform!r} is not on this run's path {chain}")
        target_pdir = platform
    else:
        target_pdir = None
    target = Location(target_pdir, arm)

    report = {"target": target.label(), "written": [], "unchanged": [], "refused": []}
    for item in cases:
        name = f"{item.suite}/{item.case}"
        if item.refused:
            report["refused"].append({"case": name, "reason": item.refused})
            continue
        data = encode(item.lines)
        if only_changed and store.read(item.suite, item.case, run_pdir, arm) == data:
            report["unchanged"].append(name)
            continue
        if store.write(target, item.suite, item.case, data):
            report["written"].append(name)
        else:
            report["unchanged"].append(name)
    return report


# ------------------------------------------------------------------------------------------ optimize


def _configurations(locations: set[Location]) -> list[tuple[str | None, str | None]]:
    pdirs: set[str | None] = {None}
    arms: set[str | None] = {None}
    for loc in locations:
        arms.add(loc.arm)
        if loc.platform is not None:
            pdirs.update(platform_chain(loc.platform))
    return [(p, a) for p in sorted(pdirs, key=lambda v: (v is not None, v or "")) for a in sorted(arms, key=lambda v: (v is not None, v or ""))]


def _resolve(files: dict[Location, bytes], pdir: str | None, arm: str | None) -> bytes | None:
    for loc in fallback_order(pdir, arm):
        if loc in files:
            return files[loc]
    return None


def redundant(files: dict[Location, bytes]) -> list[Location]:
    """Locations whose removal leaves every configuration reading the same bytes (most specific first)."""
    configs = _configurations(set(files))
    want = {c: _resolve(files, *c) for c in configs}
    keep = dict(files)
    removed = []

    def specificity(loc: Location):
        return (loc.arm is not None and loc.platform is not None, loc.arm is not None,
                len(platform_chain(loc.platform)), loc.label())

    for loc in sorted(files, key=specificity, reverse=True):
        trial = {k: v for k, v in keep.items() if k != loc}
        if all(_resolve(trial, *c) == want[c] for c in configs):
            keep = trial
            removed.append(loc)
    return removed


def optimize(store: Store, suite: str | None, dry_run: bool) -> dict:
    by_case: dict[tuple[str, str], dict[Location, Path]] = {}
    errors = []
    for entry in _safe_entries(store, errors):
        loc, s, case, path = entry
        if suite is not None and s != suite:
            continue
        if suite_class(s) == DIFFERENTIAL:
            continue
        by_case.setdefault((s, case), {})[loc] = path
    report = {"removed": [], "errors": errors, "dryRun": dry_run}
    for (s, case), slots in sorted(by_case.items()):
        files = {loc: path.read_bytes() for loc, path in slots.items()}
        for loc in redundant(files):
            report["removed"].append(str(slots[loc].relative_to(store.root)))
            if not dry_run:
                slots[loc].unlink()
                _prune(slots[loc].parent, store.root)
    return report


def _prune(directory: Path, root: Path) -> None:
    while directory != root and directory.is_dir() and not any(directory.iterdir()):
        directory.rmdir()
        directory = directory.parent


def _safe_entries(store: Store, errors: list):
    if not store.root.is_dir():
        return
    for path in sorted(store.root.rglob("*" + SUFFIX)):
        try:
            yield (*store.parse(path), path)
        except BaselineError as error:
            errors.append(str(error))


# --------------------------------------------------------------------------------------------- check


def check(store: Store) -> dict:
    """Lint the tree: classified golden suite, valid jsonl, no refused results, no redundant baselines."""
    errors: list[str] = []
    for loc, suite, case, path in _safe_entries(store, errors):
        rel = path.relative_to(store.root)
        if suite_class(suite) == DIFFERENTIAL:
            errors.append(f"{rel}: suite {suite!r} is differential and may not have a baseline")
            continue
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            try:
                line = json.loads(raw)
            except ValueError as error:
                errors.append(f"{rel}:{number}: {error}")
                continue
            if not isinstance(line, dict) or not line.get("sha256") or "snapshot" not in line or "step" not in line:
                errors.append(f"{rel}:{number}: needs step, sha256 and snapshot")
            elif "result" in line or line.get("uncertain") or line.get("notComparable"):
                errors.append(f"{rel}:{number}: run metadata in a baseline (write it with rebaseline)")
    redundant_paths = optimize(store, None, dry_run=True)["removed"]
    errors += [f"{p}: redundant, run `baselines.py optimize`" for p in redundant_paths]
    return {"errors": errors}


# ------------------------------------------------------------------------------------------ selftest


def selftest() -> int:
    import unittest

    def line(step, sha, result="Pass", **extra):
        record = {"suite": "journeys", "case": "split/basic", "step": step, "checkpoint": "settled",
                  "result": result, "sha256": sha, "snapshot": {"v": sha}}
        record.update(extra)
        return record

    class Case(unittest.TestCase):
        def setUp(self):
            self.tmp = tempfile.TemporaryDirectory()
            self.root = Path(self.tmp.name) / "baselines"
            self.store = Store(self.root)

        def tearDown(self):
            self.tmp.cleanup()

        def put(self, rel: str, body: str = "x"):
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")

        def run_dir(self, lines, platform="linux", product="daemon", arm=None, cases=None):
            run = Path(self.tmp.name) / f"run{len(list(Path(self.tmp.name).glob('run*')))}"
            run.mkdir()
            receipt = {"platform": platform, "product": product, "arm": arm}
            if cases is not None:
                receipt["cases"] = cases
            (run / "receipt.json").write_text(json.dumps(receipt), encoding="utf-8")
            (run / "checkpoints.jsonl").write_text("\n".join(json.dumps(l) for l in lines) + "\n", encoding="utf-8")
            return run

        def located(self, pdir, arm):
            found = self.store.lookup("journeys", "split/basic", pdir, arm)
            return found[0].label() if found else None

        def test_generic_arm_beats_platform_base(self):
            self.put("arm/motion-on/journeys/split/basic.expected.jsonl")
            self.put("platform/linux/journeys/split/basic.expected.jsonl")
            self.put("journeys/split/basic.expected.jsonl")
            self.assertEqual(self.located("linux", "motion-on"), "arm/motion-on")
            self.assertEqual(self.located("linux", None), "platform/linux")
            self.assertEqual(self.located("mac", "motion-on"), "arm/motion-on")
            self.assertEqual(self.located("mac", None), "generic")

        def test_full_order(self):
            self.assertEqual(
                [l.label() for l in fallback_order("mac-app", "f6.new")],
                ["platform/mac-app/arm/f6.new", "platform/mac/arm/f6.new", "arm/f6.new",
                 "platform/mac-app", "platform/mac", "generic"])
            self.put("platform/mac/arm/f6.new/journeys/split/basic.expected.jsonl")
            self.put("arm/f6.new/journeys/split/basic.expected.jsonl")
            self.assertEqual(self.located("mac-app", "f6.new"), "platform/mac/arm/f6.new")
            self.assertEqual(self.located("linux", "f6.new"), "arm/f6.new")
            self.assertIsNone(self.located("linux", None))

        def test_differential_suites_have_no_baselines(self):
            with self.assertRaises(BaselineError):
                self.store.lookup("daemon-ops", "pane.split")
            run = self.run_dir([dict(line(1, "a"), suite="daemon-ops", case="pane.split")])
            report = rebaseline(self.store, run, False, None)
            self.assertEqual(report["written"], [])
            self.assertIn("differential", report["refused"][0]["reason"])
            self.assertFalse(self.root.exists())
            self.put("daemon-ops/pane.split.expected.jsonl", '{"step":1,"sha256":"a","snapshot":{}}\n')
            self.assertTrue(any("differential" in e for e in check(self.store)["errors"]))

        def test_unknown_suite_and_bad_names(self):
            with self.assertRaises(BaselineError):
                self.store.lookup("nope", "x")
            for bad in ("../x", "a/../b", "", "a//b", ".hidden"):
                with self.assertRaises(BaselineError):
                    self.store.lookup("journeys", bad)
            with self.assertRaises(BaselineError):
                fallback_order("linux", "../arm")
            with self.assertRaises(BaselineError):
                fallback_order("solaris", None)

        def test_never_writes_timeout_or_uncertain(self):
            refusals = [
                [line(1, "a"), line(2, "b", result="Timeout")],
                [line(1, "a", result="Crash")],
                [line(1, "a", result="Skip")],
                [line(1, "a", uncertain=True)],
                [line(1, "a", notComparable=["tabs"])],
                [line(1, "a", sha256=None)],
                [{k: v for k, v in line(1, "a").items() if k != "snapshot"}],
                [line(1, "a", attempt=0), line(1, "b", attempt=1)],
            ]
            for lines in refusals:
                report = rebaseline(self.store, self.run_dir(lines), False, None)
                self.assertEqual(report["written"], [], lines)
                self.assertEqual(len(report["refused"]), 1, lines)
            flaky = self.run_dir([line(1, "a")], cases=[{"suite": "journeys", "case": "split/basic", "flaky": True}])
            self.assertEqual(rebaseline(self.store, flaky, False, None)["written"], [])
            self.assertFalse(self.root.exists())

        def test_failure_and_agreeing_repeats_are_written(self):
            run = self.run_dir([line(1, "a", result="Failure", attempt=0), line(1, "a", attempt=1)])
            report = rebaseline(self.store, run, False, None)
            self.assertEqual(report["written"], ["journeys/split/basic"])
            data = (self.root / "journeys/split/basic.expected.jsonl").read_text(encoding="utf-8")
            self.assertEqual(json.loads(data), {"checkpoint": "settled", "sha256": "a", "snapshot": {"v": "a"}, "step": 1})
            self.assertEqual(check(self.store)["errors"], [])

        def test_platform_and_arm_targets(self):
            run = self.run_dir([line(1, "a")], platform="mac", product="app", arm="f6.new")
            self.assertEqual(rebaseline(self.store, run, False, True)["target"], "platform/mac/arm/f6.new")
            self.assertTrue((self.root / "platform/mac/arm/f6.new/journeys/split/basic.expected.jsonl").is_file())
            self.assertEqual(rebaseline(self.store, run, False, "mac-app")["target"], "platform/mac-app/arm/f6.new")
            with self.assertRaises(BaselineError):
                rebaseline(self.store, run, False, "linux")

        def test_only_changed(self):
            rebaseline(self.store, self.run_dir([line(1, "a")]), False, None)
            same = rebaseline(self.store, self.run_dir([line(1, "a")]), True, True)
            self.assertEqual(same["unchanged"], ["journeys/split/basic"])
            self.assertFalse((self.root / "platform").exists())
            changed = rebaseline(self.store, self.run_dir([line(1, "b")]), True, True)
            self.assertEqual(changed["written"], ["journeys/split/basic"])
            self.assertEqual(self.located("linux", None), "platform/linux")

        def test_optimize(self):
            self.put("journeys/split/basic.expected.jsonl", "G")
            self.put("platform/linux/journeys/split/basic.expected.jsonl", "G")
            self.put("platform/mac/journeys/split/basic.expected.jsonl", "M")
            self.put("platform/mac-app/journeys/split/basic.expected.jsonl", "M")
            self.put("arm/a/journeys/split/basic.expected.jsonl", "A")
            self.put("platform/mac/arm/a/journeys/split/basic.expected.jsonl", "M")
            self.put("platform/linux/arm/a/journeys/split/basic.expected.jsonl", "A")
            before = {c: self.store.read("journeys", "split/basic", *c) for c in
                      [(p, a) for p in (None, "linux", "mac", "mac-app", "linux-daemon") for a in (None, "a")]}
            report = optimize(self.store, None, dry_run=False)
            self.assertEqual(sorted(report["removed"]), sorted([
                "platform/linux/journeys/split/basic.expected.jsonl",
                "platform/mac-app/journeys/split/basic.expected.jsonl",
                "platform/linux/arm/a/journeys/split/basic.expected.jsonl",
            ]))
            after = {c: self.store.read("journeys", "split/basic", *c) for c in before}
            self.assertEqual(before, after)
            self.assertFalse((self.root / "platform/linux").exists())
            self.assertTrue((self.root / "platform/mac/arm/a/journeys/split/basic.expected.jsonl").is_file())
            self.assertEqual(optimize(self.store, None, dry_run=False)["removed"], [])

        def test_check_reports_redundant(self):
            self.put("journeys/x.expected.jsonl", '{"step":1,"sha256":"a","snapshot":{}}\n')
            self.put("platform/linux/journeys/x.expected.jsonl", '{"step":1,"sha256":"a","snapshot":{}}\n')
            self.assertTrue(any("redundant" in e for e in check(self.store)["errors"]))

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Case)
    result = unittest.TextTestRunner(stream=sys.stderr, verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


# ----------------------------------------------------------------------------------------------- cli


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="baseline tree (default: tests/oracle/baselines)")
    sub = parser.add_subparsers(dest="command", required=True)

    p_lookup = sub.add_parser("lookup", help="print the baseline a configuration reads")
    p_lookup.add_argument("suite")
    p_lookup.add_argument("case")
    p_lookup.add_argument("--platform", choices=PLATFORMS)
    p_lookup.add_argument("--product", choices=PRODUCTS)
    p_lookup.add_argument("--arm")

    p_rebase = sub.add_parser("rebaseline", help="write certain golden cases of a run as baselines")
    p_rebase.add_argument("--run", type=Path, required=True)
    p_rebase.add_argument("--only-changed", action="store_true", help="skip cases whose current baseline already matches")
    p_rebase.add_argument("--platform", nargs="?", const=True, default=None,
                          help="write platform baselines (bare: the run's platform; or a dir on its path, e.g. mac-app)")

    p_opt = sub.add_parser("optimize", help="remove baselines the fallback already provides")
    p_opt.add_argument("--suite")
    p_opt.add_argument("--dry-run", action="store_true")

    sub.add_parser("check", help="lint the baseline tree")
    sub.add_parser("selftest", help="run the unit tests")

    args = parser.parse_args(argv)
    if args.command == "selftest":
        return selftest()
    store = Store(args.root)
    try:
        if args.command == "lookup":
            if args.product and not args.platform:
                raise BaselineError("--product needs --platform")
            pdir = platform_dir(args.platform, args.product) if args.platform else None
            found = store.lookup(args.suite, args.case, pdir, args.arm)
            report = {"location": found[0].label(), "path": str(found[1])} if found else {"location": None}
            code = 0 if found else 1
        elif args.command == "rebaseline":
            report = rebaseline(store, args.run, args.only_changed, args.platform)
            code = 1 if report["refused"] else 0
        elif args.command == "optimize":
            if args.suite:
                require_golden(args.suite)
            report = optimize(store, args.suite, args.dry_run)
            code = 1 if report["errors"] else 0
        else:
            report = check(store)
            code = 1 if report["errors"] else 0
    except BaselineError as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
