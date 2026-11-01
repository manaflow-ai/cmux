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
name. The pull request half stops there: it has no token to list runners.

The live half also counts hosts. Main's ci-repo-variables.yml runs this file from
feat-cmux-next (the reviewed tooling ref): its runners job lists the self-hosted
runners this repository can use (its own and the org's glaeda group,
pr_runner_pool.GitHub.runners(), with the routing App's token, `--list-runners`)
and hands the names and labels to the check, which resolves each runs-on
alternative that reads a variable to the label set it asks for (every label of a JSON list must be on one runner:
nightly.yml's `fromJSON(format('["{0}", "{1}"]', vars.CI_SEED_TRUSTED_POOL,
vars.CI_NIGHTLY_TRUSTED_RUNNER))`), and fails a set that the runners of exactly one
host carry, picker guard or not: a pool label a single mini serves is still one
machine. A set no self-hosted runner carries (Blacksmith, GitHub-hosted) is not
counted. A runner's host is its glaeda member (`<member>-glaeda`,
`<member>-glaeda-<n>`, `<member>-glaeda-<dedicated entry>`, glaeda's
scripts/glaeda-cmux-runner), else the longest leading host name, else the runner's
own name. An unreadable or empty runner list fails the run: it never passes
uncounted.

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

import json
import re
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any


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


# glaeda's scripts/glaeda-cmux-runner names a runner <member>-glaeda, <member>-glaeda-<n> (an instance) or
# <member>-glaeda-<entry> (a runner.dedicated entry); the member is the host.
GLAEDA_RUNNER_NAME = re.compile(r"(.+?)-glaeda(?:-.+)?")
# The value terms whose label set this resolves; any other term reading a variable is named, never skipped.
FORMAT_JSON = re.compile(r"fromJSON\(\s*format\(\s*'([^']*)'\s*,(.*)\)\s*\)", re.DOTALL)
JSON_FIELD = re.compile(r"fromJSON\(\s*vars\.([A-Za-z0-9_]+)(?:\s*\|\|\s*'([^']*)')?\s*\)\.([A-Za-z0-9_-]+)")
BARE_VARIABLE = re.compile(r"vars\.([A-Za-z0-9_]+)")
LITERAL = re.compile(r"'([^']*)'")


def runner_host(name: str) -> str:
    """The machine a self-hosted runner runs on, from its registered name."""
    name = name.strip().lower()
    match = GLAEDA_RUNNER_NAME.fullmatch(name)
    if match:
        return match.group(1)
    parts = name.split("-")
    for end in range(len(parts), 0, -1):
        if HOST_NAME.fullmatch("-".join(parts[:end])):
            return "-".join(parts[:end])
    return name


def _labels(value: Any) -> frozenset[str] | None:
    """A runs-on value as the label set it asks for; None when it is not a label or a list of labels."""
    if isinstance(value, str):
        return frozenset({value.strip().lower()}) if value.strip() else frozenset()
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return frozenset(item.strip().lower() for item in value if item.strip())
    return None


def value_label_set(term: str, values: Mapping[str, str]) -> tuple[list[str], frozenset[str] | None]:
    """(variables read, label set) of one value term; the set is None when this cannot resolve it.

    An unset variable asks for nothing (an empty set): GitHub falls through to the next alternative.
    """
    term = unwrap(term)
    names = list(dict.fromkeys(VARIABLE.findall(term)))
    if match := BARE_VARIABLE.fullmatch(term):
        return names, _labels(values.get(match.group(1), ""))
    if match := FORMAT_JSON.fullmatch(term):
        template, args = match.group(1), [unwrap(arg) for arg in split_top(match.group(2), ",")]
        filled = []
        for arg in args:
            if variable := BARE_VARIABLE.fullmatch(arg):
                filled.append(values.get(variable.group(1), "").strip())
            elif literal := LITERAL.fullmatch(arg):
                filled.append(literal.group(1))
            else:
                return names, None
        if any(not item for item in filled):
            return names, frozenset()
        try:
            text = re.sub(r"\{(\d+)\}", lambda m: filled[int(m.group(1))], template)
            return names, _labels(json.loads(text))
        except (IndexError, ValueError):
            return names, None
    if match := JSON_FIELD.fullmatch(term):
        raw = values.get(match.group(1), "").strip() or (match.group(2) or "")
        try:
            document = json.loads(raw)
        except ValueError:
            return names, None
        if not isinstance(document, dict):
            return names, None
        field = document.get(match.group(3))
        return names, frozenset() if field in (None, "") else _labels(field)
    return names, None


def label_sets(expression: str, values: Mapping[str, str]) -> list[tuple[list[str], frozenset[str] | None]]:
    """(variables, label set) for each `||` alternative of `expression` whose value term reads a variable."""
    found = []
    for alternative in split_top(unwrap(expression), "||"):
        value = conjuncts(alternative)[-1]
        if len(split_top(value, "||")) > 1:
            found += label_sets(value, values)
        elif VARIABLE.search(value):
            found.append(value_label_set(value, values))
    return found


def hosts_serving(labels: frozenset[str], runners: Sequence[Mapping[str, Any]]) -> dict[str, list[str]]:
    """host -> names of its runners that carry every label in `labels`."""
    hosts: dict[str, list[str]] = {}
    for runner in runners:
        carried = {str(label.get("name", "")).lower() for label in runner.get("labels") or []
                   if isinstance(label, Mapping)}
        if labels <= carried:
            name = str(runner.get("name") or "")
            hosts.setdefault(runner_host(name), []).append(name)
    return hosts


def single_host_sets(trees: Iterable[tuple[str, Path]], values: Mapping[str, str],
                     runners: Sequence[Mapping[str, Any]]) -> list[str]:
    """A line per variable-derived label set that the runners of exactly one host carry, and per variable
    read in a shape this cannot resolve to labels."""
    served: dict[tuple[tuple[str, ...], frozenset[str]], list[str]] = {}
    unresolved: dict[str, list[str]] = {}
    for where, job_id, text in jobs(trees):
        for expression in runs_on_expressions(text):
            for names, labels in label_sets(expression, values):
                if labels is None:
                    for name in names:
                        unresolved.setdefault(name, []).append(f"{where} {job_id}")
                elif labels:
                    served.setdefault((tuple(names), labels), []).append(f"{where} {job_id}")
    found = []
    for (names, labels), readers in served.items():
        hosts = hosts_serving(labels, runners)
        if len(hosts) != 1:
            continue
        (host, names_on_host), = hosts.items()
        shown = ", ".join(dict.fromkeys(readers))
        found.append(f"{' + '.join(f'vars.{name}' for name in names)} asks for {sorted(labels)}, which only host "
                     f"{host} serves (runners {', '.join(sorted(names_on_host))}), so the jobs that take it wait on "
                     f"that one machine while it is busy or offline, picker or not. Read by: {shown}. Fix: give a "
                     "second host's runner every label of the set, or point the variable at a pool more hosts serve")
    for name, readers in unresolved.items():
        found.append(f"a runs-on reads vars.{name} in a form this check cannot turn into labels "
                     f"({', '.join(dict.fromkeys(readers))}), so its hosts were not counted. Fix: teach "
                     "value_label_set() in scripts/ci/runs_on_values.py that form")
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
    # Imported here, not at the top: the runners job runs `--list-runners` on a bare Python with no PyYAML.
    import yaml  # noqa: PLC0415

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


def problems(trees: Iterable[tuple[str, Path]], values: Mapping[str, str],
             runners: Sequence[Mapping[str, Any]] | None = None) -> list[str]:
    """A line per runs-on that waits on one machine, and per variable a runs-on reads that `values` lacks.

    With `runners` (the live half), also a line per variable-derived label set only one host serves.
    """
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
    if runners is not None:
        found += single_host_sets(trees, values, runners)
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


COUNT_HOSTS_ENV = "CMUX_CI_COUNT_RUNNER_HOSTS"
RUNNER_LIST_ENV = "CMUX_CI_RUNNER_LIST"


def github_runners(token: str, repo: str) -> list[Mapping[str, Any]]:
    """The self-hosted runners `repo` can use: its own and the org's glaeda group. Raises when unreadable."""
    import pr_runner_pool  # noqa: PLC0415  (only the runners job lists runners)

    return pr_runner_pool.GitHub(token, repo).runners()


def list_runners(env: Mapping[str, str], read: Callable[[str, str], Sequence[Mapping[str, Any]]]) -> int:
    """`--list-runners`: print `list=<JSON>` (each runner's name and labels) for $GITHUB_OUTPUT, or fail."""
    token = env.get("ROUTE_TOKEN", "")
    if not token:
        print("::error title=runs-on value::no ROUTE_TOKEN: the routing App token was not minted "
              "(GLAEDA_ROUTE_APP_ID and its key), so the runner list cannot be read")
        return 1
    try:
        runners = list(read(token, env.get("GITHUB_REPOSITORY") or "manaflow-ai/cmux"))
    except Exception as error:  # noqa: BLE001  (any failure to read is a failed read, never an empty list)
        print(f"::error title=runs-on value::the self-hosted runner list is unreadable ({str(error)[:200]})")
        return 1
    slim = [{"name": str(runner.get("name") or ""),
             "labels": [{"name": str(label.get("name") or "")} for label in runner.get("labels") or []
                        if isinstance(label, Mapping)]}
            for runner in runners if isinstance(runner, Mapping)]
    print("list=" + json.dumps(slim, separators=(",", ":"), sort_keys=True))
    return 0


def well_formed(runner: Any) -> bool:
    """A runner record as --list-runners prints it: a non-empty name and a non-empty list of named labels."""
    if not isinstance(runner, dict) or not isinstance(runner.get("name"), str) or not runner["name"].strip():
        return False
    labels = runner.get("labels")
    return (isinstance(labels, list) and bool(labels)
            and all(isinstance(label, dict) and isinstance(label.get("name"), str) and label["name"].strip()
                    for label in labels))


def runner_list(env: Mapping[str, str]) -> tuple[list | None, str]:
    """(runners, why not): the runners job's list, or None and why no label set's hosts can be counted."""
    raw = env.get(RUNNER_LIST_ENV, "").strip()
    if not raw:
        return None, ("the runners job gave no self-hosted runner list (its log says why), so no label set's hosts "
                      "were counted")
    try:
        runners = json.loads(raw)
    except ValueError:
        runners = None
    if not isinstance(runners, list) or not all(well_formed(runner) for runner in runners):
        return None, f"{RUNNER_LIST_ENV} is not a JSON list of runners, so no label set's hosts were counted"
    if not runners:
        return None, "the self-hosted runner list is empty, so no label set's hosts were counted"
    return runners, ""


def main(argv: list[str], env: Mapping[str, str],
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] = github_runners) -> int:
    """runs_on_values.py BRANCH=DIR... : each DIR a branch's .github/workflows, read with the live values.

    With CMUX_CI_COUNT_RUNNER_HOSTS=1 (the live half) it also counts the hosts that serve each variable-derived
    label set, from CMUX_CI_RUNNER_LIST; a missing, malformed or empty list fails.
    `runs_on_values.py --list-runners` prints that list, read with ROUTE_TOKEN.
    """
    if argv[:1] == ["--list-runners"]:
        return list_runners(env, read_runners)
    raw = env.get(RUNS_ON_VARIABLES_ENV, "")
    runners, why = runner_list(env) if env.get(COUNT_HOSTS_ENV) == "1" else (None, "")
    if not raw.strip():
        found = [f"{RUNS_ON_VARIABLES_ENV} is empty: the workflow passed no variable values to check"]
    else:
        try:
            found = problems(parse_trees(argv), parse_values(raw), runners)
        except ValueError as error:
            found = [str(error)]
    if why:
        found.append(why)
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
