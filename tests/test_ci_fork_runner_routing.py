#!/usr/bin/env python3
"""Fork pull-request workflows must use GitHub-hosted runners with zero setup."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

FORK_LINUX_BRANCH = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
# A fork running CI in its own repository compiles on GitHub-hosted macos-26,
# the image and Xcode main compiles with, so it can hit main's public caches.
FORK_MACOS_BRANCH = "github.repository_owner != 'manaflow-ai' && 'macos-26'"
# Only jobs that need the macOS 15 image itself keep a macos-15 fork branch.
FORK_MACOS_15_BRANCH = "github.repository_owner != 'manaflow-ai' && 'macos-15'"
MACOS_15_FORK_JOBS = {
    # Builds the release Ghostty CLI helper against the macOS 15 SDK.
    ("ci-macos.yml", "swift-package-tests"),
    ("release.yml", "build-ghostty-cli-helper"),
    ("nightly.yml", "build-nightly-ghostty-cli-helper"),
    # Its matrix exists to cover each macOS major; only the macOS 15 row.
    ("ci-macos-compat.yml", "compat-tests"),
    # Exists to exercise the paste worker on macOS 15.
    ("plain-paste-worker.yml", "macos-15"),
    # Seeds the macOS 15 pool's SwiftPM manifest cache, keyed on its Xcode.
    ("seed-swiftpm-manifests.yml", "seed"),
}
# A matrix job may instead pick a hosted label per row, e.g. to spread
# app-host shards over macos-15 and macos-26. Accepted only when every
# `hosted_runner:` value in the workflow is a GitHub-hosted macOS label.
FORK_MACOS_MATRIX_BRANCH = "github.repository_owner != 'manaflow-ai' && matrix.hosted_runner"
HOSTED_MACOS_LABELS = {"macos-15", "macos-26"}
# Any Blacksmith runner label. Script names such as
# scripts/blacksmith-bounded-command.sh have no `-Nvcpu-` part.
BLACKSMITH_LABEL = re.compile(r"blacksmith-\d+vcpu-[a-z0-9]+(?:[.-][a-z0-9]+)*")
FORK_BRANCHES = (FORK_LINUX_BRANCH, FORK_MACOS_BRANCH, FORK_MACOS_15_BRANCH, FORK_MACOS_MATRIX_BRANCH)
OWNER_ONLY_JOB_IF = "if: github.repository_owner == 'manaflow-ai'"
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
INPUT_HEADER = re.compile(r"^      ([A-Za-z0-9_-]+):\s*$")
# (workflow, stripped line) -> why a Blacksmith label there may stay ungated.
UNGATED_BLACKSMITH_ALLOWED = {
    ("reload-build.yml", "macOS runner label to build on. Blacksmith (blacksmith-6vcpu-macos-26),"): (
        "description text of the runner input, not a value"
    ),
}
# (workflow, dispatch input) -> why its Blacksmith default and choices may be
# read before the fork branch.
UNTRANSLATED_DISPATCH_INPUTS: dict[tuple[str, str], str] = {}
LOCAL_WORKFLOW_CALL = re.compile(
    r"uses:\s+\./\.github/workflows/([A-Za-z0-9_.-]+\.ya?ml)"
)
# Events an outside contributor can start in manaflow-ai's own context, with
# its secrets and, for pull_request_target, a write token. A comment event
# does not say whether its pull request comes from a fork, so the fork branch
# below cannot gate these: their jobs pin a GitHub-hosted label.
# Matched as a whole word anywhere in the `on:` value, so block, inline,
# list and mapping forms all count.
OUTSIDER_TRIGGER = re.compile(
    r"(?<![\w-])(?:pull_request_target|issue_comment|issues|pull_request_review"
    r"|pull_request_review_comment|discussion|discussion_comment)(?![\w-])"
)
HOSTED_LITERAL_RUNNER = re.compile(
    r"^\s*runs-on:\s*(?:ubuntu-\d+\.\d+|ubuntu-latest|macos-\d+)\s*(?:#.*)?$"
)

# A fork pull request into manaflow-ai runs with repository_owner ==
# 'manaflow-ai', so the owner branches above do not catch it. Before any
# repository variable or pool picker output can pick a runner, it must take
# this branch to a Blacksmith or GitHub-hosted label, because the runner
# variables, and any pool pr_runner_pool.py may learn later, may name owned
# self-hosted machines. The branch either names a label or keeps the picker's
# choice only when it is a Blacksmith label (the picker already limits forks
# to ephemeral pools; this restates that where the runner is picked).
# Comparing full_name instead of reading head.repo.fork also covers a deleted
# head repository (head.repo is null).
FORK_PULL_REQUEST_CONDITIONS = frozenset(
    {
        ("==", "github.event_name", "'pull_request'"),
        ("!=", "github.event.pull_request.head.repo.full_name", "github.repository"),
    }
)
# `github.event_name == 'pull_request' && '<label>'` alone also works: it
# sends every pull request, fork or not, to the label.
PULL_REQUEST_CONDITION = ("==", "github.event_name", "'pull_request'")
FORK_PULL_REQUEST_LABEL = re.compile(
    r"blacksmith-\d+vcpu-(?:macos|ubuntu)-[a-z0-9.]+|macos-\d+|ubuntu-[a-z0-9.-]+"
)
# Values that can resolve to an owned self-hosted label. A variable counts on
# any line (env mirrors such as CMUX_PRODUCT_RUNNER must agree with runs-on); a
# matrix pool or the pull request pool picker's output only where it picks the
# runner.
#
# LINUX_RUNNER and LINUX_ARM64_RUNNER name Blacksmith and GitHub-hosted labels
# today, but they are free-form like MACOS_RUNNER_*, and
# docs/ci-runner-capability-labels.md maps them to self-hosted `linux` labels.
# Nothing keeps them hosted except their current values, so they are gated too.
# Context names are case-insensitive, and `vars['X']` reads the same value as
# `vars.X`; _refs normalizes the index form before matching.
OWNED_RUNNER_NAME = r"(?:MACOS_RUNNER_\w+|LINUX_RUNNER|LINUX_ARM64_RUNNER)"
OWNED_RUNNER_VARIABLE = re.compile(
    rf"\bvars(?:\.{OWNED_RUNNER_NAME}\b|\[\s*'{OWNED_RUNNER_NAME}'\s*\])", re.IGNORECASE
)
OWNED_RUNNER_SELECTOR = re.compile(
    OWNED_RUNNER_VARIABLE.pattern
    + r"|\bmatrix(?:\.pr_runner\b|\[\s*'pr_runner'\s*\])"
    + r"|\binputs(?:\.pr_runner\b|\[\s*'pr_runner'\s*\])"
    + r"|\bneeds\.changes\.outputs\.macos_pr_runner\b",
    re.IGNORECASE,
)
# (workflow, stripped line) -> why a runner variable read there picks no runner.
FORK_GATE_EXEMPT = {
    ("ci.yml", "DEFAULT_RUNNER: ${{ vars.MACOS_RUNNER_PR }}"): (
        "pr_runner_pool.py's input: it compares the lane with its default and "
        "ignores it for a fork head, and every runs-on reading its output takes "
        "the fork branch first"
    ),
    ("test-ios.yml", "RUNNER_VARIABLE: ${{ vars.MACOS_RUNNER_TESTS || vars.MACOS_RUNNER_IOS }}"): (
        "ios_runner_pool.py's input: for a fork head (--fork) the picker returns "
        "its hosted 6vcpu pool without reading this default, and every runs-on "
        "reads its output"
    ),
}


class ExpressionSyntaxError(ValueError):
    pass


_TOKEN = re.compile(
    r"""
    \s*(?:
      (?P<string>'(?:[^']|'')*')
    | (?P<number>-?\d+(?:\.\d+)?)
    | (?P<op>&&|\|\||==|!=|<=|>=|[!<>()\[\],.*])
    | (?P<name>[A-Za-z_][A-Za-z0-9_-]*)
    )
    """,
    re.VERBOSE,
)


def _tokenize(source: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    position = 0
    source = source.rstrip()
    while position < len(source):
        match = _TOKEN.match(source, position)
        if not match or match.end() == position:
            raise ExpressionSyntaxError(f"unexpected {source[position:]!r}")
        kind = match.lastgroup
        assert kind is not None
        tokens.append((kind, match.group(kind)))
        position = match.end()
    return tokens


class _Parser:
    """Recursive-descent parser for GitHub Actions `${{ }}` expressions.

    Nodes are tuples:
      ("or", [node, ...]) and ("and", [node, ...]), flattened;
      ("not", node); ("cmp", op, left, right);
      ("literal", source text); ("ref", "a.b['c'].*"); ("call", name, [args]).
    A parenthesized `||` chain inside a `||` chain flattens into it, because
    `a || (b || c)` evaluates exactly like `a || b || c`.
    """

    def __init__(self, source: str) -> None:
        self.tokens = _tokenize(source)
        self.index = 0

    def parse(self) -> tuple:
        node = self._or()
        if self.index != len(self.tokens):
            raise ExpressionSyntaxError(f"trailing {self.tokens[self.index][1]!r}")
        return node

    def _peek(self) -> str | None:
        return self.tokens[self.index][1] if self.index < len(self.tokens) else None

    def _take(self, expected: str | None = None) -> tuple[str, str]:
        if self.index >= len(self.tokens):
            raise ExpressionSyntaxError("unexpected end of expression")
        token = self.tokens[self.index]
        if expected is not None and token[1] != expected:
            raise ExpressionSyntaxError(f"expected {expected!r}, got {token[1]!r}")
        self.index += 1
        return token

    def _chain(self, operator: str, operand) -> tuple:
        items = [operand()]
        while self._peek() == operator:
            self._take()
            items.append(operand())
        if len(items) == 1:
            return items[0]
        kind = "or" if operator == "||" else "and"
        flat: list[tuple] = []
        for item in items:
            flat.extend(item[1] if item[0] == kind else [item])
        return (kind, flat)

    def _or(self) -> tuple:
        return self._chain("||", self._and)

    def _and(self) -> tuple:
        return self._chain("&&", self._comparison)

    def _comparison(self) -> tuple:
        left = self._unary()
        while self._peek() in ("==", "!=", "<", "<=", ">", ">="):
            operator = self._take()[1]
            left = ("cmp", operator, left, self._unary())
        return left

    def _unary(self) -> tuple:
        if self._peek() == "!":
            self._take()
            return ("not", self._unary())
        return self._primary()

    def _primary(self) -> tuple:
        kind, text = self._take()
        if text == "(":
            node = self._or()
            self._take(")")
            return node
        if kind in ("string", "number") or (kind == "name" and text in ("true", "false", "null")):
            return ("literal", text)
        if kind != "name":
            raise ExpressionSyntaxError(f"unexpected {text!r}")
        if self._peek() == "(":
            self._take()
            args: list[tuple] = []
            if self._peek() != ")":
                args.append(self._or())
                while self._peek() == ",":
                    self._take()
                    args.append(self._or())
            self._take(")")
            call = ("call", text, args)
            if self._peek() not in (".", "["):
                return call
            # e.g. fromJSON(x)[0]: an index into a call's result. Its refs are
            # the call's, so keep the call and drop the index.
            self._path("")
            return call
        return ("ref", self._path(text))

    def _path(self, path: str) -> str:
        while self._peek() in (".", "["):
            if self._take()[1] == ".":
                part = self._take()
                if part[0] != "name" and part[1] != "*":
                    raise ExpressionSyntaxError(f"bad property {part[1]!r}")
                path += "." + part[1]
            else:
                inner = self._take()
                if inner[0] not in ("string", "number") and inner[1] != "*":
                    raise ExpressionSyntaxError(f"bad index {inner[1]!r}")
                self._take("]")
                path += f"[{inner[1]}]"
        return path


def parse_expression(source: str) -> tuple:
    return _Parser(source).parse()


def _refs(node: tuple) -> list[str]:
    kind = node[0]
    if kind == "ref":
        return [re.sub(r"\['([A-Za-z_][A-Za-z0-9_-]*)'\]", r".\1", node[1])]
    if kind in ("or", "and"):
        return [ref for child in node[1] for ref in _refs(child)]
    if kind == "not":
        return _refs(node[1])
    if kind == "cmp":
        return _refs(node[2]) + _refs(node[3])
    if kind == "call":
        return [ref for arg in node[2] for ref in _refs(arg)]
    return []


def _owned(node: tuple, selector: re.Pattern[str]) -> list[str]:
    return [ref for ref in _refs(node) if selector.fullmatch(ref)]


def _condition_key(node: tuple) -> tuple[str, str, str] | None:
    if node[0] != "cmp" or node[2][0] not in ("ref", "literal") or node[3][0] not in ("ref", "literal"):
        return None
    return (node[1], node[2][1], node[3][1])


def _guarded_literal(node: tuple) -> tuple[list[tuple], str] | None:
    """(conditions, label) for `cond && ... && 'label'`, else None."""
    if node[0] != "and" or node[1][-1][0] != "literal" or not node[1][-1][1].startswith("'"):
        return None
    return node[1][:-1], node[1][-1][1][1:-1]


def _blacksmith_pick(node: tuple) -> bool:
    """`startsWith(X, 'blacksmith-') && X || 'blacksmith-...'`: keep a picked
    runner only when it is a Blacksmith label, else fall back to one."""
    if node[0] != "or" or len(node[1]) != 2:
        return False
    kept, fallback = node[1]
    if fallback[0] != "literal" or not re.fullmatch(r"'blacksmith-\d+vcpu-macos-\d+'", fallback[1]):
        return False
    if kept[0] != "and" or len(kept[1]) != 2:
        return False
    check, picked = kept[1]
    return (
        picked[0] == "ref"
        and check == ("call", "startsWith", [picked, ("literal", "'blacksmith-'")])
    )


def _is_fork_pull_request_branch(node: tuple) -> bool:
    if node[0] == "and" and node[1] and _blacksmith_pick(node[1][-1]):
        conditions = node[1][:-1]
        keys = [_condition_key(condition) for condition in conditions]
        return None not in keys and set(keys) == FORK_PULL_REQUEST_CONDITIONS
    guarded = _guarded_literal(node)
    if not guarded:
        return False
    conditions, label = guarded
    keys = [_condition_key(condition) for condition in conditions]
    if None in keys:
        return False
    if not (set(keys) == FORK_PULL_REQUEST_CONDITIONS or keys == [PULL_REQUEST_CONDITION]):
        return False
    return bool(FORK_PULL_REQUEST_LABEL.fullmatch(label))


def _runner_value_error(
    node: tuple, selector: re.Pattern[str], dispatch_inputs_are_empty: bool
) -> str | None:
    """Why a runner-valued expression lets a fork PR read an owned selector."""
    owned = _owned(node, selector)
    if not owned:
        return None
    if node[0] == "call":
        # e.g. startsWith(<runner expression>, 'tart-'): each argument that
        # reads a selector is a runner expression of its own.
        for arg in node[2]:
            error = _runner_value_error(arg, selector, dispatch_inputs_are_empty)
            if error:
                return error
        return None
    disjuncts = node[1] if node[0] == "or" else [node]
    for disjunct in disjuncts:
        if _is_fork_pull_request_branch(disjunct):
            return None
        early = _owned(disjunct, selector)
        if early:
            return f"checks {early[0]} before the fork pull-request branch"
        # Anything else ahead of the fork branch must be a condition that picks
        # a literal label, such as the owner branch. A bare dispatch input is
        # empty on a pull_request run, but only if no caller can pass it.
        guarded = _guarded_literal(disjunct)
        if guarded and FORK_PULL_REQUEST_LABEL.fullmatch(guarded[1]):
            continue
        if dispatch_inputs_are_empty and disjunct[0] == "ref" and disjunct[1].startswith("inputs."):
            continue
        return "has no top-level fork pull-request branch"
    return "has no top-level fork pull-request branch"


def fork_pull_request_gate_error(
    line: str,
    selector: re.Pattern[str] = OWNED_RUNNER_SELECTOR,
    dispatch_inputs_are_empty: bool = False,
) -> str | None:
    """Why a fork PR into manaflow-ai could reach an owned runner label, if it can.

    Each `${{ }}` reading a selector must lead its top-level `||` chain with
    `github.event_name == 'pull_request' && <head.repo.full_name !=
    github.repository> && '<hosted or Blacksmith label>'`. Only guarded
    literals (such as the owner branch) may come first. A fork branch nested
    under another condition does not count: when that condition is false the
    expression falls through to whatever follows.
    """
    if not selector.search(line):
        return None
    if selector.search(EXPRESSION.sub("", line)):
        return "reads a runner selector outside a ${{ }} expression"
    for expression in EXPRESSION.findall(line):
        try:
            node = parse_expression(expression)
        except ExpressionSyntaxError as error:
            return f"has an expression the guard cannot parse ({error})"
        error = _runner_value_error(node, selector, dispatch_inputs_are_empty)
        if error:
            return error
    return None


def pull_request_workflows() -> list[Path]:
    result: list[Path] = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if re.search(r"(?m)^  pull_request:\s*(?:$|\[|\{)", text):
            result.append(path)
    return result


def has_workflow_call_trigger(text: str) -> bool:
    """A reusable workflow's `inputs` come from its caller, even on pull_request.

    Any uncommented mention counts, so a flow-style or oddly indented `on:`
    fails closed.
    """
    return bool(re.search(r"(?m)^[^#\n]*\bworkflow_call\b", text))


def triggers_block(text: str) -> str:
    """The `on:` block, so `  issues: write` under `permissions:` does not count."""
    match = re.search(r"(?ms)^(?:on|\"on\"|'on'):(.*?)(?=^\S|\Z)", text)
    return match.group(1) if match else ""


def outsider_triggered_workflows() -> list[Path]:
    return [
        path
        for path in sorted(WORKFLOWS.glob("*.y*ml"))
        if OUTSIDER_TRIGGER.search(triggers_block(path.read_text(encoding="utf-8")))
    ]


def outsider_runner_errors(name: str, text: str) -> list[str]:
    """Every runner must be a hosted literal; no runner selector may appear."""
    errors: list[str] = []
    for number, line in enumerate(text.splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        if OWNED_RUNNER_SELECTOR.search(line):
            errors.append(f"{name}:{number} reads a runner selector: {line.strip()}")
        elif re.match(r"^\s*runs-on:", line) and not HOSTED_LITERAL_RUNNER.match(line):
            errors.append(f"{name}:{number} is not a GitHub-hosted label: {line.strip()}")
    return errors


def fork_exercised_workflows(roots: list[Path] | None = None) -> list[Path]:
    """PR workflows plus every local reusable workflow reachable from them."""
    pending = list(pull_request_workflows() if roots is None else roots)
    seen: set[Path] = set()
    while pending:
        path = pending.pop()
        if path in seen:
            continue
        seen.add(path)
        text = path.read_text(encoding="utf-8")
        for name in LOCAL_WORKFLOW_CALL.findall(text):
            called = WORKFLOWS / name
            if called.is_file() and called not in seen:
                pending.append(called)
    return sorted(seen)


def pull_request_selects(line: str, family: str) -> bool:
    """True when `github.event_name == 'pull_request'` selects a hosted label."""
    return bool(
        re.search(
            r"github\.event_name == 'pull_request' && '" + family + r"-[^']+'",
            line,
        )
    )


def _gated_expression(expression: str, explicit_input_first: bool = False) -> bool:
    """True when a `${{ }}` body picks a GitHub-hosted label first outside manaflow-ai.

    With `explicit_input_first`, a leading `inputs.X ||` is allowed: an input
    someone set explicitly wins, and its default is checked on its own line.
    """
    body = expression.strip()
    if body.startswith("startsWith("):
        body = body[len("startsWith("):]
    if explicit_input_first:
        body = re.sub(r"^(?:inputs\.[A-Za-z0-9_-]+ \|\| )+", "", body)
    return body.startswith(FORK_BRANCHES)


def ungated_blacksmith_labels(name: str, text: str) -> list[str]:
    """Blacksmith labels a zero-configuration run outside manaflow-ai could select.

    A label is fine when every `${{ }}` holding it starts with the owner fork
    branch, when it sits in a job whose `if:` is the owner check, when it is a
    matrix row whose `hosted_runner` a fork branch picks instead, or when it is a
    dispatch input's default or choice and every `runs-on:` reading that input
    starts with the fork branch.
    """
    lines = text.splitlines()
    owner_only_jobs: set[str] = set()
    job = None
    for raw in lines:
        header = JOB_HEADER.match(raw)
        if header:
            job = header.group(1)
        elif job and raw.strip() == OWNER_ONLY_JOB_IF and raw.startswith("    if:"):
            owner_only_jobs.add(job)

    def input_is_translated(input_name: str) -> bool:
        read = re.compile(rf"inputs\.{re.escape(input_name)}\b")
        for raw in lines:
            if not re.match(r"^\s*runs-on:", raw):
                continue
            for expression in EXPRESSION.findall(raw):
                if read.search(expression) and not _gated_expression(expression):
                    return False
        return True

    matrix_branch = FORK_MACOS_MATRIX_BRANCH in text
    errors: list[str] = []
    job = None
    current_input = None
    in_options = False
    for number, raw in enumerate(lines, start=1):
        stripped = raw.strip()
        header = JOB_HEADER.match(raw)
        if header:
            job = header.group(1)
        input_header = INPUT_HEADER.match(raw)
        if input_header:
            current_input = input_header.group(1)
        if stripped.startswith("options:"):
            in_options = True
            continue
        if in_options and not stripped.startswith("- "):
            in_options = False
        if stripped.startswith("#") or not BLACKSMITH_LABEL.search(raw):
            continue
        if job in owner_only_jobs or (name, stripped) in UNGATED_BLACKSMITH_ALLOWED:
            continue
        if matrix_branch and re.search(r'"hosted_runner":\s*"macos-[^"]+"', raw):
            continue
        label = BLACKSMITH_LABEL.search(raw).group(0)
        dispatch_value = (in_options and stripped == f"- {label}") or stripped == f"default: {label}"
        if dispatch_value and current_input and (
            input_is_translated(current_input)
            or (name, current_input) in UNTRANSLATED_DISPATCH_INPUTS
        ):
            continue
        expressions = [e for e in EXPRESSION.findall(raw) if BLACKSMITH_LABEL.search(e)]
        if expressions and all(_gated_expression(e, explicit_input_first=True) for e in expressions):
            # A label outside every expression (e.g. `group: blacksmith-...-${{ }}`)
            # is still selectable.
            if not BLACKSMITH_LABEL.search(EXPRESSION.sub("", raw)):
                continue
        errors.append(
            f"{name}:{number}: {label} is selectable outside manaflow-ai, where no "
            f"Blacksmith runner exists; start the expression with the owner fork branch, "
            f"e.g. ${{{{ {FORK_LINUX_BRANCH} || ... }}}}"
        )
    return errors


class ForkRunnerRoutingTests(unittest.TestCase):
    def test_pull_request_branch_must_select_the_hosted_label(self) -> None:
        selected = (
            "runs-on: ${{ github.event_name == 'pull_request' && 'ubuntu-latest'"
            " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
        )
        inverted = (
            "runs-on: ${{ github.event_name == 'pull_request'"
            " && 'blacksmith-6vcpu-macos-15' || 'macos-15' }}"
        )
        inverted_linux = (
            "runs-on: ${{ github.event_name == 'pull_request'"
            " && 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04' }}"
        )
        self.assertTrue(pull_request_selects(selected, "ubuntu"))
        self.assertFalse(pull_request_selects(inverted, "macos"))
        self.assertFalse(pull_request_selects(inverted_linux, "ubuntu"))

    def test_fork_pull_request_gate_must_precede_every_owned_selector(self) -> None:
        clause = (
            "github.event_name == 'pull_request'"
            " && github.event.pull_request.head.repo.full_name != github.repository"
        )
        gated = (
            "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || ("
            + clause
            + " && 'blacksmith-6vcpu-macos-15' || vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15') }}"
        )
        ungated = (
            "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26'"
            " || (vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15') }}"
        )
        late = (
            "runs-on: ${{ vars.MACOS_RUNNER_PR || "
            + clause
            + " && 'blacksmith-6vcpu-macos-15' || 'blacksmith-6vcpu-macos-15' }}"
        )
        # head.repo.fork is false-y when the head repository was deleted.
        null_unsafe = (
            "runs-on: ${{ github.event.pull_request.head.repo.fork && 'blacksmith-6vcpu-macos-15'"
            " || matrix.pr_runner }}"
        )
        # The fork branch must pick a hosted label, not another variable.
        to_variable = (
            "runs-on: ${{ " + clause + " && vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}"
        )
        # The picker's choice may stand for a fork only when it is Blacksmith.
        picked = (
            "runs-on: ${{ " + clause + " && (startsWith(inputs.pr_runner, 'blacksmith-')"
            " && inputs.pr_runner || 'blacksmith-6vcpu-macos-15')"
            " || github.event_name == 'pull_request' && (inputs.pr_runner || vars.MACOS_RUNNER_PR"
            " || 'blacksmith-6vcpu-macos-15') }}"
        )
        picked_unchecked = (
            "runs-on: ${{ " + clause + " && (inputs.pr_runner || 'blacksmith-6vcpu-macos-15')"
            " || vars.MACOS_RUNNER_PR }}"
        )
        picked_mismatch = (
            "runs-on: ${{ " + clause + " && (startsWith(inputs.pr_runner, 'blacksmith-')"
            " && vars.MACOS_RUNNER_PR || 'blacksmith-6vcpu-macos-15') || vars.MACOS_RUNNER_PR }}"
        )
        picker_first = (
            "runs-on: ${{ needs.changes.outputs.macos_pr_runner || "
            + clause
            + " && 'blacksmith-6vcpu-macos-15' || 'blacksmith-6vcpu-macos-15' }}"
        )
        self.assertIsNone(fork_pull_request_gate_error(picked))
        self.assertIsNotNone(fork_pull_request_gate_error(picked_unchecked))
        self.assertIsNotNone(fork_pull_request_gate_error(picked_mismatch))
        self.assertIsNotNone(fork_pull_request_gate_error(picker_first))
        self.assertIsNone(fork_pull_request_gate_error(gated))
        self.assertIsNone(fork_pull_request_gate_error("runs-on: macos-15"))
        self.assertIsNotNone(fork_pull_request_gate_error(ungated))
        self.assertIsNotNone(fork_pull_request_gate_error(late))
        self.assertIsNotNone(fork_pull_request_gate_error(null_unsafe))
        self.assertIsNotNone(fork_pull_request_gate_error(to_variable))

    def test_fork_pull_request_gate_reads_expression_structure(self) -> None:
        clause = (
            "github.event_name == 'pull_request'"
            " && github.event.pull_request.head.repo.full_name != github.repository"
        )
        owner = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
        accepted = {
            "linux gated": (
                "runs-on: ${{ " + owner + " || " + clause
                + " && 'blacksmith-4vcpu-ubuntu-2404' || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
            ),
            "conditions in either order": (
                "runs-on: ${{ github.event.pull_request.head.repo.full_name != github.repository"
                " && github.event_name == 'pull_request' && 'macos-26' || vars.MACOS_RUNNER_26 }}"
            ),
            "every pull request to a hosted label": (
                "runs-on: ${{ " + owner + " || (github.event_name == 'pull_request' && 'ubuntu-latest'"
                " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404') }}"
            ),
            "inside a function call": (
                "if: ${{ startsWith(" + clause + " && 'blacksmith-6vcpu-macos-26'"
                " || vars.MACOS_RUNNER_TESTS || 'blacksmith-6vcpu-macos-26', 'tart-') }}"
            ),
            "no selector": "runs-on: ${{ inputs.runner || 'macos-15' }}",
        }
        rejected = {
            "linux ungated": (
                "runs-on: ${{ " + owner + " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"
            ),
            "arm64 ungated": "LINUX_ARM64_RUNNER: ${{ vars.LINUX_ARM64_RUNNER || 'ubuntu-24.04-arm' }}",
            "fork branch under a negated condition": (
                "runs-on: ${{ !(vars.CI_PAID_MACOS_OVERFLOW == '1') && (" + clause
                + " && 'macos-26') || vars.MACOS_RUNNER_15 }}"
            ),
            "fork branch picks a self-hosted label": (
                "runs-on: ${{ " + clause + " && 'tart-macos-15' || vars.MACOS_RUNNER_15 }}"
            ),
            "fork branch misses a condition": (
                "runs-on: ${{ github.event.pull_request.head.repo.full_name != github.repository"
                " && 'macos-26' || vars.MACOS_RUNNER_26 }}"
            ),
            "a variable-valued disjunct first": (
                "runs-on: ${{ vars.OTHER_RUNNER || " + clause + " && 'macos-26' || vars.MACOS_RUNNER_26 }}"
            ),
            "inside a function call": (
                "if: ${{ startsWith(vars.MACOS_RUNNER_TESTS || 'blacksmith-6vcpu-macos-26', 'tart-') }}"
            ),
            "unparseable": "runs-on: ${{ vars.MACOS_RUNNER_15 || ( }}",
            "index form": "runs-on: ${{ vars['MACOS_RUNNER_15'] || 'blacksmith-6vcpu-macos-15' }}",
            "other case": "runs-on: ${{ VARS.macos_runner_15 || 'blacksmith-6vcpu-macos-15' }}",
            "self-hosted literal ahead of the fork branch": (
                "runs-on: ${{ github.repository_owner == 'manaflow-ai' && 'tart-macos-15' || "
                + clause + " && 'macos-26' || vars.MACOS_RUNNER_26 }}"
            ),
            "second expression on the line": (
                "run-name: ${{ " + clause + " && 'macos-26' || vars.MACOS_RUNNER_26 }}"
                " on ${{ vars.MACOS_RUNNER_26 }}"
            ),
        }
        for name, line in accepted.items():
            with self.subTest(accepted=name):
                self.assertIsNone(fork_pull_request_gate_error(line))
        for name, line in rejected.items():
            with self.subTest(rejected=name):
                self.assertIsNotNone(fork_pull_request_gate_error(line))

        # A dispatch input is empty on a pull_request run, so it may precede the
        # fork branch; a workflow_call caller can fill it, so there it may not.
        dispatch = (
            "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || inputs.runner || ("
            + clause + " && 'blacksmith-6vcpu-macos-15' || vars.MACOS_RUNNER_15) }}"
        )
        self.assertIsNone(fork_pull_request_gate_error(dispatch, dispatch_inputs_are_empty=True))
        self.assertIsNotNone(fork_pull_request_gate_error(dispatch, dispatch_inputs_are_empty=False))

    def test_expression_parser(self) -> None:
        self.assertEqual(
            parse_expression("a.b == 'x' && (c || d['e'].*) || !f(g, 1)"),
            (
                "or",
                [
                    ("and", [("cmp", "==", ("ref", "a.b"), ("literal", "'x'")), ("or", [("ref", "c"), ("ref", "d['e'].*")])]),
                    ("not", ("call", "f", [("ref", "g"), ("literal", "1")])),
                ],
            ),
        )
        # An index into a call's result keeps the call's refs.
        self.assertEqual(parse_expression("fromJSON(a.b)[0]"), ("call", "fromJSON", [("ref", "a.b")]))
        # A quoted `||` is a string, not an operator; `''` escapes a quote.
        self.assertEqual(parse_expression("'a || b' || 'it''s'"), ("or", [("literal", "'a || b'"), ("literal", "'it''s'")]))
        for broken in ("a ||", "(a", "a b", "'open"):
            with self.subTest(broken=broken), self.assertRaises(ExpressionSyntaxError):
                parse_expression(broken)

    def test_fork_pull_requests_into_manaflow_ai_never_reach_an_owned_runner_label(self) -> None:
        """Runner variables may name self-hosted machines; fork PR code must not run there."""
        checked = 0
        failures = []
        for path in fork_exercised_workflows():
            text = path.read_text(encoding="utf-8")
            dispatch_inputs_are_empty = not has_workflow_call_trigger(text)
            for number, line in enumerate(text.splitlines(), start=1):
                if line.lstrip().startswith("#"):
                    continue
                if not (
                    OWNED_RUNNER_VARIABLE.search(line)
                    or ("runs-on:" in line and OWNED_RUNNER_SELECTOR.search(line))
                ):
                    continue
                # A selector split across lines would hide the gate from
                # this line-based check.
                if "${{" in line and "}}" not in line:
                    failures.append(f"{path.name}:{number} spans lines; keep runner expressions on one line")
                    continue
                if (path.name, line.strip()) in FORK_GATE_EXEMPT:
                    continue
                checked += 1
                error = fork_pull_request_gate_error(
                    line, dispatch_inputs_are_empty=dispatch_inputs_are_empty
                )
                if error:
                    failures.append(f"{path.name}:{number} {error}: {line.strip()}")
        self.assertEqual(failures, [])
        self.assertGreater(checked, 0)

    def test_pull_request_xcode_pin_follows_the_same_repository_lane(self) -> None:
        """A fork PR leaves MACOS_RUNNER_PR, so it must leave its Xcode pin too.

        select-ci-xcode.sh fails on a pinned Xcode the image does not carry, so a
        fork PR routed to the macOS 15 default while still reading
        CMUX_CI_XCODE_APP_PR would fail at Xcode selection.
        """
        same_repository = "github.event.pull_request.head.repo.full_name == github.repository"
        checked = 0
        failures = []
        for path in fork_exercised_workflows():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                if line.lstrip().startswith("#") or not re.search(r"vars\.CMUX_(?:CI|CI_HELPER)_XCODE_APP_PR\b", line):
                    continue
                checked += 1
                if same_repository not in line:
                    failures.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(failures, [])
        self.assertGreater(checked, 0)

    def test_pull_request_graph_is_nonempty_and_includes_reusable_workflows(self) -> None:
        roots = pull_request_workflows()
        graph = fork_exercised_workflows()
        self.assertTrue(roots)
        self.assertGreater(len(graph), len(roots))

    def test_fork_macos_branches_use_macos_26_unless_the_job_needs_macos_15(self) -> None:
        workflows = Path(__file__).resolve().parents[1] / ".github" / "workflows"
        wrong = []
        for path in sorted(workflows.glob("*.yml")):
            job = None
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
                match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
                if match:
                    job = match.group(1)
                if FORK_MACOS_15_BRANCH in line and (path.name, job) not in MACOS_15_FORK_JOBS:
                    wrong.append(f"{path.name}:{number} ({job})")
        self.assertEqual(wrong, [], "fork branches compile on macos-26 so they can reuse main's caches")

    def test_every_fork_exercised_runner_has_a_hosted_path(self) -> None:
        """No fork PR may queue forever on organization-only capacity."""
        saw_linux = 0
        saw_macos = 0

        for path in fork_exercised_workflows():
            text = path.read_text(encoding="utf-8")
            # Rows are YAML (`hosted_runner: macos-15`) or JSON literals in a
            # matrix `include` expression (`"hosted_runner": "macos-15"`).
            hosted_rows = re.findall(r"(?m)^\s+hosted_runner:\s*(\S+)\s*$", text)
            hosted_rows += re.findall(r'"hosted_runner":\s*"([^"]*)"', text)
            matrix_hosted = bool(hosted_rows) and set(hosted_rows) <= HOSTED_MACOS_LABELS
            for number, line in enumerate(text.splitlines(), start=1):
                if "runs-on:" not in line:
                    continue

                # A few trust-boundary workflows already choose GitHub-hosted
                # capacity specifically for pull_request and use the repository
                # pool for push/main. That is equivalent to the owner branch,
                # but only when the hosted label is the value the pull_request
                # condition selects, not a label appearing later on the line.
                pull_request_linux = pull_request_selects(line, "ubuntu")
                pull_request_macos = pull_request_selects(line, "macos")
                hosted_linux = FORK_LINUX_BRANCH in line or pull_request_linux
                hosted_macos = (
                    FORK_MACOS_BRANCH in line
                    or FORK_MACOS_15_BRANCH in line
                    or pull_request_macos
                    or (matrix_hosted and FORK_MACOS_MATRIX_BRANCH in line)
                )

                with self.subTest(workflow=path.name, line=number):
                    if "vars.LINUX_RUNNER" in line:
                        saw_linux += 1
                        self.assertTrue(
                            hosted_linux,
                            f"{path.name}:{number} has no GitHub-hosted Linux fork branch",
                        )
                    if "vars.MACOS_RUNNER" in line:
                        saw_macos += 1
                        self.assertTrue(
                            hosted_macos,
                            f"{path.name}:{number} has no GitHub-hosted macOS fork branch",
                        )
                    if "blacksmith-" in line:
                        self.assertTrue(
                            hosted_linux or hosted_macos,
                            f"{path.name}:{number} can queue forever in a fork: {line.strip()}",
                        )
                    if re.search(r"\b(?:warp|depot|tart)-", line):
                        self.assertTrue(
                            hosted_linux or hosted_macos,
                            f"{path.name}:{number} can route a fork onto non-GitHub capacity",
                        )

        self.assertGreater(saw_linux, 0)
        self.assertGreater(saw_macos, 0)

    def test_outsider_triggered_workflows_pin_a_hosted_runner(self) -> None:
        """pull_request_target and comment events run fork-started jobs with trusted tokens."""
        roots = outsider_triggered_workflows()
        self.assertIn(WORKFLOWS / "cla.yml", roots)
        self.assertIn(WORKFLOWS / "claude.yml", roots)
        errors: list[str] = []
        for path in fork_exercised_workflows(roots):
            errors.extend(outsider_runner_errors(path.name, path.read_text(encoding="utf-8")))
        self.assertEqual(errors, [], "\n" + "\n".join(errors))

    def test_outsider_runner_check_rejects_variables_and_self_hosted_labels(self) -> None:
        text = (
            "on:\n"
            "  pull_request_target:\n"
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "  b:\n"
            "    runs-on: ${{ " + FORK_LINUX_BRANCH + " || vars.LINUX_RUNNER || 'ubuntu-24.04' }}\n"
            "  c:\n"
            "    runs-on: self-hosted\n"
            "  d:\n"
            "    runs-on:\n"
            "      - self-hosted\n"
            "  e:\n"
            "    env:\n"
            "      RUNNER: ${{ vars['LINUX_RUNNER'] }}\n"
            "    runs-on: blacksmith-4vcpu-ubuntu-2404\n"
            "  ok:\n"
            "    runs-on: ubuntu-24.04 # github-hosted-required: write token\n"
        )
        self.assertTrue(OUTSIDER_TRIGGER.search(triggers_block(text)))
        self.assertFalse(OUTSIDER_TRIGGER.search(triggers_block(
            "on:\n  push:\npermissions:\n  issues: write\njobs: {}\n"
        )))
        for flow in (
            "on: [push, issue_comment]\n",
            "on: pull_request_target\n",
            "on: {issues: {}}\n",
            "on:\n    pull_request_review:\n",
        ):
            with self.subTest(flow=flow):
                self.assertTrue(OUTSIDER_TRIGGER.search(triggers_block(flow + "jobs: {}\n")))
        self.assertFalse(OUTSIDER_TRIGGER.search(triggers_block("on: [pull_request, push]\njobs: {}\n")))
        errors = outsider_runner_errors("x.yml", text)
        self.assertEqual([error.split(" ", 1)[0] for error in errors],
                         ["x.yml:5", "x.yml:7", "x.yml:9", "x.yml:11", "x.yml:15", "x.yml:16"])

    def test_no_workflow_falls_back_to_blacksmith_outside_manaflow_ai(self) -> None:
        """Scheduled, dispatched and push-only workflows need a fork branch too.

        A fork running its own CI has no Blacksmith installation and no runner
        variables, so an ungated fallback sits queued forever and holds its
        concurrency group.
        """
        errors: list[str] = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            errors.extend(ungated_blacksmith_labels(path.name, path.read_text(encoding="utf-8")))
        self.assertEqual(errors, [], "\n" + "\n".join(errors))

    def test_ungated_blacksmith_fallbacks_are_rejected(self) -> None:
        text = (
            "on:\n"
            "  workflow_dispatch:\n"
            "    inputs:\n"
            "      runner:\n"
            "        default: blacksmith-6vcpu-macos-26\n"
            "        type: choice\n"
            "        options:\n"
            "          - blacksmith-6vcpu-macos-26\n"
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "  b:\n"
            "    runs-on: blacksmith-6vcpu-macos-15\n"
            "  c:\n"
            "    strategy:\n"
            "      matrix:\n"
            "        include:\n"
            "          - runner: blacksmith-6vcpu-macos-26\n"
            "  d:\n"
            "    runs-on: ${{ inputs.runner || " + FORK_MACOS_BRANCH + " || 'blacksmith-6vcpu-macos-26' }}\n"
        )
        # a, b, c, and the dispatch default and option that d reads before
        # the fork branch. d itself passes: an explicitly chosen input wins.
        self.assertEqual(len(ungated_blacksmith_labels("x.yml", text)), 5)

    def test_owner_gated_blacksmith_fallbacks_pass(self) -> None:
        text = (
            "on:\n"
            "  workflow_dispatch:\n"
            "    inputs:\n"
            "      runner:\n"
            "        default: blacksmith-6vcpu-macos-26\n"
            "        type: choice\n"
            "        options:\n"
            "          - blacksmith-6vcpu-macos-26\n"
            "concurrency:\n"
            "  group: x-${{ " + FORK_MACOS_BRANCH + " || inputs.runner }}\n"
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ " + FORK_LINUX_BRANCH + " || vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "  b:\n"
            "    runs-on: ${{ " + FORK_MACOS_BRANCH + " || inputs.runner || 'blacksmith-6vcpu-macos-26' }}\n"
            "    steps:\n"
            "      - if: ${{ startsWith(" + FORK_MACOS_BRANCH + " || 'blacksmith-6vcpu-macos-26', 'glaeda-') }}\n"
            "        run: ./scripts/blacksmith-bounded-command.sh\n"
            "  c:\n"
            "    " + OWNER_ONLY_JOB_IF + "\n"
            "    runs-on: blacksmith-32vcpu-ubuntu-2404\n"
        )
        self.assertEqual(ungated_blacksmith_labels("x.yml", text), [])


if __name__ == "__main__":
    unittest.main()
