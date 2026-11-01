#!/usr/bin/env python3
"""Which `runs-on` reads a repository variable whose live value is one machine, with no live pick.

Leo, 2026-10-24: every reservation (a label only one host serves) has a fallback
within minutes, and "a CI test fails on a runs-on that can resolve to a
single-host label with no fallback". The workflow-text checks see
`vars.CI_IOS_INTERNAL_RUNNER || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'`
and pass it: the `||` only falls through while the variable is unset. Once it
holds glaeda-runner-<one mini>, every archive waits on that mini however long it
is busy or offline, and nothing in a diff shows it.

This reads the values. For every job of every workflow file given, each `||`
alternative of its `runs-on` that reads a variable whose value is one machine
must be a guarded preference:

- one of its `&&` terms reads a picker's output (`needs.<job>.outputs.<name>`),
  the live check made right before the job queued that the machine can take it
  (nightly.yml's build-nightly-app: `needs.pick-nightly-app-runner.outputs.trusted != 'false'`);
- and a later alternative, at its level or an enclosing one, always names a
  runner (a non-empty label literal), so a pick that says no lands somewhere.

A bare `vars.X ||` fails however many alternatives follow it, since a set
variable never falls through.

Single-host values are a runner's own name label (glaeda-runner-<runner name>,
the label only the runner registered under that name carries) or a mini's host
name. A pool label is never single-host here, however few runners serve it today:
counting runners needs an admin token this check does not hold.

Every variable a scanned runs-on reads must also be among the values handed in,
so a new routing variable cannot go unchecked.

Two halves, so a pull request is blocked too:
- ci-repo-variables.yml runs this every 15 minutes with the live values, over the
  workflows of every branch in its ROUTE_BRANCHES (a `gh variable set` never
  shows in a diff, and the archive's workflow runs from rc/cnx-ios-builder);
- tests/test_ci_runs_on_values.py (the guard suite) runs it on the pull request's
  own workflows with RUNNER_NAME_VARIABLES taken as one machine: the only
  variables runner_label_policy.py lets hold a glaeda-runner-* label. So a
  pull request that reads one of them bare in a runs-on fails before it lands,
  and the live run catches any other variable that comes to name one machine.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from pathlib import Path

import yaml

# glaeda-cmux-runner's runner_label(): the static label only the runner registered under that name carries.
RUNNER_NAME_LABEL = re.compile(r"glaeda-runner-[a-z0-9][a-z0-9._-]*")
# A mini or perf host's name (tests/test_ci_runs_on_fallback.py on feat-cmux-next keeps the same list).
HOST_NAME = re.compile(r"cmux\d+s?(?:-perf)?|cmuxs-mac-mini-\d+|cmux-austin-mini-\d+|cmux-lawrence|cmux\d+s?-mac-mini(?:-\d+)?")
# The variables runner_label_policy.py lets hold a runner's own name label (nightly_runner_reason()).
RUNNER_NAME_VARIABLES = ("CI_IOS_INTERNAL_RUNNER", "CI_NIGHTLY_NEXT_TRUSTED_RUNNER", "CI_NIGHTLY_TRUSTED_RUNNER")
VARIABLE = re.compile(r"\bvars\.([A-Za-z0-9_]+)\b")
# A positive test of a picker's output, as one whole `&&` term: the output itself, or the output compared with
# `==` / `!=` to a literal or to format(...) (`needs.p.outputs.trusted != 'false'`,
# `needs.p.outputs.attempt == format('{0}', github.run_attempt)`). A negation (`!needs...`), an `||` group or an
# output mentioned anywhere else is no pick.
PICK = re.compile(r"needs\.[\w-]+\.outputs\.[\w-]+(?:\s*(?:==|!=)\s*(?:'[^']*'|format\([^|&]*\)))?")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)


def single_host(value: str | None) -> bool:
    """Whether a variable's value names one machine."""
    label = (value or "").strip().lower()
    return bool(label) and bool(RUNNER_NAME_LABEL.fullmatch(label) or HOST_NAME.fullmatch(label))


