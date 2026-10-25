#!/usr/bin/env python3
"""Oracle baseline store: Blink two-pass fallback, rebaseline from a run, optimize, suite classes.

Stdlib only and safe under `python3 -I` (fleet minis have no third-party packages).
Spec: plans/cmux-next/chrome-parity/p15-oracle.md, sections 3D and 3E, task 016.

Chrome reference:
  third_party/blink/web_tests/ and docs/testing/web_test_baseline_fallback.md (two passes: the virtual
  name along the platform path, then the base name along the platform path);
  third_party/blink/tools/blinkpy/common/checkout/baseline_optimizer.py (`blink_tool.py optimize-baselines`:
  drop a baseline when every configuration that reads it reads the same bytes without it, and move a baseline
  that all children share up to their common fallback parent);
  third_party/blink/tools/blinkpy/tool/commands/rebaseline.py (`rebaseline-cl` copies actual results to the
  builder's location, then optimizes unless --no-optimize).

Layout under tests/oracle/baselines (the Blink web_tests root layout, `virtual/<v>` renamed `arm/<arm>`):
  <suite>/<case>.expected.jsonl                              generic
  platform/<p>/<suite>/<case>.expected.jsonl                 platform, or platform-product (`mac-app`)
  arm/<arm>/<suite>/<case>.expected.jsonl                    arm (switch arm, `motion-on`, ...)
  platform/<p>/arm/<arm>/<suite>/<case>.expected.jsonl       platform arm
A platform dir is `<platform>` or `<platform>-<product>`; `mac-app` falls back to `mac`.
Lookup for (platform-product, arm) on one case:
  pass 1: platform/mac-app/arm/A -> platform/mac/arm/A -> arm/A
  pass 2: platform/mac-app       -> platform/mac       -> <generic>
so a generic arm baseline beats a platform base baseline, as in Blink. A configuration always has a platform
(a run's receipt names one), so `optimize` reasons over every platform and platform-product dir.

Suite classes (3D). Differential suites compare base == head (or arm == arm, product == product): the base
run is the oracle, so they never get a reviewed baseline. `rebaseline` refuses them, `lookup` raises and
`check` reports any baseline file under one.

Run directory read by `rebaseline --run DIR` (written by oracle.py run, task 017):
  receipt.json       {"platform": "linux", "product": "daemon" | null, "arm": null | "NAME",
                      "cases": [{"suite": S, "case": C, "result": R, "checkpoints": N, "flaky"?: bool}, ...]}
                     `cases` is required: one entry per case, written when the case ends. `result` is the
                     case's final result; `checkpoints` (required for Pass and Failure) is the number of
                     checkpoint lines each attempt of the case emitted.
  checkpoints.jsonl  one object per checkpoint, in step order:
                      {"suite", "case", "step": int | str, "checkpoint"?: str, "result", "sha256", "snapshot",
                       "attempt"?: int >= 0, "uncertain"?, "notComparable"?: [facet, ...]}
  `snapshot` is already canonical (normalize.py, task 013, computes `sha256` over its canonical JSON); this
  store compares by that hash and never re-canonicalizes.
A case is written only when the receipt proves it finished and every checkpoint is certain: its receipt entry
has result Pass or Failure (Failure is a mismatch with the current baseline, which is what a rebaseline
replaces), every attempt emitted exactly `checkpoints` lines, each line has result Pass or Failure, a snapshot
and a sha256, is not flagged uncertain and has no not-comparable facet, the case is not flaky, and every
attempt gives the same hashes. Every other result (Timeout, Crash, Slow, ...), a missing receipt entry and a
short checkpoint stream refuse the whole case, so a baseline never holds a partial run. A case the receipt
reports as Skip with no checkpoint lines is listed as skipped, not refused.
`rebaseline` refuses a case when a more specific baseline on the run's own fallback path holds other bytes
(the run's configuration would keep reading it; `--platform` writes there instead), then optimizes the cases
it touched unless `--no-optimize`.

Usage:
  baselines.py lookup SUITE CASE [--platform P] [--product X] [--arm A]
  baselines.py rebaseline --run DIR [--only-changed] [--platform [DIR]] [--no-optimize]
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


def check_arm(arm: object) -> None:
    if arm is not None and not (isinstance(arm, str) and _ARM.match(arm)):
        raise BaselineError(f"bad arm name {arm!r}")


def platform_dir(platform: object, product: object = None) -> str:
    if not isinstance(platform, str) or platform not in PLATFORMS:
        raise BaselineError(f"unknown platform {platform!r}: one of {', '.join(PLATFORMS)}")
    if product is None:
        return platform
    if not isinstance(product, str) or product not in PRODUCTS:
        raise BaselineError(f"unknown product {product!r}: one of {', '.join(PRODUCTS)}")
    return f"{platform}-{product}"


def platform_chain(pdir: str | None) -> list[str]:
    """Most specific first: `mac-app` -> [`mac-app`, `mac`]; None -> []."""
    if pdir is None:
        return []
    if not isinstance(pdir, str):
        raise BaselineError(f"bad platform dir {pdir!r}")
    platform, dash, product = pdir.partition("-")
    if dash and not product:
        raise BaselineError(f"bad platform dir {pdir!r}: empty product")
    platform_dir(platform, product or None)
    return [pdir, platform] if product else [pdir]


# Every platform dir a configuration can read from, least specific first per platform.
ALL_PDIRS: tuple[str, ...] = tuple(
    pdir for platform in PLATFORMS for pdir in (platform, *(f"{platform}-{product}" for product in PRODUCTS))
)


def _is_count(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


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

    def case_slots(self, suite: str, case: str) -> dict[Location, Path]:
        """Every baseline file of one case, by location (case names hold no glob characters)."""
        tail = f"{suite}/{case}{SUFFIX}"
        slots: dict[Location, Path] = {}
        for pattern in (tail, f"arm/*/{tail}", f"platform/*/{tail}", f"platform/*/arm/*/{tail}"):
            for path in self.root.glob(pattern):
                try:
                    loc, s, c = self.parse(path)
                except BaselineError:
                    continue  # `check` reports it; lookup never reads it
                if (s, c) == (suite, case) and path.is_file():
                    slots[loc] = path
        return slots

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
    """One case of a run: `lines` to write, or a `refused` reason; neither means the receipt skipped it."""

    suite: str
    case: str
    lines: list[dict] | None
    refused: str | None


def _receipt_cases(receipt: dict) -> dict[tuple[str, str], dict]:
    entries = receipt.get("cases")
    if not isinstance(entries, list):
        raise BaselineError("receipt.json needs a `cases` list: without each case's final result no case is proven finished")
    declared: dict[tuple[str, str], dict] = {}
    for index, entry in enumerate(entries):
        where = f"receipt.json cases[{index}]"
        if not isinstance(entry, dict) or not isinstance(entry.get("suite"), str) or not isinstance(entry.get("case"), str):
            raise BaselineError(f"{where}: needs string suite and case")
        key = (entry["suite"], entry["case"])
        if key in declared:
            raise BaselineError(f"{where}: duplicate case {key[0]}/{key[1]}")
        if not isinstance(entry.get("result"), str):
            raise BaselineError(f"{where}: needs a string result")
        if entry["result"] in CERTAIN_RESULTS and not _is_count(entry.get("checkpoints")):
            raise BaselineError(f"{where}: result {entry['result']} needs checkpoints, a count >= 0")
        if not isinstance(entry.get("flaky", False), bool):
            raise BaselineError(f"{where}: flaky must be a bool")
        declared[key] = entry
    return declared


def _read_checkpoints(run: Path) -> dict[tuple[str, str], dict[int, list[dict]]]:
    try:
        text = (run / "checkpoints.jsonl").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise BaselineError(f"{run}/checkpoints.jsonl: {error}") from error
    grouped: dict[tuple[str, str], dict[int, list[dict]]] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        where = f"checkpoints.jsonl:{number}"
        try:
            line = json.loads(raw)
        except ValueError as error:
            raise BaselineError(f"{where}: {error}") from error
        if not isinstance(line, dict) or not isinstance(line.get("suite"), str) or not isinstance(line.get("case"), str):
            raise BaselineError(f"{where}: needs string suite and case")
        step = line.get("step")
        if not (isinstance(step, str) or (isinstance(step, int) and not isinstance(step, bool))):
            raise BaselineError(f"{where}: step must be an int or a string")
        if not isinstance(line.get("checkpoint", ""), (str, type(None))):
            raise BaselineError(f"{where}: checkpoint must be a string")
        attempt = line.get("attempt", 0)
        if not _is_count(attempt):
            raise BaselineError(f"{where}: attempt must be an int >= 0, not {attempt!r}")
        grouped.setdefault((line["suite"], line["case"]), {}).setdefault(attempt, []).append(line)
    return grouped


def load_run(run: Path) -> tuple[dict, list[RunCase]]:
    try:
        receipt = json.loads((run / "receipt.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise BaselineError(f"{run}/receipt.json: {error}") from error
    if not isinstance(receipt, dict):
        raise BaselineError(f"{run}/receipt.json: not an object")
    declared = _receipt_cases(receipt)
    grouped = _read_checkpoints(run)
    cases = []
    for suite, case in sorted(set(declared) | set(grouped)):
        entry = declared.get((suite, case))
        cases.append(RunCase(suite, case, *_judge(suite, case, entry, grouped.get((suite, case), {}))))
    return receipt, cases


def _judge(suite: str, case: str, entry: dict | None, attempts: dict[int, list[dict]]):
    try:
        require_golden(suite)
        check_case_name(case)
    except BaselineError as error:
        return None, str(error)
    if entry is None:
        return None, "no final result in receipt.json (the case never finished)"
    if entry["result"] == "Skip" and not attempts:
        return None, None
    if entry["result"] not in CERTAIN_RESULTS:
        return None, f"case result {entry['result']!r}"
    if entry.get("flaky"):
        return None, "flaky in receipt"
    if not attempts:
        return None, "no checkpoint lines"
    expected = entry["checkpoints"]
    for attempt, lines in sorted(attempts.items()):
        if len(lines) != expected:
            return None, f"attempt {attempt}: {len(lines)} of {expected} checkpoints (truncated run)"
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


def _shadow(store: Store, shadowers: list[Location], suite: str, case: str, data: bytes) -> Location | None:
    """The more specific slot the run's configuration reads instead of the target, when it holds other bytes."""
    for loc in shadowers:
        path = store.path(loc, suite, case)
        if path.is_file():
            return None if path.read_bytes() == data else loc
    return None


