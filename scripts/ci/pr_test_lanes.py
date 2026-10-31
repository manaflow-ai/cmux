#!/usr/bin/env python3
"""What a pull request into a branch runs: the PR-time lanes of the Python tests.

The registry validator used to accept a test as live when any workflow named it.
tests/test_webviews_tests_per_file.py was named only by web-validation.yml's
main-push job and the nightly car guards, so a feat-cmux-next pull request that
broke scripts/ci/run-webviews-tests.sh (a2d6b35) landed green and nobody saw the
red until #23430. This reads the workflows the way GitHub does for one event, a
pull request into BRANCH, and returns the `run:` text that event can execute:

  - every workflow whose `on.pull_request` covers BRANCH (`branches` absent or
    naming it, `branches-ignore` not naming it; a `paths` filter still counts,
    since the workflow runs whenever the pull request touches those paths);
  - every job and step whose `if:` is not false for that event. The expression
    is evaluated with what a pull request into BRANCH fixes (event name, base
    ref, an empty `inputs`, the matrix values) and everything else unknown, so
    only a condition that cannot be true for the pull request drops a job.
    A job that needs a dropped job is dropped too unless its `if:` calls a
    status function;
  - reusable workflows a kept job calls (`uses: ./.github/workflows/X.yml`),
    with the caller's literal `with:` inputs bound, and local composite actions;
  - ci-guards.yml's guard steps that `scripts/ci/guards-local.sh` runs (its
    default `ci` group, `--group X`, `--all`, or `--feat-routes FILE`: the groups
    detect_linux_guard_changes.classify_feat can route a feat-cmux-next change
    to), through run_ci_guards.py's plan.

The registry validator adds what those steps reach indirectly (the
verify-local.py recipe, workload profiles) and the runner lanes they invoke.
"""

from __future__ import annotations

import fnmatch
import itertools
import json
import math
import re
import shlex
from pathlib import Path

WORKFLOWS = Path(".github/workflows")
ACTIONS = Path(".github/actions")
GUARDS_LOCAL = re.compile(r"scripts/ci/(?:guards-local\.sh|run_ci_guards\.py)(?P<args>[^\n]*)")
LOCAL_WORKFLOW = re.compile(r"^\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)$")
LOCAL_ACTION = re.compile(r"^\./\.github/actions/([A-Za-z0-9_.-]+)/?$")
STATUS_FUNCTIONS = ("always()", "cancelled()", "failure()")
MAX_MATRIX = 256
# The context key that holds the jobs this event skips (see kept_jobs).
SKIPPED = "<skipped jobs>"


class Unknown:
    """A value the pull request event does not fix (a label, a vars.*, a needs output)."""

    def __repr__(self) -> str:
        return "UNKNOWN"


UNKNOWN = Unknown()
# The pull request's label names: unknown, except that a lane cannot depend on one.
LABELS = Unknown()


# --- GitHub Actions expressions, three-valued -------------------------------------------

TOKEN = re.compile(
    r"\s*(?:(?P<string>'(?:[^']|'')*')|(?P<number>-?\d+(?:\.\d+)?)|(?P<op>==|!=|<=|>=|&&|\|\||[!()<>,\[\]])"
    r"|(?P<name>[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z_*][A-Za-z0-9_\-*]*|\[[^\]]*\])*))"
)


