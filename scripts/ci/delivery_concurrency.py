"""Delivery workflows never evict or cancel a waiting delivery run.

GitHub keeps one running and one pending run per concurrency group: a newer run replaces (cancels) the
pending one, and `cancel-in-progress: true` also cancels the running one. A delivery workflow (a
nightly, DEV, promote or release build or publication) whose group is the same string for two
different runs therefore drops queued deliveries, and a newer tip waits behind a running build
instead of building beside it. Standing rule (Leo, 2026-10-23/24): never cancel a nightly, dev or
promote build once it has started; a newer tip builds alongside a running one, and a run publishes
only when it is newer than what the feed already has.

So in a delivery workflow every concurrency group, top-level or job-level, must be keyed per run or
per payload (run id, SHA, build, source run) on every path, and cancel-in-progress is never true
(only `github.event_name == 'pull_request'`, for a PR's test run, which delivers nothing). A shared
group is allowed only where every run that can wait in it is interchangeable (a schedule or input-less
dispatch that reads the current tip when it starts, so the newest pending run does all the work an
evicted one would have); each such group is declared in ALLOWED_SHARED with its reason.

This file is the canonical copy. manaflow-ai/cmuxterm-hq (tests/delivery_concurrency.py) and
teamleaderleo/glaeda (scripts/delivery_concurrency.py) carry byte-identical copies, each read by that
repo's own test over its own delivery workflows; change all three together. It needs no PyYAML.
"""

from __future__ import annotations

import re
from pathlib import Path

# A per-run or per-payload identity: a reference whose value differs between two runs carrying different
# work (the run, the commit, or the build or source run a job computed or was handed). A matrix leg, a PR
# number or a branch name is not one: two commits share them, and a PR number is empty outside
# pull_request events. A job output named for a sha, build or run is taken to be set; an input so named
# is set only when the workflow declares it `required: true`, and may be empty otherwise.
IDENTITY = re.compile(
    r"github\.(?:run_id|run_number|sha)|github\.event\.workflow_run\.(?:id|head_sha)|[\w.-]*\.head_sha|"
    r"(?:needs\.[\w-]+\.outputs|inputs|github\.event\.inputs)\.[\w-]*(?:sha|build|run_id|run)")
INPUT = re.compile(r"(?:inputs|github\.event\.inputs)\.([\w-]+)")
PR_ONLY_CANCEL = "${{ github.event_name == 'pull_request' }}"

# What an expression can evaluate to: an identity (always truthy), a constant truthy value, or a falsy one.
VARY, CONST, FALSY = "vary", "const", "falsy"
_TOKEN = re.compile(r"\s*(?:('(?:[^']|'')*')|(\d+(?:\.\d+)?)|(==|!=|<=|>=|&&|\|\||[()<>!,])|([A-Za-z_][\w.\-\[\]'*]*))")


class _Unreadable(ValueError):
    pass


def _tokens(expr: str) -> list[tuple[str, str]]:
    out, i = [], 0
    while i < len(expr):
        if not expr[i:].strip():
            break
        match = _TOKEN.match(expr, i)
        if not match:
            raise _Unreadable(expr)
        string, number, op, name = match.groups()
        out.append(("str", string[1:-1].replace("''", "'")) if string is not None else ("num", number)
                   if number is not None else ("op", op) if op is not None else ("name", name))
        i = match.end()
    return out


