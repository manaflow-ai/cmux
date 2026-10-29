#!/usr/bin/env python3
"""A roll-up gate's verdict: every job it summarizes reported, or was routed off.

A gate that reads `needs` and allows `success` or `skipped` cannot tell a job
its routing turned off from a job that was selected and never ran: an absent
signal reads green. This decides from the source that routed the job, its own
`if:` in the workflow file, so there is no second copy of any routing rule to
drift. For each job the gate needs:

- `success` passes;
- `failure`, `cancelled` or anything else fails;
- `skipped` passes only when the job's `if:`, evaluated against the same
  `needs` results and outputs, the repository variables, the workflow inputs
  and the event fields that decided it, is false. A job whose `if:` says it
  should have run was skipped for some other reason, and fails the gate.

An `if:` this evaluator cannot resolve (an unknown function, a context field
the gate was not given, a need the gate does not see) counts as selected: it
fails closed. tests/test_ci_gate_absent_signal.py walks every gate's needs
graph and checks that each one resolves.

Usage, from a gate job's step:

    env:
      GATE_NEEDS: ${{ toJSON(needs) }}
      GATE_VARS: ${{ toJSON(vars) }}
      GATE_INPUTS: ${{ toJSON(inputs) }}
      GATE_GITHUB: '{"event_name": ${{ toJSON(github.event_name) }}, ...}'
    run: python3 scripts/ci/gate_verdict.py --workflow <file> --gate <job id>
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class Unresolved(Exception):
    """The expression references something this evaluator cannot answer."""


# --------------------------------------------------------------------------
# Workflow reading. The runners that host gates have no PyYAML, so this reads
# only the two keys it needs, `if:` and `needs:`, from each job. The test
# compares the result with a full YAML parse of every gated workflow, so a
# layout this reader does not understand fails a pull request, not a gate.

_JOB_HEADER = re.compile(r"^  ([A-Za-z_][A-Za-z0-9_-]*):\s*(#.*)?$")
_KEY = re.compile(r"^    ([A-Za-z_-]+):(.*)$")
_LIST_ITEM = re.compile(r"^      - ([A-Za-z0-9_-]+)\s*(#.*)?$")


@dataclass(frozen=True)
class Job:
    name: str
    needs: tuple[str, ...]
    condition: str | None


def _scalar(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def read_jobs(text: str) -> dict[str, Job]:
    lines = text.splitlines()
    try:
        start = lines.index("jobs:") + 1
    except ValueError as error:
        raise ValueError("no top-level `jobs:` key") from error
    jobs: dict[str, Job] = {}
    current: str | None = None
    needs: list[str] = []
    condition: str | None = None
    in_needs = False

    def close() -> None:
        if current is not None:
            jobs[current] = Job(current, tuple(needs), condition)

    for line in lines[start:]:
        if line and not line.startswith(" ") and not line.startswith("#"):
            break  # the next top-level key
        header = _JOB_HEADER.match(line)
        if header:
            close()
            current, needs, condition, in_needs = header.group(1), [], None, False
            continue
        if current is None:
            continue
        key = _KEY.match(line)
        if key:
            in_needs = False
            name, rest = key.group(1), key.group(2).strip()
            if name == "if":
                if rest[:1] in {">", "|"}:
                    raise ValueError(f"{current}: a block-scalar `if:` is not supported")
                condition = _scalar(rest)
            elif name == "needs":
                if rest.startswith("["):
                    needs = [_scalar(item) for item in rest.strip("[]").split(",") if item.strip()]
                elif rest:
                    needs = [_scalar(rest)]
                else:
                    in_needs = True
            continue
        if in_needs:
            item = _LIST_ITEM.match(line)
            if item:
                needs.append(item.group(1))
            elif line.strip() and not line.strip().startswith("#"):
                in_needs = False
    close()
    return jobs


# --------------------------------------------------------------------------
# GitHub Actions expressions, the subset workflow `if:` conditions use.

_TOKEN = re.compile(
    r"\s*(?:"
    r"(?P<str>'(?:[^']|'')*')"
    r"|(?P<num>-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?))"
    r"|(?P<op>==|!=|<=|>=|&&|\|\||[<>!().,\[\]*])"
    r"|(?P<ident>[A-Za-z_][A-Za-z0-9_-]*)"
    r")"
)


def _tokens(source: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    position = 0
    source = source.rstrip()
    while position < len(source):
        match = _TOKEN.match(source, position)
        if not match or match.end() == position:
            raise Unresolved(f"cannot read the expression at {source[position:]!r}")
        position = match.end()
        kind = match.lastgroup
        assert kind is not None
        out.append((kind, match.group(kind)))
    return out


class _Filtered(list):
    """The result of `.*`: property access maps over the elements."""


def _truthy(value: Any) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return not (value == 0 or (isinstance(value, float) and math.isnan(value)))
    if isinstance(value, str):
        return value != ""
    return True


def _number(value: Any) -> float:
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if text == "":
            return 0.0
        try:
            return float(int(text, 16)) if text.lower().startswith("0x") else float(text)
        except ValueError:
            return math.nan
    return math.nan


def _equal(left: Any, right: Any) -> bool:
    if isinstance(left, str) and isinstance(right, str):
        return left.casefold() == right.casefold()
    if left is None and right is None:
        return True
    if isinstance(left, (dict, list)) or isinstance(right, (dict, list)):
        return left is right
    if type(left) is type(right) and not isinstance(left, str):
        return left == right
    return _number(left) == _number(right)


def _compare(left: Any, right: Any) -> float:
    if isinstance(left, str) and isinstance(right, str):
        a, b = left.casefold(), right.casefold()
        return (a > b) - (a < b)
    a, b = _number(left), _number(right)
    if math.isnan(a) or math.isnan(b):
        return math.nan
    return (a > b) - (a < b)


def _string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


class _Strict(dict):
    """A context object whose missing keys are a gap in what the gate was given.

    `deep` objects (the event fields) are strict all the way down; `needs` is
    strict only about which jobs it holds, since a job's outputs may be unset.
    """

    def __init__(self, data: dict[str, Any], *, deep: bool):
        super().__init__(data)
        self.deep = deep

    def lookup(self, name: str) -> Any:
        for key, item in self.items():
            if key.casefold() == name.casefold():
                if self.deep and isinstance(item, dict):
                    return _Strict(item, deep=True)
                return item
        raise Unresolved(f"context field {name!r} was not passed to the gate")


class _Vars(dict):
    """Repository variables: an unset one reads as the empty string, as in GitHub."""


def _member(value: Any, name: str) -> Any:
    if isinstance(value, _Filtered):
        return _Filtered(_member(item, name) for item in value if isinstance(item, dict))
    if isinstance(value, _Strict):
        return value.lookup(name)
    if isinstance(value, dict):
        for key, item in value.items():
            if key.casefold() == name.casefold():
                return item
        return "" if isinstance(value, _Vars) else None
    return None


class _Parser:
    """Builds a small tree, so `&&` and `||` can short-circuit as GitHub does."""

    def __init__(self, tokens: list[tuple[str, str]]):
        self.tokens = tokens
        self.index = 0

    def peek(self) -> tuple[str, str] | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self, value: str | None = None) -> tuple[str, str]:
        token = self.peek()
        if token is None or (value is not None and token[1] != value):
            raise Unresolved(f"expected {value!r}, found {token!r}")
        self.index += 1
        return token

    def parse(self) -> tuple:
        node = self.binary(0)
        if self.peek() is not None:
            raise Unresolved(f"unexpected {self.peek()!r}")
        return node

    LEVELS = (("||",), ("&&",), ("==", "!="), ("<", "<=", ">", ">="))

    def binary(self, level: int) -> tuple:
        if level == len(self.LEVELS):
            return self.unary()
        node = self.binary(level + 1)
        while self.peek() is not None and self.peek()[0] == "op" and self.peek()[1] in self.LEVELS[level]:
            op = self.take()[1]
            node = ("bin", op, node, self.binary(level + 1))
        return node

    def unary(self) -> tuple:
        if self.peek() == ("op", "!"):
            self.take()
            return ("not", self.unary())
        return self.postfix()

    def postfix(self) -> tuple:
        kind, text = self.take()
        if kind == "str":
            node: tuple = ("lit", text[1:-1].replace("''", "'"))
        elif kind == "num":
            node = ("lit", _number(text))
        elif text == "(":
            node = self.binary(0)
            self.take(")")
        elif kind == "ident" and self.peek() == ("op", "("):
            self.take("(")
            args: list[tuple] = []
            if self.peek() != ("op", ")"):
                args.append(self.binary(0))
                while self.peek() == ("op", ","):
                    self.take()
                    args.append(self.binary(0))
            self.take(")")
            node = ("call", text.lower(), args)
        elif kind == "ident" and text in {"true", "false", "null"}:
            node = ("lit", {"true": True, "false": False, "null": None}[text])
        elif kind == "ident":
            node = ("ctx", text)
        else:
            raise Unresolved(f"unexpected {text!r}")
        while self.peek() in {("op", "."), ("op", "[")}:
            if self.take()[1] == ".":
                kind, name = self.take()
                if name == "*":
                    node = ("star", node)
                elif kind == "ident":
                    node = ("get", node, ("lit", name))
                else:
                    raise Unresolved(f"bad property {name!r}")
            else:
                key = self.binary(0)
                self.take("]")
                node = ("get", node, key)
        return node


def _run(node: tuple, context: dict[str, Any], status: dict[str, bool]) -> Any:
    kind = node[0]
    if kind == "lit":
        return node[1]
    if kind == "ctx":
        if node[1] not in context:
            raise Unresolved(f"unknown context {node[1]!r}")
        return context[node[1]]
    if kind == "not":
        return not _truthy(_run(node[1], context, status))
    if kind == "star":
        value = _run(node[1], context, status)
        return _Filtered(value.values() if isinstance(value, dict)
                         else value if isinstance(value, list) else [])
    if kind == "get":
        value = _run(node[1], context, status)
        key = _run(node[2], context, status)
        if isinstance(value, list) and not isinstance(value, _Filtered):
            index = _number(key)
            return value[int(index)] if index.is_integer() and 0 <= index < len(value) else None
        return _member(value, _string(key))
    if kind == "bin":
        op = node[1]
        left = _run(node[2], context, status)
        if op == "&&":
            return _run(node[3], context, status) if _truthy(left) else left
        if op == "||":
            return left if _truthy(left) else _run(node[3], context, status)
        right = _run(node[3], context, status)
        if op == "==":
            return _equal(left, right)
        if op == "!=":
            return not _equal(left, right)
        order = _compare(left, right)
        if math.isnan(order):
            return False
        return {"<": order < 0, "<=": order <= 0, ">": order > 0, ">=": order >= 0}[op]
    if kind == "call":
        name, arg_nodes = node[1], node[2]
        if name in status:
            if arg_nodes:
                raise Unresolved(f"{name}() takes no arguments here")
            return status[name]
        args = [_run(arg, context, status) for arg in arg_nodes]
        if name == "contains" and len(args) == 2:
            haystack, needle = args
            if isinstance(haystack, list):
                return any(_equal(item, needle) for item in haystack)
            return _string(needle).casefold() in _string(haystack).casefold()
        if name == "startswith" and len(args) == 2:
            return _string(args[0]).casefold().startswith(_string(args[1]).casefold())
        if name == "endswith" and len(args) == 2:
            return _string(args[0]).casefold().endswith(_string(args[1]).casefold())
        if name == "fromjson" and len(args) == 1:
            try:
                return json.loads(_string(args[0]))
            except ValueError as error:
                raise Unresolved(f"fromJSON of {args[0]!r}") from error
        if name == "tojson" and len(args) == 1:
            return json.dumps(args[0], indent=2)
        if name == "format" and args:
            template = _string(args[0]).replace("{{", "\0").replace("}}", "\1")
            filled = re.sub(r"\{(\d+)\}", lambda m: _string(args[1 + int(m.group(1))]), template)
            return filled.replace("\0", "{").replace("\1", "}")
        if name == "join" and args:
            separator = _string(args[1]) if len(args) > 1 else ","
            items = args[0] if isinstance(args[0], list) else [args[0]]
            return separator.join(_string(item) for item in items)
        raise Unresolved(f"unsupported function {name}()")
    raise Unresolved(f"unknown node {kind}")


_STATUS = re.compile(r"\b(success|failure|always|cancelled)\s*\(", re.IGNORECASE)


def strip_expression(condition: str) -> str:
    text = condition.strip()
    if text.startswith("${{") and text.endswith("}}"):
        return text[3:-2].strip()
    return text


def evaluate(expression: str, context: dict[str, Any], status: dict[str, bool]) -> Any:
    return _run(_Parser(_tokens(expression)).parse(), context, status)


# --------------------------------------------------------------------------
# The verdict.

PASSING = "success"


def _ancestors(job: Job, jobs: dict[str, Job] | None) -> set[str]:
    """Every job upstream of this one. GitHub's status functions see the whole
    chain: a skipped or failed ancestor skips an implicit-success dependent
    even when the job between them ran under !cancelled()."""
    seen: set[str] = set()
    pending = list(job.needs)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        if jobs is not None:
            if name not in jobs:
                raise Unresolved(f"{job.name} has ancestor {name}, which is not in the workflow")
            pending.extend(jobs[name].needs)
    return seen


def selected(job: Job, needs: dict[str, Any], context: dict[str, Any], *,
             jobs: dict[str, Job] | None = None, tolerate_variable_flips: bool = True) -> bool:
    """Whether the job's own `if:` says it should have run, given what the gate sees.

    With `tolerate_variable_flips` off this is plain routing: the `if:` as
    GitHub evaluates it with these variables. Pass `jobs`: without it the
    status functions see only direct needs, and a skipped grandparent can make
    a job look selected when GitHub skipped it."""
    results = {}
    for name in _ancestors(job, jobs):
        if name not in needs:
            raise Unresolved(f"{job.name} depends on {name}, which the gate does not see")
        results[name] = needs[name].get("result")
    status = {
        # The gate itself runs under !cancelled(), so the run is not cancelled.
        "cancelled": False,
        "always": True,
        "success": all(result == "success" for result in results.values()),
        "failure": any(result == "failure" for result in results.values()),
    }
    expression = strip_expression(job.condition) if job.condition else ""
    if not expression:
        return status["success"]
    scope = dict(context)
    scope["needs"] = _Strict({name: {"result": needs[name].get("result"),
                                     "outputs": needs[name].get("outputs") or {}}
                              for name in job.needs}, deep=False)
    implicit = not _STATUS.search(expression)
    if implicit and not status["success"]:
        # A condition without a status function runs only when its needs passed.
        return False
    # Repository variables are read again here, after the job was routed, and
    # an operator may have flipped one in between (or between re-run
    # attempts). A skip that some value of the variables this `if:` reads
    # explains is therefore accepted: a variable is a deliberate switch, not
    # a routing signal, and reading it late must not red every PR in flight.
    current = context.get("vars") or _Vars()
    choices = _variable_choices(expression, current) if tolerate_variable_flips else [_Vars(current)]
    for variables in choices:
        scope["vars"] = variables
        if not _truthy(evaluate(expression, scope, status)):
            return False
    return True


_VAR_REF = re.compile(r"\bvars\.([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE)


def _variable_choices(expression: str, current: dict[str, Any]) -> list[dict[str, Any]]:
    """The current variables, then each referenced one set to every value the
    expression compares it with, or to unset."""
    choices = [_Vars(current)]
    literals = [match.group(0)[1:-1].replace("''", "'")
                for match in re.finditer(r"'(?:[^']|'')*'", expression)]
    for name in sorted(set(_VAR_REF.findall(expression))):
        for value in ["", *literals, "x"]:
            # Replace the variable however its key is cased: lookups ignore case.
            others = {key: item for key, item in current.items() if key.casefold() != name.casefold()}
            choices.append(_Vars({**others, name: value}))
    return choices


def problems(jobs: dict[str, Job], gate: str, needs: dict[str, Any], context: dict[str, Any],
             context_only: frozenset[str] = frozenset()) -> list[str]:
    """What keeps the gate from passing. `context_only` names best-effort needs
    the gate reads only to evaluate other needs' `if:`; their own result,
    whatever it is, is not a verdict."""
    found: list[str] = []
    for name in jobs[gate].needs:
        entry = needs.get(name)
        if entry is None:
            found.append(f"{name}: no result reached the gate")
            continue
        if name in context_only:
            continue
        result = entry.get("result")
        if result == PASSING:
            continue
        if result != "skipped":
            found.append(f"{name}: {result}")
            continue
        try:
            wanted = selected(jobs[name], needs, context, jobs=jobs)
        except Unresolved as error:
            found.append(f"{name}: skipped, and its routing could not be read ({error}); "
                         "a skip nobody can explain is not a pass")
            continue
        if wanted:
            found.append(f"{name}: skipped, though its own `if:` selected it; "
                         "it never ran, so nothing stands behind this gate")
    return found


def context_from_environment(environ: dict[str, str]) -> dict[str, Any]:
    def load(name: str) -> Any:
        return json.loads(environ.get(name) or "{}") or {}

    return {
        "vars": _Vars(load("GATE_VARS")),
        "inputs": load("GATE_INPUTS"),
        "github": _Strict(load("GATE_GITHUB"), deep=True),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workflow", required=True, type=Path)
    parser.add_argument("--gate", required=True)
    parser.add_argument("--context-only", default="",
                        help="comma-separated best-effort needs read only for other needs' `if:`")
    args = parser.parse_args(argv)
    context_only = frozenset(name for name in args.context_only.split(",") if name)

    jobs = read_jobs(args.workflow.read_text())
    if args.gate not in jobs:
        print(f"no job {args.gate!r} in {args.workflow}", file=sys.stderr)
        return 1
    needs = json.loads(os.environ.get("GATE_NEEDS") or "{}")
    unknown = context_only - set(jobs[args.gate].needs)
    if unknown:
        print(f"--context-only names jobs {args.gate} does not need: {sorted(unknown)}", file=sys.stderr)
        return 1
    found = problems(jobs, args.gate, needs, context_from_environment(dict(os.environ)), context_only)
    if found:
        for line in found:
            print(f"::error::{line}")
        return 1
    for name in jobs[args.gate].needs:
        print(f"{name}: {needs[name]['result']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