def tokenize(text: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    position = 0
    text = text.strip()
    while position < len(text):
        match = TOKEN.match(text, position)
        if not match or match.end() == position:
            raise ValueError(f"cannot read expression at {text[position:]!r}")
        position = match.end()
        kind = match.lastgroup or ""
        tokens.append((kind, match.group(kind)))
    return tokens


def truthy(value: object) -> object:
    if isinstance(value, Unknown):
        return UNKNOWN
    if isinstance(value, float) and math.isnan(value):
        return False
    return bool(value)


def as_number(value: object) -> float:
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        if not value.strip():
            return 0.0
        try:
            return float(value)
        except ValueError:
            return math.nan
    return math.nan


def equal(left: object, right: object) -> object:
    if isinstance(left, Unknown) or isinstance(right, Unknown):
        return UNKNOWN
    if isinstance(left, str) and isinstance(right, str):
        return left.lower() == right.lower()
    if type(left) is type(right) and not isinstance(left, (int, float)):
        return left == right
    return as_number(left) == as_number(right)


class Expression:
    """A recursive-descent reader of one `${{ }}` expression over a context."""

    def __init__(self, text: str, context: dict[str, object]):
        self.tokens = tokenize(text)
        self.index = 0
        self.context = context

    def peek(self) -> str | None:
        return self.tokens[self.index][1] if self.index < len(self.tokens) else None

    def take(self) -> tuple[str, str]:
        token = self.tokens[self.index]
        self.index += 1
        return token

    def evaluate(self) -> object:
        value = self.disjunction()
        if self.index != len(self.tokens):
            raise ValueError(f"unexpected {self.peek()!r}")
        return value

    def disjunction(self) -> object:
        values = [self.conjunction()]
        while self.peek() == "||":
            self.take()
            values.append(self.conjunction())
        if len(values) == 1:
            return values[0]
        truths = [truthy(v) for v in values]
        if any(t is True for t in truths):
            return True
        return UNKNOWN if any(t is UNKNOWN for t in truths) else False

    def conjunction(self) -> object:
        values = [self.comparison()]
        while self.peek() == "&&":
            self.take()
            values.append(self.comparison())
        if len(values) == 1:
            return values[0]
        truths = [truthy(v) for v in values]
        if any(t is False for t in truths):
            return False
        return UNKNOWN if any(t is UNKNOWN for t in truths) else True

    def comparison(self) -> object:
        left = self.unary()
        while self.peek() in ("==", "!=", "<", ">", "<=", ">="):
            op = self.take()[1]
            right = self.unary()
            if op in ("==", "!="):
                result = equal(left, right)
                left = result if result is UNKNOWN or op == "==" else not result
            else:
                left = UNKNOWN
        return left

    def unary(self) -> object:
        if self.peek() == "!":
            self.take()
            value = truthy(self.unary())
            return UNKNOWN if value is UNKNOWN else not value
        return self.primary()

    def primary(self) -> object:
        kind, text = self.take()
        if text == "(":
            value = self.disjunction()
            self.expect(")")
            return value
        if kind == "string":
            return text[1:-1].replace("''", "'")
        if kind == "number":
            return float(text)
        if kind != "name":
            raise ValueError(f"unexpected {text!r}")
        if self.peek() == "(":
            self.take()
            args: list[object] = []
            while self.peek() != ")":
                args.append(self.disjunction())
                if self.peek() == ",":
                    self.take()
            self.expect(")")
            return self.call(text, args)
        if text in ("true", "false"):
            return text == "true"
        if text == "null":
            return None
        if text in self.context:
            return self.context[text]
        if text == "github.event.pull_request.labels.*.name":
            return LABELS
        # A job this event skips: `needs.<job>.result` is 'skipped' and its outputs are empty.
        parts = text.split(".")
        if len(parts) >= 3 and parts[0] == "needs" and parts[1] in self.context.get(SKIPPED, ()):
            return "skipped" if parts[2] == "result" else ""
        return UNKNOWN

    def expect(self, token: str) -> None:
        if self.peek() != token:
            raise ValueError(f"expected {token!r}, found {self.peek()!r}")
        self.take()

    @staticmethod
    def call(name: str, args: list[object]) -> object:
        lowered = name.lower()
        # The pull request's own lanes: earlier jobs passed and nothing was cancelled.
        if lowered in ("always", "success"):
            return True
        # A step kept for a failure is a report, not a lane.
        if lowered in ("cancelled", "failure"):
            return False
        # A pull request carries no label by default: a job only a label starts is opt-in, not a lane.
        if lowered == "contains" and len(args) == 2 and args[0] is LABELS:
            return False
        if lowered == "fromjson" and args and isinstance(args[0], str):
            try:
                return json.loads(args[0])
            except ValueError:
                return UNKNOWN
        return UNKNOWN


def evaluate(condition: object, context: dict[str, object]) -> object:
    """An `if:` for this event: True, False or UNKNOWN. An unreadable one is UNKNOWN."""
    if condition is None:
        return True
    if isinstance(condition, bool):
        return condition
    text = str(condition).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    if not text.strip():
        return True
    try:
        return truthy(Expression(text, context).evaluate())
    except (ValueError, IndexError):
        return UNKNOWN


def value_of(raw: object, context: dict[str, object]) -> object:
    """A `with:` value: a literal, or a whole `${{ }}` expression's value."""
    if not isinstance(raw, str):
        return raw
    text = raw.strip()
    if text.startswith("${{") and text.endswith("}}"):
        try:
            return Expression(text[3:-2], context).evaluate()
        except (ValueError, IndexError):
            return UNKNOWN
    return UNKNOWN if "${{" in text else raw


# --- workflows ---------------------------------------------------------------------------


def load_yaml(path: Path) -> dict:
    import yaml  # PyYAML: the guard venv and the Linux runners have it.

    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    return loaded if isinstance(loaded, dict) else {}


def triggers(workflow: dict) -> dict:
    found = workflow.get("on", workflow.get(True))
    if isinstance(found, str):
        return {found: None}
    if isinstance(found, list):
        return {name: None for name in found}
    return found if isinstance(found, dict) else {}


def runs_on_pull_requests_into(workflow: dict, branch: str) -> bool:
    on = triggers(workflow)
    if "pull_request" not in on:
        return False
    trigger = on["pull_request"] or {}
    branches = trigger.get("branches")
    ignored = trigger.get("branches-ignore") or []
    if branches is not None and not branch_matches(branch, branches):
        return False
    return not branch_matches(branch, ignored)


def branch_matches(branch: str, patterns: list) -> bool:
    """GitHub's branch filter: glob patterns, a later `!pattern` taking a match back."""
    matched = False
    for pattern in [patterns] if isinstance(patterns, str) else patterns or []:
        pattern = str(pattern)
        if pattern.startswith("!"):
            if matched and fnmatch.fnmatchcase(branch, pattern[1:]):
                matched = False
        elif fnmatch.fnmatchcase(branch, pattern):
            matched = True
    return matched


def event_context(branch: str) -> dict[str, object]:
    return {
        "github.event_name": "pull_request",
        "github.base_ref": branch,
        "github.event.pull_request.base.ref": branch,
        "github.ref": "refs/pull/0/merge",
        # ci.yml's legacy lanes skip the cmux NEXT line by this output (scripts/ci/next_line.sh),
        # which is true for every pull request into feat-cmux-next.
        "needs.changes.outputs.next_line": "true" if branch == "feat-cmux-next" else "false",
    }


def matrix_rows(job: dict, context: dict[str, object]) -> list[dict[str, object]]:
    matrix = (job.get("strategy") or {}).get("matrix")
    if matrix is None:
        return [{}]
    if not isinstance(matrix, dict):
        return [{"*": UNKNOWN}]
    axes: dict[str, list[object]] = {}
    for key, raw in matrix.items():
        if key in ("include", "exclude"):
            continue
        values = value_of(raw, context) if isinstance(raw, str) else raw
        axes[key] = values if isinstance(values, list) else [UNKNOWN]
    # A matrix of only `include:` entries has no axes: its rows are the entries alone.
    rows = [dict(zip(axes, combo)) for combo in itertools.product(*axes.values())][:MAX_MATRIX] if axes else []
    excludes = matrix.get("exclude") if isinstance(matrix.get("exclude"), list) else []
    rows = [row for row in rows
            if not any(isinstance(ex, dict) and all(row.get(k) == v for k, v in ex.items()) for ex in excludes)]
    includes = matrix.get("include") if isinstance(matrix.get("include"), list) else []
    rows += [dict(entry) for entry in includes if isinstance(entry, dict)]
    return rows or [{}]


def with_matrix(context: dict[str, object], row: dict[str, object]) -> dict[str, object]:
    bound = dict(context)
    bound.update({f"matrix.{key}": value for key, value in row.items()})
    return bound


def kept_jobs(jobs: dict, context: dict[str, object]) -> list[str]:
    """Jobs a run of this event may execute, in file order."""
    dropped: set[str] = set()
    kept: list[str] = []
    pending = list(jobs)
    # needs form a DAG; a few passes settle it in file order.
    for _ in range(len(pending) + 1):
        progressed = False
        for name in list(pending):
            job = jobs[name] if isinstance(jobs[name], dict) else {}
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else list(needs)
            if any(need in pending for need in needs if need in jobs):
                continue
            pending.remove(name)
            progressed = True
            condition = job.get("if")
            status_call = any(call in str(condition or "") for call in STATUS_FUNCTIONS)
            if any(need in dropped for need in needs) and not status_call:
                dropped.add(name)
            elif evaluate(condition, {**context, SKIPPED: frozenset(dropped)}) is False:
                dropped.add(name)
            else:
                kept.append(name)
        if not pending or not progressed:
            break
    kept += pending  # a cycle GitHub would reject anyway: keep, never hide a lane
    return [name for name in jobs if name in kept]


def guards_local_texts(root: Path, run: str) -> list[str]:
    """ci-guards.yml's guard steps each `guards-local.sh` invocation in `run` executes."""
    texts: list[str] = []
    for match in GUARDS_LOCAL.finditer(run):
        try:
            args = shlex.split(match.group("args"), comments=True)
        except ValueError:
            args = match.group("args").split()
        groups: list[str] = []
        everything = False
        feat_routes = False
        for index, arg in enumerate(args):
            if arg in ("&&", "||", "|", ";"):
                break
            if arg == "--all":
                everything = True
            elif arg == "--feat-routes" or arg.startswith("--feat-routes="):
                feat_routes = True
            elif arg == "--group" and index + 1 < len(args):
                groups.append(args[index + 1])
            elif arg.startswith("--group="):
                groups.append(arg.split("=", 1)[1])
        import run_ci_guards  # noqa: PLC0415 - imported only where a step runs the guards

        workflow = load_yaml(root / WORKFLOWS / "ci-guards.yml")
        try:
            units = run_ci_guards.plan(workflow, "", "")
        except run_ci_guards.PlanError:
            continue
        # A group from a shell variable is routed at run time: any group may run.
        everything = everything or any("$" in group for group in groups)
        wanted = None if everything else (set(groups) or set(run_ci_guards.FAST_GROUPS))
        if feat_routes and wanted is not None:
            # Routed by the change's paths at run time: any group the feat-cmux-next router can pick may run.
            import detect_linux_guard_changes  # noqa: PLC0415

            wanted |= set(detect_linux_guard_changes.FEAT_ROUTED)
        texts += [step.run for unit in units
                  if wanted is None or unit.group in wanted or unit.job in wanted
                  for step in unit.steps]
    return texts


def action_texts(root: Path, name: str) -> list[str]:
    for filename in ("action.yml", "action.yaml"):
        path = root / ACTIONS / name / filename
        if path.is_file():
            action = load_yaml(path)
            steps = ((action.get("runs") or {}).get("steps")) or []
            return [str(step.get("run", "")) for step in steps if isinstance(step, dict)]
    return []


def workflow_texts(root: Path, name: str, context: dict[str, object], seen: tuple[str, ...] = ()) -> list[str]:
    """`run:` text a workflow file executes under `context`, following local calls."""
    if name in seen:
        return []
    path = root / WORKFLOWS / name
    if not path.is_file():
        return []
    workflow = load_yaml(path)
    jobs = workflow.get("jobs") or {}
    texts: list[str] = []
    for job_name in kept_jobs(jobs, context):
        job = jobs[job_name] if isinstance(jobs[job_name], dict) else {}
        called = LOCAL_WORKFLOW.match(str(job.get("uses", "")))
        if called:
            texts += workflow_texts(root, called.group(1), call_context(root, called.group(1), job, context),
                                    seen + (name,))
            continue
        rows = matrix_rows(job, context)
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            if all(evaluate(step.get("if"), with_matrix(context, row)) is False for row in rows):
                continue
            run = str(step.get("run", ""))
            if run:
                texts.append(run)
                texts += guards_local_texts(root, run)
            action = LOCAL_ACTION.match(str(step.get("uses", "")))
            if action:
                texts += action_texts(root, action.group(1))
    return texts


def call_context(root: Path, name: str, job: dict, caller: dict[str, object]) -> dict[str, object]:
    """The callee's context: the same event, its `inputs` from the caller's `with:` or defaults."""
    context = {key: value for key, value in caller.items() if not key.startswith(("inputs.", "matrix."))}
    path = root / WORKFLOWS / name
    declared = {}
    if path.is_file():
        call = triggers(load_yaml(path)).get("workflow_call") or {}
        declared = call.get("inputs") or {}
    for key, spec in declared.items():
        if isinstance(spec, dict) and "default" in spec:
            context[f"inputs.{key}"] = spec["default"]
        else:
            context[f"inputs.{key}"] = ""
    rows = matrix_rows(job, caller)
    for key, raw in (job.get("with") or {}).items():
        values = {repr(value_of(raw, with_matrix(caller, row))) for row in rows}
        context[f"inputs.{key}"] = value_of(raw, with_matrix(caller, rows[0])) if len(values) == 1 else UNKNOWN
    return context


def pull_request_texts(root: Path, branch: str) -> list[str]:
    """Every `run:` text a pull request into `branch` can execute."""
    texts: list[str] = []
    for path in sorted((root / WORKFLOWS).glob("*.y*ml")):
        workflow = load_yaml(path)
        if not runs_on_pull_requests_into(workflow, branch):
            continue
        context = event_context(branch)
        # A pull_request event has no workflow inputs: each reads as empty.
        for key in ((triggers(workflow).get("workflow_dispatch") or {}).get("inputs") or {}):
            context[f"inputs.{key}"] = ""
        for key in ((triggers(workflow).get("workflow_call") or {}).get("inputs") or {}):
            context[f"inputs.{key}"] = ""
        texts += workflow_texts(root, path.name, context)
    return texts
