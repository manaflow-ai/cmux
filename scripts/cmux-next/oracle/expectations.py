#!/usr/bin/env python3
"""Oracle expectations: parser, matcher, verdicts and linter (stdlib only, safe under `python3 -I`).

The format and semantics copy Blink's TestExpectations (chromium/src
`docs/testing/web_test_expectations.md`, the typ parser in
`third_party/catapult/third_party/typ/typ/expectations_parser.py` and the linter in
`third_party/blink/tools/blinkpy/web_tests/lint_test_expectations.py`):

    [ bug ] [ [ tags ] ] suite/case[/step][#/json/pointer] [ results ] [# comment]

- `bug` is a WORK.tsv task id (`p15-oracle-015`) or a cmux issue (`#1234`). A `#1234` line is an
  expectation only when a `suite/case` target and its `[ results ]` bracket follow; any other line
  that starts with `#` is a comment.
- Tags come from four groups; a line matches a run when every tag on it equals the run's value
  for that group (typ semantics: tags on one line are ANDed, two tags of one group never match).
- Results: Pass Failure Crash Timeout Skip Slow. Several results (Slow aside) mean flaky; there
  is no Flaky keyword. Skip never runs. Expecting a non-Pass result and passing is an unexpected
  pass: reported, it does not fail the run (Blink behavior).
- Slow is a modifier, not a result: any matching case, step or `suite/*` line with Slow gives 5x
  settleMaxMs, whatever line wins the result (Blink keeps it in a separate SlowTests file; typ
  ORs `is_slow_test` over every matching line). A Slow-only line never competes for the result.
- A `#/json/pointer` suffix scopes the line to that value and its subtree; every other value of
  the snapshot stays strict. A `suite/*` line takes no Failure: it would hide a whole suite.
- Most specific target wins: pointer-in-step > pointer > step > case > `suite/*` (typ: an exact
  name beats a glob), then the deeper pointer. Tags do not rank: lines on one target whose tag
  sets can both match a run union their results (typ `expectations_for`), and the linter refuses
  them (typ `check_for_conflicts`), so a union never reaches a run.

Files: `tests/oracle/Expectations.d/<suite>.txt` and `tests/oracle/NeverFix.d/<suite>.txt`, one
file per suite so parallel agents do not conflict. A combined file (all suites in one file) is
read the same way. NeverFix lines are `[ Skip ]` only.

Usage:
    expectations.py lint [--root DIR] [--corpus DIR] [--results FILE ...] [--min-runs N] [--json]
    expectations.py query SUITE/CASE[/STEP] [--platform P] [--arm A] [--product P] [--build B]
    expectations.py selftest
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import Iterable, Sequence

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_ROOT = REPO_ROOT / "tests" / "oracle"

TAG_GROUPS: dict[str, tuple[str, ...]] = {
    "platform": ("linux", "mac", "windows"),
    "arm": ("old", "new"),
    "product": ("daemon", "app", "cli", "headless", "tui", "mcp"),
    "build": ("debug", "bench", "asan", "tsan"),
}
GROUP_OF_TAG = {tag: group for group, tags in TAG_GROUPS.items() for tag in tags}

PASS, FAILURE, CRASH, TIMEOUT, SKIP, SLOW = "Pass", "Failure", "Crash", "Timeout", "Skip", "Slow"
RESULTS = (PASS, FAILURE, CRASH, TIMEOUT, SKIP, SLOW)
ACTUAL_RESULTS = (PASS, FAILURE, CRASH, TIMEOUT)
SLOW_MULTIPLIER = 5

# Suite classes of p15-oracle section 3D. Only golden suites carry reviewed baselines and the budget.
GOLDEN_SUITES = frozenset(
    {"upgrades", "terminal", "pane-protocol", "journeys", "tours", "e2e", "live", "tla", "ax"}
)
GOLDEN_BUDGET = 0.02

TASK_ID_RE = re.compile(r"^p\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*-\d{3}$")
ISSUE_RE = re.compile(r"^#\d+$")
# `#1234 [ tags ] suite/case... [` : an issue line has a target and its results bracket; other `#` lines are comments.
ISSUE_LINE_RE = re.compile(r"^\s*#\d+\s+(?:\[[^\[\]]*\]\s*)?[A-Za-z0-9][A-Za-z0-9._-]*/\S*\s*\[")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# Scope ranks, least to most specific.
SCOPE_GLOB, SCOPE_CASE, SCOPE_STEP, SCOPE_POINTER, SCOPE_STEP_POINTER = range(5)

EXPECTED, UNEXPECTED_FAILURE, UNEXPECTED_PASS, SKIPPED = (
    "expected",
    "unexpected-failure",
    "unexpected-pass",
    "skipped",
)


@dataclasses.dataclass(frozen=True)
class Diagnostic:
    file: str
    line: int
    code: str
    message: str
    severity: str = "error"

    def render(self) -> str:
        return f"{self.file}:{self.line}: {self.severity} [{self.code}] {self.message}"


@dataclasses.dataclass(frozen=True)
class RunConfig:
    """The run's value in each tag group; None means the run has no value there."""

    platform: str | None = None
    arm: str | None = None
    product: str | None = None
    build: str | None = None

    def value(self, group: str) -> str | None:
        return getattr(self, group)


