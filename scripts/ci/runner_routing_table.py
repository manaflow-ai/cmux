#!/usr/bin/env python3
"""Every job that runs on macOS says why, once, in .github/runners.json.

macOS runners are the scarce part of CI and Linux runners are the plentiful
part. A job lands on macOS because its `runs-on:` says so, and nothing used to
ask whether the job needed macOS. This module asks.

`.github/runners.json` carries two tables next to the capability map:

* `job_classes`: what kind of work a job does, and whether that kind of work
  needs macOS (`"needs": "macos"`), runs on Linux (`"needs": "linux"`), or
  runs anywhere (`"needs": "any"`: fleet Linux first, then a free owned mini,
  Blacksmith Linux last, through scripts/ci/portable_job_placement.py).
* `macos_jobs`: every workflow job whose `runs-on:` can route to macOS,
  as `"<workflow file>#<job id>"`, mapped to its class.

`check()` fails when:

* a job routes to macOS and has no `macos_jobs` entry (a new macOS job must
  name its class);
* a `macos_jobs` entry names a class whose `needs` is `linux` and the entry
  carries no `linux_followup` (that work belongs on a Linux runner);
* a macOS job reads an owned side-lane label straight from a repository
  variable (`vars.CI_SIDE_LANE_RUNNER`, `vars.CI_LIGHT_LANE_RUNNER`) with no
  placement output (`needs.<job>.outputs...`, a caller's `inputs.pr_*runner`)
  in its `runs-on:`, and its entry carries no `placement_followup`. Such a job
  bypasses placement: it waits on the side label however busy it is, while a
  placement step would spill it to an idle compatible pool;
* a `macos_jobs` entry names a job that no longer exists or no longer routes
  to macOS (the table stays true);
* a job of an `any` class does not take portable placement's fleet Linux
  output, then its mini output, then a Blacksmith label, in that order
  (portable_order()); nightly.yml's light jobs read build-nightly-app's
  light-job placement (its mini output, then a Blacksmith label) instead.

`linux_followup`, `placement_followup` and `picker_followup` exist only so the
table can describe today's tree: an existing job that should move but has not yet. A new
job never gets one. An entry whose followup no longer applies fails too, so
the list only shrinks.

A job wired to the capability map (`fromJSON(needs.runners.outputs.map).<key>`)
routes to macOS when its key is not a `linux*` key. Otherwise a job "routes to
macOS" when its `runs-on:` (and, for a matrix-driven
`runs-on:`, its strategy) does not plainly name a Linux or Windows runner, or
names a macOS image, a macOS runner variable or an owned Mac pool. An
expression the scan cannot read counts as macOS: an unlisted job fails loudly
instead of slipping through.

Usage:
  python3 scripts/ci/runner_routing_table.py check
  python3 scripts/ci/runner_routing_table.py inventory   # print routed jobs
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import yaml

ROOT = Path(__file__).resolve().parents[2]
MAP_PATH = ROOT / ".github" / "runners.json"
WORKFLOWS = ROOT / ".github" / "workflows"

# Text in a runs-on expression that means "this can be a Mac". Owned Mac pools
# are glaeda-* labels and the repository variables that name them.
MACOS_HINT = re.compile(
    r"macos|glaeda-|MACOS_RUNNER|CI_SIDE_LANE_RUNNER|CI_LIGHT_LANE_RUNNER"
    r"|CI_NEXT_[A-Z_]*POOL|CI_SEED_TRUSTED_POOL|NIGHTLY_[A-Z_]*(RUNNER|POOL)"
    r"|pr_[a-z_]*runner|macos_runner|mini_runner|pick-nightly-build-runner\.outputs\.helper"
    r"|early_(?!(?:linux|mini)_runner)[a-z_]+_runner",
    re.IGNORECASE,
)
NON_MAC_HINT = re.compile(r"ubuntu|linux|windows", re.IGNORECASE)

NEEDS = ("macos", "linux", "any")

PORTABLE_LINUX = re.compile(r"needs\.portable-placement\.outputs\.linux_runner$")
PORTABLE_MINI = re.compile(r"needs\.portable-placement\.outputs\.mini_runner$")
# nightly.yml's light jobs: build-nightly-app's last step places them (NIGHTLY=1) on a free mini, else
# Blacksmith; build-nightly-remote-daemon, which builds beside the app, takes the Ghostty helper's owned
# Mac pick (pick-nightly-build-runner's helper) instead. They have no fleet Linux step: a nightly job
# never takes vars.LINUX_RUNNER as it is.
NIGHTLY_MINI = re.compile(r"needs\.(?:build-nightly-app\.outputs\.light_mini_runner|decide\.outputs\.early_mini_runner"
                          r"|pick-nightly-build-runner\.outputs\.helper)$")
# nightly.yml's first job (decide) has no job before it to place it: attempt 1 of a nightly-next push asks for
# glaeda's nightly slot, which only nightly jobs take, and the owned-pool rescue moves it to Blacksmith when no
# slot takes it (its picker_followup says so).
NIGHTLY_SLOT = re.compile(r"vars\.CI_NIGHTLY_NEXT_BUILD_RUNNER$")
BLACKSMITH_LINUX = re.compile(r"^'blacksmith-\d+vcpu-ubuntu-2404'$")


def nightly_reservation(term: str) -> bool:
    """The explicit all-nightly reservation, restricted to NEXT and attempt one.

    This exception is not a general permission to route a variable before fleet
    admission. The exact label is enabled only after its managed runner enrolls.
    """
    parts = [part.strip() for part in _split_top(term, "&&")]
    return (len(parts) == 5 and parts[0] == "github.repository == 'manaflow-ai/cmux'"
            and parts[1] in ("needs.decide.outputs.track == 'nightly-next'",
                             "github.ref == 'refs/heads/nightly-next'")
            and parts[2:] == ["github.run_attempt == 1",
                             "vars.CI_NIGHTLY_ONLY_RUNNER == 'glaeda-nightly-only-m4pro'",
                             "vars.CI_NIGHTLY_ONLY_RUNNER"])


def has_nightly_reservation(runs_on: str) -> bool:
    text = json.loads(runs_on) if runs_on.startswith('"') else runs_on
    expressions = EXPRESSION.findall(text)
    return len(expressions) == 1 and any(nightly_reservation(part.strip())
                                        for part in _split_top(expressions[0].strip(), "||"))


def portable_order(runs_on: str, nightly: bool = False) -> str:
    """Why a portable job's runs-on is out of the routing order, or "".

    The order (Leo's rulebook, 2026-10-31): fleet Linux, then a free mini, then Blacksmith as the
    overflow. The value terms must read portable placement's linux_runner before its mini_runner,
    and end on a Blacksmith Linux label.
    """
    expressions = EXPRESSION.findall(json.loads(runs_on) if runs_on.startswith('"') else runs_on)
    if len(expressions) != 1:
        return "its runs-on is not one expression"
    terms = [term.strip() for term in value_terms(expressions[0])]
    # Early nightly admission owns fleet/mini/overflow selection and validates
    # the per-job lease. Missing or stale outputs must use measured overflow,
    # never queue on a generic pool whose registration is unknown.
    if nightly and re.search(r"needs\.decide\.outputs\.early_(?!(?:linux|mini)_runner)[a-z_]+_runner", runs_on):
        alternatives = [part.strip() for part in _split_top(expressions[0].strip(), "||")]
        if alternatives[0] == "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'":
            alternatives = alternatives[1:]
        if alternatives and nightly_reservation(alternatives[0]):
            alternatives = alternatives[1:]
        gated = [part.strip() for part in _split_top(alternatives[0], "&&")]
        if len(gated) != 2 or gated[0] != "needs.decide.outputs.track == 'nightly-next'":
            return "early admission must be the first route for the NEXT track"
        # Other tracks retain their prior route outside this guarded branch.
        admitted = _unwrap(gated[1])
        admitted_terms = value_terms(admitted)
        if len(admitted_terms) != 1 or not re.fullmatch(r"needs\.decide\.outputs\.early_[a-z_]+_runner", admitted_terms[0]):
            return "early admission must use only its verified runner output"
        if not alternatives[-1:] or alternatives[-1] not in ("'blacksmith-16vcpu-ubuntu-2404'", "'blacksmith-32vcpu-ubuntu-2404'"):
            return "early admission must retain measured Linux overflow"
        if "needs.decide.outputs.early_attempt == format('{0}', github.run_attempt)" not in admitted:
            return "early admission must consume only its own attempt"
        return ""
    if nightly:
        if has_nightly_reservation(runs_on):
            return "" if BLACKSMITH_LINUX.match(terms[-1]) else "the nightly reservation lost its fallback"
        mini = next((i for i, term in enumerate(terms) if NIGHTLY_MINI.search(term) or NIGHTLY_SLOT.search(term)), None)
        if mini is None:
            return "it does not read needs.build-nightly-app.outputs.light_mini_runner (or the nightly slot)"
        linux = -1
        if "needs.decide.outputs.early_mini_runner" in runs_on:
            linux = next((i for i, term in enumerate(terms)
                          if term.endswith("needs.decide.outputs.early_linux_runner")), None)
    else:
        linux = next((i for i, term in enumerate(terms) if PORTABLE_LINUX.search(term)), None)
        mini = next((i for i, term in enumerate(terms) if PORTABLE_MINI.search(term)), None)
    if linux is None or mini is None:
        return "it does not read needs.portable-placement.outputs.linux_runner and mini_runner"
    if linux > mini:
        return "it takes the mini before fleet Linux"
    if not BLACKSMITH_LINUX.match(terms[-1]) or not any(BLACKSMITH_LINUX.match(t) for t in terms[mini + 1:]):
        return "it does not end on a Blacksmith Linux label after the mini"
    return ""

OWNED_LABEL_VARIABLE = re.compile(r"vars\.CI_(SIDE|LIGHT)_LANE_RUNNER")
PLACEMENT_OUTPUT = re.compile(r"needs\.[\w-]+\.outputs|inputs\.pr_[a-z_]*runner")


def bypasses_placement(runs_on: str) -> bool:
    """The job takes an owned side label from a variable, not from placement."""
    return bool(OWNED_LABEL_VARIABLE.search(runs_on)) and not PLACEMENT_OUTPUT.search(runs_on)


# What a picker gives a runs-on: a picker or placement job's output, or a label the caller of a reusable
# workflow (or a dispatcher) chose. The capability map (`fromJSON(needs.runners.outputs.map).<key>`) is
# not one: it names one fixed label per key, whatever that label's queue holds.
PICKER_OUTPUT = re.compile(r"(?<![\w.])(?:needs\.[\w-]+\.outputs\.(?!map\b)[\w-]+|inputs\.[\w-]+)(?![\w-])")
# A value term that is a boolean, not a label: a negation, a comparison or a predicate call.
BOOLEAN_TERM = re.compile(r"^(?:!|(?:contains|startsWith|endsWith|always|success|failure|cancelled)\s*\()",
                          re.IGNORECASE)
COMPARISON = ("==", "!=", "<=", ">=", "<", ">")


def _picker_value_term(term: str) -> bool:
    """Whether a value term yields a picker's label: it reads a picker output, as itself or through an
    index or a call (`fromJSON(needs.p.outputs.runners)['label']`), and is not a boolean."""
    if BOOLEAN_TERM.match(term) or any(len(_split_top(term, op)) > 1 for op in COMPARISON):
        return False
    return PICKER_OUTPUT.search(re.sub(r"'(?:[^']|'')*'", "''", term)) is not None
MATRIX_VALUE = re.compile(r"^matrix\.([\w-]+)$")
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
CALL = re.compile(r"^([A-Za-z]\w*)\((.*)\)$", re.DOTALL)


def _split_top(text: str, operator: str) -> list[str]:
    """`text` split on `operator` outside parentheses, brackets and quotes."""
    parts, depth, quoted, start, index = [], 0, False, 0, 0
    while index < len(text):
        char = text[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char in "([":
            depth += 1
        elif not quoted and char in ")]":
            depth -= 1
        elif not quoted and depth == 0 and text.startswith(operator, index):
            parts.append(text[start:index])
            index += len(operator)
            start = index
            continue
        index += 1
    parts.append(text[start:])
    return parts


def _unwrap(text: str) -> str:
    text = text.strip()
    while text.startswith("(") and text.endswith(")") and len(_split_top(text[1:-1], ")")) == 1 \
            and _balanced(text[1:-1]):
        text = text[1:-1].strip()
    return text


def _balanced(text: str) -> bool:
    depth, quoted = 0, False
    for char in text:
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def value_terms(expression: str) -> list[str]:
    """The terms of one GitHub expression that can become its value: the last `&&` operand of each `||`
    alternative, with groups opened and `fromJSON(...)` read through. A term used only as a condition
    (`needs.x.outputs.ok == 'true' && 'label'`) is not one."""
    terms = []
    for alternative in _split_top(_unwrap(expression), "||"):
        alternative = _unwrap(alternative)
        if len(_split_top(alternative, "||")) > 1:
            terms += value_terms(alternative)
            continue
        value = _unwrap(_split_top(alternative, "&&")[-1])
        if len(_split_top(value, "||")) > 1 or len(_split_top(value, "&&")) > 1:
            terms += value_terms(value)
            continue
        call = CALL.match(value)
        if call and call.group(1).lower() == "fromjson":
            terms += value_terms(call.group(2))
        else:
            terms.append(value)
    return terms


def _picked_value(value: object, strategy: dict[str, Any], seen: frozenset[str] = frozenset()) -> bool:
    """Whether a runs-on value (a string, or a list of labels) takes any label from a picker."""
    if isinstance(value, list):
        return any(_picked_value(item, strategy, seen) for item in value)
    text = str(value if value is not None else "")
    expressions = EXPRESSION.findall(text)
    if not expressions:
        return False
    for expression in expressions:
        for term in value_terms(expression):
            if _picker_value_term(term):
                return True
            matrix = MATRIX_VALUE.match(term)
            if matrix and matrix.group(1) not in seen and \
                    _picked_matrix_key(matrix.group(1), strategy, seen | {matrix.group(1)}):
                return True
    return False


def _picked_matrix_key(key: str, strategy: dict[str, Any], seen: frozenset[str]) -> bool:
    """Whether every leg's value of the matrix key the runs-on reads comes from a picker.

    Each leg runs on its own label, so one literal value (on the axis or in an `include` row) is a pinned
    leg. A matrix that is one expression counts when it is a picker output. So does an `include` that is
    one expression, but only when nothing else gives the key a value: GitHub keeps the axis's own legs
    whatever an include adds."""
    matrix = strategy.get("matrix") if isinstance(strategy, dict) else None
    if not isinstance(matrix, dict):
        return _picked_value(matrix, strategy, seen)
    values: list[object] = []
    axis = matrix.get(key)
    if isinstance(axis, list):
        values += axis
    elif axis is not None:
        values.append(axis)
    include = matrix.get("include")
    if isinstance(include, list):
        values += [row.get(key) for row in include if isinstance(row, dict) and row.get(key) is not None]
    elif include is not None:
        values.append(include)
    # A leg on a plainly Linux or Windows label is not a macOS leg; this check is about the Mac ones.
    mac_values = [value for value in values if not _non_mac_literal(value)]
    return bool(mac_values) and all(_picked_value(value, strategy, seen) for value in mac_values)


def _non_mac_literal(value: object) -> bool:
    text = str(value if value is not None else "")
    return not EXPRESSION.search(text) and bool(NON_MAC_HINT.search(text)) and not MACOS_HINT.search(text)


def picked(job: dict[str, Any]) -> bool:
    """Whether the job's runs-on takes its label from a picker output in a value position (directly, or
    through the matrix key it reads). Otherwise every run waits on the same label: a literal, a
    repository variable or a capability-map key."""
    strategy = job.get("strategy") if isinstance(job.get("strategy"), dict) else {}
    return _picked_value(job.get("runs-on", ""), strategy)


class RoutingTableError(RuntimeError):
    """The routing table is malformed."""


@dataclass(frozen=True)
class Job:
    workflow: str
    job_id: str
    runs_on: str
    # Whether runs-on takes its label from a picker output (picked()).
    from_picker: bool = True

    @property
    def key(self) -> str:
        return f"{self.workflow}#{self.job_id}"


def load_table(path: Path = MAP_PATH) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    classes = document.get("job_classes")
    jobs = document.get("macos_jobs")
    if not isinstance(classes, dict) or not classes:
        raise RoutingTableError(f"{path}: job_classes must be a non-empty object")
    if not isinstance(jobs, dict):
        raise RoutingTableError(f"{path}: macos_jobs must be an object")
    for name, spec in classes.items():
        if name.startswith("$"):
            continue
        if not isinstance(spec, dict) or spec.get("needs") not in NEEDS:
            raise RoutingTableError(f"job_classes.{name}.needs must be one of {NEEDS}")
        if not isinstance(spec.get("description"), str) or not spec["description"].strip():
            raise RoutingTableError(f"job_classes.{name} must describe the work in prose")
    normalized: dict[str, dict[str, Any]] = {}
    for key, entry in jobs.items():
        if key.startswith("$"):
            continue
        if isinstance(entry, str):
            entry = {"class": entry}
        if not isinstance(entry, dict) or not isinstance(entry.get("class"), str):
            raise RoutingTableError(f"macos_jobs[{key!r}] must name a class")
        normalized[key] = entry
    return {k: v for k, v in classes.items() if not k.startswith("$")}, normalized


MAP_CAPABILITY = re.compile(r"outputs\.map\)\.([a-z0-9_]+)")


def routes_to_macos(job: dict[str, Any]) -> bool:
    runs_on = json.dumps(job.get("runs-on", ""))
    # A job wired to the capability map names its capability key.
    capabilities = MAP_CAPABILITY.findall(runs_on)
    if capabilities and runs_on.count("${{") == 1:
        return any(not key.startswith("linux") for key in capabilities)
    if "matrix" in runs_on:
        runs_on += json.dumps(job.get("strategy", {}))
    if MACOS_HINT.search(runs_on):
        return True
    return not NON_MAC_HINT.search(runs_on)


def iter_jobs(workflows: Path = WORKFLOWS) -> Iterable[tuple[Job, bool]]:
    """Every runnable job in every workflow, with whether it routes to macOS."""
    for path in sorted(workflows.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_id, job in (document.get("jobs") or {}).items():
            # A reusable-workflow call runs the callee's jobs, which this scan
            # visits in the callee's own file.
            if not isinstance(job, dict) or "uses" in job:
                continue
            yield Job(path.name, str(job_id), json.dumps(job.get("runs-on", "")), picked(job)), routes_to_macos(job)



def action_expressions(text: str) -> Iterable[str]:
    """GitHub expressions, whose quoted strings may contain the closing token."""
    offset = 0
    while (start := text.find("${{", offset)) >= 0:
        index, quoted = start + 3, False
        while index < len(text):
            if text[index] == "'":
                if quoted and text[index:index + 2] == "''":
                    index += 2
                    continue
                quoted = not quoted
            elif not quoted and text[index:index + 2] == "}}":
                yield text[start + 3:index]
                offset = index + 2
                break
            index += 1
        else:
            raise ValueError("unterminated GitHub expression")


def referenced_secrets(value: Any) -> set[str]:
    """Literal secret references in expressions; reject dynamic/context-wide access."""
    if isinstance(value, dict):
        return set().union(*(referenced_secrets(v) for v in value.values())) if value else set()
    if isinstance(value, list):
        return set().union(*(referenced_secrets(v) for v in value)) if value else set()
    if not isinstance(value, str):
        return set()
    names: set[str] = set()
    for expression in action_expressions(value):
        # Keep quoted literals whole so text that merely says secrets.NAME is
        # not a credential access. GitHub escapes a quote by doubling it.
        tokens = re.findall(r"'(?:[^']|'')*'|[A-Za-z_][A-Za-z0-9_]*|[^\s]", expression)
        for index, token in enumerate(tokens):
            if token.lower() != "secrets" or index > 0 and tokens[index - 1] == ".":
                continue
            tail = tokens[index + 1:]
            if len(tail) >= 2 and tail[0] == "." and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tail[1]):
                names.add(tail[1].upper())
            elif len(tail) >= 3 and tail[0] == "[" and tail[2] == "]" and re.fullmatch(r"'[A-Za-z_][A-Za-z0-9_]*'", tail[1]):
                names.add(tail[1][1:-1].upper())
            else:
                raise ValueError("secret references must name one literal declared secret")
    return names


def _routing_environment(environment: object) -> bool:
    """No environment, `ci-routing-agent`, or one expression whose only values are those two."""
    if environment in (None, "", "ci-routing-agent"):
        return True
    if not isinstance(environment, str):
        return False
    expressions = EXPRESSION.findall(environment)
    if len(expressions) != 1 or EXPRESSION.sub("", environment).strip():
        return False
    values = value_terms(expressions[0].strip())
    return bool(values) and all(value in ("'ci-routing-agent'", "''") for value in values)


def hosted_light_policy(map_path: Path = MAP_PATH, workflows: Path = WORKFLOWS) -> tuple[list[str], list[str]]:
    """Validate the central light-job exception and emit exact shell-guard lines.

    Existing fork-only routes stay outside this exception. A declaration never
    permits a release environment, signing key, hosted Mac, or arbitrary label.
    """
    document = json.loads(map_path.read_text())
    declarations = document.get("hosted_light_jobs", {})
    classes = document.get("job_classes", {})
    if not isinstance(declarations, dict):
        return ["hosted_light_jobs must be an object"], []
    problems, allowed, seen = [], [], set()
    fork = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
    hosted = "github.run_attempt == 1 && 'ubuntu-24.04'"
    paid = {"'blacksmith-8vcpu-ubuntu-2404'", "'blacksmith-16vcpu-ubuntu-2404'", "'blacksmith-32vcpu-ubuntu-2404'"}
    sensitive = re.compile(r"secrets\.(?:APPLE|SIGN|CMUX_RELEASE|NOTARY)|codesign|notarytool|signing-keychain|gh release upload|softprops/action-gh-release", re.I)
    for path in sorted(workflows.glob("*.y*ml")):
        source = path.read_text()
        workflow = yaml.safe_load(source) or {}
        for name, job in (workflow.get("jobs") or {}).items():
            key = f"{path.name}#{name}"
            if key not in declarations or key.startswith("$"):
                continue
            seen.add(key)
            entry = declarations[key]
            issue = ""
            if not isinstance(entry, dict) or classes.get(entry.get("class"), {}).get("needs") != "any" or not entry.get("reason"):
                issue = "must declare a portable class and a reason"
            elif not isinstance(job, dict) or "uses" in job:
                issue = "must name a runnable lightweight job"
            elif (not _routing_environment(job.get("environment"))
                  or sensitive.search(json.dumps([workflow.get("env", {}), job]))):
                issue = "cannot authorize release/signing credentials or operations"
            elif re.search(r"(?:^|[-_])(sign|signer|signing|publish|promote|release)(?:[-_]|$)", str(name)) or str(name) in {"route-visual-gate-nightly", "published-in"}:
                issue = "cannot authorize release/signing or credentialed publication routes"
            if issue:
                problems.append(f"hosted_light_jobs[{key!r}] {issue}")
                continue
            permitted = entry.get("allowed_secrets", [])
            if (not isinstance(permitted, list)
                    or any(not isinstance(secret, str) or not re.fullmatch(r"[A-Z_][A-Z0-9_]*", secret)
                           for secret in permitted)):
                problems.append(f"hosted_light_jobs[{key!r}] allowed_secrets must list literal secret names")
                continue
            try:
                used = referenced_secrets([workflow.get("env", {}), job])
            except ValueError as error:
                problems.append(f"hosted_light_jobs[{key!r}] {error}")
                continue
            if any(re.match(r"(?:APPLE|SIGN|CMUX_RELEASE|NOTARY)", secret) for secret in used):
                problems.append(f"hosted_light_jobs[{key!r}] cannot authorize release/signing credentials")
                continue
            if used - set(permitted):
                problems.append(f"hosted_light_jobs[{key!r}] references undeclared secrets: {', '.join(sorted(used - set(permitted)))}")
                continue
            route = job.get("runs-on", "")
            expressions = EXPRESSION.findall(route) if isinstance(route, str) else []
            if len(expressions) != 1:
                problems.append(f"hosted_light_jobs[{key!r}] must use an explicit attempt-aware runner expression")
                continue
            alternatives = [part.strip() for part in _split_top(expressions[0].strip(), "||")]
            if alternatives and alternatives[0] == fork:
                alternatives = alternatives[1:]
            if path.name == "nightly.yml" and alternatives and nightly_reservation(alternatives[0]):
                alternatives = alternatives[1:]
            text = " || ".join(alternatives)
            if re.search(r"(?<![a-z-])macos-", text):
                problems.append(f"hosted_light_jobs[{key!r}] never permits hosted macOS")
                continue
            if "ubuntu-24.04'" not in text:
                # A declaration may precede the separate workflow routing change.
                continue
            track_hosted = "needs.decide.outputs.track == 'nightly-next' && github.run_attempt == 1 && 'ubuntu-24.04'"
            hosted_terms = [part for part in alternatives if part in (hosted, track_hosted)]
            if len(hosted_terms) != 1 or alternatives[-1] not in paid:
                problems.append(f"hosted_light_jobs[{key!r}] must use hosted Ubuntu on attempt 1 then measured paid retries")
                continue
            hosted_term = hosted_terms[0]
            # Track-gating is required when a declared resolver also runs on
            # non-NEXT tracks; a bare hosted branch would widen the exception.
            if hosted_term == hosted and "needs.decide.outputs.track == 'nightly-next'" in text:
                problems.append(f"hosted_light_jobs[{key!r}] must gate hosted Ubuntu to nightly-next")
                continue
            position = alternatives.index(hosted_term)
            tail = alternatives[position + 1:]
            measured16 = "vars.LINUX_RUNNER == 'blacksmith-16vcpu-ubuntu-2404' && 'blacksmith-16vcpu-ubuntu-2404'"
            # The overflow switch's failover (tests/test_ci_blacksmith_linux_failover.py) may precede the retry size.
            switched = (len(tail) == 2 and tail[1] in paid and tail[0].startswith("vars.CI_CLOUD_OVERFLOW_SAVED && ")
                        and tail[0].split(" && ", 1)[1] in paid)
            if not (len(tail) == 1 and tail[0] in paid or switched or tail == [measured16, "'blacksmith-32vcpu-ubuntu-2404'"]):
                problems.append(f"hosted_light_jobs[{key!r}] contains an undeclared retry runner")
                continue
            if any(not _picker_value_term(value) for part in alternatives[:position] for value in value_terms(part)):
                problems.append(f"hosted_light_jobs[{key!r}] has an unverified label before hosted overflow")
                continue
            if any("needs.decide.outputs.early_attempt == format('{0}', github.run_attempt)" not in part for part in alternatives[:position]):
                problems.append(f"hosted_light_jobs[{key!r}] must consume only current-attempt placement")
                continue
            if value_terms(text).count("'ubuntu-24.04'") != 1:
                problems.append(f"hosted_light_jobs[{key!r}] contains an extra hosted Ubuntu route")
                continue
            # Only the exact one-line runs-on under this declared job is exempt.
            current = None
            for number, line in enumerate(source.splitlines(), 1):
                match = re.fullmatch(r"  ([\w-]+):\s*", line)
                if match:
                    current = match[1]
                if current == name and line.startswith("    runs-on:") and line.split("runs-on:", 1)[1].strip() == route:
                    allowed.append(f"{path.resolve()}:{number}")
                    break
            else:
                problems.append(f"hosted_light_jobs[{key!r}] requires a one-line runs-on expression")
    for key in declarations:
        if not key.startswith("$") and key not in seen:
            problems.append(f"hosted_light_jobs[{key!r}] names a job that does not exist")
    return problems, allowed


def check(map_path: Path = MAP_PATH, workflows: Path = WORKFLOWS) -> list[str]:
    classes, table = load_table(map_path)
    problems, _ = hosted_light_policy(map_path, workflows)
    seen: dict[str, bool] = {}
    for job, on_macos in iter_jobs(workflows):
        seen[job.key] = on_macos
        if not on_macos:
            continue
        entry = table.get(job.key)
        if entry is None:
            problems.append(
                f"{job.key} runs on macOS but has no entry in .github/runners.json macos_jobs. "
                f"Add it with the job class that says why it needs a Mac "
                f"(classes: {', '.join(sorted(classes))}), or run it on Linux."
            )
            continue
        spec = classes.get(entry["class"])
        if spec is None:
            problems.append(f"{job.key}: unknown job class {entry['class']!r}")
            continue
        bypass = bypasses_placement(job.runs_on)
        if bypass and not entry.get("placement_followup"):
            problems.append(
                f"{job.key} takes vars.CI_SIDE_LANE_RUNNER / vars.CI_LIGHT_LANE_RUNNER in runs-on "
                f"with no placement output, so it bypasses placement. Route it through the "
                f"workflow's placement job (scripts/ci/side_lane_placement.py) instead."
            )
        elif entry.get("placement_followup") and not bypass:
            problems.append(f"{job.key} no longer bypasses placement; remove its placement_followup")
        # A bypass is already one pin, recorded by its placement_followup.
        reserved = job.key.startswith("nightly.yml#") and has_nightly_reservation(job.runs_on)
        pin = not bypass and not job.from_picker and not reserved
        if pin and not entry.get("picker_followup"):
            problems.append(
                f"{job.key} runs on macOS from a fixed label (no picker output can be its runs-on value), so "
                f"it waits on that one label however long it starts nothing. Take runs-on from a picker "
                f"job's output (scripts/ci/ios_runner_pool.py, simple_pool_picker.py or "
                f"side_lane_placement.py): an idle owned Mac first, Blacksmith macOS last, with "
                f"stall-aware failover."
            )
        elif entry.get("picker_followup") and not pin:
            problems.append(f"{job.key} no longer runs on a fixed label; remove its picker_followup")
        if spec["needs"] == "any":
            why = portable_order(job.runs_on, nightly=job.key.startswith("nightly.yml#"))
            if why:
                problems.append(f"{job.key} is class {entry['class']!r} (fleet Linux, then a free mini, then "
                                f"Blacksmith), but {why}.")
        if spec["needs"] == "linux" and not entry.get("linux_followup"):
            problems.append(
                f"{job.key} is class {entry['class']!r}, which runs on Linux runners: "
                f"{spec['description']} Move the job to a Linux runner "
                f"(fromJSON(needs.runners.outputs.map).linux, via resolve-runners.yml)."
            )
        elif spec["needs"] == "macos" and entry.get("linux_followup"):
            problems.append(f"{job.key}: class {entry['class']!r} needs macOS; remove its linux_followup")
    for key in sorted(table):
        if key not in seen:
            problems.append(f"macos_jobs[{key!r}] names a job that does not exist; remove the entry")
        elif not seen[key]:
            problems.append(f"macos_jobs[{key!r}] no longer runs on macOS; remove the entry")
    return problems


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "check"
    if command == "hosted-light-lines":
        problems, lines = hosted_light_policy()
        if problems:
            print("\n".join(problems), file=sys.stderr)
            return 1
        print("\n".join(lines))
        return 0
    if command == "inventory":
        for job, on_macos in iter_jobs():
            if on_macos:
                print(job.key)
        return 0
    if command != "check":
        print(__doc__, file=sys.stderr)
        return 2
    problems = check()
    for problem in problems:
        print(f"::error file=.github/runners.json::{problem}")
    if problems:
        return 1
    _, table = load_table()
    pending = sorted(k for k, v in table.items() if v.get("linux_followup"))
    bypass = sorted(k for k, v in table.items() if v.get("placement_followup"))
    fixed = sorted(k for k, v in table.items() if v.get("picker_followup"))
    print(
        f"runner routing table: {len(table)} macOS jobs classified; "
        f"{len(pending)} still to move to Linux; {len(bypass)} still bypass placement; "
        f"{len(fixed)} still on a fixed label"
    )
    for key in pending:
        print(f"  linux: {key}: {table[key]['linux_followup']}")
    for key in bypass:
        print(f"  placement: {key}")
    for key in fixed:
        print(f"  picker: {key}: {table[key]['picker_followup']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
