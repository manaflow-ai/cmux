"""Every runner label a `runs-on` value can resolve to in manaflow-ai, and the check that each is Linux we own.

Tests used to pin a job's whole `runs-on` expression as an exact string. Every routing tweak (a vCPU
size, the CI_CLOUD_OVERFLOW_SAVED failover) then broke them while the workflow was right: three pins went
red on one day (#26439, #26453). What those tests mean is "this job runs on Blacksmith Linux, never on a
GitHub-hosted runner or a personal machine". This module checks exactly that and nothing about size or
overflow wiring.

`resolve_labels` evaluates a GitHub Actions expression the way the runner does (`a && b` is `a` when `a`
is falsy, else `b`; `a || b` is `a` when `a` is truthy, else `b`), with `github.repository_owner` fixed
to 'manaflow-ai', so the fork branch (`github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'`)
drops out. Every other context (`vars.X`, `github.event_name`, ...) is unknown: a comparison or
`contains()` on it may be true or false, and a context used as a value may be empty or may be its own
unknown value, reported as `vars.X`. The result over-approximates: it holds every label any setting of
those unknowns can produce.

`disallowed_labels` names each label that is not Blacksmith Linux or a Linux label the manaflow-ai
fleet declares in .github/runners.json, with the reason. A personal machine's label is neither, so it fails
like any other label (tests/test_runs_on_labels.py mutates a workflow onto one to prove it). An empty result is a falsy value (an empty
runs-on never schedules). An unknown variable is refused unless the caller allows it by name.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OWNER = "manaflow-ai"

# Blacksmith Linux, any size, x86_64 or arm: blacksmith-4vcpu-ubuntu-2404, blacksmith-16vcpu-ubuntu-2404-arm.
BLACKSMITH_LINUX = re.compile(r"blacksmith-[0-9]+vcpu-ubuntu-[0-9]{4}(?:-arm)?")
# GitHub-hosted images: ubuntu-24.04, ubuntu-latest, macos-26, macos-15-intel, windows-2022, ...
GITHUB_HOSTED = re.compile(r"(?:ubuntu|macos|windows)-(?:latest|[0-9][0-9.]*)(?:-[a-z0-9]+)*")

TOKEN = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<op>&&|\|\||==|!=|<=|>=|[!(),<>])"
    r"|(?P<num>-?[0-9]+(?:\.[0-9]+)?)|(?P<ident>[A-Za-z_][A-Za-z0-9_.*\[\]'-]*))"
)


class Unknown(str):
    """A context's value we cannot know (vars.X, matrix.y); truthy, reported by its name."""


EMPTY = ""


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
        node = self.unary()
        while self.peek() and self.peek()[0] == "op" and self.peek()[1] in {"==", "!=", "<", ">", "<=", ">="}:
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
            return ("lit", value)
        if value == "(":
            node = self.or_()
            self.take(")")
            return node
        if kind == "ident":
            if value in {"true", "false"}:
                return ("bool", value == "true")
            if value == "null":
                return ("lit", EMPTY)
            if self.peek() == ("op", "("):
                self.take()
                args = []
                while self.peek() != ("op", ")"):
                    args.append(self.or_())
                    if self.peek() == ("op", ","):
                        self.take()
                self.take(")")
                return ("call", value, args)
            return ("ctx", value)
        raise ValueError(f"unexpected {value!r}")


def _truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    return value != EMPTY


def _evaluate(node, owner: str) -> set:
    kind = node[0]
    if kind == "lit":
        return {node[1]}
    if kind == "bool":
        return {node[1]}
    if kind == "ctx":
        if node[1] == "github.repository_owner":
            return {owner}
        return {EMPTY, Unknown(node[1])}
    if kind == "not":
        return {not _truthy(value) for value in _evaluate(node[1], owner)}
    if kind == "and":
        out = set()
        for left in _evaluate(node[1], owner):
            out |= {left} if not _truthy(left) else _evaluate(node[2], owner)
        return out
    if kind == "or":
        out = set()
        for left in _evaluate(node[1], owner):
            out |= {left} if _truthy(left) else _evaluate(node[2], owner)
        return out
    if kind == "cmp":
        op, lefts, rights = node[1], _evaluate(node[2], owner), _evaluate(node[3], owner)
        out = set()
        for left in lefts:
            for right in rights:
                known = not isinstance(left, Unknown) and not isinstance(right, Unknown)
                if known and op in {"==", "!="}:
                    same = str(left).lower() == str(right).lower() and type(left) is type(right)
                    out.add(same if op == "==" else not same)
                else:
                    out |= {True, False}
        return out
    if kind == "call":
        # contains(), startsWith(), format(), fromJSON(), ...: the result is not worth modelling here.
        # A boolean function may go either way; a value-returning one is an unknown value.
        name = node[1]
        if name in {"contains", "startsWith", "endsWith", "success", "failure", "always", "cancelled"}:
            return {True, False}
        return {EMPTY, Unknown(f"{name}(...)")}
    raise ValueError(f"unknown node {node!r}")


def resolve_labels(runs_on, owner: str = OWNER) -> set:
    """Every label `runs_on` (a string, an expression or a list of them) can select for `owner`."""
    if isinstance(runs_on, list):
        out = set()
        for item in runs_on:
            out |= resolve_labels(item, owner)
        return out
    if isinstance(runs_on, dict):
        raise ValueError(f"runs-on group/labels mappings are not modelled: {runs_on!r}")
    text = str(runs_on).strip()
    whole = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.DOTALL)
    if whole is None:
        if "${{" in text:
            raise ValueError(f"runs-on mixes text and an expression: {text!r}")
        return {text}
    return _evaluate(_Parser(whole.group(1)).parse(), owner)


def declared_fleet_linux_labels(root: Path = ROOT) -> set[str]:
    """The Linux labels the manaflow-ai fleet declares in .github/runners.json."""
    runners = json.loads((root / ".github/runners.json").read_text(encoding="utf-8"))
    fleet = runners["fleets"][runners["owners"][OWNER]]
    return {label for capability, label in fleet.items() if capability.startswith("linux")}


def disallowed_labels(runs_on, allow_vars: frozenset[str] = frozenset(), root: Path = ROOT) -> dict[str, str]:
    """label -> why it may not run this job; empty when every label is Blacksmith or declared fleet Linux."""
    fleet_linux = declared_fleet_linux_labels(root)
    bad = {}
    for label in resolve_labels(runs_on):
        if isinstance(label, Unknown):
            if str(label) not in {f"vars.{name}" for name in allow_vars}:
                bad[str(label)] = "an unknown value: nothing proves it is Blacksmith Linux"
        elif isinstance(label, bool) or label == EMPTY:
            bad[repr(label)] = "a falsy value: an empty runs-on never schedules"
        elif GITHUB_HOSTED.fullmatch(label):
            bad[label] = "a GitHub-hosted runner outside the fork branch"
        elif not (BLACKSMITH_LINUX.fullmatch(label) or label in fleet_linux):
            bad[label] = "neither Blacksmith Linux nor a declared manaflow-ai fleet Linux label"
    return bad
