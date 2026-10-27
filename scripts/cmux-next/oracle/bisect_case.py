#!/usr/bin/env python3
"""`git bisect run` of one divergent oracle case over the commits of a batch (p15-oracle-009).

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, 3F.6 and task 009. Stdlib only, Python 3.9+, safe under
`python3 -I`. This file is bisect_case.py and not bisect.py: a `bisect.py` beside the oracle scripts would shadow
the stdlib `bisect` module, which `random` (and so `tempfile`) imports, for every oracle script run without -I.

    bisect_case.py --good A --bad B --case SUITE/CASE [--product P] [--all-parents] [--out DIR] [-- DIFF_ARGS]
    oracle.py bisect ARGS                    the same (oracle.py delegates here)

A commit is tested as `oracle.py diff --product P --base GOOD --head COMMIT --suite SUITE --filter CASE` (DIFF_ARGS
are added): on the VM the runnerd queue builds both and keeps the GOOD run's receipt for every step; the app product
goes to the fleet through fleet.py. The verdict of a commit:
    bad   the case is divergent in comparison.json
    good  the case was compared and matched, or its difference is an expected one (explained)
    skip  the diff refused (a build that failed, a host mismatch), or the case was flaky or not comparable
    stop  the oracle failed (bad arguments, a diff.py internal error): the bisection is abandoned
Before bisecting, the ends are checked like LUCI Bisection checks a regression range: BAD must diverge (else the
result is "not-reproducible") and, unless --no-check-good, GOOD against itself must match (else the case is
"not-deterministic" and no commit can be blamed). Then `git bisect start --no-checkout [--first-parent] BAD GOOD`
runs in a temporary worktree that is never checked out, so this checkout and its HEAD are never touched; each step
reads the commit from BISECT_HEAD. The default is --first-parent: a batch of perf/chrome-parity is a merge train, and
the culprit is the merge that brought the change in; --all-parents bisects into the merged branches.

Output (outside the checkout, default /tmp/oracle/bisect/<run id>): bisect.json {"schema": "cmux-oracle-bisect-v1",
"case", "product", "good", "bad", "first_parent", "status", "culprit": {"sha", "subject"} or null, "candidates"
(the commits a skip left undecided), "reason", "steps": [{"sha", "verdict", "reason", "exit", "first_divergence",
"dir"}]}, steps.jsonl, bisect.log (`git bisect log`), and steps/<n>-<sha>/ (each oracle diff's comparison).
Status: "culprit" (exit 0), "not-reproducible" (exit 1), "not-deterministic" or "inconclusive" (exit 3: skipped
commits leave several candidates, an end could not be tested, or the oracle failed). Exit 2: bad arguments.
With a deterministic oracle the steps and the culprit are the same on every run: git picks the midpoints from the
commit graph alone.

Chrome reference:
- tools/bisect-builds.py (chromium/src): bisects a good..bad revision range by testing the midpoint build; a build
  that cannot be tested is skipped, never guessed.
- LUCI Bisection (luci-go bisection/, the test failure analysis): reruns the failing test at the ends of the
  regression range first and stops when the failure does not reproduce; nthsection then narrows the range, and the
  culprit is reported with the reruns that prove it.
- `git bisect run` (git's own): exit 0 good, 1-127 bad, 125 skip, 128 or more abandons the run.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
ORACLE = HERE / "oracle.py"
DEFAULT_MAP = REPO / "tests" / "oracle" / "suite-map.json"
DEFAULT_OUT_BASE = Path("/tmp/oracle/bisect")
SCHEMA = "cmux-oracle-bisect-v1"

GOOD, BAD, SKIP, STOP = "good", "bad", "skip", "stop"
# git bisect run: 0 good, 1 bad, 125 skip, >= 128 abandons the bisection.
GIT_EXIT = {GOOD: 0, BAD: 1, SKIP: 125, STOP: 128}
# oracle.py diff: 0 no unexplained divergence, 1 divergences, 2 bad input, 3 refused, 4 diff.py internal error.
DIFF_BAD_INPUT, DIFF_REFUSED, DIFF_INTERNAL = 2, 3, 4

CULPRIT, NOT_REPRODUCIBLE, NOT_DETERMINISTIC, INCONCLUSIVE = "culprit", "not-reproducible", "not-deterministic", "inconclusive"
EXIT = {CULPRIT: 0, NOT_REPRODUCIBLE: 1, NOT_DETERMINISTIC: 3, INCONCLUSIVE: 3}

STEP_ERROR = "bisect step error:"
FIRST_BAD = re.compile(r"^([0-9a-f]{40}) is the first bad commit$", re.M)
SHA_LINE = re.compile(r"^([0-9a-f]{40})\b", re.M)


class UsageError(Exception):
    """A bad argument, a missing commit or an unreadable map: exit 2."""


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(["git", "-C", str(repo), *args], check=False, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)
    if check and proc.returncode != 0:
        raise UsageError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc


def resolve(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").stdout.strip()


def subject(repo: Path, sha: str) -> str:
    return git(repo, "log", "-1", "--format=%s", sha).stdout.strip()


def default_product(map_path: Path, suite: str) -> str:
    """The first product of the suite map (by name) that runs the suite."""
    try:
        products = json.loads(map_path.read_text(encoding="utf-8"))["products"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise UsageError(f"{map_path}: cannot read the suite map ({error}); pass --product") from None
    running = sorted(p for p, spec in products.items() if suite in (spec.get("suites") or ()))
    if not running:
        raise UsageError(f"no product of {map_path} runs suite {suite}; pass --product")
    return running[0]


# ------------------------------------------------------------------------------------------------------- one step


@dataclass(frozen=True)
class Config:
    repo: Path
    oracle: Path
    product: str
    case: str
    good: str
    out: Path
    diff_args: Tuple[str, ...]

    @property
    def suite(self) -> str:
        return self.case.split("/", 1)[0]

    def to_json(self) -> Dict[str, Any]:
        return {"repo": str(self.repo), "oracle": str(self.oracle), "product": self.product, "case": self.case,
                "good": self.good, "out": str(self.out), "diff_args": list(self.diff_args)}

    @classmethod
    def from_json(cls, data: Dict[str, Any]) -> "Config":
        return cls(Path(data["repo"]), Path(data["oracle"]), data["product"], data["case"], data["good"],
                   Path(data["out"]), tuple(data["diff_args"]))


def read_steps(out: Path) -> List[Dict[str, Any]]:
    path = out / "steps.jsonl"
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def find_comparison(directory: Path) -> Optional[Path]:
    """oracle.py diff writes comparison.json in --out; fleet.py diff (the app) in --out/compare."""
    for path in (directory / "comparison.json", directory / "compare" / "comparison.json"):
        if path.is_file():
            return path
    return None


def first_divergence(comparison: Dict[str, Any], case: str) -> Optional[Dict[str, Any]]:
    """The case's first divergent checkpoint in divergence.json, to show which value the culprit changed."""
    path = comparison.get("divergence")
    if not path:
        return None
    try:
        document = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    for item in document.get("divergences") or ():
        if item.get("journey") == case or item.get("case") == case:
            return {k: item.get(k) for k in ("step", "checkpoint", "pointer")}
    return None