def split_top(text: str, operator: str) -> list[str]:
    """`text` split on `operator` outside parentheses and quotes."""
    parts, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(text):
        char = text[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        elif not quoted and depth == 0 and text.startswith(operator, index):
            parts.append(text[start:index])
            index += len(operator)
            start = index
            continue
        index += 1
    parts.append(text[start:])
    return parts


def _wrapped(text: str) -> bool:
    """Whether `text` is one parenthesized expression, `( ... )`."""
    if not (text.startswith("(") and text.endswith(")")):
        return False
    depth, quoted = 0, False
    for index, char in enumerate(text):
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
            if depth == 0 and index != len(text) - 1:
                return False
    return depth == 0


def unwrap(text: str) -> str:
    text = text.strip()
    while _wrapped(text):
        text = text[1:-1].strip()
    return text


def unconditional(alternative: str) -> bool:
    """Whether an `||` alternative always yields a label: a non-empty literal, or a group one of whose
    alternatives does. A variable may be unset, and a conjunction may be false."""
    alternative = unwrap(alternative)
    alternatives = split_top(alternative, "||")
    if len(alternatives) > 1:
        return any(unconditional(part) for part in alternatives)
    return re.fullmatch(r"'[^'\s]+'", alternative) is not None


def conjuncts(text: str) -> list[str]:
    """The `&&` terms of `text`, parenthesized conjunctions flattened; a term holding an `||` stays one."""
    terms = []
    for term in split_top(unwrap(text), "&&"):
        term = unwrap(term)
        nested = split_top(term, "&&")
        terms += conjuncts(term) if len(nested) > 1 and len(split_top(term, "||")) == 1 else [term]
    return terms


def unguarded(expression: str, values: Mapping[str, str], falls_through: bool = False,
              picked: bool = False) -> list[str]:
    """The variables in `expression` whose value is one machine, that it can yield with no live pick.

    An `||` alternative yields its last `&&` term; earlier terms only decide whether it does. So a variable
    counts where it can be that value (a variable in a comparison is not a label), and a pick counts when it
    is one of the earlier terms, here or in an enclosing conjunction (`picked`). A value that is itself an
    `||` group is read the same way, falling through to what follows the enclosing alternative.
    """
    found = []
    alternatives = split_top(unwrap(expression), "||")
    for index, alternative in enumerate(alternatives):
        tail = falls_through or any(unconditional(later) for later in alternatives[index + 1:])
        terms = conjuncts(alternative)
        guarded = picked or any(PICK.fullmatch(term) for term in terms[:-1])
        value = terms[-1]
        if len(split_top(value, "||")) > 1:
            found += unguarded(value, values, tail, guarded)
            continue
        names = [name for name in dict.fromkeys(VARIABLE.findall(value)) if single_host(values.get(name))]
        if names and not (guarded and tail):
            found += names
    return found


def runs_on_text(job: Mapping) -> str:
    value = job.get("runs-on")
    if isinstance(value, dict):
        labels = value.get("labels") or []
        value = [value.get("group", ""), *([labels] if isinstance(labels, str) else labels)]
    if isinstance(value, list):
        return " ".join(str(item) for item in value)
    return str(value or "")


def runs_on_expressions(text: str) -> list[str]:
    """Each `${{ }}` of a runs-on; a runs-on with none reads no variable."""
    return EXPRESSION.findall(text)


def jobs(trees: Iterable[tuple[str, Path]]) -> list[tuple[str, str, str]]:
    """(branch/file, job id, runs-on text) for every job of every workflow in each (branch, directory)."""
    found = []
    for branch, directory in trees:
        for path in sorted([*directory.glob("*.yml"), *directory.glob("*.yaml")]):
            # BaseLoader keeps every scalar a string, as GitHub reads them.
            doc = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
            for job_id, job in ((doc.get("jobs") or {}) if isinstance(doc, dict) else {}).items():
                if isinstance(job, dict):
                    found.append((f"{branch}:{path.name}", job_id, runs_on_text(job)))
    return found


def read_variables(trees: Iterable[tuple[str, Path]]) -> set[str]:
    """Every variable a runs-on in `trees` reads."""
    return {name for _, _, text in jobs(trees) for name in VARIABLE.findall(text)}


def problems(trees: Iterable[tuple[str, Path]], values: Mapping[str, str]) -> list[str]:
    """A line per runs-on that waits on one machine, and per variable a runs-on reads that `values` lacks."""
    trees = list(trees)
    found = []
    for where, job_id, text in jobs(trees):
        for expression in runs_on_expressions(text):
            for name in dict.fromkeys(unguarded(expression, values)):
                found.append(f"{where} {job_id}: runs-on reads vars.{name}={values[name].strip()!r}, one machine, "
                             "with no live pick before it, so every run waits on that machine while it is busy or "
                             "offline. Fix: put a picker's output and a later pool label in front of it "
                             "(nightly.yml's build-nightly-app), or point the variable at a pool")
    for name in sorted(read_variables(trees) - set(values)):
        found.append(f"a runs-on reads vars.{name}, which ci-repo-variables.yml does not pass to this check. "
                     "Fix: add it to CMUX_CI_RUNS_ON_VARIABLES there")
    return found


RUNS_ON_VARIABLES_ENV = "CMUX_CI_RUNS_ON_VARIABLES"


def parse_values(raw: str) -> dict[str, str]:
    """NAME=value per line, as the workflow passes them; a repeated name is an error (a value spanning lines)."""
    values: dict[str, str] = {}
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        name, separator, value = line.strip().partition("=")
        if not separator or not name or not re.fullmatch(r"[A-Za-z0-9_]+", name):
            # The line's text is not printed: only runner labels belong in this public log.
            raise ValueError(f"{RUNS_ON_VARIABLES_ENV} line {number} is not NAME=value")
        if name in values:
            raise ValueError(f"{RUNS_ON_VARIABLES_ENV} repeats {name}: a variable's value spans lines")
        values[name] = value
    return values


def parse_trees(argv: Iterable[str]) -> list[tuple[str, Path]]:
    """BRANCH=DIR arguments, each DIR a branch's .github/workflows."""
    trees = []
    for arg in argv:
        branch, separator, directory = arg.partition("=")
        if not separator or not branch or not directory:
            raise ValueError(f"argument {arg!r} is not BRANCH=DIR")
        trees.append((branch, Path(directory)))
    return trees


def main(argv: list[str], env: Mapping[str, str]) -> int:
    """runs_on_values.py BRANCH=DIR... : each DIR a branch's .github/workflows, read with the live values."""
    raw = env.get(RUNS_ON_VARIABLES_ENV, "")
    if not raw.strip():
        found = [f"{RUNS_ON_VARIABLES_ENV} is empty: the workflow passed no variable values to check"]
    else:
        try:
            found = problems(parse_trees(argv), parse_values(raw))
        except ValueError as error:
            found = [str(error)]
    if not argv:
        found.append("no workflow directories to read")
    summary = env.get("GITHUB_STEP_SUMMARY")
    lines = [f"- {p}" for p in found] or [f"- no runs-on in {len(argv)} branch(es) waits on one machine"]
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### runs-on values\n\n" + "\n".join(lines) + "\n")
    for problem in found:
        print(f"::error title=runs-on value::{problem}")
    if not found:
        print(f"runs-on values: ok ({len(argv)} branch(es))")
    return 1 if found else 0


if __name__ == "__main__":
    import os
    import sys
    sys.exit(main(sys.argv[1:], os.environ))
