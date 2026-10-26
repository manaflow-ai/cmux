#!/usr/bin/env python3
"""Mutation smoke test of the oracle: `oracle.py selftest --mutants` (p15-oracle-115).

For each seeded patch mutant under tests/oracle/mutants/<product>/*.patch (task 026: 10 app,
10 daemon; nothing is added to Sources or crates), this runs the smallest suite that catches it:
the candidate suites run one at a time, smallest first, base against base+patch at the same SHA,
and the first that catches the mutant ends its search. A mutant no candidate suite catches is a
corpus gap and gets one MQ-mutants queue line. The run fails below 19/20 caught over both products
and below 9/10 per product (spec section 5, item 7).

    python3 -I scripts/cmux-next/oracle/oracle.py selftest --mutants [options]
    python3 -I scripts/cmux-next/oracle/patch_mutants.py [options]

Chrome reference: this is the "is the suite strong enough" question Chromium's mutation testing
answers (docs/testing/mutation_testing.md; Gerrit's Mutation Testing plugin reports the mutants a
change's tests leave alive). cargo-mutants (task 191) is the primary measure; these 20 hand-made
faults are the smoke set that every product run must still catch.

Patch format (git format-patch or a plain git diff). Lines before the first `diff --git` may name:
    Oracle-Fault: <one line: what the fault breaks>     (default: the Subject line)
    Oracle-Suites: <suite>[,<suite>...]                 (candidate suites; repeatable)
Without Oracle-Suites, the candidates are the suites tests/oracle/suite-map.json (task 009) maps
the patch's paths to, and without a match every suite with a case the product can run. A daemon
patch changes cmux-tui/ only and an app patch Packages/ only; neither touches Cargo.lock,
a submodule or tests/oracle/.

A mutant is caught on a suite when, against the base run of the same suite, its run has
- a confirmed divergence (diff.py, through oracle.compare_views; flaky cases left out), or
- a case with an unexpected result that is expected on the base (Failure, Crash, Timeout), or
- an invariant violation (invariants.py, task 110: id, case, pointer) the base run does not have.
A result that is only flaky is not a catch: the oracle never fails a run on a flaky case.

Products:
- daemon (VM): one detached worktree of the SHA under /tmp/oracle-wt; linux_run.sh builds the
  base, then each patch is applied, built, copied out and reverted, and the tree is checked clean
  before the next one. Builds after the first are incremental. Suites run in process through
  oracle.run_one (driver_daemon.py, task 023) with the retry policy of a diff run.
- app (fleet): `fleet.py diff --product app --base SHA --head SHA --head-mutant PATCH --suite S
  --out DIR` (tasks 050, 008, 026): both sides on one host, the patch applied in the job worktree
  by scripts/measure/oracle.sh; DIR gets comparison.json and the base/ and head/ run directories.

Outputs (outside the checkout): OUT/mutants.json (per mutant verdict and every suite tried) and
OUT/corpus-gaps.jsonl (or --gaps-out), rewritten by every run.

Exit: 0 every gate that applies passes; 1 a gate fails; 2 bad usage or no mutants; 3 undecided
(an unmeasured mutant could still change the result).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import oracle  # noqa: E402

TASK = "p15-oracle-115"
REPO = oracle.REPO
MUTANTS_ROOT = REPO / "tests" / "oracle" / "mutants"
SUITE_MAP = REPO / "tests" / "oracle" / "suite-map.json"
DEFAULT_OUT_BASE = Path("/tmp/oracle/mutants")
DEFAULT_WORKTREE_BASE = Path("/tmp/oracle-wt")
DEFAULT_TARGET_BASE = Path("/tmp/oracle-target")
BUILD_SCRIPT = HERE / "linux_run.sh"
FLEET = HERE / "fleet.py"

PRODUCTS = ("app", "daemon")
# Where each product's mutants may change code, and the platform its cases run on.
PRODUCT_PATHS = {"daemon": ("cmux-tui/",), "app": ("Packages/",)}
PRODUCT_PLATFORM = {"daemon": "linux", "app": "mac"}
FORBIDDEN_PATHS = ("tests/oracle/", "scripts/cmux-next/oracle/", "cmux-tui/Cargo.lock", "ghostty-next")
TOTAL_RATE = Fraction(19, 20)
PRODUCT_RATE = Fraction(9, 10)
QUEUE = "MQ-mutants"

CAUGHT, SURVIVED, MISSED, UNVIABLE, UNMEASURED = "caught", "survived", "missed", "unviable", "unmeasured"
EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_UNDECIDED = 0, 1, 2, 3


class MutantError(Exception):
    """The patch itself is wrong (does not apply, does not build, changes the wrong paths): fix it in 026."""


class InfraError(Exception):
    """The run could not measure a mutant (worktree, build of the base, driver, fleet)."""


# ---------------------------------------------------------------------------------------- mutants


@dataclass(frozen=True)
class Mutant:
    id: str  # <product>/<patch stem>
    product: str
    path: Path
    paths: Tuple[str, ...]
    suites: Tuple[str, ...]
    fault: str

    def path_errors(self) -> List[str]:
        errors = []
        if not self.paths:
            errors.append("the patch changes no file")
        allowed = PRODUCT_PATHS[self.product]
        for path in self.paths:
            if not path.startswith(allowed):
                errors.append(f"{path}: a {self.product} mutant changes {' or '.join(allowed)} only")
            if any(path == f or path.startswith(f.rstrip("/") + "/") for f in FORBIDDEN_PATHS):
                errors.append(f"{path}: a mutant never changes the oracle, the lockfile or a submodule")
        return errors


def parse_mutant(path: Path, product: str) -> Mutant:
    text = path.read_text(encoding="utf-8", errors="replace")
    paths: List[str] = []
    suites: List[str] = []
    fault = subject = ""
    in_header = True
    for line in text.splitlines():
        if line.startswith("diff --git "):
            in_header = False
            for token in line[len("diff --git "):].split(" "):
                if token[:2] in ("a/", "b/") and token[2:] not in paths:
                    paths.append(token[2:])
            continue
        if not in_header:
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if key == "Oracle-Suites":
            suites.extend(s.strip() for s in value.split(",") if s.strip())
        elif key == "Oracle-Fault":
            fault = value
        elif key == "Subject":
            subject = value.split("]", 1)[1].strip() if value.startswith("[") and "]" in value else value
    return Mutant(f"{product}/{path.stem}", product, path, tuple(sorted(paths)), tuple(dict.fromkeys(suites)),
                  fault or subject or path.stem)


def load_mutants(root: Path, products: Sequence[str], only: Sequence[str] = ()) -> List[Mutant]:
    mutants = []
    for product in products:
        for path in sorted((root / product).glob("*.patch")):
            mutant = parse_mutant(path, product)
            if only and not any(fnmatch.fnmatchcase(mutant.id, glob) for glob in only):
                continue
            mutants.append(mutant)
    return mutants


def load_suite_map(path: Path) -> List[Tuple[str, Tuple[str, ...]]]:
    """tests/oracle/suite-map.json (task 009): {"rules": [{"paths": [glob], "suites": [name]}]}
    or {glob: [name]}; keys that start with "$" or "_" are comments."""
    if not path.is_file():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as error:
        raise oracle.UsageError(f"{path}: {error}") from None
    rules: List[Tuple[str, Tuple[str, ...]]] = []
    if isinstance(data, dict) and isinstance(data.get("rules"), list):
        for rule in data["rules"]:
            for glob in rule.get("paths") or ():
                rules.append((glob, tuple(rule.get("suites") or ())))
    elif isinstance(data, dict):
        for glob, suites in data.items():
            if not glob.startswith(("$", "_")) and isinstance(suites, list):
                rules.append((glob, tuple(suites)))
    return rules


def suite_sizes(cases: Sequence[oracle.Case], product: str) -> Dict[str, int]:
    """Cases per suite that the product can run on its platform."""
    selected, _ = oracle.select_cases(cases, suites=(), filters=(), product=product,
                                      platform=PRODUCT_PLATFORM[product])
    sizes: Dict[str, int] = {}
    for case in selected:
        sizes[case.suite] = sizes.get(case.suite, 0) + 1
    return sizes


def candidate_suites(mutant: Mutant, sizes: Mapping[str, int],
                     suite_map: Sequence[Tuple[str, Tuple[str, ...]]]) -> Tuple[List[Tuple[str, int]], str]:
    """The suites to try, smallest first, and where the list came from."""
    if mutant.suites:
        names, source = list(mutant.suites), "Oracle-Suites"
    else:
        mapped = [s for glob, suites in suite_map for s in suites
                  if any(fnmatch.fnmatchcase(p, glob) for p in mutant.paths)]
        names, source = (mapped, "suite-map.json") if mapped else (list(sizes), "every suite")
    runnable = [(name, sizes[name]) for name in dict.fromkeys(names) if sizes.get(name)]
    return sorted(runnable, key=lambda item: (item[1], item[0])), source


# ---------------------------------------------------------------------------------------- verdicts


@dataclass
class Trial:
    suite: str
    cases: int
    verdict: str  # caught | survived | unmeasured
    reasons: List[str] = field(default_factory=list)
    dir: Optional[str] = None

    def to_json(self) -> Dict[str, Any]:
        return {"suite": self.suite, "cases": self.cases, "verdict": self.verdict, "reasons": self.reasons,
                "dir": self.dir}


@dataclass
class Outcome:
    mutant: Mutant
    verdict: str  # caught | missed | unviable | unmeasured
    caught_by: Optional[str] = None
    source: str = ""
    trials: List[Trial] = field(default_factory=list)
    error: Optional[str] = None

    def to_json(self) -> Dict[str, Any]:
        return {
            "id": self.mutant.id,
            "product": self.mutant.product,
            "patch": rel(self.mutant.path),
            "fault": self.mutant.fault,
            "paths": list(self.mutant.paths),
            "verdict": self.verdict,
            "caught_by": self.caught_by,
            "candidates_from": self.source,
            "trials": [t.to_json() for t in self.trials],
            "error": self.error,
        }


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(REPO).as_posix()
    except ValueError:
        return str(path)


def violation_key(violation: Any) -> Tuple[str, str, str]:
    get = violation.get if isinstance(violation, Mapping) else (lambda k: getattr(violation, k, None))
    return str(get("id")), str(get("case")), str(get("pointer"))


def run_violations(run_dir: Path) -> Optional[set]:
    """Invariant violations of a run (invariants.check_run, task 110), or None before 110 lands."""
    module = oracle.load_sibling("invariants")
    check = getattr(module, "check_run", None) if module else None
    if check is None:
        return None
    return {violation_key(v) for v in check(run_dir)}


def judge(base: Mapping[str, Any], head: Mapping[str, Any], comparison: Mapping[str, Any],
          new_violations: Iterable[Tuple[str, str, str]] = ()) -> Tuple[str, List[str]]:
    """caught, survived or unmeasured for one suite, with the reasons."""
    for side, receipt in (("base", base), ("mutant", head)):
        if receipt.get("infra_errors"):
            return UNMEASURED, [f"{side} run infra error: {e}" for e in receipt["infra_errors"][:3]]
    reasons = [f"divergent: {cid}" for cid in comparison.get("divergent") or ()]
    base_unexpected = set(base.get("unexpected") or ())
    for cid in sorted(set(head.get("unexpected") or ()) - base_unexpected):
        status = (head.get("cases") or {}).get(cid, {}).get("status")
        reasons.append(f"new unexpected result: {cid} ({status})")
    reasons.extend(f"invariant {inv} violated: {cid} {pointer}" for inv, cid, pointer in sorted(new_violations))
    if reasons:
        return CAUGHT, reasons
    if comparison.get("refused"):
        return UNMEASURED, [f"comparison refused: {comparison['refused']}"]
    flaky = sorted(set(head.get("flaky") or ()) - set(base.get("flaky") or ()))
    note = [f"flaky only (not a catch): {', '.join(flaky[:5])}"] if flaky else []
    return SURVIVED, note + [f"compared {comparison.get('compared', 0)} cases, all equal or explained"]


# ---------------------------------------------------------------------------------------- git


def git(repo: Path, *args: str, env: Optional[Mapping[str, str]] = None) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], check=False, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, env={**os.environ, **env} if env else None)


def must(proc: subprocess.CompletedProcess, what: str, error: type = InfraError) -> str:
    if proc.returncode != 0:
        raise error(f"{what} failed (exit {proc.returncode}): {(proc.stderr or proc.stdout).strip()[-600:]}")
    return proc.stdout


def apply_check(repo: Path, sha: str, patch: Path) -> Optional[str]:
    """`git apply --check` of the patch against the tree of SHA, without a checkout. None when it applies."""
    with tempfile.TemporaryDirectory(prefix="oracle-mutant-index-") as tmp:
        env = {"GIT_INDEX_FILE": str(Path(tmp) / "index")}
        must(git(repo, "read-tree", sha, env=env), f"git read-tree {sha}")
        proc = git(repo, "apply", "--cached", "--check", str(patch.resolve()), env=env)
    return None if proc.returncode == 0 else (proc.stderr or proc.stdout).strip()[-600:]


# ---------------------------------------------------------------------------------------- backends


class Backend:
    """Measures one product's mutants. trial() runs base and base+patch on one suite and judges them."""

    product = ""

    def trial(self, mutant: Mutant, suite: str, cases: int, out: Path) -> Trial:
        raise NotImplementedError

    def close(self) -> None:
        pass


