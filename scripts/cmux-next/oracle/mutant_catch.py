#!/usr/bin/env python3
"""The oracle's mutation smoke run: `oracle.py selftest --mutants` (p15-oracle-115).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3F "Mutation strength", acceptance item 7 and task 115.
Stdlib only, Python 3.9+, safe under `python3 -I`.

    oracle.py selftest --mutants [--ref REF] [--product app|daemon]... [--mutant GLOB]... [--out DIR]
                                 [--jobs N] [--dry-run] [--json]

For each seeded patch mutant of tests/oracle/mutants/<product>/ (task 026, patch_mutants.py), the smallest
selection that can catch it runs first, base against base+patch at one SHA, and the first one that catches it
ends that mutant's search:

1. `exercising`: every case the product can run whose steps call one of the names in the patch's `Exercises`
   header (a resource.call `method` or an action.run `action`), in any suite.
2. `suite`: the whole suite of the patch's `Suite` header, when it holds other cases than rung 1.

A rung that selects no case is left out. Each rung is one diff run with the diff retry policy
(oracle.DEFAULT_RETRY_LIMIT): a case that passes on retry is Flaky and diff.py leaves it out, so a flaky case
is never a catch. A mutant is:
- caught: a rung's comparison has a divergent case: a checkpoint value or a case result (diff.py compares the
  result too, so a Failure the base does not have, an invariant failure of the run included, is a divergence);
- missed: every rung compared cases and none diverged, or no case exercises the fault at all. Each miss is one
  MQ-mutants corpus-gap line (OUT/corpus-gaps.jsonl): the suite to extend and what its new case must do;
- unviable: the patch does not apply at the SHA, or the head build fails; it counts as not caught, and its
  line asks for the fault to be written again against the new code (tests/oracle/mutants/README.md);
- unmeasured: no rung caught it and at least one could not compare (refused, incomplete, infra error).

Gate (spec 5, item 7): over the full checked-in set, >= 19/20 caught and >= 9/10 per product; with
`--product`, that product's 9/10; with `--mutant`, every selected mutant. Unmeasured mutants count both ways:
the run passes when the gate holds without them, fails when it fails with all of them caught, and is
undecided otherwise.

Backends (both apply the patch to the head side only, in the job's own worktree; nothing goes into the sources):
- daemon, on the Linux VM: `linux_run.sh diff SHA SHA --mutant PATCH --suite S --out DIR -- --retry-limit 3
  [--filter IDS]` through the runnerd queue (one base run per selection is shared by every mutant);
  DIR/comparison.json.
- app, on the fleet: `fleet.py diff --base SHA --head SHA --head-mutant tests/oracle/mutants/app/NAME.patch
  --suite S [--filter IDS] --retry-limit 3 --out DIR`; DIR/compare/comparison.json. The patch must be in the
  commit's tree (fleet.py checks).

Outputs (outside the checkout; default /tmp/oracle/mutants/<run id>): mutants.json (cmux-oracle-mutants-v1:
every mutant, its rungs, the comparisons and the gate), corpus-gaps.jsonl, and one directory per rung run.
Exit: 0 pass, 1 fail, 2 bad usage, 3 undecided (an unmeasured mutant could change the verdict).

Chrome reference: docs/testing/mutation_testing.md (the Gerrit Mutation Testing plugin reports a change's
surviving mutants as findings to act on); test selection by what a change touches is the CQ's analyze step
(testing/buildbot/filters, `gn analyze`), here the patch's own `Exercises` header. cargo mutants (task 191)
stays the broad measure; these 20 faults are the smoke set every product run must still catch.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import glob
import json
import platform as platform_mod
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import oracle  # noqa: E402  (corpus, selection, retry policy, out-dir rule)
import patch_mutants  # noqa: E402  (the seeded mutants of task 026)

TASK = "p15-oracle-115"
SCHEMA = "cmux-oracle-mutants-v1"
GAP_SCHEMA = "cmux-oracle-corpus-gap-v1"
QUEUE = "MQ-mutants"
REPO = oracle.REPO
DEFAULT_OUT_BASE = Path("/tmp/oracle/mutants")
LINUX_RUN = HERE / "linux_run.sh"
FLEET = HERE / "fleet.py"
DEFAULT_JOBS = 10
# The platform each product's cases run on (oracle.select_cases).
PLATFORM = {"daemon": "linux", "app": "mac"}
# Spec 5, item 7: caught / total for the whole set and for each product.
TOTAL_RATE = (19, 20)
PRODUCT_RATE = (9, 10)

CAUGHT, SURVIVED, MISSED, UNVIABLE, UNMEASURED = "caught", "survived", "missed", "unviable", "unmeasured"
PASS, FAIL, UNDECIDED = "pass", "fail", "undecided"
EXIT_PASS, EXIT_FAIL, EXIT_USAGE, EXIT_UNDECIDED = 0, 1, 2, 3
EXITS = {PASS: EXIT_PASS, FAIL: EXIT_FAIL, UNDECIDED: EXIT_UNDECIDED}


# ------------------------------------------------------------------------------------------------ selection


def exercise_names(exercises: str) -> frozenset:
    """The names in an `Exercises` header: `closePane (layout.splitSizing even)` -> closePane, layout.splitSizing,
    even. Words that are no method or action select nothing, so prose in the header is harmless."""
    return frozenset(token for token in re.split(r"[\s,;()]+", exercises) if token)


def called_names(case: oracle.Case) -> frozenset:
    """What a case's steps call: each resource.call `method` and action.run `action`."""
    names = set()
    for step in case.data.get("steps") or ():
        args = step.get("args") if isinstance(step, dict) else None
        if isinstance(args, dict):
            names.update(value for key in ("method", "action") for value in (args.get(key),) if isinstance(value, str))
    return frozenset(names)