class _Parser:
    def __init__(self, expr: str, required: frozenset[str] = frozenset()):
        self.tokens, self.at, self.required = _tokens(expr), 0, required

    def peek(self) -> tuple[str, str] | None:
        return self.tokens[self.at] if self.at < len(self.tokens) else None

    def take(self, op: str | None = None) -> tuple[str, str]:
        token = self.peek()
        if token is None or (op is not None and token != ("op", op)):
            raise _Unreadable(f"expected {op or 'a value'}")
        self.at += 1
        return token

    def parse(self) -> set[str]:
        kinds = self.or_()
        if self.peek() is not None:
            raise _Unreadable("trailing tokens")
        return kinds

    def or_(self) -> set[str]:
        kinds = self.and_()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.and_()
            kinds = (kinds - {FALSY}) | (right if FALSY in kinds else set())
        return kinds

    def and_(self) -> set[str]:
        kinds = self.compare()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.compare()
            kinds = ({FALSY} & kinds) | (right if kinds - {FALSY} else set())
        return kinds

    def compare(self) -> set[str]:
        kinds = self.unary()
        while self.peek() in {("op", o) for o in ("==", "!=", "<", "<=", ">", ">=")}:
            self.take()
            self.unary()
            kinds = {CONST, FALSY}
        return kinds

    def unary(self) -> set[str]:
        if self.peek() == ("op", "!"):
            self.take()
            self.unary()
            return {CONST, FALSY}
        return self.primary()

    def primary(self) -> set[str]:
        kind, value = self.take()
        if kind == "op" and value == "(":
            kinds = self.or_()
            self.take(")")
            return kinds
        if kind == "str":
            return {CONST} if value else {FALSY}
        if kind == "num":
            return {FALSY} if float(value) == 0 else {CONST}
        if kind != "name":
            raise _Unreadable(value)
        if self.peek() == ("op", "("):
            return self.call(value)
        if value in ("true",):
            return {CONST}
        if value in ("false", "null"):
            return {FALSY}
        if not IDENTITY.fullmatch(value):
            return {CONST, FALSY}
        name = INPUT.fullmatch(value)
        return {VARY} if name is None or name.group(1) in self.required else {VARY, FALSY}

    def call(self, name: str) -> set[str]:
        self.take("(")
        args: list[tuple[set[str], tuple[str, str] | None]] = []
        if self.peek() != ("op", ")"):
            while True:
                first = self.peek()
                start = self.at
                kinds = self.or_()
                args.append((kinds, first if self.at == start + 1 else None))
                if self.peek() == ("op", ","):
                    self.take()
                    continue
                break
        self.take(")")
        if name.lower() != "format" or not args or args[0][1] is None or args[0][1][0] != "str":
            return {CONST, FALSY}  # another function, or a computed format string: no identity assumed
        used = {int(n) for n in re.findall(r"(?<!\{)\{(\d+)\}", args[0][1][1])}
        referenced = [args[n + 1][0] for n in used if n + 1 < len(args)]
        kinds = set()
        if any(VARY in k for k in referenced):
            kinds.add(VARY)
        if all(k - {VARY} for k in referenced):
            kinds.add(CONST)
        return kinds


def required_inputs(text: str) -> frozenset[str]:
    """Names of the workflow's inputs declared `required: true` (workflow_dispatch and workflow_call)."""
    names, lines = set(), text.splitlines()
    for index, line in enumerate(lines):
        block = re.match(r"(\s+)inputs:\s*(?:#.*)?$", line)
        if not block:
            continue
        base, child, current = len(block.group(1)), None, None
        for follow in lines[index + 1:]:
            if not follow.strip() or follow.lstrip().startswith("#"):
                continue
            indent = len(follow) - len(follow.lstrip(" "))
            if indent <= base:
                break
            if child is None:
                child = indent
            if indent == child:
                current = follow.strip().split(":", 1)[0].strip("'\"")
            elif current and re.fullmatch(r"\s*required:\s*true\s*(?:#.*)?", follow):
                names.add(current)
    return frozenset(names)


def can_be_shared(group: str, required: frozenset[str] = frozenset()) -> bool:
    """Whether two runs carrying different work can get the same group string: every `${{ }}` part of it
    can evaluate to something other than a per-run or per-payload identity. `required` names the inputs
    the workflow requires. An expression this reader cannot parse counts as shared."""
    for part in re.findall(r"\$\{\{(.*?)\}\}", group, flags=re.S):
        try:
            kinds = _Parser(part, required).parse()
        except _Unreadable:
            continue
        if not kinds - {VARY}:
            return False
    return True


def _scalar(value: str) -> str:
    value = value.strip()
    if value.startswith("#"):
        return ""
    value = re.sub(r"\s+#.*$", "", value) if not value.startswith(("'", '"')) else value
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        value = value[1:-1]
    return value


