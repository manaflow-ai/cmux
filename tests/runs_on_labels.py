"""Every runner label a `runs-on` value can resolve to in manaflow-ai, and the check that each is Linux we own.

Tests used to pin a job's whole `runs-on` expression as an exact string. Every routing tweak (a vCPU
size, the CI_CLOUD_OVERFLOW_SAVED failover) then broke them while the workflow was right: three pins went
red on one day (#26439, #26453). What those tests mean is "this job runs on Blacksmith Linux, never on a
GitHub-hosted runner or a personal machine". This module checks exactly that and nothing about size or
overflow wiring.

`resolve_labels` evaluates a GitHub Actions expression the way the runner does: `a && b` is `a` when `a`
is falsy, else `b`; `a || b` is `a` when `a` is truthy, else `b`; false, null, 0, NaN and '' are falsy.
`github.repository_owner` is fixed to 'manaflow-ai', so the fork branch
(`github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'`) drops out. A variable the caller describes
(`variables={"LINUX_RUNNER": {...}}`) takes each of those values or '', one at a time, the same value
everywhere it is read in the expression. Every other context (`vars.X`,
`github.event_name`, ...) is unknown: it may be falsy or its own unknown value, reported as its name, and
a comparison or function on an unknown may go either way. Known values compare exactly when they have the
same type; mixed types (GitHub coerces them to numbers) go either way. The result over-approximates: it
holds every label any setting of the unknowns can produce.

`disallowed_labels` names each label that is not Blacksmith Linux or a Linux label the manaflow-ai fleet
declares in .github/runners.json, with the reason. A personal machine's label is neither, so it fails like
any other label (tests/test_runs_on_labels.py mutates a workflow onto one to prove it). An unknown value,
a falsy value and a runs-on with no label at all are refused too: none of them is known to schedule on
Blacksmith Linux.
"""
from __future__ import annotations

import itertools
import json
import math
import re
from collections.abc import Iterable, Mapping
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OWNER = "manaflow-ai"

# Blacksmith Linux, any size, x86_64 or arm: blacksmith-4vcpu-ubuntu-2404, blacksmith-16vcpu-ubuntu-2404-arm.
BLACKSMITH_LINUX = re.compile(r"blacksmith-[0-9]+vcpu-ubuntu-[0-9]{4}(?:-arm)?")
# GitHub-hosted images: ubuntu-24.04, ubuntu-latest, ubuntu-slim, macos-26, macos-15-intel, windows-2022, ...
# Any label of these families, so a new image name is refused before anyone has to list it.
GITHUB_HOSTED = re.compile(r"(?:ubuntu|macos|windows)(?:-.*)?")
# What scripts/ci/cloud_overflow_switch.py points LINUX_RUNNER at while Blacksmith is down (HOSTED_LINUX).
OVERFLOW_HOSTED_LINUX = "ubuntu-24.04"

TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<op>&&|\|\||==|!=|<=|>=|[!(),<>])"
    r"|(?P<num>-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)|(?P<ident>[A-Za-z_][A-Za-z0-9_.*-]*))"
)


class Unknown:
    """A context's value we cannot know (vars.X, matrix.y): any non-empty string, reported by its name.

    Not a str: it never equals, or hashes like, a literal that happens to spell its name.
    """

    __slots__ = ("name",)

    def __init__(self, name: str):
        self.name = name

    def __eq__(self, other) -> bool:
        return isinstance(other, Unknown) and other.name == self.name

    def __hash__(self) -> int:
        return hash((Unknown, self.name))

    def __str__(self) -> str:
        return self.name

    __repr__ = __str__


EMPTY = ""
NULL = None


def _tokens(text: str) -> list[tuple[str, str]]:
    out, pos = [], 0
    text = text.strip()
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match or match.end() == pos:
            raise ValueError(f"cannot read the expression at {text[pos:]!r}")
        kind = match.lastgroup
        out.append((kind, match.group(kind)))
        pos = match.end()
    return out