@dataclass(frozen=True)
class Rung:
    """One selection a mutant runs against: `exercising` (case ids) or `suite` (a whole suite)."""

    label: str
    suite: str
    cases: Tuple[str, ...]
    filtered: bool

    def filter_arg(self) -> List[str]:
        return ["--filter", ",".join(glob.escape(case) for case in self.cases)] if self.filtered else []

    def record(self) -> Dict[str, Any]:
        return {"rung": self.label, "suite": self.suite, "cases": len(self.cases)}


def ladder(mutant: patch_mutants.Mutant, cases: Sequence[oracle.Case]) -> List[Rung]:
    """The mutant's rungs, smallest first; a rung that selects nothing or repeats the one before is left out."""
    runnable, _ = oracle.select_cases(cases, suites=(), filters=(), product=mutant.product,
                                      platform=PLATFORM[mutant.product])
    wanted = exercise_names(mutant.exercises)
    exercising = tuple(sorted(case.id for case in runnable if called_names(case) & wanted))
    suite = tuple(sorted(case.id for case in runnable if case.suite == mutant.suite))
    rungs = []
    if exercising:
        rungs.append(Rung("exercising", "all", exercising, filtered=True))
    if suite and set(suite) != set(exercising):
        rungs.append(Rung("suite", mutant.suite, suite, filtered=False))
    return rungs


# ------------------------------------------------------------------------------------------------ judging


@dataclass(frozen=True)
class Outcome:
    """One rung's comparison: caught, survived, unviable or unmeasured, with its evidence."""

    status: str
    detail: str = ""
    divergent: Tuple[str, ...] = ()
    compared: int = 0
    comparison: Optional[str] = None