@dataclasses.dataclass(frozen=True)
class Entry:
    file: str
    lineno: int
    kind: str  # "expectations" or "neverfix"
    bug: str | None
    tags: frozenset[str]
    suite: str
    case: str
    step: str | None
    pointer: str | None
    results: frozenset[str]

    @property
    def scope(self) -> int:
        if self.case == "*":
            return SCOPE_GLOB
        if self.pointer is not None:
            return SCOPE_STEP_POINTER if self.step is not None else SCOPE_POINTER
        return SCOPE_STEP if self.step is not None else SCOPE_CASE

    @property
    def target(self) -> str:
        text = f"{self.suite}/{self.case}"
        if self.step is not None:
            text += f"/{self.step}"
        if self.pointer is not None:
            text += f"#{self.pointer}"
        return text

    @property
    def outcomes(self) -> frozenset[str]:
        """Results a run may give; Slow alone means an expected Pass with the longer settle."""
        rest = self.results - {SLOW}
        return rest or frozenset({PASS})

    @property
    def slow(self) -> bool:
        return SLOW in self.results

    @property
    def has_result(self) -> bool:
        """False for a Slow-only line: it modifies the settle time and never competes for the result."""
        return bool(self.results - {SLOW})

    @property
    def flaky(self) -> bool:
        return len(self.outcomes) > 1

    @property
    def key(self) -> str:
        """Location-free canonical text: equal for one line read from a split dir or a combined file."""
        tags = " ".join(sorted(self.tags, key=_tag_order))
        results = " ".join(r for r in RESULTS if r in self.results)
        bug = self.bug or "-"
        return f"{bug} [ {tags} ] {self.target} [ {results} ]".replace("[  ]", "[ ]")

    @property
    def where(self) -> str:
        return f"{self.file}:{self.lineno}"

    def matches(self, config: RunConfig) -> bool:
        return all(config.value(GROUP_OF_TAG[tag]) == tag for tag in self.tags)

    def covers_pointer(self, pointer: str | None) -> bool:
        if self.pointer is None:
            return True
        if pointer is None:
            return False
        return pointer == self.pointer or pointer.startswith(self.pointer + "/")

    def covers(self, d: "Divergence") -> bool:
        return (self.step is None or self.step == d.step) and self.covers_pointer(d.pointer)


def _tag_order(tag: str) -> tuple[int, int]:
    group = GROUP_OF_TAG.get(tag)
    if group is None:
        return (len(TAG_GROUPS), 0)
    return (list(TAG_GROUPS).index(group), TAG_GROUPS[group].index(tag))


def _rank(entry: Entry) -> tuple[int, int]:
    depth = 0 if entry.pointer is None else entry.pointer.count("/")
    return (entry.scope, depth)


def _tags_compatible(a: frozenset[str], b: frozenset[str]) -> bool:
    """True when some run matches both tag sets (no group where the two lines name different tags)."""
    groups: dict[str, str] = {}
    for tag in a | b:
        group = GROUP_OF_TAG[tag]
        if groups.setdefault(group, tag) != tag:
            return False
    return True


def _valid_pointer(pointer: str) -> bool:
    if not pointer.startswith("/"):
        return False
    return re.search(r"~(?![01])", pointer) is None and not re.search(r"[\s\[\]]", pointer)


# ----------------------------------------------------------------------------------------- parse


def parse_text(text: str, file: str, kind: str) -> tuple[list[Entry], list[Diagnostic]]:
    entries: list[Entry] = []
    diags: list[Diagnostic] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        entry, diag = _parse_line(raw, file, lineno, kind)
        if diag is not None:
            diags.append(diag)
        if entry is not None:
            entries.append(entry)
    return entries, diags


def _parse_line(raw: str, file: str, lineno: int, kind: str) -> tuple[Entry | None, Diagnostic | None]:
    def error(code: str, message: str) -> tuple[None, Diagnostic]:
        return None, Diagnostic(file, lineno, code, message)

    tokens = raw.replace("[", " [ ").replace("]", " ] ").split()
    if not tokens:
        return None, None
    if tokens[0].startswith("#") and not ISSUE_LINE_RE.match(raw):
        return None, None  # comment line
    for index, token in enumerate(tokens[1:], start=1):
        if token.startswith("#"):
            tokens = tokens[:index]  # trailing comment
            break

    i = 0
    bug: str | None = None
    if tokens[0] != "[" and "/" not in tokens[0]:
        bug = tokens[0]
        i = 1
    tags: list[str] = []
    if i < len(tokens) and tokens[i] == "[":
        close = _close(tokens, i)
        if close is None:
            return error("syntax", "unclosed tag bracket")
        tags = tokens[i + 1 : close]
        i = close + 1
    if i >= len(tokens) or tokens[i] == "[":
        return error("syntax", "missing suite/case")
    test = tokens[i]
    i += 1
    if i >= len(tokens) or tokens[i] != "[":
        return error("syntax", f"{test}: missing [ results ]")
    close = _close(tokens, i)
    if close is None:
        return error("syntax", f"{test}: unclosed results bracket")
    results = tokens[i + 1 : close]
    if close + 1 != len(tokens):
        return error("syntax", f"{test}: text after the results bracket: {' '.join(tokens[close + 1:])}")

    for tag in tags:
        if tag not in GROUP_OF_TAG:
            return error("unknown-tag", f"unknown tag {tag!r}; known: {', '.join(GROUP_OF_TAG)}")
    seen_groups: dict[str, str] = {}
    for tag in tags:
        group = GROUP_OF_TAG[tag]
        if seen_groups.setdefault(group, tag) != tag:
            return error(
                "conflicting-tags",
                f"{seen_groups[group]} and {tag} are both {group} tags; no run matches both (write two lines)",
            )
    if not results:
        return error("syntax", f"{test}: empty results")
    for result in results:
        if result not in RESULTS:
            return error("unknown-result", f"unknown result {result!r}; known: {' '.join(RESULTS)}")

    name, _, pointer_text = test.partition("#")
    pointer = pointer_text if "#" in test else None
    parts = name.split("/")
    if len(parts) not in (2, 3):
        return error("bad-target", f"{test}: want suite/case[/step][#/json/pointer]")
    suite, case = parts[0], parts[1]
    step = parts[2] if len(parts) == 3 else None
    for part in (suite, step):
        if part is not None and not NAME_RE.match(part):
            return error("bad-target", f"{test}: bad name {part!r}")
    if case != "*" and not NAME_RE.match(case):
        return error("bad-target", f"{test}: bad name {case!r}")
    if case == "*" and (step is not None or pointer is not None):
        return error("bad-target", f"{test}: suite/* takes no step or pointer")
    if pointer is not None and not _valid_pointer(pointer):
        return error("bad-pointer", f"{test}: {pointer!r} is not an RFC 6901 pointer")

    entry = Entry(
        file=file,
        lineno=lineno,
        kind=kind,
        bug=bug,
        tags=frozenset(tags),
        suite=suite,
        case=case,
        step=step,
        pointer=pointer,
        results=frozenset(results),
    )
    if len(entry.results) != len(results):
        return error("duplicate-result", f"{test}: a result appears twice")
    if SKIP in entry.results and len(entry.results) > 1:
        return error("skip-alone", f"{test}: Skip never runs, so it cannot share a line with other results")
    if entry.pointer is not None and not entry.results <= {PASS, FAILURE}:
        return error("pointer-results", f"{test}: a pointer line scopes one value; only Pass and Failure apply")
    if entry.scope == SCOPE_GLOB and FAILURE in entry.results:
        return error(
            "glob-failure",
            f"{test}: Failure on suite/* hides every divergence of the suite; scope the known-wrong value with "
            "#/pointer, or use Skip, Crash or Timeout",
        )
    if entry.step is not None and SKIP in entry.results:
        return error("step-skip", f"{test}: a step cannot be skipped alone; skip the case")
    if kind == "neverfix" and entry.results != {SKIP}:
        return error("neverfix-skip", f"{test}: NeverFix lines are [ Skip ] only")
    return entry, None


