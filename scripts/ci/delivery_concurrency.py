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

# A reference that differs between two runs carrying different work: the run, the commit, or the
# build or source run a job computed or was handed. A matrix leg, a PR number or a branch name is not
# one: two commits share them (and a PR number is empty outside pull_request events).
VARYING = re.compile(
    r"github\.run_id|github\.sha\b|head_sha|github\.event\.workflow_run\.id|"
    r"(?:needs\.[\w-]+\.outputs|inputs)\.[\w-]*(?:sha|build|run_id|run)\b")
PR_ONLY_CANCEL = "${{ github.event_name == 'pull_request' }}"


def _split_top(expr: str, sep: str) -> list[str]:
    """Split an Actions expression at top-level `sep` (`||` or `&&`), outside quotes and parentheses."""
    parts, depth, quote, start, i = [], 0, False, 0, 0
    while i < len(expr):
        ch = expr[i]
        if quote:
            if ch == "'":
                if expr[i + 1:i + 2] == "'":
                    i += 2
                    continue
                quote = False
        elif ch == "'":
            quote = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0 and expr.startswith(sep, i):
            parts.append(expr[start:i])
            start = i + len(sep)
            i += len(sep)
            continue
        i += 1
    parts.append(expr[start:])
    return [p.strip() for p in parts]


def _strip_parens(expr: str) -> str:
    """Drop parentheses that wrap the whole expression."""
    expr = expr.strip()
    while expr.startswith("("):
        depth, quote, close = 0, False, -1
        for i, ch in enumerate(expr):
            if ch == "'":
                quote = not quote
            elif not quote and ch == "(":
                depth += 1
            elif not quote and ch == ")":
                depth -= 1
                if depth == 0:
                    close = i
                    break
        if close != len(expr) - 1:
            break
        expr = expr[1:-1].strip()
    return expr


def _constant_possible(expr: str) -> bool:
    """Whether some evaluation of an Actions expression yields a value with no per-run or per-payload
    reference. `a && b || c`: a true guard yields b, a false one goes on to c, and a false guard in the
    last alternative yields the guard's own (constant) false value."""
    alternatives = _split_top(_strip_parens(expr), "||")
    for index, alternative in enumerate(alternatives):
        conjuncts = _split_top(alternative, "&&")
        if _value_constant_possible(conjuncts[-1]):
            return True
        if len(conjuncts) > 1 and index == len(alternatives) - 1:
            return True
    return False


def _value_constant_possible(value: str) -> bool:
    value = _strip_parens(value)
    if len(_split_top(value, "||")) > 1 or len(_split_top(value, "&&")) > 1:
        return _constant_possible(value)
    call = re.fullmatch(r"format\((.*)\)", value, flags=re.S)
    if call:
        # format('x-{0}', a, b) is constant on a path where every argument is.
        return all(_value_constant_possible(arg) for arg in _split_top(call.group(1), ",")[1:])
    return not VARYING.search(value)


def can_be_shared(group: str) -> bool:
    """Whether two runs carrying different work can get the same group string: some path through every
    `${{ }}` part of it yields a value with no per-run or per-payload reference."""
    parts = re.findall(r"\$\{\{(.*?)\}\}", group, flags=re.S)
    return all(_constant_possible(part) for part in parts)


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
        elif in_jobs and (job_indent is None or indent == job_indent) and re.match(r"\s+[\w-]+:\s*(?:#.*)?$", line):
            job_indent, prop_indent = indent, None
            job = line.strip().split(":", 1)[0]
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
    for owner, block in concurrency_blocks(path.read_text(encoding="utf-8")):
        where = f"{path.name} {'job ' + owner if owner else 'top-level'}"
        if "unreadable" in block or "group" not in block:
            problems.append(f"{where}: concurrency this check cannot read ({block}); write group and "
                            "cancel-in-progress as plain keys")
            continue
        cancel = block.get("cancel-in-progress", "false")
        if cancel not in ("false", PR_ONLY_CANCEL):
            problems.append(f"{where}: cancel-in-progress is {cancel!r}; a delivery run is never cancelled "
                            "(only a pull_request test run may be)")
        if can_be_shared(block["group"]) and (path.name, owner) not in allowed_shared:
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
        blocks = dict(concurrency_blocks(path.read_text(encoding="utf-8"))) if path else {}
        block = blocks.get(owner)
        if not block or "group" not in block or not can_be_shared(block["group"]):
            stale.append(f"ALLOWED_SHARED names {name} {owner or 'top-level'}, which has no shared group: drop it")
    return stale