def judge_comparison(path: Path) -> Outcome:
    """A comparison.json that oracle.compare_views wrote. A refusal or nothing compared is no evidence either way."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return Outcome(UNMEASURED, f"no readable comparison ({error})")
    if not isinstance(document, dict):
        return Outcome(UNMEASURED, f"{path}: not a comparison object")
    divergent = tuple(document.get("divergent") or ())
    compared = int(document.get("compared") or 0)
    where = str(path)
    if document.get("refused"):
        return Outcome(UNMEASURED, f"refused: {document['refused']}", compared=compared, comparison=where)
    if divergent:
        return Outcome(CAUGHT, f"{len(divergent)} of {compared} compared cases diverged", divergent, compared, where)
    if compared and document.get("diff_exit") == oracle.DIFF_OK:
        return Outcome(SURVIVED, f"{compared} compared cases, none diverged", (), compared, where)
    return Outcome(UNMEASURED, f"diff.py exit {document.get('diff_exit')} with {compared} compared cases",
                   compared=compared, comparison=where)


Runner = Callable[[Sequence[str], Path], int]


def run_logged(argv: Sequence[str], log: Path) -> int:
    """Runs one backend command with its output in `log` (the rung's directory)."""
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as handle:
        handle.write("$ " + " ".join(argv) + "\n")
        handle.flush()
        return subprocess.run(list(argv), cwd=str(REPO), stdout=handle, stderr=subprocess.STDOUT,
                              check=False).returncode


def log_tail(log: Path, lines: int = 3) -> str:
    try:
        text = log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return " | ".join(line.strip() for line in text.strip().splitlines()[-lines:])


class Backend:
    """Runs base against base+patch for one rung and judges the comparison."""

    product = ""

    def __init__(self, runner: Runner = run_logged) -> None:
        self.runner = runner

    def command(self, mutant: patch_mutants.Mutant, rung: Rung, sha: str, out: Path) -> List[str]:
        raise NotImplementedError

    def comparison(self, out: Path) -> Path:
        raise NotImplementedError

    def unavailable(self) -> Optional[str]:
        """Why this backend cannot run here, or None."""
        return None

    def judge(self, out: Path, code: int, log: Path) -> Outcome:
        outcome = judge_comparison(self.comparison(out))
        if outcome.status == UNMEASURED and outcome.comparison is None:
            return Outcome(UNMEASURED, f"exit {code}, {outcome.detail}: {log_tail(log)}")
        return outcome

    def check(self, mutant: patch_mutants.Mutant, rung: Rung, sha: str, out: Path) -> Outcome:
        reason = self.unavailable()
        if reason:
            return Outcome(UNMEASURED, reason)
        out.mkdir(parents=True, exist_ok=True)
        log = out / "command.log"
        code = self.runner(self.command(mutant, rung, sha, out), log)
        return self.judge(out, code, log)


class VmBackend(Backend):
    """Daemon mutants: linux_run.sh diff in the runnerd queue on the Linux VM."""

    product = "daemon"

    def __init__(self, runner: Runner = run_logged, system: Optional[str] = None) -> None:
        super().__init__(runner)
        self.system = system or platform_mod.system()

    def unavailable(self) -> Optional[str]:
        if self.system != "Linux":
            return "daemon mutants build and run in the Linux VM's queue (linux_run.sh); nothing was queued"
        return None

    def command(self, mutant: patch_mutants.Mutant, rung: Rung, sha: str, out: Path) -> List[str]:
        return ["bash", str(LINUX_RUN), "diff", sha, sha, "--mutant", str(mutant.path), "--suite", rung.suite,
                "--out", str(out), "--", "--retry-limit", str(oracle.DEFAULT_RETRY_LIMIT), *rung.filter_arg()]

    def comparison(self, out: Path) -> Path:
        return out / "comparison.json"

    def judge(self, out: Path, code: int, log: Path) -> Outcome:
        # linux_run.sh copies a side's build receipt only after that build succeeded.
        if (not self.comparison(out).is_file() and (out / "build-base.json").is_file()
                and not (out / "build-head.json").is_file()):
            return Outcome(UNVIABLE, f"the head build with the patch failed: {log_tail(log)}")
        return super().judge(out, code, log)


class FleetBackend(Backend):
    """App mutants: fleet.py diff, both sides on one worker, the patch applied by scripts/measure/oracle.sh."""

    product = "app"

    def command(self, mutant: patch_mutants.Mutant, rung: Rung, sha: str, out: Path) -> List[str]:
        patch = mutant.path.resolve()
        rel = patch.relative_to(REPO).as_posix() if REPO in patch.parents else str(patch)
        return [sys.executable, "-I", str(FLEET), "diff", "--product", "app", "--base", sha, "--head", sha,
                "--head-mutant", rel, "--suite", rung.suite, *rung.filter_arg(),
                "--retry-limit", str(oracle.DEFAULT_RETRY_LIMIT), "--out", str(out)]

    def comparison(self, out: Path) -> Path:
        return out / "compare" / "comparison.json"


# ------------------------------------------------------------------------------------------------ one mutant


@dataclass
class Result:
    mutant: patch_mutants.Mutant
    rungs: List[Rung]
    status: str = UNMEASURED
    reason: str = ""
    catcher: Optional[Rung] = None
    tried: List[Dict[str, Any]] = field(default_factory=list)

    def record(self) -> Dict[str, Any]:
        m = self.mutant
        return {"id": m.id, "product": m.product, "suite": m.suite, "exercises": m.exercises, "fault": m.fault,
                "patch": str(m.path), "status": self.status, "reason": self.reason,
                "caughtBy": self.catcher.record() if self.catcher else None,
                "rungs": [rung.record() for rung in self.rungs], "tried": self.tried}


def rung_dir(out: Path, mutant: patch_mutants.Mutant, index: int, rung: Rung) -> Path:
    return out / mutant.product / mutant.name / f"{index}-{rung.label}"


def measure(mutant: patch_mutants.Mutant, rungs: Sequence[Rung], sha: str, backend: Backend, out: Path,
            apply_error: Optional[str] = None) -> Result:
    """Runs the rungs smallest first and stops at the first catch (or at a patch that cannot be built)."""
    result = Result(mutant, list(rungs))
    if apply_error:
        result.status, result.reason = UNVIABLE, apply_error
        return result
    if not rungs:
        result.status = MISSED
        result.reason = (f"no {mutant.product} case calls {', '.join(sorted(exercise_names(mutant.exercises)))} "
                         f"and suite {mutant.suite} has no {mutant.product} case")
        return result
    unmeasured: List[str] = []
    for index, rung in enumerate(rungs):
        outcome = backend.check(mutant, rung, sha, rung_dir(out, mutant, index, rung))
        result.tried.append({**rung.record(), "status": outcome.status, "detail": outcome.detail,
                             "compared": outcome.compared, "divergent": list(outcome.divergent),
                             "comparison": outcome.comparison})
        if outcome.status == CAUGHT:
            result.status, result.reason, result.catcher = CAUGHT, outcome.detail, rung
            return result
        if outcome.status == UNVIABLE:
            result.status, result.reason = UNVIABLE, outcome.detail
            return result
        if outcome.status == UNMEASURED:
            unmeasured.append(f"{rung.label}: {outcome.detail}")
    if unmeasured:
        result.status, result.reason = UNMEASURED, "; ".join(unmeasured)
    else:
        result.status = MISSED
        result.reason = "; ".join(f"{t['rung']} ({t['cases']} cases): {t['detail']}" for t in result.tried)
    return result


def gap_line(result: Result, sha: str) -> Optional[Dict[str, Any]]:
    """The MQ-mutants queue line of a mutant that was not caught: a corpus gap, or a stale patch to rewrite."""
    m = result.mutant
    base = {"schema": GAP_SCHEMA, "queue": QUEUE, "task": TASK, "sha": sha, "mutant": m.id, "product": m.product,
            "suite": m.suite, "exercises": m.exercises, "fault": m.fault, "reason": result.reason,
            "tried": [rung.record() for rung in result.rungs]}
    if result.status == MISSED:
        return {**base, "kind": "corpus-gap",
                "title": f"{m.suite}: add a case that catches {m.id}",
                "work": f"a {m.suite} case that calls {m.exercises} where this fault changes the settled state "
                        f"or the result ({m.fault})"}
    if result.status == UNVIABLE:
        return {**base, "kind": "stale-mutant",
                "title": f"rewrite {m.id} against {sha[:12]}",
                "work": "write the same fault again against the current code, with the same name "
                        "(tests/oracle/mutants/README.md)"}
    return None


# ------------------------------------------------------------------------------------------------ the gate


@dataclass(frozen=True)
class Requirement:
    scope: str
    need: int
    of: int
    caught: int
    unmeasured: int

    @property
    def verdict(self) -> str:
        if self.caught >= self.need:
            return PASS
        return UNDECIDED if self.caught + self.unmeasured >= self.need else FAIL

    def record(self) -> Dict[str, Any]:
        return {"scope": self.scope, "need": self.need, "of": self.of, "caught": self.caught,
                "unmeasured": self.unmeasured, "verdict": self.verdict}


def at_least(rate: Tuple[int, int], total: int) -> int:
    """The smallest count that keeps `rate` of `total`: 19/20 of 20 is 19, 9/10 of 10 is 9."""
    caught, out_of = rate
    return -(-caught * total // out_of)


def requirements(results: Sequence[Result], *, full_products: Sequence[str], subset: bool) -> List[Requirement]:
    """Spec 5 item 7 over what was selected: a subset needs every mutant; each full product its 9/10; both
    full products together 19/20."""

    def requirement(scope: str, chosen: Sequence[Result], need: int) -> Requirement:
        return Requirement(scope, need, len(chosen), sum(r.status == CAUGHT for r in chosen),
                           sum(r.status == UNMEASURED for r in chosen))

    if subset:
        return [requirement("selected mutants", results, len(results))]
    out = []
    for product in full_products:
        chosen = [r for r in results if r.mutant.product == product]
        out.append(requirement(product, chosen, at_least(PRODUCT_RATE, len(chosen))))
    if len(full_products) == len(patch_mutants.PRODUCTS):
        out.append(requirement("all", results, at_least(TOTAL_RATE, len(results))))
    return out


def verdict_of(reqs: Sequence[Requirement]) -> str:
    verdicts = {req.verdict for req in reqs}
    if FAIL in verdicts:
        return FAIL
    return UNDECIDED if UNDECIDED in verdicts else PASS


# ------------------------------------------------------------------------------------------------ the run


def select_mutants(mutants: Sequence[patch_mutants.Mutant], products: Sequence[str],
                   globs: Sequence[str]) -> List[patch_mutants.Mutant]:
    return [m for m in mutants
            if m.product in products and (not globs or any(fnmatch.fnmatchcase(m.id, g) for g in globs))]


def default_backends(runner: Runner = run_logged) -> Dict[str, Backend]:
    return {"daemon": VmBackend(runner), "app": FleetBackend(runner)}


def write_json(path: Path, value: Any) -> None:
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(json.dumps(value, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def run(*, ref: str, products: Sequence[str], globs: Sequence[str], root: Path, corpus: Path, out: Path,
        gaps_out: Optional[Path], jobs: int, dry_run: bool, backends: Dict[str, Backend],
        expected_per_product: Optional[int], log: Callable[[str], None] = print) -> Tuple[int, Dict[str, Any]]:
    sha = patch_mutants.resolve(ref)
    loaded, errors = patch_mutants.load(root)
    if errors:
        raise oracle.UsageError("the mutants do not load (patch_mutants.py check):\n  " + "\n  ".join(errors))
    if expected_per_product is not None:
        for product in products:
            count = sum(m.product == product for m in loaded)
            if count != expected_per_product:
                raise oracle.UsageError(f"{root / product}: {count} mutants; the smoke set has "
                                        f"{expected_per_product} per product (patch_mutants.py check)")
    mutants = select_mutants(loaded, products, globs)
    if not mutants:
        raise oracle.UsageError(f"no mutant of {', '.join(products)} matches {', '.join(globs) or '*'} under {root}")
    cases, case_errors = oracle.load_corpus(corpus)
    if case_errors:
        raise oracle.UsageError("the corpus does not load (oracle.py check):\n  " + "\n  ".join(case_errors[:20]))
    plans = [(m, ladder(m, cases)) for m in mutants]
    stale = {}
    for mutant in mutants:
        found = patch_mutants.apply_errors([mutant], sha)
        if found:
            stale[mutant.id] = "; ".join(found)
    log(f"oracle selftest --mutants ({TASK}) at {sha[:12]}: {len(mutants)} mutants, out {out}")
    if dry_run:
        for mutant, rungs in plans:
            steps = ", ".join(f"{r.label} {r.suite} ({len(r.cases)} cases)" for r in rungs) or "no case"
            log(f"  plan {mutant.id}: {steps}" + (f"; stale: {stale[mutant.id]}" if mutant.id in stale else ""))
            for index, rung in enumerate(rungs):
                command = backends[mutant.product].command(mutant, rung, sha, rung_dir(out, mutant, index, rung))
                log("    $ " + " ".join(command))
        return EXIT_PASS, {"schema": SCHEMA, "sha": sha, "dryRun": True,
                           "plan": {m.id: [r.record() for r in rungs] for m, rungs in plans}}

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futures = [pool.submit(measure, m, rungs, sha, backends[m.product], out, stale.get(m.id))
                   for m, rungs in plans]
        results = [future.result() for future in futures]

    full = [p for p in products if not globs]
    reqs = requirements(results, full_products=full, subset=bool(globs))
    verdict = verdict_of(reqs)
    gaps = [line for line in (gap_line(r, sha) for r in results) if line is not None]
    gaps_path = gaps_out or out / "corpus-gaps.jsonl"
    gaps_path.parent.mkdir(parents=True, exist_ok=True)
    with gaps_path.open("w", encoding="utf-8") as handle:
        for line in gaps:
            handle.write(json.dumps(line, sort_keys=True) + "\n")
    document = {"schema": SCHEMA, "task": TASK, "ref": ref, "sha": sha, "products": list(products),
                "mutantGlobs": list(globs), "mutants": [r.record() for r in results],
                "gate": {"verdict": verdict, "requirements": [req.record() for req in reqs]},
                "corpusGaps": str(gaps_path), "exit": EXITS[verdict]}
    write_json(out / "mutants.json", document)
    for result in results:
        caught_by = f" by {result.catcher.label} {result.catcher.suite} ({len(result.catcher.cases)} cases)" \
            if result.catcher else ""
        log(f"  {result.status:<10} {result.mutant.id}{caught_by}: {result.reason}")
    for req in reqs:
        log(f"  gate {req.scope}: {req.caught}/{req.of} caught, need {req.need}"
            + (f", {req.unmeasured} unmeasured" if req.unmeasured else "") + f": {req.verdict}")
    log(f"mutants: {verdict}; {out / 'mutants.json'}; {len(gaps)} {QUEUE} lines in {gaps_path}")
    return EXITS[verdict], document


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="oracle.py selftest --mutants", description=__doc__.split("\n\n")[0])
    parser.add_argument("--ref", default="HEAD", help="the commit both sides build (default HEAD)")
    parser.add_argument("--product", action="append", choices=patch_mutants.PRODUCTS,
                        help="only this product's mutants (repeatable; default both)")
    parser.add_argument("--mutant", action="append", default=[], help="only mutants whose id matches this glob")
    parser.add_argument("--root", type=Path, default=patch_mutants.DEFAULT_ROOT, help="the mutants directory")
    parser.add_argument("--corpus", type=Path, default=oracle.DEFAULT_CORPUS)
    parser.add_argument("--out", type=Path, help=f"output dir outside the checkout (default {DEFAULT_OUT_BASE}/<run>)")
    parser.add_argument("--gaps-out", type=Path, help="the corpus-gap lines (default OUT/corpus-gaps.jsonl)")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS, help=f"mutants at once (default {DEFAULT_JOBS})")
    parser.add_argument("--dry-run", action="store_true", help="print each mutant's rungs and commands; run nothing")
    parser.add_argument("--json", action="store_true", help="print mutants.json")
    return parser


def main(argv: Optional[Sequence[str]] = None, backends: Optional[Dict[str, Backend]] = None) -> int:
    args = build_parser().parse_args(argv)
    products = tuple(dict.fromkeys(args.product or patch_mutants.PRODUCTS))
    out = args.out or DEFAULT_OUT_BASE / oracle.new_run_id()
    try:
        oracle.check_out_dir(out)
        out.mkdir(parents=True, exist_ok=True)
        expected = patch_mutants.EXPECTED_PER_PRODUCT if args.root.resolve() == patch_mutants.DEFAULT_ROOT else None
        code, document = run(ref=args.ref, products=products, globs=args.mutant, root=args.root, corpus=args.corpus,
                             out=out, gaps_out=args.gaps_out, jobs=args.jobs, dry_run=args.dry_run,
                             backends=backends or default_backends(), expected_per_product=expected,
                             log=(lambda line: print(line, file=sys.stderr)) if args.json else print)
    except (oracle.UsageError, patch_mutants.UsageError) as error:
        print(f"selftest --mutants: {error}", file=sys.stderr)
        return EXIT_USAGE
    if args.json:
        print(json.dumps(document, indent=1, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