class _Parser:
    def __init__(self, text: str):
        self.tokens = _tokens(text)
        self.at = 0

    def peek(self) -> tuple[str, str] | None:
        return self.tokens[self.at] if self.at < len(self.tokens) else None

    def take(self, value: str | None = None) -> tuple[str, str]:
        token = self.peek()
        if token is None or (value is not None and token[1] != value):
            raise ValueError(f"expected {value!r}, found {token!r}")
        self.at += 1
        return token

    def parse(self):
        node = self.or_()
        if self.peek() is not None:
            raise ValueError(f"unexpected {self.peek()!r}")
        return node

    def or_(self):
        node = self.and_()
        while self.peek() == ("op", "||"):
            self.take()
            node = ("or", node, self.and_())
        return node

    def and_(self):
        node = self.compare()
        while self.peek() == ("op", "&&"):
            self.take()
            node = ("and", node, self.compare())
        return node

    def compare(self):
        # Equality binds looser than the relational operators, as in GitHub's grammar.
        node = self.relational()
        while self.peek() and self.peek()[0] == "op" and self.peek()[1] in {"==", "!="}:
            op = self.take()[1]
            node = ("cmp", op, node, self.relational())
        return node

    def relational(self):
        node = self.unary()
        while self.peek() and self.peek()[0] == "op" and self.peek()[1] in {"<", ">", "<=", ">="}:
            op = self.take()[1]
            node = ("cmp", op, node, self.unary())
        return node

    def unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return ("not", self.unary())
        return self.primary()

    def primary(self):
        kind, value = self.take()
        if kind == "str":
            return ("lit", value[1:-1].replace("''", "'"))
        if kind == "num":
            return ("lit", float(value))
        if value == "(":
            node = self.or_()
            self.take(")")
            return node
        if kind == "ident":
            if value in {"true", "false"}:
                return ("lit", value == "true")
            if value == "null":
                return ("lit", NULL)
            if self.peek() == ("op", "("):
                self.take()
                args = []
                while self.peek() != ("op", ")"):
                    args.append(self.or_())
                    if self.peek() == ("op", ","):
                        self.take()
                self.take(")")
                return ("call", value.lower(), args)
            return ("ctx", value)
        raise ValueError(f"unexpected {value!r}")


def _truthy(value) -> bool:
    if value is NULL or value is False:
        return False
    if isinstance(value, float):
        return value != 0 and not math.isnan(value)
    return value != EMPTY


def _known(value) -> bool:
    return not isinstance(value, Unknown)


def _kind(value) -> type:
    return type(None) if value is NULL else (str if isinstance(value, str) else type(value))


def _compare(op: str, left, right) -> set:
    if not (_known(left) and _known(right)) or _kind(left) is not _kind(right):
        # An unknown, or a pair GitHub coerces to numbers first: either outcome.
        return {True, False}
    if left is NULL:
        result = {"==": True, "!=": False}.get(op)
        return {True, False} if result is None else {result}
    if isinstance(left, str):
        left, right = left.lower(), right.lower()
    return {{"==": left == right, "!=": left != right, "<": left < right, ">": left > right,
             "<=": left <= right, ">=": left >= right}[op]}


def _call(name: str, args: list[set]) -> set:
    if name in {"contains", "startswith", "endswith"} and len(args) == 2:
        out = set()
        for haystack in args[0]:
            for needle in args[1]:
                if not (isinstance(haystack, str) and isinstance(needle, str)):
                    out |= {True, False}
                    continue
                haystack_l, needle_l = haystack.lower(), needle.lower()
                out.add(needle_l in haystack_l if name == "contains"
                        else haystack_l.startswith(needle_l) if name == "startswith"
                        else haystack_l.endswith(needle_l))
        return out
    if name in {"contains", "startswith", "endswith", "success", "failure", "always", "cancelled"}:
        return {True, False}
    # format(), fromJSON(), join(), toJSON(), hashFiles(): an unknown value, possibly falsy.
    return {EMPTY, NULL, False, 0.0, Unknown(f"{name}(...)")}


class _Evaluator:
    def __init__(self, owner: str, variables: Mapping[str, str], silent: tuple[str, ...] = ()):
        # One value per described variable: a variable reads the same everywhere in one evaluation.
        self.owner = owner
        self.variables = {f"vars.{name}": {value} for name, value in variables.items()}
        # Context roots (needs, inputs, ...) read as '' only: every picker answered nothing.
        self.silent = silent

    def __call__(self, node) -> set:
        kind = node[0]
        if kind == "lit":
            return {node[1]}
        if kind == "ctx":
            if node[1] == "github.repository_owner":
                return {self.owner}
            if node[1] in self.variables:
                return set(self.variables[node[1]])
            if node[1].split(".", 1)[0] in self.silent:
                return {EMPTY}
            return {EMPTY, NULL, False, 0.0, Unknown(node[1])}
        if kind == "not":
            return {not _truthy(value) for value in self(node[1])}
        if kind == "and":
            out = set()
            for left in self(node[1]):
                out |= {left} if not _truthy(left) else self(node[2])
            return out
        if kind == "or":
            out = set()
            for left in self(node[1]):
                out |= {left} if _truthy(left) else self(node[2])
            return out
        if kind == "cmp":
            out = set()
            for left in self(node[2]):
                for right in self(node[3]):
                    out |= _compare(node[1], left, right)
            return out
        if kind == "call":
            return _call(node[1], [self(arg) for arg in node[2]])
        raise ValueError(f"unknown node {node!r}")