def _close(tokens: Sequence[str], start: int) -> int | None:
    for index in range(start + 1, len(tokens)):
        if tokens[index] == "]":
            return index
        if tokens[index] == "[":
            return None
    return None


# ------------------------------------------------------------------------------------------- load


@dataclasses.dataclass
class Expectations:
    entries: list[Entry]
    diagnostics: list[Diagnostic]

    @classmethod
    def load(cls, expectations: Iterable[Path] = (), neverfix: Iterable[Path] = ()) -> "Expectations":
        """Each path is a `.d` directory of `<suite>.txt` files or one combined file."""
        entries: list[Entry] = []
        diags: list[Diagnostic] = []
        for kind, paths in (("expectations", expectations), ("neverfix", neverfix)):
            for path in paths:
                for file, split in _files(Path(path)):
                    found, found_diags = parse_text(file.read_text(encoding="utf-8"), _rel(file), kind)
                    diags.extend(found_diags)
                    for entry in found:
                        if split and entry.suite != file.stem:
                            diags.append(
                                Diagnostic(
                                    entry.file,
                                    entry.lineno,
                                    "wrong-file",
                                    f"{entry.target} belongs in {entry.suite}.txt (one file per suite)",
                                )
                            )
                        entries.append(entry)
        return cls(entries, diags)

    @classmethod
    def load_root(cls, root: Path = DEFAULT_ROOT) -> "Expectations":
        return cls.load([root / "Expectations.d"], [root / "NeverFix.d"])

    def keys(self) -> list[str]:
        return sorted(f"{e.kind} {e.key}" for e in self.entries)

    # -------------------------------------------------------------------------------- matching

    def _matching(self, suite: str, case: str, config: RunConfig) -> list[Entry]:
        return [
            e
            for e in self.entries
            if e.suite == suite and e.case in (case, "*") and e.matches(config)
        ]

    def resolve(self, suite: str, case: str, config: RunConfig, step: str | None = None) -> "Resolution":
        """Case-level (or step-level) expectation; pointer lines never apply here."""
        candidates = [
            e
            for e in self._matching(suite, case, config)
            if e.kind == "expectations" and e.pointer is None and (e.step is None or e.step == step)
        ]
        return Resolution.of(candidates)

    def neverfix(self, suite: str, case: str, config: RunConfig) -> Entry | None:
        hits = [e for e in self._matching(suite, case, config) if e.kind == "neverfix"]
        return max(hits, key=_rank) if hits else None

    def should_run(self, suite: str, case: str, config: RunConfig) -> bool:
        if self.neverfix(suite, case, config) is not None:
            return False
        return SKIP not in self.resolve(suite, case, config).outcomes

    def settle_multiplier(self, suite: str, case: str, config: RunConfig, step: str | None = None) -> int:
        return SLOW_MULTIPLIER if self.resolve(suite, case, config, step).slow else 1

    def evaluate(self, suite: str, case: str, config: RunConfig, actual: "Actual") -> "Verdict":
        if not self.should_run(suite, case, config):
            return Verdict(SKIPPED, actual.result, frozenset({SKIP}), False, (), (), {})
        case_level = self.resolve(suite, case, config, actual.step)
        lines: dict[str, str] = {}
        if actual.result in (CRASH, TIMEOUT):
            expected = actual.result in case_level.outcomes
            for e in case_level.lines:
                lines[e.key] = "hit" if expected else "missed"
            outcome = EXPECTED if expected else UNEXPECTED_FAILURE
            return Verdict(
                outcome, actual.result, case_level.outcomes, case_level.flaky, (), (), lines
            )

        candidates = [
            e for e in self._matching(suite, case, config) if e.kind == "expectations" and e.has_result
        ]
        divergences = list(actual.divergences)
        if actual.result == FAILURE and not divergences:
            divergences = [Divergence(actual.step, None)]
        uncovered: list[Divergence] = []
        hit: set[str] = set()
        missed: set[str] = set()
        diverged: set[str] = set()  # lines whose scope holds a divergence
        flaky = False
        for d in divergences:
            covering = _cover(candidates, d)
            flaky = flaky or covering.flaky
            if FAILURE in covering.outcomes:
                hit.update(e.key for e in covering.lines)
            else:
                uncovered.append(d)
                missed.update(e.key for e in covering.lines)
            diverged.update(e.key for e in candidates if e.covers(d))

        # A winning line is an unexpected pass only when its whole scope passed: the Blink signal
        # that the line can go. A line whose scope diverged under a more specific line is shadowed.
        unexpected_pass: list[str] = []
        for e in _winners(candidates):
            if e.key in hit:
                lines[e.key] = "hit"
            elif e.key in missed:
                lines[e.key] = "missed"
            elif e.key in diverged:
                lines[e.key] = "shadowed"
            elif PASS in e.outcomes:
                lines[e.key] = "pass-ok"
            else:
                lines[e.key] = "unexpected-pass"
                unexpected_pass.append(e.key)
        if uncovered:
            outcome = UNEXPECTED_FAILURE
        elif unexpected_pass and actual.result == PASS:
            outcome = UNEXPECTED_PASS
        else:
            outcome = EXPECTED
        return Verdict(
            outcome,
            actual.result,
            case_level.outcomes,
            flaky or case_level.flaky,
            tuple(uncovered),
            tuple(sorted(unexpected_pass)),
            lines,
        )


def _files(path: Path) -> list[tuple[Path, bool]]:
    if path.is_dir():
        return [(f, True) for f in sorted(path.glob("*.txt"))]
    if path.is_file():
        return [(path, False)]
    return []


def _rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _winners(entries: list[Entry]) -> list[Entry]:
    """One line per (step, pointer) target: the most specific matching line (ties all win)."""
    by_target: dict[tuple[str | None, str | None], list[Entry]] = {}
    for e in entries:
        by_target.setdefault((e.step, e.pointer), []).append(e)
    result: list[Entry] = []
    for group in by_target.values():
        best = max(_rank(e) for e in group)
        result.extend(e for e in group if _rank(e) == best)
    return result