def judge(code: int, comparison: Optional[Dict[str, Any]], case: str) -> Tuple[str, str]:
    """(verdict, reason) of one oracle diff of the case."""
    if comparison is None:
        if code == DIFF_REFUSED:
            return SKIP, "the diff was refused before a comparison (a build or a run failed)"
        return STOP, f"oracle diff exited {code} without a comparison"
    if code in (DIFF_BAD_INPUT, DIFF_INTERNAL):
        return STOP, f"oracle diff exited {code}"
    if case in (comparison.get("divergent") or ()):
        return BAD, "divergent"
    if comparison.get("refused"):
        return SKIP, f"refused: {comparison['refused']}"
    if case in (comparison.get("flaky_excluded") or ()):
        return SKIP, "flaky: passed on retry, left out of the comparison"
    if case in (comparison.get("not_comparable") or {}):
        return SKIP, f"not comparable: {comparison['not_comparable'][case]}"
    if case in (comparison.get("explained") or ()):
        return GOOD, "explained by an expected difference"
    if comparison.get("ok") and comparison.get("compared"):
        return GOOD, "equal"
    return SKIP, "the case was not compared (not selected on this product or platform)"


def test_commit(config: Config, sha: str) -> Dict[str, Any]:
    """Runs (or reuses) the verdict of one commit and appends it to steps.jsonl."""
    for row in read_steps(config.out):
        if row["sha"] == sha:
            return row
    index = len(read_steps(config.out))
    directory = config.out / "steps" / f"{index:02d}-{sha[:12]}"
    directory.mkdir(parents=True, exist_ok=True)
    command = [sys.executable, "-I", str(config.oracle), "diff", "--product", config.product,
               "--base", config.good, "--head", sha, "--suite", config.suite, "--filter", config.case,
               "--out", str(directory), *config.diff_args]
    started = time.monotonic()
    with (directory / "oracle.log").open("w", encoding="utf-8") as log:
        log.write(" ".join(command) + "\n")
        log.flush()
        code = subprocess.run(command, check=False, stdout=log, stderr=subprocess.STDOUT, cwd=str(config.repo)).returncode
    path = find_comparison(directory)
    comparison = None
    if path is not None:
        try:
            comparison = json.loads(path.read_text(encoding="utf-8"))
        except ValueError:
            comparison = None
    verdict, reason = judge(code, comparison, config.case)
    row = {"sha": sha, "verdict": verdict, "reason": reason, "exit": code, "dir": str(directory),
           "seconds": round(time.monotonic() - started, 1),
           "first_divergence": first_divergence(comparison, config.case) if verdict == BAD and comparison else None}
    with (config.out / "steps.jsonl").open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
    return row