class VmDaemonBackend(Backend):
    """daemon mutants on the Linux VM: one worktree, base build, then apply/build/revert per patch."""

    product = "daemon"

    def __init__(self, *, repo: Path, sha: str, out: Path, corpus: Path, expectations_root: Path,
                 worktree_base: Path, target_dir: Path, jobs: Optional[int], build_script: Path = BUILD_SCRIPT,
                 open_session: Optional[oracle.SessionOpener] = None, keep_worktree: bool = False) -> None:
        self.repo, self.sha, self.out = repo, sha, out
        self.corpus, self.expectations_root = corpus, expectations_root
        self.worktree = worktree_base / f"mutants-{sha[:12]}-{oracle.new_run_id()[-6:]}"
        self.target_dir, self.jobs, self.build_script = target_dir, jobs, build_script
        self.open_session, self.keep_worktree = open_session, keep_worktree
        self.ready = False
        self.base_binary: Optional[str] = None
        self.binaries: Dict[str, str] = {}
        self.base_runs: Dict[str, oracle.RunView] = {}
        self.broken: Optional[str] = None

    # -- worktree and builds

    def prepare(self) -> None:
        """Worktree and base build, once. A failure stops every later daemon trial with the same error."""
        if self.broken:
            raise InfraError(self.broken)
        if self.base_binary:
            return
        try:
            self.worktree.parent.mkdir(parents=True, exist_ok=True)
            must(git(self.repo, "worktree", "add", "--detach", str(self.worktree), self.sha), "git worktree add")
            self.ready = True
            if git(self.worktree, "config", "-f", ".gitmodules", "--get", "submodule.ghostty-next.path").returncode == 0:
                reference = self.repo / "ghostty-next"
                extra = ["--reference", str(reference)] if (reference / ".git").exists() else []
                must(git(self.worktree, "submodule", "update", "--init", *extra, "ghostty-next"), "submodule ghostty-next")
            self.base_binary = self.build("base", error=InfraError)
        except InfraError as error:
            self.broken = f"base: {error}"
            raise InfraError(self.broken) from None

    def build(self, label: str, *, error: type) -> str:
        proc = subprocess.run(["bash", str(self.build_script), "build", "--checkout", str(self.worktree),
                               "--target-dir", str(self.target_dir)],
                              check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
        if proc.returncode != 0 or not lines:
            raise error(f"build of {label} failed (exit {proc.returncode}): {proc.stderr.strip()[-800:]}")
        kept = self.out / "builds" / label.replace("/", "-") / Path(lines[-1]).name
        kept.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(lines[-1], kept)  # the next build overwrites the target dir's binary
        return str(kept)

    def assert_clean(self, after: str) -> None:
        status = must(git(self.worktree, "status", "--porcelain", "--untracked-files=all"), "git status")
        if status.strip():
            self.broken = f"the worktree is not clean after {after}: {status.strip()[:300]}"
            raise InfraError(self.broken)

    def mutant_binary(self, mutant: Mutant) -> str:
        if mutant.id in self.binaries:
            return self.binaries[mutant.id]
        self.prepare()
        patch = str(mutant.path.resolve())
        must(git(self.worktree, "apply", patch), f"git apply {rel(mutant.path)}", MutantError)
        try:
            binary = self.build(mutant.id, error=MutantError)
        finally:
            must(git(self.worktree, "apply", "-R", patch), f"git apply -R {rel(mutant.path)}")
            self.assert_clean(f"reverting {mutant.id}")
        self.binaries[mutant.id] = binary
        return binary

    # -- runs

    def run(self, binary: str, suite: str, out: Path, ref: str) -> oracle.RunView:
        argv = ["run", "--product", "daemon", "--suite", suite, "--platform", "linux", "--corpus", str(self.corpus),
                "--expectations-root", str(self.expectations_root)]
        if self.jobs:
            argv += ["--jobs", str(self.jobs)]
        args = oracle.build_parser().parse_args(argv)
        options = oracle.options_from_args(args, retry_default=oracle.DEFAULT_RETRY_LIMIT, out=out,
                                           run_id=f"{oracle.new_run_id()}-{out.name}", switch=None, arm=None,
                                           switches={}, ref=ref, binary=binary)
        oracle.run_one(options, open_session=self.open_session)
        view, errors = oracle.merge_runs([out], require_complete=True)
        if errors:
            raise InfraError("; ".join(errors))
        return view

    def base_run(self, suite: str) -> oracle.RunView:
        if suite not in self.base_runs:
            self.prepare()
            self.base_runs[suite] = self.run(str(self.base_binary), suite, self.out / "base-runs" / suite, self.sha)
        return self.base_runs[suite]

    def trial(self, mutant: Mutant, suite: str, cases: int, out: Path) -> Trial:
        binary = self.mutant_binary(mutant)
        base = self.base_run(suite)
        head = self.run(binary, suite, out / "head", f"{self.sha}+{mutant.id}")
        oracle.compare_views(base, head, a_dir=base.directories[0], b_dir=head.directories[0], out=out,
                             labels=("base", mutant.id), partial=False, expected=[],
                             rules=oracle.comparison_rules(head, self.expectations_root))
        comparison = json.loads((out / "comparison.json").read_text(encoding="utf-8"))
        verdict, reasons = judge(base.receipt, head.receipt, comparison,
                                 new_invariant_violations(base.directories[0], head.directories[0]))
        return Trial(suite, cases, verdict, reasons, str(out))

    def close(self) -> None:
        if self.ready and not self.keep_worktree:
            git(self.repo, "worktree", "remove", "--force", str(self.worktree))


def new_invariant_violations(base_dir: Path, head_dir: Path) -> List[Tuple[str, str, str]]:
    base, head = run_violations(base_dir), run_violations(head_dir)
    if base is None or head is None:
        return []
    return sorted(head - base)


class FleetAppBackend(Backend):
    """app mutants on the fleet: fleet.py runs base and base+patch on one host and compares them."""

    product = "app"

    def __init__(self, *, sha: str, fleet: Path = FLEET, runner: Callable[[List[str]], int] = None) -> None:
        self.sha, self.fleet = sha, fleet
        self.runner = runner or (lambda cmd: subprocess.run(cmd, check=False).returncode)

    def trial(self, mutant: Mutant, suite: str, cases: int, out: Path) -> Trial:
        if not self.fleet.is_file():
            raise InfraError("app mutants run on the fleet through fleet.py, not on this branch yet (p15-oracle-050)")
        code = self.runner([sys.executable, "-I", str(self.fleet), "diff", "--product", "app", "--base", self.sha,
                            "--head", self.sha, "--head-mutant", str(mutant.path.resolve()), "--suite", suite,
                            "--out", str(out)])
        try:
            comparison = json.loads((out / "comparison.json").read_text(encoding="utf-8"))
            base = oracle.read_receipt(out / "base")
            head = oracle.read_receipt(out / "head")
        except (OSError, ValueError, oracle.UsageError) as error:
            raise InfraError(f"fleet.py diff exited {code} without its comparison and run receipts: {error}") from None
        verdict, reasons = judge(base, head, comparison, new_invariant_violations(out / "base", out / "head"))
        return Trial(suite, cases, verdict, reasons, str(out))


# ---------------------------------------------------------------------------------------- evaluation


def evaluate_mutant(mutant: Mutant, backend: Optional[Backend], candidates: Sequence[Tuple[str, int]],
                    source: str, out: Path) -> Outcome:
    outcome = Outcome(mutant, MISSED, source=source)
    if backend is None:
        outcome.verdict, outcome.error = UNMEASURED, f"no backend runs {mutant.product} mutants here"
        return outcome
    for suite, cases in candidates:
        try:
            trial = backend.trial(mutant, suite, cases, out / mutant.id / suite)
        except MutantError as error:
            outcome.verdict, outcome.error = UNVIABLE, str(error)
            return outcome
        except (InfraError, oracle.UsageError) as error:
            trial = Trial(suite, cases, UNMEASURED, [str(error)])
        outcome.trials.append(trial)
        if trial.verdict == CAUGHT:
            outcome.verdict, outcome.caught_by = CAUGHT, suite
            return outcome
    if any(t.verdict == UNMEASURED for t in outcome.trials):
        outcome.verdict = UNMEASURED
        outcome.error = next(t.reasons[0] for t in outcome.trials if t.verdict == UNMEASURED and t.reasons)
    return outcome


def evaluate(mutants: Sequence[Mutant], backends: Mapping[str, Optional[Backend]], cases: Sequence[oracle.Case],
             suite_map: Sequence[Tuple[str, Tuple[str, ...]]], out: Path,
             preflight: Callable[[Mutant], Optional[str]]) -> List[Outcome]:
    """Every mutant's verdict. Products run in parallel; a product's mutants run in order (one worktree)."""
    sizes = {product: suite_sizes(cases, product) for product in {m.product for m in mutants}}

    def one_product(product: str) -> List[Outcome]:
        results = []
        for mutant in (m for m in mutants if m.product == product):
            problems = mutant.path_errors()
            refused = preflight(mutant)
            if refused:
                problems.append(f"git apply --check: {refused}")
            if problems:
                results.append(Outcome(mutant, UNVIABLE, error="; ".join(problems)))
                continue
            candidates, source = candidate_suites(mutant, sizes[product], suite_map)
            results.append(evaluate_mutant(mutant, backends.get(product), candidates, source, out))
            print(f"mutant {mutant.id}: {results[-1].verdict}"
                  + (f" by {results[-1].caught_by}" if results[-1].caught_by else ""), flush=True)
        return results

    products = sorted({m.product for m in mutants})
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(products) or 1) as pool:
        by_product = dict(zip(products, pool.map(one_product, products)))
    order = {m.id: i for i, m in enumerate(mutants)}
    return sorted((o for results in by_product.values() for o in results), key=lambda o: order[o.mutant.id])