def rebaseline(store: Store, run: Path, only_changed: bool, platform: str | bool | None, optimize_after: bool = True) -> dict:
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
    path_order = fallback_order(run_pdir, arm)
    shadowers = path_order[: path_order.index(target)]

    report = {"target": target.label(), "written": [], "unchanged": [], "skipped": [], "refused": [],
              "optimized": {"removed": [], "added": []}}
    touched = []
    for item in cases:
        name = f"{item.suite}/{item.case}"
        if item.refused:
            report["refused"].append({"case": name, "reason": item.refused})
            continue
        if item.lines is None:
            report["skipped"].append(name)
            continue
        data = encode(item.lines)
        if only_changed and store.read(item.suite, item.case, run_pdir, arm) == data:
            report["unchanged"].append(name)
            continue
        shadow = _shadow(store, shadowers, item.suite, item.case, data)
        if shadow is not None:
            report["refused"].append({"case": name, "reason": f"shadowed by {shadow.label()}: this run reads it; "
                                                              f"use --platform {shadow.platform}"})
            continue
        if store.write(target, item.suite, item.case, data):
            report["written"].append(name)
            touched.append((item.suite, item.case))
        else:
            report["unchanged"].append(name)
    if optimize_after:
        for suite, case in touched:
            removed, added = optimize_case(store, suite, case, store.case_slots(suite, case), dry_run=False)
            report["optimized"]["removed"] += removed
            report["optimized"]["added"] += added
    return report