def _cover(candidates: list[Entry], d: "Divergence") -> "Resolution":
    return Resolution.of([e for e in candidates if e.covers(d)])


@dataclasses.dataclass(frozen=True)
class Resolution:
    lines: tuple[Entry, ...]  # the winning result lines
    outcomes: frozenset[str]
    slow_lines: tuple[Entry, ...]  # every candidate with Slow, winner or not

    @property
    def slow(self) -> bool:
        return bool(self.slow_lines)

    @property
    def flaky(self) -> bool:
        return len(self.outcomes) > 1

    @classmethod
    def of(cls, candidates: list[Entry]) -> "Resolution":
        """Most specific result lines win and union on a tie (typ); Slow is ORed over all candidates."""
        slow_lines = tuple(e for e in candidates if e.slow)
        ranked = [e for e in candidates if e.has_result]
        if not ranked:
            return cls((), frozenset({PASS}), slow_lines)
        best = max(_rank(e) for e in ranked)
        top = tuple(e for e in ranked if _rank(e) == best)
        return cls(top, frozenset().union(*(e.outcomes for e in top)), slow_lines)


@dataclasses.dataclass(frozen=True)
class Divergence:
    step: str | None
    pointer: str | None  # None: the step (or case) failed without a value-level pointer


@dataclasses.dataclass(frozen=True)
class Actual:
    result: str
    divergences: tuple[Divergence, ...] = ()
    step: str | None = None  # the step a Crash or Timeout happened at

    def __post_init__(self) -> None:
        if self.result not in ACTUAL_RESULTS:
            raise ValueError(f"actual result {self.result!r} is not one of {' '.join(ACTUAL_RESULTS)}")


@dataclasses.dataclass(frozen=True)
class Verdict:
    outcome: str
    actual: str
    expected: frozenset[str]
    flaky: bool
    uncovered: tuple[Divergence, ...]
    unexpected_pass_lines: tuple[str, ...]
    lines: dict[str, str]  # line key -> hit | missed | shadowed | pass-ok | unexpected-pass

    @property
    def fails_run(self) -> bool:
        return self.outcome == UNEXPECTED_FAILURE

    def to_json(self) -> dict:
        return {
            "outcome": self.outcome,
            "actual": self.actual,
            "expected": sorted(self.expected),
            "flaky": self.flaky,
            "fails_run": self.fails_run,
            "uncovered": [dataclasses.asdict(d) for d in self.uncovered],
            "unexpected_pass_lines": list(self.unexpected_pass_lines),
            "lines": dict(sorted(self.lines.items())),
        }


# ------------------------------------------------------------------------------------------- lint


def lint(
    exp: Expectations,
    corpus: Path | None = None,
    results: Iterable[dict] = (),
    min_runs: int = 3,
) -> list[Diagnostic]:
    diags = list(exp.diagnostics)
    entries = exp.entries
    for e in entries:
        if e.bug is None:
            diags.append(Diagnostic(e.file, e.lineno, "bug-id", f"{e.target}: every line names a task id or #issue"))
        elif not (TASK_ID_RE.match(e.bug) or ISSUE_RE.match(e.bug)):
            diags.append(Diagnostic(e.file, e.lineno, "bug-id", f"{e.bug!r} is neither a task id nor #issue"))
        if e.kind == "expectations" and e.scope in (SCOPE_CASE, SCOPE_STEP) and e.outcomes == {FAILURE}:
            diags.append(
                Diagnostic(
                    e.file,
                    e.lineno,
                    "whole-case-failure",
                    f"{e.target}: rebaseline, or scope the known-wrong value with #/pointer",
                    "warning",
                )
            )

    diags.extend(_lint_overlaps(entries))
    if corpus is not None:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import corpus_store  # noqa: PLC0415 - sibling: the stored suites of the repository corpus

        for error in corpus_store.load_errors(corpus):  # its lines then show as stale
            print(f"expectations: warning: {error}", file=sys.stderr)
        diags.extend(_lint_stale_corpus(entries, corpus))
        diags.extend(_lint_budget(entries, corpus))
    diags.extend(_lint_stale_results(entries, results, min_runs))
    return sorted(diags, key=lambda d: (d.file, d.line, d.code))


def _lint_overlaps(entries: list[Entry]) -> list[Diagnostic]:
    diags: list[Diagnostic] = []
    expectations = [e for e in entries if e.kind == "expectations"]
    neverfix = [e for e in entries if e.kind == "neverfix"]
    for e in expectations:
        skip = next(
            (
                n
                for n in neverfix
                if n.suite == e.suite and n.case in (e.case, "*") and _tags_compatible(e.tags, n.tags)
            ),
            None,
        )
        if skip is not None:
            diags.append(
                Diagnostic(
                    e.file,
                    e.lineno,
                    "neverfix-overlap",
                    f"{e.target} never takes effect: NeverFix {skip.where} skips it on "
                    f"[ {' '.join(sorted(e.tags | skip.tags, key=_tag_order))} ] runs",
                )
            )

    by_target: dict[tuple, list[Entry]] = {}
    for e in entries:
        by_target.setdefault((e.kind, e.suite, e.case, e.step, e.pointer), []).append(e)
    for group in by_target.values():
        for index, a in enumerate(group):
            for b in group[index + 1 :]:
                if a.tags == b.tags:
                    diags.append(
                        Diagnostic(b.file, b.lineno, "duplicate", f"{b.target} duplicates {a.where}")
                    )
                elif (
                    a.kind == "expectations"
                    and a.has_result
                    and b.has_result
                    and _tags_compatible(a.tags, b.tags)
                ):
                    diags.append(
                        Diagnostic(
                            b.file,
                            b.lineno,
                            "overlap",
                            f"{b.target} and {a.where} both match a "
                            f"[ {' '.join(sorted(a.tags | b.tags, key=_tag_order))} ] run, which would get "
                            "both lines' results; make the tag sets disjoint",
                        )
                    )
    return diags


def _corpus_case(corpus: Path, suite: str, case: str) -> Path:
    return corpus / suite / f"{case}.json"