def required(count: int, rate: Fraction) -> int:
    return -(-count * rate.numerator // rate.denominator)


def gate(outcomes: Sequence[Outcome], complete: Mapping[str, bool]) -> Tuple[Dict[str, Any], int]:
    """The 19/20 and 9/10 gates. A gate applies to a product when every one of its mutants was selected,
    and the total gate when every product's set was; otherwise the run only reports."""

    def tally(items: Sequence[Outcome], rate: Fraction, applies: bool) -> Dict[str, Any]:
        counts = {v: sum(1 for o in items if o.verdict == v) for v in (CAUGHT, MISSED, UNVIABLE, UNMEASURED)}
        need = required(len(items), rate)
        if counts[CAUGHT] >= need:
            state = "pass"
        elif counts[CAUGHT] + counts[UNMEASURED] >= need:
            state = "undecided"
        else:
            state = "fail"
        return {"mutants": len(items), **counts, "required": need, "rate": f"{rate.numerator}/{rate.denominator}",
                "applies": applies, "state": state}

    products = sorted({o.mutant.product for o in outcomes})
    report = {
        "products": {p: tally([o for o in outcomes if o.mutant.product == p], PRODUCT_RATE, complete.get(p, False))
                     for p in products},
        "total": tally(outcomes, TOTAL_RATE, all(complete.get(p, False) for p in PRODUCTS)),
    }
    gates = [g for g in (*report["products"].values(), report["total"]) if g["applies"]]
    if not gates:  # a subset run: every selected mutant must be caught
        gates = [{**report["total"], "state": "pass" if report["total"][CAUGHT] == len(outcomes) else
                  ("undecided" if report["total"][CAUGHT] + report["total"][UNMEASURED] == len(outcomes) else "fail")}]
    states = {g["state"] for g in gates}
    code = EXIT_FAILED if "fail" in states else EXIT_UNDECIDED if "undecided" in states else EXIT_OK
    return report, code


def corpus_gaps(outcomes: Sequence[Outcome], sha: str) -> List[Dict[str, Any]]:
    """One MQ-mutants queue line per missed mutant: a corpus-gap task."""
    lines = []
    for o in outcomes:
        if o.verdict != MISSED:
            continue
        smallest = o.trials[0].suite if o.trials else None
        where = f"the {smallest} suite" if smallest else f"a {o.mutant.product} suite (no runnable case today)"
        lines.append({
            "queue": QUEUE,
            "kind": "corpus-gap",
            "source": f"oracle.py selftest --mutants ({TASK})",
            "sha": sha,
            "mutant": o.mutant.id,
            "product": o.mutant.product,
            "patch": rel(o.mutant.path),
            "fault": o.mutant.fault,
            "paths": list(o.mutant.paths),
            "suites_tried": [t.suite for t in o.trials],
            "task": f"corpus gap: add a case to {where} that catches {o.mutant.id} ({o.mutant.fault})",
        })
    return lines


# ---------------------------------------------------------------------------------------- CLI


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="oracle.py selftest --mutants",
                                     description="Run the smallest catching suite per seeded patch mutant; "
                                                 "fail below 19/20 (9/10 per product).")
    parser.add_argument("--product", choices=(*PRODUCTS, "all"), default="all")
    parser.add_argument("--only", action="append", help="mutant id globs (<product>/<stem>), comma separated")
    parser.add_argument("--repo", type=Path, default=REPO, help="the checkout the mutants apply to (default this one)")
    parser.add_argument("--ref", default="HEAD", help="the SHA every mutant applies to (default HEAD)")
    parser.add_argument("--mutants-root", type=Path, default=MUTANTS_ROOT)
    parser.add_argument("--corpus", type=Path, default=oracle.DEFAULT_CORPUS)
    parser.add_argument("--expectations-root", type=Path, default=oracle.DEFAULT_EXPECTATIONS_ROOT)
    parser.add_argument("--suite-map", type=Path, default=SUITE_MAP)
    parser.add_argument("--out", type=Path, help=f"output directory (default {DEFAULT_OUT_BASE}/<run id>)")
    parser.add_argument("--gaps-out", type=Path, help="corpus-gap queue lines (default OUT/corpus-gaps.jsonl)")
    parser.add_argument("--jobs", type=int, help="parallel daemon sessions per suite run (default oracle.py's)")
    parser.add_argument("--worktree-base", type=Path, default=DEFAULT_WORKTREE_BASE)
    parser.add_argument("--target-dir", type=Path, help=f"cargo target dir (default {DEFAULT_TARGET_BASE}/mutants-<sha12>)")
    parser.add_argument("--keep-worktree", action="store_true")
    parser.add_argument("--list", action="store_true", help="print mutants, apply checks and candidate suites; run nothing")
    parser.add_argument("--json", action="store_true", help="print mutants.json")
    return parser