def cmd_step(state: Path) -> int:
    """`git bisect run`'s command: the verdict of BISECT_HEAD as git's exit code."""
    config = Config.from_json(json.loads(state.read_text(encoding="utf-8")))
    sha = git(Path.cwd(), "rev-parse", "--verify", "BISECT_HEAD").stdout.strip()
    row = test_commit(config, sha)
    print(f"bisect step {sha[:12]}: {row['verdict']} ({row['reason']})")
    return GIT_EXIT[row["verdict"]]


# ------------------------------------------------------------------------------------------------------ the bisection


def run_git_bisect(config: Config, bad: str, first_parent: bool) -> Tuple[str, List[str], str]:
    """(first bad sha or "", undecided candidates, why) from `git bisect run` in a worktree never checked out."""
    holder = Path(tempfile.mkdtemp(prefix="oracle-bisect-"))
    worktree = holder / "wt"
    state = config.out / "state.json"
    state.write_text(json.dumps(config.to_json(), indent=1, sort_keys=True) + "\n", encoding="utf-8")
    added = False
    try:
        git(config.repo, "worktree", "add", "--detach", "--no-checkout", str(worktree), config.good)
        added = True
        start = ["bisect", "start", "--no-checkout"] + (["--first-parent"] if first_parent else []) + [bad, config.good]
        git(worktree, *start)
        proc = subprocess.run(["git", "-C", str(worktree), "bisect", "run", sys.executable, "-I", str(Path(__file__).resolve()),
                               "step", str(state)], check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (config.out / "bisect-run.log").write_text(proc.stdout, encoding="utf-8")
        (config.out / "bisect.log").write_text(git(worktree, "bisect", "log", check=False).stdout, encoding="utf-8")
        found = FIRST_BAD.search(proc.stdout)
        if found:
            return found.group(1), [], ""
        if "could be any of" in proc.stdout:
            tail = proc.stdout.split("could be any of", 1)[1]
            return "", sorted(set(SHA_LINE.findall(tail))), "skipped commits leave several candidates"
        errors = [line[len(STEP_ERROR):].strip() for line in proc.stdout.splitlines() if line.startswith(STEP_ERROR)]
        stopped = [r for r in read_steps(config.out) if r["verdict"] == STOP]
        why = (f"a step failed: {errors[-1]}" if errors else stopped[-1]["reason"] if stopped
               else f"git bisect run exited {proc.returncode}")
        return "", [], f"the bisection stopped: {why}"
    finally:
        if added:
            git(worktree, "bisect", "reset", check=False)
            git(config.repo, "worktree", "remove", "--force", str(worktree), check=False)
        shutil.rmtree(holder, ignore_errors=True)


def bisect(config: Config, bad: str, *, first_parent: bool, check_good: bool) -> Dict[str, Any]:
    status, culprit, candidates, reason = INCONCLUSIVE, "", [], ""
    at_bad = test_commit(config, bad)
    if at_bad["verdict"] == GOOD:
        status, reason = NOT_REPRODUCIBLE, f"the case matches at the bad end ({at_bad['reason']})"
    elif at_bad["verdict"] != BAD:
        reason = f"the bad end could not be tested: {at_bad['reason']}"
    else:
        at_good = test_commit(config, config.good) if check_good else {"verdict": GOOD}
        if at_good["verdict"] == BAD:
            status, reason = NOT_DETERMINISTIC, "the good end diverges from itself"
        elif at_good["verdict"] != GOOD:
            reason = f"the good end could not be tested: {at_good['reason']}"
        else:
            line = ["--first-parent"] if first_parent else []
            between = git(config.repo, "rev-list", "--count", *line, f"{config.good}..{bad}").stdout.strip()
            if between == "1":
                culprit = bad  # nothing between the ends: the bad end is the first bad commit
            else:
                culprit, candidates, reason = run_git_bisect(config, bad, first_parent)
            if culprit:
                status, reason = CULPRIT, ""
    steps = read_steps(config.out)
    return {
        "schema": SCHEMA,
        "case": config.case,
        "product": config.product,
        "good": config.good,
        "bad": bad,
        "first_parent": first_parent,
        "status": status,
        "culprit": {"sha": culprit, "subject": subject(config.repo, culprit)} if culprit else None,
        "candidates": [{"sha": c, "subject": subject(config.repo, c)} for c in candidates],
        "reason": reason,
        "steps": steps,
    }


def new_run_id() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + "".join(
        random.SystemRandom().choice("0123456789abcdefghijklmnopqrstuvwxyz") for _ in range(6))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bisect_case.py", description=__doc__.split("\n\n")[0],
                                     epilog="Arguments after -- go to every `oracle.py diff` (for example --seed N).")
    parser.add_argument("--good", required=True, help="a commit where the case matches (the batch base)")
    parser.add_argument("--bad", required=True, help="a commit where the case diverges from --good (the batch head)")
    parser.add_argument("--case", required=True, help="SUITE/CASE, as the comparison names it")
    parser.add_argument("--product", help="default: the first product of tests/oracle/suite-map.json that runs the suite")
    parser.add_argument("--all-parents", action="store_true", help="bisect into merged branches, not only the merges")
    parser.add_argument("--no-check-good", action="store_true", help="skip the GOOD-against-GOOD determinism run")
    parser.add_argument("--out", type=Path, help=f"output dir outside the checkout (default {DEFAULT_OUT_BASE}/<run id>)")
    parser.add_argument("--repo", type=Path, default=REPO, help="the git checkout (default: this one)")
    parser.add_argument("--oracle", type=Path, default=ORACLE, help="the oracle.py that runs each diff")
    parser.add_argument("--map", type=Path, default=DEFAULT_MAP)
    parser.add_argument("--json", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["step"]:
        if len(argv) != 2:
            print("bisect: step takes the state file", file=sys.stderr)
            return GIT_EXIT[STOP]
        # An uncaught exception exits 1, which `git bisect run` reads as BAD: a broken step must abandon the run.
        try:
            return cmd_step(Path(argv[1]))
        except Exception as error:  # noqa: BLE001 - every failure of the step is the oracle failing
            print(f"{STEP_ERROR} {type(error).__name__}: {error}")
            return GIT_EXIT[STOP]
    diff_args: List[str] = []
    if "--" in argv:
        split = argv.index("--")
        argv, diff_args = argv[:split], argv[split + 1:]
    args = build_parser().parse_args(argv)
    try:
        repo = Path(git(args.repo, "rev-parse", "--show-toplevel").stdout.strip())
        if "/" not in args.case:
            raise UsageError(f"--case {args.case!r}: write SUITE/CASE")
        good, bad = resolve(repo, args.good), resolve(repo, args.bad)
        if good == bad:
            raise UsageError("--good and --bad are the same commit")
        if git(repo, "merge-base", "--is-ancestor", good, bad, check=False).returncode != 0:
            raise UsageError(f"--good {args.good} is not an ancestor of --bad {args.bad}")
        out = (args.out or DEFAULT_OUT_BASE / new_run_id()).resolve()
        if out == repo or repo in out.parents:
            raise UsageError(f"--out {out}: bisect output stays outside the checkout (spec 3G)")
        if out.exists() and any(out.iterdir()):
            raise UsageError(f"--out {out} is not empty")
        out.mkdir(parents=True, exist_ok=True)
        product = args.product or default_product(args.map, args.case.split("/", 1)[0])
        config = Config(repo, args.oracle.resolve(), product, args.case, good, out, tuple(diff_args))
        result = bisect(config, bad, first_parent=not args.all_parents, check_good=not args.no_check_good)
    except UsageError as error:
        print(f"bisect: {error}", file=sys.stderr)
        return 2
    (out / "bisect.json").write_text(json.dumps(result, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    if args.json:
        print(json.dumps(result, indent=1, sort_keys=True))
    else:
        print(f"bisect {result['case']} on {result['product']} over {good[:12]}..{bad[:12]}: {result['status']}"
              f" after {len(result['steps'])} oracle diffs")
        if result["culprit"]:
            print(f"  first bad commit: {result['culprit']['sha']} {result['culprit']['subject']}")
        for candidate in result["candidates"]:
            print(f"  candidate: {candidate['sha']} {candidate['subject']}")
        if result["reason"]:
            print(f"  {result['reason']}")
        print(f"  result: {out / 'bisect.json'}")
    return EXIT[result["status"]]


if __name__ == "__main__":
    sys.exit(main())
