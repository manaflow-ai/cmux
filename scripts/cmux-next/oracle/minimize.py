#!/usr/bin/env python3
"""Minimize a failing or divergent oracle case with delta debugging (ddmin) into a small case of its suite.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3D (suite walks: seeded walks, ddmin) and task 098.
Stdlib only, Python 3.9+, safe under `python3 -I`. `oracle.py minimize ARGS` runs it.

A test runs one candidate case on the daemon product through driver_daemon.py (the same driver `oracle.py run
--product daemon` uses: a hermetic cmux-tui per case, I6 teardown) and reduces what it saw to a signature:

- `--base-binary A --head-binary B` (diff): the candidate runs on both and the two runs are compared with diff.py's
  compare_case and the rules `oracle.py diff` applies (the Expectations pointer lines of the run's configuration,
  plus every `--expected FILE`), matched against the original case id. The signature is the first divergence those
  rules do not explain: its kind, the op (and method) of the step it is in, and its pointer with numbers
  generalized, because removing steps relabels ids and moves indexes. A same-side control runs the original at
  least twice on each binary: a pointer that differs between two runs of one binary is noise (a random id, a time)
  and is never the signature, and a case whose every divergence is noise is refused.
- `--binary B` (fail): the candidate runs once. The signature is its result (Failure, Crash, Timeout) and the op
  (and method) of the step that gave it.

The original case must reproduce its signature on every one of `--confirm` runs (a flaky case is refused: a
reduction that is not a function of its input proves nothing). ddmin (Zeller and Hildebrandt, "Simplifying and
Isolating Failure-Inducing Input", IEEE TSE 2002) then removes steps while the candidate still reproduces that
signature (`--any`: any divergence or failure), testing the subsets and then the complements of a partition in
parallel (`--jobs`) and taking the first that reproduces in partition order, so the result does not depend on
timing. A candidate keeps every step the kept steps read through `$step:` references, with what those read, in the
original order. The result is 1-minimal: removing any one more step loses the signature. It is run `--confirm`
more times before it is written as `<suite>/min-<case>-<signature6>.json` beside the original (or in `--out`), with
the signature, the original case and the test count in its invariants.

Chrome reference (chromium/src and ClusterFuzz): ClusterFuzz minimizes a crashing testcase by removing chunks
while the crash state (the top frames of the stack) stays the same (src/clusterfuzz/_internal/bot/minimizer/
delta_minimizer.py, the same ddmin); a testcase that does not reproduce reliably is marked unreliable and not
minimized. tools/ipc_fuzzer/ keeps each failing message sequence as the file that reproduces it.

Usage:
  minimize.py CASE.json --base-binary A --head-binary B [--expected FILE]... [--expectations-root DIR] [--build B]
  minimize.py CASE.json --binary B [--any] [...]
  Common: [--any] [--jobs N] [--confirm N] [--out DIR] [--isolation netns|auto|none] [--state-base DIR]
          [--ref-base SHA] [--ref-head SHA]
Exit: 0 the minimized case is written and reproduces, 1 the original does not reproduce (or is flaky, or shows only
noise), 2 bad usage.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import copy
import hashlib
import itertools
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, FrozenSet, List, Mapping, Optional, Protocol, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import diff  # noqa: E402 - sibling: compare_case, the comparison oracle.py diff makes
import oracle  # noqa: E402 - sibling: the Expectations pointer rules oracle.py diff applies

DEFAULT_CONFIRM = 2
DEFAULT_JOBS = 32
STEP_REF = re.compile(r"\$step:([a-z0-9][a-z0-9-]{0,63})#")
MIN_PREFIX = "min-"
SLUG_MAX = 64
# A case minimize.py wrote: min-<case>-<signature6>; minimizing it again keeps <case>.
MINIMIZED = re.compile(r"^min-(.+)-[0-9a-f]{6}$")
# A divergence pointer with its numbers generalized: ids are relabeled in first-seen order and array indexes move
# when steps go, so `/daemon/session/workspaces/2/name` and `.../1/name` are the same place.
NUMBER = re.compile(r"[0-9]+")
# The invariant a minimized case carries; minimizing it again keeps the original id, which the rules match.
MINIMIZED_FROM = re.compile(r"^minimized by scripts/cmux-next/oracle/minimize\.py from (\S+): ")
NOISE_SOURCE = "minimize.py same-side control"


class MinimizeError(Exception):
    """A case that cannot be minimized (no steps, an unknown step reference, a bad option)."""


# ------------------------------------------------------------------------------------------ the candidates


def step_refs(value: Any) -> Set[str]:
    return set(STEP_REF.findall(json.dumps(value)))


def closure(case: Mapping[str, Any], keep: FrozenSet[int]) -> List[int]:
    """Indexes of the steps a candidate runs: `keep` and every step they read through `$step:` references,
    transitively, in the original order."""
    steps = case["steps"]
    index_of = {step["id"]: index for index, step in enumerate(steps)}
    out: Set[int] = set()
    todo = list(keep)
    while todo:
        index = todo.pop()
        if index in out:
            continue
        out.add(index)
        for ref in step_refs(steps[index]):
            if ref not in index_of:
                raise MinimizeError(f"step {steps[index]['id']} reads {ref}, which is not a step of the case")
            todo.append(index_of[ref])
    return sorted(out)


def candidate(case: Mapping[str, Any], keep: FrozenSet[int], case_id: Optional[str] = None) -> Dict[str, Any]:
    """The case with only the steps of `closure(keep)`; allow_crashes keeps only entries for steps still in it."""
    out = copy.deepcopy(dict(case))
    out["steps"] = [copy.deepcopy(case["steps"][i]) for i in closure(case, keep)]
    kept = {step["id"] for step in out["steps"]}
    crashes = []
    for entry in case.get("allow_crashes") or ():
        if "steps" not in entry:
            crashes.append(copy.deepcopy(entry))
            continue
        steps = [s for s in entry["steps"] if s in kept]
        if steps:
            crashes.append({**copy.deepcopy(entry), "steps": steps,
                            **({"max": min(int(entry.get("max", 1)), len(steps))} if "max" in entry else {})})
    if crashes:
        out["allow_crashes"] = crashes
    else:
        out.pop("allow_crashes", None)
    if case_id is not None:
        out["id"] = case_id
    return out


# ------------------------------------------------------------------------------------------ ddmin


def split(items: Sequence[int], parts: int) -> List[Tuple[int, ...]]:
    """`items` in `parts` contiguous chunks whose sizes differ by at most one."""
    size, rest = divmod(len(items), parts)
    out, start = [], 0
    for index in range(parts):
        end = start + size + (1 if index < rest else 0)
        out.append(tuple(items[start:end]))
        start = end
    return [chunk for chunk in out if chunk]


TestFn = Callable[[Sequence[FrozenSet[int]]], List[bool]]


def ddmin(items: Sequence[int], test: TestFn) -> Tuple[List[int], int]:
    """Zeller's ddmin over `items`, with `test` answering a batch of candidates at once (True: it still
    reproduces). Returns the 1-minimal items and the number of candidates tested. Each answer is cached, so a
    subset seen before is never run again."""
    cache: Dict[FrozenSet[int], bool] = {}

    def first(candidates: Sequence[FrozenSet[int]]) -> Optional[FrozenSet[int]]:
        todo = [c for c in dict.fromkeys(candidates) if c not in cache]
        if todo:
            for subset, answer in zip(todo, test(todo)):
                cache[subset] = answer
        return next((c for c in candidates if cache[c]), None)

    current = list(items)
    parts = 2
    while len(current) >= 2:
        chunks = split(current, parts)
        found = first([frozenset(chunk) for chunk in chunks])
        if found is not None:
            current, parts = sorted(found), 2
            continue
        if len(chunks) > 2:
            found = first([frozenset(current) - frozenset(chunk) for chunk in chunks])
            if found is not None:
                current, parts = sorted(found), max(parts - 1, 2)
                continue
        if parts >= len(current):
            break
        parts = min(len(current), parts * 2)
    return current, len(cache)


# ------------------------------------------------------------------------------------------ signatures


@dataclass(frozen=True)
class Signature:
    """What a run of a candidate showed. None of it names an id or an index of the original case."""

    kind: str          # pass, a result (Failure, Crash, Timeout) or a diff.py divergence kind
    where: str         # op (and method) of the step it is in, or "" for the whole case
    pointer: str = ""  # the first divergence's pointer, numbers generalized

    @property
    def reproduces(self) -> bool:
        return self.kind != "pass"

    def describe(self) -> str:
        return " ".join(part for part in (self.kind, self.where, self.pointer) if part)

    def digest(self) -> str:
        return hashlib.sha256(self.describe().encode("utf-8")).hexdigest()[:6]


PASS = Signature("pass", "")


def step_kind(case: Mapping[str, Any], step_id: Optional[str]) -> str:
    """`op` or `op method` of a step, by id; "" when the case has no such step."""
    for step in case.get("steps") or ():
        if step.get("id") == step_id:
            method = (step.get("args") or {}).get("method") or (step.get("args") or {}).get("action")
            return f"{step['op']} {method}" if method else step["op"]
    return ""


def failure_signature(case: Mapping[str, Any], result: Mapping[str, Any]) -> Signature:
    status = result.get("status")
    if status == "Pass":
        return PASS
    return Signature(str(status), step_kind(case, result.get("step")))


def general(pointer: str) -> str:
    return NUMBER.sub("N", pointer)


def run_of(label: str, case_id: str, result: Mapping[str, Any]) -> diff.Run:
    """A diff.py Run of one case result: checkpoint indexes as oracle.py writes them (order of first use)."""
    indexes: Dict[str, int] = {}
    points = []
    for line, row in enumerate(result.get("checkpoints") or (), 1):
        step = str(row["step"])
        index = indexes.setdefault(step, len(indexes))
        points.append(diff.Checkpoint(case_id, step, index, row["checkpoint"], row["snapshot"], None, line))
    return diff.Run(label, label, "0" * 40, None, {case_id: result.get("status")}, {}, {case_id: points})


@dataclass(frozen=True)
class NoiseRule(diff.Rule):
    """Excuses the pointers (numbers generalized, and what is under them) that differed between two runs of one
    binary: compare_case skips them as it skips a pointer an expected difference explains."""

    pointers: FrozenSet[str] = frozenset()

    def covers(self, case: str, step: str, checkpoint: str, pointer: str) -> bool:
        pointer = general(pointer)
        return any(pointer == p or pointer.startswith(p + "/") for p in self.pointers)


def differing_pointers(case_id: str, a: Mapping[str, Any], b: Mapping[str, Any]) -> Set[str]:
    """Every snapshot pointer (numbers generalized) where two runs of a case differ at the same checkpoint."""
    points_a = {p.key: p for p in run_of("a", case_id, a).checkpoints[case_id]}
    points_b = {p.key: p for p in run_of("b", case_id, b).checkpoints[case_id]}
    out: Set[str] = set()
    for key in set(points_a) | set(points_b):
        left, right = points_a.get(key), points_b.get(key)
        for pointer, _, _ in diff.iter_differences(left.snapshot if left else diff.MISSING,
                                                   right.snapshot if right else diff.MISSING):
            out.add(general(pointer))
    return out


@dataclass(frozen=True)
class Judge:
    """Reduces the results of one run of a candidate (fail mode: one; diff mode: base, head) to its Signature.
    `case_id` is the original case's id, which the rules match (a candidate's min- id matches none); `noise` holds
    the generalized pointers the same-side control saw differ."""

    case_id: str
    rules: Tuple[diff.Rule, ...] = ()
    noise: FrozenSet[str] = frozenset()

    def comparison_rules(self) -> List[diff.Rule]:
        if not self.noise:
            return list(self.rules)
        return [*self.rules, NoiseRule(pointer="", reason="differs between two runs of the same binary",
                                       source=NOISE_SOURCE, pointers=self.noise)]

    def signature(self, case: Mapping[str, Any], results: Sequence[Mapping[str, Any]]) -> Signature:
        if len(results) == 1:
            return failure_signature(case, results[0])
        return divergence_signature(case, results[0], results[1], self.comparison_rules(), self.case_id)


def divergence_signature(case: Mapping[str, Any], base: Mapping[str, Any], head: Mapping[str, Any],
                         rules: Sequence[diff.Rule] = (), case_id: Optional[str] = None) -> Signature:
    """The first divergence compare_case reports under `rules`, matched against `case_id` (default: the case's)."""
    case_id = case_id or f"{case.get('suite')}/{case.get('id')}"
    report = diff.compare_case(case_id, run_of("base", case_id, base), run_of("head", case_id, head), list(rules))
    if report.status != "divergent" or report.first is None:
        return PASS
    first = report.first
    pointer = general(str(first.get("pointer") or ""))
    if first.get("kind") == "result":
        return Signature(f"result {base.get('status')}->{head.get('status')}", "", pointer)
    return Signature(str(first.get("kind")), step_kind(case, first.get("step")), pointer)


# ------------------------------------------------------------------------------------------ running cases


class Session(Protocol):
    def run_case(self, case: Dict[str, Any], case_ctx: Dict[str, Any]) -> Dict[str, Any]: ...


class Prober:
    """Runs candidates on every session. `sessions` is one session (fail mode) or base and head (diff mode); run n
    gets the state root `<base>/<n, 6 digits>`, so every socket path stays short and no two runs share a root."""

    def __init__(self, sessions: Sequence[Session], jobs: int, base: Path):
        if len(sessions) not in (1, 2):
            raise MinimizeError("one session (fail mode) or two (base, head: diff mode)")
        self.sessions = list(sessions)
        self.jobs = max(1, jobs)
        self.base = base
        self.numbers = itertools.count()
        self.started: List[int] = []

    @property
    def runs(self) -> int:
        return len(self.started)

    @property
    def diff_mode(self) -> bool:
        return len(self.sessions) == 2

    def run(self, session: Session, case: Dict[str, Any]) -> Dict[str, Any]:
        number = next(self.numbers)
        self.started.append(number)
        ctx = {"case_id": f"{case.get('suite')}/{case.get('id')}", "key": str(number),
               "state_root": str(self.base / f"{number:06d}"[-6:])}
        return session.run_case(case, ctx)

    def result(self, case: Dict[str, Any]) -> List[Dict[str, Any]]:
        """One result per session: [run] in fail mode, [base, head] in diff mode."""
        if len(self.sessions) == 1:
            return [self.run(self.sessions[0], case)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            return list(pool.map(lambda s: self.run(s, case), self.sessions))

    def results(self, cases: Sequence[Dict[str, Any]]) -> List[List[Dict[str, Any]]]:
        workers = max(1, self.jobs // len(self.sessions))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            return list(pool.map(self.result, cases))

    def close(self) -> None:
        try:
            self.base.rmdir()
        except OSError:
            pass


# ------------------------------------------------------------------------------------------ the minimizer


@dataclass
class Outcome:
    signature: Signature
    case: Optional[Dict[str, Any]]
    tests: int
    kept: int
    original: int
    message: str


def matches(want: Signature, got: Signature, any_failure: bool) -> bool:
    return got.reproduces and (any_failure or got == want)


def origin_id(case: Mapping[str, Any]) -> str:
    """`suite/id` of the case a minimized case came from (its invariant names it), else of the case itself: the id
    expected differences and Expectations lines are written against."""
    for line in case.get("invariants") or ():
        found = MINIMIZED_FROM.match(str(line))
        if found:
            return found.group(1)
    return f"{case.get('suite')}/{case.get('id')}"


def same_side_control(origin: str, runs: Sequence[Sequence[Mapping[str, Any]]]) -> Tuple[Optional[str], FrozenSet[str]]:
    """Diff mode's control over the original's runs (each [base, head]): a refusal when one binary gives several
    results, else the generalized pointers where two runs of one binary differ."""
    noise: Set[str] = set()
    for side, label in enumerate(("base", "head")):
        results = [run[side] for run in runs]
        statuses = sorted({str(r.get("status")) for r in results})
        if len(statuses) > 1:
            return f"the case is flaky: {label} gives {', '.join(statuses)} on the same binary", frozenset()
        for other in results[1:]:
            noise |= differing_pointers(origin, results[0], other)
    return None, frozenset(noise)


def minimize(case: Mapping[str, Any], prober: Prober, *, rules: Sequence[diff.Rule] = (),
             confirm: int = DEFAULT_CONFIRM, any_failure: bool = False) -> Outcome:
    """The original's signature, confirmed `confirm` times (in diff mode at least twice: the same-side control);
    ddmin over its steps; the result confirmed again. `rules` are diff mode's expected differences."""
    steps = case.get("steps") or []
    if not steps:
        raise MinimizeError("the case has no steps")
    original = dict(case)
    origin = origin_id(case)
    runs = prober.results([copy.deepcopy(original) for _ in range(max(2 if prober.diff_mode else 1, confirm))])
    noise: FrozenSet[str] = frozenset()
    if prober.diff_mode:
        refused, noise = same_side_control(origin, runs)
        if refused:
            return Outcome(PASS, None, len(runs), len(steps), len(steps), refused)
    judge = Judge(origin, tuple(rules), noise)
    seen = [judge.signature(original, run) for run in runs]
    want = seen[0]
    if not want.reproduces:
        raw = Judge(origin, tuple(rules)).signature(original, runs[0])
        if raw.reproduces:
            return Outcome(want, None, len(seen), len(steps), len(steps),
                           f"every divergence is noise (it differs between two runs of one binary): {raw.describe()}")
        return Outcome(want, None, len(seen), len(steps), len(steps), "the case passes: nothing to minimize")
    if any(s != want for s in seen):
        return Outcome(want, None, len(seen), len(steps), len(steps),
                       "the case is flaky: " + "; ".join(sorted({s.describe() for s in seen})))
    name = minimized_id(str(case.get("id")), want)

    def signatures(cases: Sequence[Dict[str, Any]]) -> List[Signature]:
        return [judge.signature(c, r) for c, r in zip(cases, prober.results(cases))]

    def test(subsets: Sequence[FrozenSet[int]]) -> List[bool]:
        return [matches(want, g, any_failure) for g in signatures([candidate(case, s, name) for s in subsets])]

    kept, tests = ddmin(list(range(len(steps))), test)
    result = candidate(case, frozenset(kept), name)
    result["title"] = f"minimized {origin}: {want.describe()}"[:200]
    result["invariants"] = [
        *[line for line in case.get("invariants") or () if not str(line).startswith("minimized by ")],
        f"minimized by scripts/cmux-next/oracle/minimize.py from {origin}: "
        f"{len(result['steps'])} of {len(steps)} steps after {tests} candidates; it reproduces "
        f"`{want.describe()}`",
    ]
    final = signatures([copy.deepcopy(result) for _ in range(max(1, confirm))])
    if not all(matches(want, s, any_failure) for s in final):
        return Outcome(want, None, len(seen) + tests + len(final), len(result["steps"]), len(steps),
                       "the minimized case does not reproduce on every confirm run: "
                       + "; ".join(sorted({s.describe() for s in final})))
    return Outcome(want, result, len(seen) + tests + len(final), len(result["steps"]), len(steps), "minimized")


def minimized_id(case_id: str, signature: Signature) -> str:
    """`min-<case>-<signature6>`, a case-v1 slug: the same failure of the same case always gets the same name."""
    stem = MINIMIZED.sub(r"\1", case_id)
    suffix = f"-{signature.digest()}"
    return MIN_PREFIX + stem[: SLUG_MAX - len(MIN_PREFIX) - len(suffix)].rstrip("-") + suffix


def render(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


# ------------------------------------------------------------------------------------------ CLI


def open_sessions(args: argparse.Namespace, run_id: str) -> List[Session]:
    import driver_daemon  # sibling: the daemon product's driver

    if args.binary:
        pairs = [(args.binary, args.ref_head)]
    else:
        pairs = [(args.base_binary, args.ref_base), (args.head_binary, args.ref_head)]
    return [driver_daemon.open_session({"binary": binary, "run_id": f"{run_id}-{side}", "ref": ref,
                                        "isolation": args.isolation})
            for side, (binary, ref) in zip(("a", "b"), pairs)]


def load_rules(expected: Sequence[Path], expectations_root: Path, build: str) -> List[diff.Rule]:
    """The rules `oracle.py diff` applies to a daemon base/head comparison: the Expectations pointer lines of its
    configuration (this platform, no arm, product daemon, `build`), then every `--expected` file."""
    store = oracle.load_expectations(expectations_root, platform=oracle.current_platform(), arm=None, product="daemon",
                                     build=build)
    source = f"{expectations_root} (Expectations pointer lines)"
    rules = [diff.Rule(pointer=entry["pointer"], reason=entry["reason"], case=entry["case"], step=entry["step"],
                       task=entry.get("task"), source=source)
             for entry in (store.pointer_rules() if store else ())]
    for path in expected:
        rules.extend(diff.load_rules(str(path)))
    return rules


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="minimize.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("case", type=Path, help="the failing or divergent case file")
    parser.add_argument("--binary", help="fail mode: the cmux-tui the case fails on")
    parser.add_argument("--base-binary", help="diff mode: the base (or old arm) cmux-tui")
    parser.add_argument("--head-binary", help="diff mode: the head (or new arm) cmux-tui")
    parser.add_argument("--ref-base", help="full SHA of the base build (default: its build.json)")
    parser.add_argument("--ref-head", help="full SHA of the head build, or of --binary (default: its build.json)")
    parser.add_argument("--expected", type=Path, action="append", default=[],
                        help="diff mode: an expected-differences file, as diff.py --expected (repeatable)")
    parser.add_argument("--expectations-root", type=Path, default=oracle.DEFAULT_EXPECTATIONS_ROOT,
                        help="diff mode: the Expectations whose pointer lines excuse a divergence, as oracle.py diff")
    parser.add_argument("--build", choices=oracle.BUILDS, default="debug",
                        help="the build Expectations lines match (default debug, as oracle.py run --product daemon)")
    parser.add_argument("--any", action="store_true", help="keep any failure or divergence, not only the original's")
    parser.add_argument("--confirm", type=int, default=DEFAULT_CONFIRM,
                        help=f"runs of the original and of the result that must reproduce (default {DEFAULT_CONFIRM})")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS, help=f"parallel case runs (default {DEFAULT_JOBS})")
    parser.add_argument("--isolation", choices=("netns", "auto", "none"), default="netns")
    parser.add_argument("--state-base", type=Path, default=Path("/tmp/o"))
    parser.add_argument("--out", type=Path, help="directory of the minimized case (default: the case's own)")
    args = parser.parse_args(argv)
    if bool(args.binary) == bool(args.base_binary or args.head_binary):
        parser.error("give --binary (fail mode) or --base-binary and --head-binary (diff mode)")
    if not args.binary and not (args.base_binary and args.head_binary):
        parser.error("diff mode needs both --base-binary and --head-binary")
    try:
        case = json.loads(args.case.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        parser.error(f"{args.case}: {error}")
    if args.binary and args.expected:
        parser.error("--expected applies to diff mode (--base-binary and --head-binary)")
    try:
        rules = [] if args.binary else load_rules(args.expected, args.expectations_root, args.build)
    except (diff.InputError, oracle.UsageError, OSError, ValueError) as error:
        print(f"minimize.py: {error}", file=sys.stderr)
        return 2
    run_id = f"min-{os.getpid()}-{time.time_ns()}"
    started = time.monotonic()
    try:
        prober = Prober(open_sessions(args, run_id), args.jobs, args.state_base / f"m{os.getpid() % 100000:05d}")
    except ValueError as error:
        print(f"minimize.py: {error}", file=sys.stderr)
        return 2
    try:
        outcome = minimize(case, prober, rules=rules, confirm=args.confirm, any_failure=args.any)
    except MinimizeError as error:
        print(f"minimize.py: {error}", file=sys.stderr)
        return 2
    finally:
        prober.close()
    report: Dict[str, Any] = {"case": f"{case.get('suite')}/{case.get('id')}", "signature": outcome.signature.describe(),
                              "steps": {"original": outcome.original, "kept": outcome.kept}, "candidates": outcome.tests,
                              "runs": prober.runs, "seconds": round(time.monotonic() - started, 1),
                              "message": outcome.message}
    if outcome.case is not None:
        out = (args.out or args.case.parent) / f"{outcome.case['id']}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render(outcome.case), encoding="utf-8")
        report["written"] = str(out)
    print(json.dumps(report, indent=1, sort_keys=True))
    return 0 if outcome.case is not None else 1


if __name__ == "__main__":
    sys.exit(main())