def resolve_sha(repo: Path, ref: str) -> str:
    return must(git(repo, "rev-parse", "--verify", f"{ref}^{{commit}}"), f"git rev-parse {ref}",
                oracle.UsageError).strip()


def print_report(document: Dict[str, Any]) -> None:
    for item in document["mutants"]:
        detail = f" by {item['caught_by']}" if item["caught_by"] else ""
        tried = ", ".join(f"{t['suite']}({t['cases']}):{t['verdict']}" for t in item["trials"]) or "none"
        print(f"  {item['verdict']:10} {item['id']}{detail}  [{item['candidates_from']}: {tried}]"
              + (f"  {item['error']}" if item["error"] else ""))
    for name, g in [*sorted(document["gate"]["products"].items()), ("total", document["gate"]["total"])]:
        applies = "" if g["applies"] else " (not applied: not every mutant selected)"
        print(f"  {name}: caught {g['caught']}/{g['mutants']}, need {g['required']} ({g['rate']}), "
              f"missed {g['missed']}, unviable {g['unviable']}, unmeasured {g['unmeasured']}: {g['state']}{applies}")
    print(f"  corpus gaps: {len(document['corpus_gaps'])} -> {document['gaps_out']}")
    print(f"  report: {document['report']}")


def main(argv: Optional[List[str]] = None, *, backends: Optional[Mapping[str, Optional[Backend]]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        products = PRODUCTS if args.product == "all" else (args.product,)
        only = oracle.parse_list(args.only)
        sha = resolve_sha(args.repo, args.ref)
        mutants = load_mutants(args.mutants_root, products, only)
        if not mutants:
            raise oracle.UsageError(f"no mutants under {args.mutants_root}/{{{','.join(products)}}}/*.patch "
                                    "(p15-oracle-026)")
        cases, errors = oracle.load_corpus(args.corpus)
        if errors:
            raise oracle.UsageError("corpus errors (run `oracle.py check`):\n  " + "\n  ".join(errors[:20]))
        suite_map = load_suite_map(args.suite_map)
        preflight = lambda m: apply_check(args.repo, sha, m.path)  # noqa: E731
        if args.list:
            sizes = {p: suite_sizes(cases, p) for p in products}
            for m in mutants:
                candidates, source = candidate_suites(m, sizes[m.product], suite_map)
                problems = m.path_errors() + [f"git apply --check: {e}" for e in [preflight(m)] if e]
                print(f"{m.id}: {m.fault}\n  paths: {', '.join(m.paths)}\n  suites ({source}): "
                      + (", ".join(f"{s}({n})" for s, n in candidates) or "none runnable")
                      + "".join(f"\n  unviable: {p}" for p in problems))
            return EXIT_OK
        out = args.out or DEFAULT_OUT_BASE / oracle.new_run_id()
        oracle.check_out_dir(out)
        out.mkdir(parents=True, exist_ok=True)
        if backends is None:
            backends = {
                "daemon": VmDaemonBackend(repo=args.repo, sha=sha, out=out / "daemon", corpus=args.corpus,
                                          expectations_root=args.expectations_root, worktree_base=args.worktree_base,
                                          target_dir=args.target_dir or DEFAULT_TARGET_BASE / f"mutants-{sha[:12]}",
                                          jobs=args.jobs, keep_worktree=args.keep_worktree)
                if oracle.current_platform() == "linux" else None,
                "app": FleetAppBackend(sha=sha),
            }
        started = time.time()
        try:
            outcomes = evaluate(mutants, backends, cases, suite_map, out, preflight)
        finally:
            for backend in backends.values():
                if backend is not None:
                    backend.close()
        everything = load_mutants(args.mutants_root, PRODUCTS)
        complete = {p: {m.id for m in everything if m.product == p} <= {m.id for m in mutants} for p in products}
        report, code = gate(outcomes, complete)
        gaps = corpus_gaps(outcomes, sha)
        gaps_out = args.gaps_out or out / "corpus-gaps.jsonl"
        oracle.write_jsonl(gaps_out, gaps)
        document = {
            "schema": "cmux-oracle-mutants-v1",
            "task": TASK,
            "sha": sha,
            "host": oracle.host_info(),
            "duration_s": round(time.time() - started, 3),
            "mutants": [o.to_json() for o in outcomes],
            "gate": report,
            "corpus_gaps": gaps,
            "gaps_out": str(gaps_out),
            "report": str(out / "mutants.json"),
            "exit": code,
        }
        oracle.write_json(out / "mutants.json", document)
        if args.json:
            print(json.dumps(document, indent=1, sort_keys=True))
        else:
            print(f"oracle selftest --mutants at {sha[:12]}: {len(outcomes)} mutants")
            print_report(document)
        return code
    except oracle.UsageError as error:
        print(f"oracle selftest --mutants: {error}", file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