def _lint_stale_corpus(entries: list[Entry], corpus: Path) -> list[Diagnostic]:
    diags: list[Diagnostic] = []
    steps_cache: dict[Path, set[str] | None] = {}
    for e in entries:
        if not (corpus / e.suite).is_dir():
            diags.append(Diagnostic(e.file, e.lineno, "stale", f"{e.target}: suite {e.suite} is not in the corpus"))
            continue
        if e.case == "*":
            continue
        path = _corpus_case(corpus, e.suite, e.case)
        if not path.is_file():
            diags.append(Diagnostic(e.file, e.lineno, "stale", f"{e.target}: no case {_rel(path)}"))
            continue
        if e.step is None:
            continue
        if path not in steps_cache:
            steps_cache[path] = _step_ids(path)
        steps = steps_cache[path]
        if steps is None:
            diags.append(Diagnostic(e.file, e.lineno, "stale", f"{e.target}: {_rel(path)} is not a readable case"))
        elif e.step not in steps:
            diags.append(Diagnostic(e.file, e.lineno, "stale", f"{e.target}: case has no step {e.step!r}"))
    return diags


def _step_ids(path: Path) -> set[str] | None:
    try:
        case = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    steps = case.get("steps") if isinstance(case, dict) else None
    if not isinstance(steps, list):
        return None
    return {s["id"] for s in steps if isinstance(s, dict) and isinstance(s.get("id"), str)}


def _lint_budget(entries: list[Entry], corpus: Path) -> list[Diagnostic]:
    """A `suite/*` line counts as every case of its suite: one line must not hide a golden suite."""
    suite_cases = {
        s: len(list((corpus / s).glob("*.json"))) for s in GOLDEN_SUITES if (corpus / s).is_dir()
    }
    cases = sum(suite_cases.values())
    counted = sum(
        suite_cases.get(e.suite, 0) if e.scope == SCOPE_GLOB else 1
        for e in entries
        if e.suite in GOLDEN_SUITES and e.outcomes != {PASS}
    )
    limit = int(cases * GOLDEN_BUDGET)
    if counted <= limit:
        return []
    return [
        Diagnostic(
            "tests/oracle",
            0,
            "golden-budget",
            f"golden Expectations + NeverFix lines cover {counted} cases > 2 % of {cases} golden cases "
            f"({limit}); rebaseline instead",
        )
    ]


def _lint_stale_results(entries: list[Entry], records: Iterable[dict], min_runs: int) -> list[Diagnostic]:
    """A non-Pass line that passed in >= min_runs verdicts and was never hit is stale (Blink
    update_expectations). Missed and shadowed runs did not pass, so they do not count."""
    passed: dict[str, int] = {}
    hit: set[str] = set()
    for record in records:
        for key, state in (record.get("lines") or {}).items():
            if state == "hit":
                hit.add(key)
            elif state == "unexpected-pass":
                passed[key] = passed.get(key, 0) + 1
    diags: list[Diagnostic] = []
    for e in entries:
        if e.kind != "expectations" or PASS in e.outcomes:
            continue
        runs = passed.get(e.key, 0)
        if runs >= min_runs and e.key not in hit:
            expected = "/".join(sorted(e.outcomes))
            diags.append(
                Diagnostic(e.file, e.lineno, "stale", f"{e.target}: passed in {runs} runs that expected {expected}; remove it")
            )
    return diags


def _read_records(paths: Sequence[str]) -> list[dict]:
    records: list[dict] = []
    for path in paths:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            if line.strip():
                records.append(json.loads(line))
    return records


# --------------------------------------------------------------------------------------- selftest