def resolve_labels(runs_on, owner: str = OWNER, variables: Mapping[str, Iterable[str]] | None = None,
                   silent: Iterable[str] = ()) -> set:
    """Every label `runs_on` (a string, an expression or a list of them) can select for `owner`.

    `variables` gives the values a repository variable can hold (it may also be unset, '');
    any other variable is unknown. A context whose root is in `silent` (`needs`, `inputs`, ...)
    reads as '' only: the labels a job gets when every picker before it answered nothing.
    """
    variables = variables or {}
    silent = tuple(silent)
    if isinstance(runs_on, list):
        out = set()
        for item in runs_on:
            out |= resolve_labels(item, owner, variables, silent)
        return out
    if isinstance(runs_on, dict):
        raise ValueError(f"runs-on group/labels mappings are not modelled: {runs_on!r}")
    text = str(runs_on).strip()
    whole = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.DOTALL)
    if whole is None:
        if "${{" in text:
            raise ValueError(f"runs-on mixes text and an expression: {text!r}")
        return {text}
    tree = _Parser(whole.group(1)).parse()
    names = sorted(variables)
    choices = [sorted({EMPTY, *variables[name]}) for name in names]
    out = set()
    for values in itertools.product(*choices):
        out |= _Evaluator(owner, dict(zip(names, values)), silent)(tree)
    return out


def declared_fleet_linux_labels(root: Path = ROOT) -> set[str]:
    """The Linux labels the manaflow-ai fleet declares in .github/runners.json."""
    runners = json.loads((root / ".github/runners.json").read_text(encoding="utf-8"))
    fleet = runners["fleets"][runners["owners"][OWNER]]
    return {label for capability, label in fleet.items() if capability.startswith("linux")}


def linux_runner_values(root: Path = ROOT) -> set[str]:
    """What LINUX_RUNNER can hold: a declared fleet Linux label, or the overflow switch's hosted Linux."""
    return declared_fleet_linux_labels(root) | {OVERFLOW_HOSTED_LINUX}


def personal_machine_names() -> tuple[str, ...]:
    """The personal workstation's names, from the fleet rule lint: the one file allowed to spell them."""
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from test_ci_fleet_rule_lints import CANDIDATE_WORDS_ANY_CASE
    return tuple(word.lower() for word in CANDIDATE_WORDS_ANY_CASE)


def disallowed_labels(runs_on, variables: Mapping[str, Iterable[str]] | None = None,
                      root: Path = ROOT) -> dict[str, str]:
    """label -> why it may not run this job; empty when every label is Blacksmith or declared fleet Linux.

    GitHub-hosted labels and the personal workstation are refused first, even if a fleet declares them.
    """
    fleet_linux = declared_fleet_linux_labels(root)
    personal = personal_machine_names()
    labels = resolve_labels(runs_on, variables=variables)
    if not labels:
        return {"[]": "no label at all: an empty runs-on never schedules"}
    bad = {}
    for label in labels:
        if isinstance(label, Unknown):
            bad[str(label)] = "an unknown value: nothing proves it is Blacksmith Linux"
        elif not isinstance(label, str) or label == EMPTY:
            bad[repr(label)] = "a falsy or non-label value: it never schedules"
        elif GITHUB_HOSTED.fullmatch(label.lower()):
            bad[label] = "a GitHub-hosted runner outside the fork branch"
        elif any(name in label.lower() for name in personal):
            bad[label] = "a personal machine, never a runner"
        elif not (BLACKSMITH_LINUX.fullmatch(label) or label in fleet_linux):
            bad[label] = "neither Blacksmith Linux nor a declared manaflow-ai fleet Linux label"
    return bad