# ------------------------------------------------------------------------------------------ optimize


def _arms(files) -> list[str | None]:
    return [None, *sorted({loc.arm for loc in files if loc.arm is not None})]


def _configurations(files) -> list[tuple[str, str | None]]:
    """Every configuration the slots can affect: each platform dir, with no arm and with each arm present."""
    return [(pdir, arm) for pdir in ALL_PDIRS for arm in _arms(files)]


def _resolve(files: dict[Location, bytes], pdir: str | None, arm: str | None) -> bytes | None:
    for loc in fallback_order(pdir, arm):
        if loc in files:
            return files[loc]
    return None


def _specificity(loc: Location):
    return (loc.arm is not None and loc.platform is not None, loc.arm is not None,
            len(platform_chain(loc.platform)), loc.label())


def _parents(files) -> list[Location]:
    """Promotion targets, least specific first: generic and arm roots, then platform dirs above products."""
    return [Location(pdir, arm) for pdir in (None, *PLATFORMS) for arm in _arms(files)]


def optimal(files: dict[Location, bytes]) -> dict[Location, bytes]:
    """The smallest slot set every configuration resolves the same in (baseline_optimizer.py).

    Drop each slot the fallback already covers, most specific first; then, while it shrinks the tree, put a
    shared baseline at a fallback parent and drop the children that now fall back to it."""
    configs = _configurations(files)
    want = {c: _resolve(files, *c) for c in configs}

    def same(slots) -> bool:
        return all(_resolve(slots, *c) == want[c] for c in configs)

    def prune(slots: dict[Location, bytes]) -> dict[Location, bytes]:
        for loc in sorted(slots, key=_specificity, reverse=True):
            trial = {k: v for k, v in slots.items() if k != loc}
            if same(trial):
                slots = trial
        return slots

    keep = prune(dict(files))
    while True:
        trials = (prune({**keep, parent: data})
                  for parent in _parents(keep) if parent not in keep
                  for data in sorted(set(keep.values())))
        better = next((t for t in trials if len(t) < len(keep) and same(t)), None)
        if better is None:
            return keep
        keep = better