def _selftest() -> int:
    failures: list[str] = []
    count = 0

    def check(name: str, condition: bool) -> None:
        nonlocal count
        count += 1
        if not condition:
            failures.append(name)

    def parse(text: str, kind: str = "expectations") -> tuple[list[Entry], list[Diagnostic]]:
        return parse_text(text, "t.txt", kind)

    def codes(text: str, kind: str = "expectations") -> list[str]:
        return [d.code for d in parse(text, kind)[1]]

    def exp(text: str, neverfix: str = "") -> Expectations:
        e1, d1 = parse(text)
        e2, d2 = parse(neverfix, "neverfix")
        return Expectations(e1 + e2, d1 + d2)

    linux_daemon = RunConfig(platform="linux", product="daemon")
    mac_app = RunConfig(platform="mac", product="app")

    # 1. Full line with bug, tags, step, pointer and a trailing comment.
    entries, diags = parse("p15-oracle-015 [ linux daemon ] journeys/split/s2#/panes/0/frame [ Failure ] # wrong frame")
    e = entries[0] if entries else None
    check(
        "full line",
        not diags
        and e is not None
        and e.bug == "p15-oracle-015"
        and e.tags == {"linux", "daemon"}
        and (e.suite, e.case, e.step, e.pointer) == ("journeys", "split", "s2", "/panes/0/frame")
        and e.results == {FAILURE},
    )
    # 2. Issue bug ids are not comments; other # lines are.
    entries, diags = parse("#1234 terminal/vt-01 [ Timeout ]\n# a comment [ Failure ]\n#tags: x")
    check("issue id and comments", len(entries) == 1 and entries[0].bug == "#1234" and not diags)
    # 3. Brackets need no inner spaces.
    entries, diags = parse("p15-oracle-015 [linux] terminal/vt-01 [Crash]")
    check("tight brackets", not diags and entries[0].tags == {"linux"} and entries[0].results == {CRASH})
    # 4. Unknown tag and unknown result.
    check("unknown tag", codes("p15-oracle-015 [ freebsd ] terminal/a [ Pass ]") == ["unknown-tag"])
    check("unknown result", codes("p15-oracle-015 terminal/a [ Flaky ]") == ["unknown-result"])
    # 5. Two tags of one group never match a run (typ semantics).
    check("conflicting tags", codes("p15-oracle-015 [ linux mac ] terminal/a [ Failure ]") == ["conflicting-tags"])
    # 6. Skip stands alone, step lines cannot Skip, pointer lines take only Pass/Failure.
    check("skip alone", codes("p15-oracle-015 terminal/a [ Skip Failure ]") == ["skip-alone"])
    check("step skip", codes("p15-oracle-015 terminal/a/s1 [ Skip ]") == ["step-skip"])
    check("pointer results", codes("p15-oracle-015 terminal/a#/x [ Timeout ]") == ["pointer-results"])
    # 7. Bad pointers and targets.
    check("bad pointer", codes("p15-oracle-015 terminal/a#x [ Failure ]") == ["bad-pointer"])
    check("bad escape", codes("p15-oracle-015 terminal/a#/a~2 [ Failure ]") == ["bad-pointer"])
    check("bad target", codes("p15-oracle-015 terminal [ Failure ]\np15-oracle-015 a/b/c/d [ Pass ]") == ["bad-target", "bad-target"])
    check("missing results", codes("p15-oracle-015 terminal/a") == ["syntax"])
    # 8. NeverFix lines are Skip only.
    check("neverfix skip only", codes("p15-oracle-015 terminal/a [ Failure ]", "neverfix") == ["neverfix-skip"])
    # 9. Several results mean flaky; either result is expected.
    flaky = exp("p15-oracle-015 terminal/a [ Pass Failure ]")
    v_pass = flaky.evaluate("terminal", "a", linux_daemon, Actual(PASS))
    v_fail = flaky.evaluate("terminal", "a", linux_daemon, Actual(FAILURE, (Divergence(None, "/x"),)))
    check("flaky", v_pass.outcome == EXPECTED and v_fail.outcome == EXPECTED and v_pass.flaky and v_fail.flaky)
    # 10. Skip never runs, and NeverFix skips too.
    skip = exp("p15-oracle-015 [ mac ] terminal/a [ Skip ]", "p15-oracle-015 [ windows ] terminal/b [ Skip ]")
    check(
        "skip never runs",
        not skip.should_run("terminal", "a", mac_app)
        and skip.should_run("terminal", "a", linux_daemon)
        and not skip.should_run("terminal", "b", RunConfig(platform="windows"))
        and skip.evaluate("terminal", "a", mac_app, Actual(PASS)).outcome == SKIPPED,
    )
    # 11. Failure that passes reports an unexpected pass, which does not fail the run.
    fail = exp("p15-oracle-015 terminal/a [ Failure ]")
    v = fail.evaluate("terminal", "a", linux_daemon, Actual(PASS))
    check("unexpected pass", v.outcome == UNEXPECTED_PASS and not v.fails_run and v.unexpected_pass_lines)
    # 12. Crash is a result: expected when listed, an unexpected failure when not.
    crash = exp("p15-oracle-015 [ asan ] terminal/a [ Crash ]")
    check(
        "crash result",
        crash.evaluate("terminal", "a", RunConfig(build="asan"), Actual(CRASH)).outcome == EXPECTED
        and crash.evaluate("terminal", "a", RunConfig(build="tsan"), Actual(CRASH)).fails_run,
    )
    # 13. A pointer line covers its value and subtree; every other value stays strict.
    ptr = exp("p15-oracle-015 journeys/j1#/layout/frame [ Failure ]")
    covered = ptr.evaluate("journeys", "j1", mac_app, Actual(FAILURE, (Divergence("s1", "/layout/frame/w"),)))
    sibling = ptr.evaluate("journeys", "j1", mac_app, Actual(FAILURE, (Divergence("s1", "/layout/frameset"),)))
    mixed = ptr.evaluate(
        "journeys",
        "j1",
        mac_app,
        Actual(FAILURE, (Divergence("s1", "/layout/frame"), Divergence("s2", "/focus/pane"))),
    )
    check(
        "pointer keeps the rest strict",
        covered.outcome == EXPECTED
        and sibling.fails_run
        and mixed.fails_run
        and mixed.uncovered == (Divergence("s2", "/focus/pane"),)
        and ptr.evaluate("journeys", "j1", mac_app, Actual(PASS)).outcome == UNEXPECTED_PASS,
    )
    # 14. A step-scoped pointer applies only at that step.
    step_ptr = exp("p15-oracle-015 journeys/j1/s2#/focus [ Failure ]")
    check(
        "step pointer",
        step_ptr.evaluate("journeys", "j1", mac_app, Actual(FAILURE, (Divergence("s2", "/focus"),))).outcome == EXPECTED
        and step_ptr.evaluate("journeys", "j1", mac_app, Actual(FAILURE, (Divergence("s1", "/focus"),))).fails_run,
    )
    # 15. The most specific target wins: a step line beats the case line, a case line beats suite/*.
    spec = exp(
        "p15-oracle-015 terminal/a [ Failure ]\n"
        "p15-oracle-015 terminal/a/s1 [ Timeout ]\n"
        "p15-oracle-015 [ mac ] terminal/* [ Skip ]"
    )
    check(
        "most specific wins",
        spec.resolve("terminal", "a", RunConfig(platform="linux")).outcomes == {FAILURE}
        and spec.resolve("terminal", "a", RunConfig(platform="linux"), "s1").outcomes == {TIMEOUT}
        and spec.resolve("terminal", "a", mac_app).outcomes == {FAILURE}
        and not spec.should_run("terminal", "zz", mac_app),
    )
    # 15b. Tags do not rank: compatible tag sets on one target union (typ) and the linter refuses them.
    union = exp("p15-oracle-015 terminal/a [ Failure ]\np15-oracle-015 [ linux daemon ] terminal/a [ Pass ]")
    check(
        "tags union, lint refuses",
        union.resolve("terminal", "a", linux_daemon).outcomes == {PASS, FAILURE}
        and union.resolve("terminal", "a", mac_app).outcomes == {FAILURE}
        and sorted(d.code for d in lint(union)) == ["overlap", "whole-case-failure"],
    )
    # 16. Slow multiplies settleMaxMs by 5 and still expects Pass.
    slow = exp("p15-oracle-015 [ debug ] tla/trace-9 [ Slow ]")
    check(
        "slow",
        slow.settle_multiplier("tla", "trace-9", RunConfig(build="debug")) == 5
        and slow.settle_multiplier("tla", "trace-9", RunConfig(build="bench")) == 1
        and slow.evaluate("tla", "trace-9", RunConfig(build="debug"), Actual(PASS)).outcome == EXPECTED,
    )
    # 16b. Slow is a modifier: a more specific step or tagged line keeps it, and a Slow-only line
    # never hides a result line.
    debug = RunConfig(build="debug")
    slow_step = exp("p15-oracle-015 t/a [ Slow ]\np15-oracle-015 t/a/s2 [ Failure ]")
    slow_tag = exp("p15-oracle-015 t/a [ Slow ]\np15-oracle-015 [ linux ] t/a [ Pass Timeout ]")
    slow_hides = exp("p15-oracle-015 tla/t1 [ Failure ]\np15-oracle-015 [ debug ] tla/t1 [ Slow ]")
    slow_tag_step = exp("p15-oracle-015 [ debug ] tla/t1 [ Slow ]\np15-oracle-015 tla/t1/s2 [ Pass Timeout ]")
    check(
        "slow is a modifier",
        slow_step.settle_multiplier("t", "a", mac_app, "s2") == 5
        and slow_step.settle_multiplier("t", "a", mac_app) == 5
        and slow_tag.settle_multiplier("t", "a", RunConfig(platform="linux")) == 5
        and slow_hides.settle_multiplier("tla", "t1", debug) == 5
        and slow_hides.resolve("tla", "t1", debug).outcomes == {FAILURE}
        and slow_hides.evaluate("tla", "t1", debug, Actual(FAILURE, (Divergence(None, "/x"),))).outcome == EXPECTED
        and [d.code for d in lint(slow_hides)] == ["whole-case-failure"]
        and slow_tag_step.settle_multiplier("tla", "t1", debug, "s2") == 5
        and slow_tag_step.settle_multiplier("tla", "t1", RunConfig(build="bench"), "s2") == 1,
    )
    # 16c. A failing run is never an unexpected pass: a line whose scope diverged under a more
    # specific line is shadowed, and an unexpected pass of another scope leaves the run expected.
    shadow = exp("p15-oracle-015 a/b [ Failure ]\np15-oracle-015 a/b#/x [ Failure ]")
    v_shadow = shadow.evaluate("a", "b", mac_app, Actual(FAILURE, (Divergence(None, "/x"),)))
    step_shadow = exp("p15-oracle-015 j/c/s1 [ Timeout ]\np15-oracle-015 j/c#/a [ Failure ]")
    v_step = step_shadow.evaluate("j", "c", mac_app, Actual(FAILURE, (Divergence("s1", "/a"),)))
    other_step = exp("p15-oracle-015 j/c/s1 [ Failure ]\np15-oracle-015 j/c/s2#/a [ Failure ]")
    v_other = other_step.evaluate("j", "c", mac_app, Actual(FAILURE, (Divergence("s2", "/a"),)))
    check(
        "failing run is not an unexpected pass",
        v_shadow.outcome == EXPECTED
        and not v_shadow.unexpected_pass_lines
        and set(v_shadow.lines.values()) == {"hit", "shadowed"}
        and v_step.outcome == EXPECTED
        and not v_step.unexpected_pass_lines
        and v_other.outcome == EXPECTED
        and v_other.unexpected_pass_lines == ("p15-oracle-015 [ ] j/c/s1 [ Failure ]",),
    )
    # 16d. The runner's actual result is one of Pass Failure Crash Timeout.
    refused = []
    for bad in (SKIP, SLOW, "pass"):
        try:
            Actual(bad)
        except ValueError:
            refused.append(bad)
    check("actual result validated", refused == [SKIP, SLOW, "pass"])
    # 17. Lint: bug id, duplicates, overlap, NeverFix overlap.
    lint_codes = sorted(
        d.code
        for d in lint(
            exp(
                "terminal/a [ Failure ]\n"
                "bug-1 terminal/b#/x [ Failure ]\n"
                "p15-oracle-015 [ linux ] terminal/c#/x [ Failure ]\n"
                "p15-oracle-015 [ linux ] terminal/c#/x [ Pass Failure ]\n"
                "p15-oracle-015 [ linux ] terminal/d#/x [ Failure ]\n"
                "p15-oracle-015 [ daemon ] terminal/d#/x [ Pass Failure ]\n"
                "p15-oracle-015 [ linux daemon ] terminal/d#/x [ Pass ]\n"
                "p15-oracle-015 terminal/e [ Timeout ]",
                "p15-oracle-015 terminal/e [ Skip ]",
            )
        )
    )
    check(
        "lint ids, duplicates, overlap",
        lint_codes
        == ["bug-id", "bug-id", "duplicate", "neverfix-overlap", "overlap", "overlap", "overlap", "whole-case-failure"],
    )
    # 17b. NeverFix overlap follows tags and suite/*: disjoint tags are fine, a glob skip hides a line.
    def nf_codes(text: str, neverfix: str) -> list[str]:
        return [d.code for d in lint(exp(text, neverfix)) if d.code == "neverfix-overlap"]

    check(
        "neverfix overlap by tags",
        nf_codes("p15-oracle-015 [ mac ] t/e [ Timeout ]", "p15-oracle-015 [ windows ] t/e [ Skip ]") == []
        and nf_codes("p15-oracle-015 [ windows ] t/e [ Timeout ]", "p15-oracle-015 [ windows ] t/* [ Skip ]")
        == ["neverfix-overlap"]
        and nf_codes("p15-oracle-015 [ debug ] t/e/s1 [ Timeout ]", "p15-oracle-015 [ mac ] t/e [ Skip ]")
        == ["neverfix-overlap"]
        and nf_codes("p15-oracle-015 [ mac ] t/* [ Timeout ]", "p15-oracle-015 [ mac ] t/e [ Skip ]") == [],
    )
    # 17c. suite/* takes no Failure: one line would hide every divergence of the suite.
    check(
        "glob failure refused",
        codes("p15-oracle-015 [ linux ] journeys/* [ Failure ]") == ["glob-failure"]
        and codes("p15-oracle-015 [ linux ] journeys/* [ Pass Failure ]") == ["glob-failure"]
        and codes("p15-oracle-015 [ linux ] journeys/* [ Pass Timeout ]") == [],
    )
    # 17d. A comment that starts with an issue number stays a comment.
    entries, diags = parse(
        "#12 is the tracking issue\n#24990 tracks the sidebar flakes [ see below ]\n"
        "#7 https://github.com/manaflow-ai/cmux/issues/7\n#8 journeys/split is broken\n"
        "#24990 [ mac app ] tours/sidebar [ Pass Timeout ]\n#24991 [linux] cli/x[Crash]\n#24992 tla/t1 [ Slow ]"
    )
    check(
        "issue comments",
        not diags and [e.target for e in entries] == ["tours/sidebar", "cli/x", "tla/t1"],
    )
    # 17e. Stale by results counts only passing runs: a Timeout line hit by crashes is not stale.
    timeout = exp("p15-oracle-015 t/a [ Timeout ]")
    crashes = [timeout.evaluate("t", "a", mac_app, Actual(CRASH)).to_json() for _ in range(3)]
    check("missed is not stale", _lint_stale_results(timeout.entries, crashes, 3) == [])

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        corpus = root / "corpus"
        (corpus / "terminal").mkdir(parents=True)
        for index in range(100):
            (corpus / "terminal" / f"vt-{index:02}.json").write_text('{"steps": [{"id": "s1"}]}')
        (corpus / "cli").mkdir()
        lines = {
            "terminal": "p15-oracle-015 terminal/vt-01#/cells [ Failure ]\n"
            "p15-oracle-015 [ mac ] terminal/vt-02/s1 [ Timeout ]\n",
            "cli": "p15-oracle-015 [ windows ] cli/* [ Skip ]\n",
        }
        split = root / "Expectations.d"
        split.mkdir()
        for suite, text in lines.items():
            (split / f"{suite}.txt").write_text(text)
        combined = root / "TestExpectations"
        combined.write_text("# combined\n" + "".join(lines.values()))
        # 18. A split directory reads the same as one combined file.
        a = Expectations.load([split])
        b = Expectations.load([combined])
        check("split equals combined", a.keys() == b.keys() and not a.diagnostics and not b.diagnostics)
        # 19. A line in the wrong suite file is refused.
        (split / "cli.txt").write_text(lines["cli"] + "p15-oracle-015 terminal/vt-03#/x [ Failure ]\n")
        check("wrong file", [d.code for d in Expectations.load([split]).diagnostics] == ["wrong-file"])
        (split / "cli.txt").write_text(lines["cli"])
        # 20. Stale: missing case, missing step, missing suite; then golden budget 2 %.
        (split / "terminal.txt").write_text(
            lines["terminal"]
            + "p15-oracle-015 terminal/vt-99/s9#/x [ Failure ]\n"
            + "p15-oracle-015 terminal/gone [ Timeout ]\n"
        )
        (split / "upgrades.txt").write_text("p15-oracle-015 upgrades/v1 [ Crash ]\n")
        stale = [d.code for d in lint(Expectations.load([split]), corpus)]
        check("stale corpus", stale.count("stale") == 3 and "golden-budget" in stale)
        (split / "terminal.txt").write_text(lines["terminal"])
        (split / "upgrades.txt").unlink()
        check("budget ok", [d.code for d in lint(Expectations.load([split]), corpus)] == [])
        (split / "terminal.txt").write_text(
            "".join(f"p15-oracle-015 terminal/vt-{i:02}#/c [ Failure ]\n" for i in range(3))
        )
        check("budget over", [d.code for d in lint(Expectations.load([split]), corpus)] == ["golden-budget"])
        # 20b. A suite/* line counts as every case of its suite, not as one line.
        (split / "terminal.txt").write_text("p15-oracle-015 [ mac ] terminal/* [ Timeout ]\n")
        check("budget glob", [d.code for d in lint(Expectations.load([split]), corpus)] == ["golden-budget"])
        (split / "terminal.txt").write_text(
            "".join(f"p15-oracle-015 terminal/vt-{i:02}#/c [ Failure ]\n" for i in range(3))
        )
        # 21. Stale from results: a Failure line never hit across min_runs verdicts.
        loaded = Expectations.load([split])
        verdicts = [
            loaded.evaluate("terminal", "vt-00", linux_daemon, Actual(PASS)).to_json() for _ in range(3)
        ] + [
            loaded.evaluate(
                "terminal", "vt-01", linux_daemon, Actual(FAILURE, (Divergence("s1", "/c/0"),))
            ).to_json()
            for _ in range(3)
        ]
        stale_results = [
            d for d in _lint_stale_results(loaded.entries, verdicts, 3) if d.code == "stale"
        ]
        check(
            "stale results",
            [d.message.split(":")[0] for d in stale_results] == ["terminal/vt-00#/c"],
        )

    for name in failures:
        print(f"FAIL {name}", file=sys.stderr)
    print(f"expectations selftest: {count - len(failures)}/{count} passed")
    return 1 if failures else 0