def concurrency_blocks(text: str) -> list[tuple[str, dict[str, str]]]:
    """(owner, {group, cancel-in-progress}) for the workflow's top-level block (owner "") and each job's
    (owner: the job id). A form this reader does not know is returned as {"unreadable": line}."""
    lines = text.splitlines()
    blocks: list[tuple[str, dict[str, str]]] = []
    # The indent of job ids under `jobs:`, and of the current job's own keys (whatever the file uses).
    in_jobs, job, job_indent, prop_indent = False, "", None, None
    for index, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_jobs = line.startswith("jobs:")
            job, job_indent, prop_indent = "", None, None
        elif in_jobs and (job_indent is None or indent == job_indent) and re.match(r"\s+(?:[\w-]+|'[\w-]+'|\"[\w-]+\"):\s*(?:#.*)?$", line):
            job_indent, prop_indent = indent, None
            job = line.strip().split(":", 1)[0].strip("'\"")
            continue
        elif in_jobs and job and prop_indent is None and job_indent is not None and indent > job_indent:
            prop_indent = indent
        match = re.match(r"(\s*)concurrency:(.*)$", line)
        if not match:
            continue
        own = len(match.group(1))
        if own == 0:
            owner = ""
        elif in_jobs and job and own == prop_indent:
            owner = job
        else:
            continue  # an input or step field named concurrency, not a group
        rest = _scalar(match.group(2))
        if rest:
            if rest.startswith("{"):
                blocks.append((owner, {"unreadable": line.strip()}))
            else:
                blocks.append((owner, {"group": rest, "cancel-in-progress": "false"}))
            continue
        fields: dict[str, str] = {}
        for follow in lines[index + 1:]:
            if not follow.strip() or follow.lstrip().startswith("#"):
                continue
            if len(follow) - len(follow.lstrip(" ")) <= own:
                break
            key, _, value = follow.strip().partition(":")
            if key in ("group", "cancel-in-progress"):
                if _scalar(value) in ("|", ">", "|-", ">-"):
                    fields["unreadable"] = follow.strip()
                fields[key] = _scalar(value)
        blocks.append((owner, fields))
    return blocks


def findings(path: Path, allowed_shared: dict[tuple[str, str], str]) -> list[str]:
    """What is wrong with one delivery workflow; allowed_shared maps (file name, owner) to its reason."""
    problems = []
    text = path.read_text(encoding="utf-8")
    required = required_inputs(text)
    for owner, block in concurrency_blocks(text):
        where = f"{path.name} {'job ' + owner if owner else 'top-level'}"
        if "unreadable" in block or "group" not in block:
            problems.append(f"{where}: concurrency this check cannot read ({block}); write group and "
                            "cancel-in-progress as plain keys")
            continue
        cancel = block.get("cancel-in-progress", "false")
        if cancel not in ("false", PR_ONLY_CANCEL):
            problems.append(f"{where}: cancel-in-progress is {cancel!r}; a delivery run is never cancelled "
                            "(only a pull_request test run may be)")
        if can_be_shared(block["group"], required) and (path.name, owner) not in allowed_shared:
            problems.append(
                f"{where}: group {block['group']!r} can be the same for two runs carrying different work, so "
                "GitHub would replace a waiting one; key it per run or per SHA/build (or drop it), or declare "
                "it in ALLOWED_SHARED if every run that can wait in it is interchangeable")
    return problems


def matching(folder: Path, patterns: tuple[str, ...]) -> list[Path]:
    """Workflow files in folder whose name matches a pattern, as .yml or .yaml."""
    found = set()
    for pattern in patterns:
        stem = pattern[:-4] if pattern.endswith(".yml") else pattern
        for suffix in (".yml", ".yaml"):
            found.update(folder.glob(stem + suffix))
    return sorted(found)


def stale_allowances(workflows: list[Path], allowed_shared: dict[tuple[str, str], str]) -> list[str]:
    """ALLOWED_SHARED entries that no longer name a shared group in a delivery workflow."""
    by_name = {path.name: path for path in workflows}
    stale = []
    for name, owner in allowed_shared:
        path = by_name.get(name)
        text = path.read_text(encoding="utf-8") if path else ""
        block = dict(concurrency_blocks(text)).get(owner)
        if not block or "group" not in block or not can_be_shared(block["group"], required_inputs(text)):
            stale.append(f"ALLOWED_SHARED names {name} {owner or 'top-level'}, which has no shared group: drop it")
    return stale