def optimize_case(store: Store, suite: str, case: str, slots: dict[Location, Path], dry_run: bool):
    """Apply `optimal` to one case; returns (removed, added) paths relative to the root."""
    files = {loc: path.read_bytes() for loc, path in slots.items()}
    keep = optimal(files)
    added = [loc for loc in keep if loc not in files]
    removed = [loc for loc in files if loc not in keep]
    if not dry_run:
        for loc in added:
            store.write(loc, suite, case, keep[loc])
        for loc in removed:
            slots[loc].unlink()
            _prune(slots[loc].parent, store.root)
    return [str(loc.relative(suite, case)) for loc in removed], [str(loc.relative(suite, case)) for loc in added]


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
    report = {"removed": [], "added": [], "errors": errors, "dryRun": dry_run}
    for (s, case), slots in sorted(by_case.items()):
        try:
            removed, added = optimize_case(store, s, case, slots, dry_run)
        except OSError as error:
            errors.append(f"{s}/{case}: {error}")
            continue
        report["removed"] += removed
        report["added"] += added
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
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            errors.append(f"{rel}: {error}")
            continue
        for number, raw in enumerate(text.splitlines(), 1):
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
    import contextlib
    import io
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
            """A run dir; `cases` defaults to one finished Pass entry per case with its first attempt's count."""
            run = Path(self.tmp.name) / f"run{len(list(Path(self.tmp.name).glob('run*')))}"
            run.mkdir()
            if cases is None:
                counts: dict[tuple, dict] = {}
                for l in lines:
                    per = counts.setdefault((l["suite"], l["case"]), {})
                    attempt = json.dumps(l.get("attempt", 0))  # malformed attempts may be unhashable
                    per[attempt] = per.get(attempt, 0) + 1
                cases = [{"suite": s, "case": c, "result": "Pass", "checkpoints": next(iter(per.values()))}
                         for (s, c), per in counts.items()]
            receipt = {"platform": platform, "product": product, "arm": arm, "cases": cases}
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
            flaky = self.run_dir([line(1, "a")], cases=[{"suite": "journeys", "case": "split/basic", "result": "Pass",
                                                          "checkpoints": 1, "flaky": True}])
            self.assertEqual(rebaseline(self.store, flaky, False, None)["written"], [])
            self.assertFalse(self.root.exists())

        def test_never_writes_an_unfinished_case(self):
            def entry(**fields):
                return [{"suite": "journeys", "case": "split/basic", **fields}]
            unfinished = {
                "truncated": (entry(result="Pass", checkpoints=3), [line(1, "a")], "1 of 3"),
                "case Timeout": (entry(result="Timeout"), [line(1, "a")], "Timeout"),
                "case Crash": (entry(result="Crash", checkpoints=1), [line(1, "a")], "Crash"),
                "case Slow": (entry(result="Slow", checkpoints=1), [line(1, "a")], "Slow"),
                "missing from receipt": ([], [line(1, "a")], "never finished"),
                "truncated retry": (entry(result="Pass", checkpoints=2),
                                    [line(1, "a"), line(2, "b"), line(1, "a", attempt=1)], "attempt 1: 1 of 2"),
                "no checkpoints": (entry(result="Pass", checkpoints=0), [], "no checkpoint lines"),
            }
            for label, (cases, lines, reason) in unfinished.items():
                report = rebaseline(self.store, self.run_dir(lines, cases=cases), False, None)
                self.assertEqual(report["written"], [], label)
                self.assertEqual(len(report["refused"]), 1, label)
                self.assertIn(reason, report["refused"][0]["reason"], label)
            skipped = rebaseline(self.store, self.run_dir([], cases=entry(result="Skip")), False, None)
            self.assertEqual((skipped["skipped"], skipped["refused"]), (["journeys/split/basic"], []))
            self.assertFalse(self.root.exists())

        def test_malformed_runs_raise(self):
            malformed = [
                ([line(1, "a", attempt=0), line(1, "a", attempt="1")], {}),
                ([line(1, "a", attempt=[0])], {}),
                ([line(1, "a", attempt=True)], {}),
                ([line(1, "a", attempt=0.0)], {}),
                ([line(1, "a", attempt=-1)], {}),
                ([line([1], "a")], {}),
                ([line(1, "a")], {"arm": ["x"]}),
                ([line(1, "a")], {"platform": {"x": 1}}),
                ([line(1, "a")], {"cases": None}),
                ([line(1, "a")], {"cases": [{"suite": "journeys", "case": "split/basic", "result": "Pass"}]}),
                ([line(1, "a")], {"cases": [{"suite": "journeys", "case": "split/basic"}]}),
            ]
            for lines, override in malformed:
                run = self.run_dir(lines)
                receipt = json.loads((run / "receipt.json").read_text(encoding="utf-8"))
                (run / "receipt.json").write_text(json.dumps({**receipt, **override}), encoding="utf-8")
                with self.assertRaises(BaselineError, msg=(lines, override)):
                    rebaseline(self.store, run, False, None)
            run = self.run_dir([line(1, "a")])
            (run / "checkpoints.jsonl").write_bytes(b"\xff\xfe\n")
            with self.assertRaises(BaselineError):
                rebaseline(self.store, run, False, None)

        def test_shadowed_target_is_refused(self):
            self.put("platform/linux/journeys/split/basic.expected.jsonl", "OLD\n")
            report = rebaseline(self.store, self.run_dir([line(1, "new")]), False, None)
            self.assertEqual(report["written"], [])
            self.assertIn("shadowed by platform/linux", report["refused"][0]["reason"])
            self.assertIn("--platform linux", report["refused"][0]["reason"])
            self.assertFalse((self.root / "journeys").exists())
            run = self.run_dir([line(1, "new")], arm="a")
            self.put("platform/linux-daemon/arm/a/journeys/split/basic.expected.jsonl", "OLD\n")
            self.assertIn("shadowed by platform/linux-daemon/arm/a", rebaseline(self.store, run, False, True)["refused"][0]["reason"])
            fixed = rebaseline(self.store, run, False, "linux-daemon")
            self.assertEqual(fixed["written"], ["journeys/split/basic"])
            data = encode([line(1, "new")])
            self.assertEqual(self.store.read("journeys", "split/basic", "linux-daemon", "a"), data)
            same = rebaseline(self.store, self.run_dir([line(1, "new")]), False, "linux")
            self.assertEqual(same["written"], ["journeys/split/basic"])
            self.assertEqual(self.store.read("journeys", "split/basic", "linux-daemon", None), data)

        def test_rebaselined_configuration_reads_new_bytes_and_tree_stays_clean(self):
            run = self.run_dir([line(1, "a")])
            rebaseline(self.store, run, False, None)
            again = rebaseline(self.store, run, False, True)
            self.assertEqual(again["optimized"]["removed"], ["platform/linux/journeys/split/basic.expected.jsonl"])
            self.assertEqual(check(self.store)["errors"], [])
            self.assertEqual(self.store.read("journeys", "split/basic", "linux-daemon"), encode([line(1, "a")]))
            raw = rebaseline(self.store, run, False, True, optimize_after=False)
            self.assertEqual(raw["optimized"], {"removed": [], "added": []})
            self.assertTrue(any("redundant" in e for e in check(self.store)["errors"]))

        def test_optimize_promotes_a_shared_baseline(self):
            for p in PLATFORMS:
                self.put(f"platform/{p}/journeys/split/basic.expected.jsonl", "S")
            self.put("platform/mac-app/journeys/split/basic.expected.jsonl", "M")
            for p in PLATFORMS:
                self.put(f"platform/{p}/arm/a/journeys/split/basic.expected.jsonl", "A")
            configs = [(p, a) for p in ALL_PDIRS for a in (None, "a")]
            before = {c: self.store.read("journeys", "split/basic", *c) for c in configs}
            report = optimize(self.store, None, dry_run=False)
            self.assertEqual(sorted(report["added"]), ["arm/a/journeys/split/basic.expected.jsonl",
                                                       "journeys/split/basic.expected.jsonl"])
            self.assertEqual({c: self.store.read("journeys", "split/basic", *c) for c in configs}, before)
            self.assertEqual(sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*" + SUFFIX)), [
                "arm/a/journeys/split/basic.expected.jsonl",
                "journeys/split/basic.expected.jsonl",
                "platform/mac-app/journeys/split/basic.expected.jsonl",
            ])
            self.assertEqual(optimize(self.store, None, dry_run=False), {"removed": [], "added": [], "errors": [], "dryRun": False})

        def test_partial_platforms_are_not_promoted(self):
            self.put("platform/linux/journeys/split/basic.expected.jsonl", "S")
            self.put("platform/mac/journeys/split/basic.expected.jsonl", "S")
            self.assertEqual(optimize(self.store, None, dry_run=False)["added"], [])
            self.assertIsNone(self.store.read("journeys", "split/basic", "windows"))

        def test_bad_platform_dirs_and_undecodable_files(self):
            for bad in ("mac-", "mac-app-x", "-app", "solaris-app"):
                with self.assertRaises(BaselineError, msg=bad):
                    platform_chain(bad)
            self.put("platform/mac-/journeys/split/basic.expected.jsonl", '{"step":1,"sha256":"a","snapshot":{}}\n')
            (self.root / "journeys").mkdir(parents=True)
            (self.root / "journeys/bin.expected.jsonl").write_bytes(b"\xff\xfe\n")
            errors = check(self.store)["errors"]
            self.assertTrue(any("mac-" in e for e in errors), errors)
            self.assertTrue(any("bin.expected.jsonl" in e for e in errors), errors)

        def cli(self, *argv):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = main(["--root", str(self.root), *argv])
            text = out.getvalue() or err.getvalue()
            return code, json.loads(text)

        def test_cli_exit_codes_and_reports(self):
            run = self.run_dir([line(1, "a")])
            code, report = self.cli("rebaseline", "--run", str(run))
            self.assertEqual((code, report["target"], report["written"]), (0, "generic", ["journeys/split/basic"]))
            changed = self.run_dir([line(1, "b")])
            code, report = self.cli("rebaseline", "--platform", "--run", str(changed))
            self.assertEqual((code, report["target"]), (0, "platform/linux"))
            code, report = self.cli("rebaseline", "--run", str(changed), "--platform", "linux-daemon")
            self.assertEqual((code, report["target"]), (0, "platform/linux-daemon"))
            self.assertEqual(report["optimized"]["removed"], ["platform/linux-daemon/journeys/split/basic.expected.jsonl"])
            code, report = self.cli("rebaseline", "--run", str(changed), "--platform", "mac")
            self.assertEqual(code, 2)
            self.assertIn("not on this run's path", report["error"])
            refused = self.run_dir([line(1, "a", result="Timeout")])
            code, report = self.cli("rebaseline", "--run", str(refused))
            self.assertEqual((code, len(report["refused"])), (1, 1))
            code, report = self.cli("rebaseline", "--run", str(Path(self.tmp.name) / "missing"))
            self.assertEqual(code, 2)
            code, report = self.cli("lookup", "journeys", "split/basic", "--platform", "linux", "--product", "daemon")
            self.assertEqual((code, report["location"]), (0, "platform/linux"))
            code, report = self.cli("lookup", "journeys", "split/basic", "--platform", "mac")
            self.assertEqual((code, report["location"]), (0, "generic"))
            code, report = self.cli("lookup", "journeys", "nothing")
            self.assertEqual((code, report["location"]), (1, None))
            code, report = self.cli("lookup", "journeys", "split/basic", "--product", "app")
            self.assertEqual((code, report["error"]), (2, "--product needs --platform"))
            code, report = self.cli("lookup", "daemon-ops", "x")
            self.assertEqual(code, 2)
            self.assertEqual(self.cli("check"), (0, {"errors": []}))
            self.put("platform/mac/journeys/split/basic.expected.jsonl",
                     (self.root / "journeys/split/basic.expected.jsonl").read_text(encoding="utf-8"))
            code, report = self.cli("check")
            self.assertEqual(code, 1)
            code, report = self.cli("optimize", "--dry-run")
            self.assertEqual((code, report["removed"]), (0, ["platform/mac/journeys/split/basic.expected.jsonl"]))
            self.assertEqual(self.cli("optimize")[0], 0)
            self.assertEqual(self.cli("check"), (0, {"errors": []}))
            self.assertEqual(self.cli("optimize", "--suite", "cli")[0], 2)

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
    p_rebase.add_argument("--no-optimize", action="store_true", help="do not optimize the touched cases afterwards")

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
            report = rebaseline(store, args.run, args.only_changed, args.platform, not args.no_optimize)
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
