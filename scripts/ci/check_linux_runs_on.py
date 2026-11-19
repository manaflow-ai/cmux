#!/usr/bin/env python3
"""Every own-branch Linux job runs on the one literal label `cmux-linux`.

The retro on 2026-11-19's CI day (cmuxterm-hq#14156, "capacity comes to the job"):
a Linux job's label never changes, and one always-on provider brings a runner to
it from the one pool. GitHub fixes `runs-on` when a job is queued, so a job queued
on any other Linux label waits for whatever serves that label: that day 168 jobs
waited on a label no runner carried, and the vendor runners' org vCPU cap started
almost none of the rest. Overflow is more runners on `cmux-linux`, never another
label, a repository variable or a picker job. The vendor runners stay only as the
overflow switch (scripts/ci/cloud_overflow_switch.py, ci-cloud-overflow-probe.yml),
never a default.

For each `runs-on` (and each matrix row key a `runs-on` reads: runner, os, pool,
runs_on), every value an own-branch run can take is checked. A value is refused
when it is Linux and not the literal `cmux-linux`:
  - a label naming Linux (a vendor Ubuntu size, ubuntu-*, cmux-gcp-*,
    cmux-fleet-linux-*, cmux-freestyle-*);
  - a Linux repository variable (LINUX_RUNNER, CI_TRUSTED_RUNNER, ...), read as
    the value or in a condition;
  - a RUNNER_POOLS pool whose members (.github/runners.json) are Linux labels;
  - a picker output whose name says linux (needs.X.outputs.linux_runner).

Allowed:
  - fork branches: an `&&` whose conditions say the run is not ours
    (`github.repository_owner != 'manaflow-ai'`, a fork pull request's
    `head.repo.full_name != github.repository`, `!contains(fromJSON(inputs.owned_head_repos), ...)`);
  - a literal marked `# github-hosted-required: <why>` (npm provenance, PyPI trusted
    publishing, attestations need GitHub's OIDC);
  - arm64 labels (the provider serves x86_64 only);
  - non-Linux values (macOS, Windows, owned Mac pools and gateways, picker outputs
    that do not say linux);
  - the files in ALLOWED, each with its reason.

Usage: check_linux_runs_on.py [workflow dir] (default .github/workflows). Exits 1
and prints file:line: why for each refusal.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGET = "cmux-linux"
LINUX_LABEL = re.compile(r"^(?:blacksmith-\d+vcpu-ubuntu-\d{4}|ubuntu-(?:latest|slim|\d\d\.\d\d)|cmux-gcp-[a-z0-9-]+"
                         r"|cmux-fleet-linux-[a-z0-9-]+|cmux-freestyle-linux-[a-z0-9-]+)$")
ARM = re.compile(r"(?:-arm|arm64)$")
LINUX_VARS = frozenset({"LINUX_RUNNER", "CI_TRUSTED_RUNNER", "CI_LINUX_GATE_OWNED_RUNNER", "LINUX_RUNNER_DARWIN_CROSS",
                        "NIGHTLY_NEXT_SMALL_RUNNER", "LINUX_POOL_OVERFLOW_RUNNER", "LINUX_BUILD_RUNNER"})
FORK_COND = re.compile(r"github\.repository_owner != '[^']+'|head\.repo\.full_name != github\.repository"
                       r"|!contains\(fromJSON\(inputs\.owned_head_repos\)")
HOSTED_MARK = re.compile(r"#\s*github-hosted-required:\s*\S")
MATRIX_KEYS = ("runner", "os", "pool", "runs_on")
# Workflows that keep a vendor Linux label, each with why. Nothing is added without naming what retires it.
ALLOWED = {
    "ci-cloud-overflow-probe.yml": ("the vendor overflow switch's own probe: it asks for one vendor label to learn "
                                    "whether the vendor starts jobs (scripts/ci/cloud_overflow_switch.py); kept as "
                                    "the overflow switch, never a default route"),
}

TOKEN = re.compile(r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>\d+(?:\.\d+)?)"
                   r"|(?P<op>\|\||&&|==|!=|<=|>=|<|>|!|\(|\)|\[|\]|,|\.|\*)|(?P<id>[A-Za-z_][A-Za-z0-9_-]*))")


class Unreadable(ValueError):
    pass


def tokens(text: str) -> list[tuple[str, str]]:
    out, i, text = [], 0, text.rstrip()
    while i < len(text):
        match = TOKEN.match(text, i)
        if not match or match.end() == i:
            raise Unreadable(f"cannot read the expression at {text[i:i + 20]!r}")
        out.append((match.lastgroup, match.group(match.lastgroup)))
        i = match.end()
    return out


class Parser:
    """GitHub Actions expressions: || && comparisons ! property index call literal (parenthesized)."""

    def __init__(self, text: str):
        self.toks, self.i = tokens(text), 0

    def peek(self) -> str | None:
        return self.toks[self.i][1] if self.i < len(self.toks) else None

    def take(self, want: str | None = None) -> str:
        if self.i >= len(self.toks) or (want is not None and self.toks[self.i][1] != want):
            raise Unreadable(f"expected {want!r}")
        self.i += 1
        return self.toks[self.i - 1][1]

    def parse(self):
        node = self.or_()
        if self.i != len(self.toks):
            raise Unreadable("text after the expression")
        return node

    def or_(self):
        parts = [self.and_()]
        while self.peek() == "||":
            self.take()
            parts.append(self.and_())
        return parts[0] if len(parts) == 1 else ("or", parts)

    def and_(self):
        parts = [self.compare()]
        while self.peek() == "&&":
            self.take()
            parts.append(self.compare())
        return parts[0] if len(parts) == 1 else ("and", parts)

    def compare(self):
        left = self.unary()
        if self.peek() in ("==", "!=", "<=", ">=", "<", ">"):
            op = self.take()
            return ("cmp", op, left, self.unary())
        return left

    def unary(self):
        if self.peek() == "!":
            self.take()
            return ("not", self.unary())
        node = self.primary()
        while self.peek() in (".", "["):
            if self.take() == ".":
                node = ("prop", node, self.take())
            else:
                index = self.or_()
                self.take("]")
                node = ("index", node, index)
        return node

    def primary(self):
        if self.i >= len(self.toks):
            raise Unreadable("the expression ends early")
        kind, value = self.toks[self.i]
        if value == "(":
            self.take()
            node = self.or_()
            self.take(")")
            return node
        self.take()
        if kind == "str":
            return ("str", value[1:-1].replace("''", "'"))
        if kind == "num":
            return ("num", value)
        if kind == "id" and self.peek() == "(":
            self.take()
            args = []
            if self.peek() != ")":
                args.append(self.or_())
                while self.peek() == ",":
                    self.take()
                    args.append(self.or_())
            self.take(")")
            return ("call", value, args)
        if kind == "id":
            return ("id", value)
        raise Unreadable(f"unexpected {value!r}")


def show(node) -> str:
    kind = node[0]
    if kind == "or":
        return " || ".join(show(n) for n in node[1])
    if kind == "and":
        return " && ".join(f"({show(n)})" if n[0] == "or" else show(n) for n in node[1])
    if kind == "cmp":
        return f"{show(node[2])} {node[1]} {show(node[3])}"
    if kind == "not":
        return "!" + show(node[1])
    if kind == "prop":
        return f"{show(node[1])}.{node[2]}"
    if kind == "index":
        return f"{show(node[1])}[{show(node[2])}]"
    if kind == "call":
        return f"{node[1]}({', '.join(show(a) for a in node[2])})"
    if kind == "str":
        return "'" + node[1].replace("'", "''") + "'"
    return node[1]


def dotted(node) -> str | None:
    if node[0] == "id":
        return node[1]
    if node[0] == "prop":
        base = dotted(node[1])
        return f"{base}.{node[2]}" if base else None
    return None


def own_values(node, fork: bool = False):
    """Yield (value node, under a fork branch) for every value the expression can answer."""
    kind = node[0]
    if kind == "or":
        for part in node[1]:
            yield from own_values(part, fork)
    elif kind == "and":
        conds = node[1][:-1]
        yield from own_values(node[1][-1], fork or any(FORK_COND.search(show(c)) for c in conds))
    else:
        yield node, fork


def walk(node):
    yield node
    for child in node[1:]:
        if isinstance(child, tuple):
            yield from walk(child)
        elif isinstance(child, list):
            for item in child:
                yield from walk(item)


def linux_pools(root: Path) -> set[str]:
    data = json.loads((root / ".github" / "runners.json").read_text())
    pools = data.get("pools", data)
    out = set()
    for name, pool in pools.items():
        if name.startswith("$") or not isinstance(pool, dict) or pool.get("hosted"):
            continue
        members = pool.get("members") or []
        if any(LINUX_LABEL.match(m) and not ARM.search(m) for m in members):
            out.add(name)
    return out


def value_problem(node, pools: set[str]) -> str | None:
    """Why one own-branch value is a Linux route other than cmux-linux, or None."""
    if node[0] == "str":
        label = node[1]
        if label != TARGET and LINUX_LABEL.match(label) and not ARM.search(label):
            return f"names the Linux label {label!r}"
        return None
    if node[0] == "prop" and node[1][0] == "call" and node[1][1] == "fromJSON" and node[1][2] \
            and dotted(node[1][2][0]) == "vars.RUNNER_POOLS" and node[2] in pools:
        return f"reads the Linux pool RUNNER_POOLS.{node[2]}"
    name = dotted(node) or ""
    if name.startswith("vars.") and name[5:] in LINUX_VARS:
        return f"reads {name}"
    if name.startswith("needs.") and ".outputs." in name and "linux" in name.rsplit(".", 1)[1]:
        return f"reads the Linux picker output {name}"
    return None


def expression_problems(value: str, pools: set[str]) -> list[str]:
    """Every refusal for one runs-on value (an expression or a literal)."""
    body = value.split(" #", 1)[0].strip() if not value.startswith("${{") else value
    if not value.startswith("${{"):
        label = body.strip("'\"[] ")
        if HOSTED_MARK.search(value) or label == TARGET:
            return []
        if any(LINUX_LABEL.match(part.strip("'\" ")) and not ARM.search(part.strip("'\" "))
               for part in label.split(",")):
            return [f"names the Linux label {label!r}; say runs-on: {TARGET}"]
        return []
    match = re.match(r"^\$\{\{(.*)\}\}\s*(?:#.*)?$", value)
    if not match:
        return [f"cannot read {value!r}"]
    try:
        tree = Parser(match.group(1)).parse()
    except Unreadable as error:
        return [f"cannot read the expression: {error}"]
    out = []
    for node, fork in own_values(tree):
        if fork:
            continue
        why = value_problem(node, pools)
        if why:
            out.append(f"{why}; an own-branch Linux job takes the literal '{TARGET}'")
    for node in walk(tree):
        name = dotted(node) or ""
        if name.startswith("vars.") and name[5:] in LINUX_VARS:
            out.append(f"reads {name} (a Linux route variable) in its selector; no variable picks a Linux label")
    return sorted(set(out))


def logical_lines(text: str):
    """(line number, key, value) of every runs-on and matrix row key, comments kept for markers."""
    for number, line in enumerate(text.splitlines(), start=1):
        match = re.match(r"^\s*(?:-\s+)?(runs-on|" + "|".join(MATRIX_KEYS) + r"):\s*(\S.*?)\s*$", line)
        if match:
            yield number, match.group(1), match.group(2)


def problems(workflows: Path, root: Path = ROOT) -> list[str]:
    pools = linux_pools(root)
    out = []
    for path in sorted(workflows.glob("*.y*ml")):
        if path.name in ALLOWED:
            continue
        for number, key, value in logical_lines(path.read_text()):
            if key != "runs-on" and not (value.startswith("${{") or LINUX_LABEL.match(value.split("#")[0].strip())):
                continue
            for why in expression_problems(value, pools):
                out.append(f"{path.name}:{number}: {key} {why}")
    return out


def main(argv: list[str]) -> int:
    workflows = Path(argv[1]) if len(argv) > 1 else ROOT / ".github" / "workflows"
    found = problems(workflows)
    for line in found:
        print(line)
    if found:
        print(f"{len(found)} Linux route(s) off '{TARGET}' (cmuxterm-hq#14156). next: write runs-on: {TARGET}, "
              "or keep the fork branch in front: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' "
              f"|| '{TARGET}' }}}}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