# -------------------------------------------------------------------------------------------- cli


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_lint = sub.add_parser("lint", help="lint Expectations.d and NeverFix.d")
    p_lint.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    p_lint.add_argument("--corpus", type=Path, help="corpus dir for stale and budget checks (default ROOT/corpus)")
    p_lint.add_argument("--results", nargs="*", default=[], help="verdict jsonl files for the stale-by-results check")
    p_lint.add_argument("--min-runs", type=int, default=3)
    p_lint.add_argument("--json", action="store_true")
    p_query = sub.add_parser("query", help="print the expectation for one case or step")
    p_query.add_argument("target", help="suite/case[/step]")
    p_query.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    for group, tags in TAG_GROUPS.items():
        p_query.add_argument(f"--{group}", choices=tags)
    sub.add_parser("selftest", help="run the parser and verdict self tests")
    args = parser.parse_args(argv)

    if args.command == "selftest":
        return _selftest()
    exp = Expectations.load_root(args.root)
    if args.command == "lint":
        corpus = args.corpus or args.root / "corpus"
        diags = lint(exp, corpus, _read_records(args.results), args.min_runs)
        errors = [d for d in diags if d.severity == "error"]
        if args.json:
            print(json.dumps([dataclasses.asdict(d) for d in diags], indent=2))
        else:
            for d in diags:
                print(d.render())
            print(f"{len(exp.entries)} lines, {len(errors)} errors, {len(diags) - len(errors)} warnings")
        return 1 if errors else 0
    parts = args.target.split("/")
    if len(parts) not in (2, 3):
        parser.error("target is suite/case[/step]")
    config = RunConfig(args.platform, args.arm, args.product, args.build)
    suite, case = parts[0], parts[1]
    step = parts[2] if len(parts) == 3 else None
    res = exp.resolve(suite, case, config, step)
    print(
        json.dumps(
            {
                "runs": exp.should_run(suite, case, config),
                "expected": sorted(res.outcomes),
                "flaky": res.flaky,
                "settle_multiplier": exp.settle_multiplier(suite, case, config, step),
                "lines": [e.where for e in res.lines],
                "slow_lines": [e.where for e in res.slow_lines],
                "pointer_lines": [
                    e.where
                    for e in exp._matching(suite, case, config)
                    if e.pointer is not None and (e.step is None or e.step == step)
                ],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
