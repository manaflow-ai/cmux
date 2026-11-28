#!/usr/bin/env python3
"""Reject local reusable-workflow calls whose callee asks for more than the caller grants.

GitHub resolves ``jobs.<id>.uses: ./.github/workflows/<file>`` while it parses the *caller*
workflow. The called workflow's ``permissions`` (its workflow-level block and every job-level
block, whether or not the job is gated by ``if:``) may only keep or reduce what the calling job
grants. Any scope that asks for more fails the caller before a single job starts::

    Invalid workflow file: ... is requesting 'actions: write', but is only allowed 'actions: none'.

That is a ``startup_failure``: no job runs, and a tag push fails exactly like a manual dispatch.
https://github.com/manaflow-ai/cmux/issues/12149 blocked the stable macOS release this way after
``release.yml`` started calling ``ios-screenshots.yml``.

Rules mirrored here (https://docs.github.com/en/actions/how-tos/sharing-automations/reuse-workflows:
"permissions can only be maintained or reduced, not elevated, throughout the chain"):

* The calling job's grant is its own ``permissions`` block, else the caller workflow's block, else
  the repository default (``--default-workflow-permissions``). A declared block sets every unlisted
  scope to ``none``; ``metadata: read`` is always granted; the default never grants ``id-token``.
* The callee's request is the per-scope maximum over its workflow-level block and every job-level
  block. A callee that declares no ``permissions`` anywhere inherits the caller's grant.
* Nested calls are checked with the intermediate job's grant.
* Only ``./.github/workflows/...`` callees are checked; cross-repository callees cannot be read here.

No third-party modules: workflow files are read with a small YAML-subset reader that understands
the block shapes GitHub Actions accepts (block scalars, indentless sequences, flow mappings, quoted
keys, comments). Sequences stay opaque because nothing under ``steps`` matters to this check.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Union

LEVELS = {"none": 0, "read": 1, "write": 2}
LEVEL_NAMES = {value: name for name, value in LEVELS.items()}

# https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#permissions
SCOPES = (
    "actions",
    "attestations",
    "checks",
    "contents",
    "deployments",
    "discussions",
    "id-token",
    "issues",
    "metadata",
    "models",
    "packages",
    "pages",
    "pull-requests",
    "repository-projects",
    "security-events",
    "statuses",
)

LOCAL_USES_PREFIX = "./.github/workflows/"

Permissions = dict[str, int]


class WorkflowSyntaxError(ValueError):
    """A workflow file uses a shape this reader (or GitHub) does not accept."""


# --------------------------------------------------------------------------------------
# YAML subset reader
# --------------------------------------------------------------------------------------


@dataclass(frozen=True)
class BlockScalar:
    """Opaque ``|`` / ``>`` scalar; its text never matters to the permission check."""

    indicator: str


@dataclass(frozen=True)
class _Line:
    number: int
    indent: int
    text: str


def _split_lines(text: str) -> list[_Line]:
    lines: list[_Line] = []
    for number, raw in enumerate(text.splitlines(), start=1):
        raw = raw.rstrip("\r")
        stripped = raw.lstrip(" ")
        lines.append(_Line(number, len(raw) - len(stripped), stripped.rstrip()))
    return lines


def _is_insignificant(line: _Line) -> bool:
    text = line.text
    if not text or text.startswith("#"):
        return True
    if line.indent == 0 and (text == "---" or text.startswith("--- ") or text == "..." or text.startswith("%")):
        return True
    return False


def _is_sequence_item(text: str) -> bool:
    return text == "-" or text.startswith("- ")


def _strip_inline_comment(value: str) -> str:
    quote: Optional[str] = None
    for index, char in enumerate(value):
        if quote:
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
        elif char == "#" and (index == 0 or value[index - 1] in " \t"):
            return value[:index].rstrip()
    return value.rstrip()


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        inner = value[1:-1]
        return inner.replace("''", "'") if value[0] == "'" else inner.replace('\\"', '"')
    return value


def _split_key(text: str) -> Optional[tuple[str, str]]:
    """Split ``key: rest`` at the first unquoted ``:`` followed by whitespace or end of line."""
    quote: Optional[str] = None
    for index, char in enumerate(text):
        if quote:
            if char == quote:
                quote = None
            continue
        if index == 0 and char in ("'", '"'):
            quote = char
            continue
        if char == ":" and (index + 1 == len(text) or text[index + 1] in " \t"):
            return _unquote(text[:index]), text[index + 1 :].strip()
    return None


def _split_flow_items(body: str) -> list[str]:
    items: list[str] = []
    depth = 0
    quote: Optional[str] = None
    current: list[str] = []
    for char in body:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
        elif char in "{[":
            depth += 1
        elif char in "}]":
            depth -= 1
        elif char == "," and depth == 0:
            items.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    tail = "".join(current).strip()
    if tail:
        items.append(tail)
    return [item for item in items if item]


class _Reader:
    def __init__(self, text: str, name: str) -> None:
        self.lines = _split_lines(text)
        self.index = 0
        self.name = name

    # -- cursor helpers -------------------------------------------------------------

    def _skip_insignificant(self) -> Optional[_Line]:
        while self.index < len(self.lines) and _is_insignificant(self.lines[self.index]):
            self.index += 1
        return self.lines[self.index] if self.index < len(self.lines) else None

    def _consume_deeper(self, indent: int) -> None:
        """Swallow continuation lines (block scalar text, wrapped plain scalars, nested comments)."""
        while self.index < len(self.lines):
            line = self.lines[self.index]
            if line.text == "" or line.indent > indent:
                self.index += 1
                continue
            return

    # -- structures -----------------------------------------------------------------

    def parse_document(self) -> dict:
        first = self._skip_insignificant()
        if first is None:
            return {}
        if _is_sequence_item(first.text):
            raise WorkflowSyntaxError(f"{self.name}: workflow root must be a mapping")
        return self.parse_mapping(first.indent)

    def parse_mapping(self, indent: int) -> dict:
        mapping: dict = {}
        while True:
            line = self._skip_insignificant()
            if line is None or line.indent < indent:
                return mapping
            if line.indent > indent or _is_sequence_item(line.text):
                if line.indent == indent:
                    # An indentless sequence belongs to the parent key, not to this mapping.
                    return mapping
                # Stray deeper content (a wrapped scalar we could not attribute); skip it.
                self.index += 1
                continue
            split = _split_key(line.text)
            self.index += 1
            if split is None:
                continue
            key, rest = split
            mapping[key] = self._parse_value(rest, indent)

    def parse_sequence(self, indent: int) -> list[str]:
        """Opaque sequence: returns the first line of every item, nothing nested."""
        items: list[str] = []
        while self.index < len(self.lines):
            line = self.lines[self.index]
            if line.text == "" or line.indent > indent:
                self.index += 1
                continue
            if line.indent == indent and _is_sequence_item(line.text):
                items.append(_unquote(_strip_inline_comment(line.text[1:].strip())))
                self.index += 1
                continue
            if line.indent == indent and line.text.startswith("#"):
                self.index += 1
                continue
            return items
        return items

    def _parse_value(self, rest: str, indent: int) -> Union[None, str, dict, list, BlockScalar]:
        value = _strip_inline_comment(rest)
        if value == "":
            nxt = self._skip_insignificant()
            if nxt is not None and nxt.indent > indent:
                if _is_sequence_item(nxt.text):
                    return self.parse_sequence(nxt.indent)
                return self.parse_mapping(nxt.indent)
            if nxt is not None and nxt.indent == indent and _is_sequence_item(nxt.text):
                return self.parse_sequence(indent)
            return None
        if value[0] in "|>":
            self._consume_deeper(indent)
            return BlockScalar(value)
        if value[0] == "{":
            return self._parse_flow_mapping(self._collect_flow(value, "{", "}"))
        if value[0] == "[":
            body = self._collect_flow(value, "[", "]").strip()[1:-1]
            return [_unquote(item) for item in _split_flow_items(body)]
        self._consume_deeper(indent)
        return _unquote(value)

    def _collect_flow(self, first: str, open_char: str, close_char: str) -> str:
        text = first
        while text.count(open_char) > text.count(close_char) and self.index < len(self.lines):
            text += " " + _strip_inline_comment(self.lines[self.index].text)
            self.index += 1
        if text.count(open_char) != text.count(close_char):
            raise WorkflowSyntaxError(f"{self.name}: unterminated flow collection: {first}")
        return text

    def _parse_flow_mapping(self, text: str) -> dict:
        body = text.strip()
        if not (body.startswith("{") and body.endswith("}")):
            raise WorkflowSyntaxError(f"{self.name}: malformed flow mapping: {text}")
        mapping: dict = {}
        for item in _split_flow_items(body[1:-1]):
            split = _split_key(item)
            if split is None:
                raise WorkflowSyntaxError(f"{self.name}: malformed flow mapping entry: {item}")
            key, rest = split
            mapping[key] = _unquote(rest)
        return mapping


def parse_workflow(path: Path) -> dict:
    return _Reader(path.read_text(encoding="utf-8"), path.name).parse_document()


# --------------------------------------------------------------------------------------
# Permission semantics
# --------------------------------------------------------------------------------------


def normalize_permissions(value: object, where: str) -> Optional[Permissions]:
    """Turn a ``permissions`` value into ``{scope: level}``; ``None`` when not declared."""
    if value is None:
        return None
    if isinstance(value, str):
        if value == "read-all":
            return {scope: LEVELS["read"] for scope in SCOPES}
        if value == "write-all":
            return {scope: LEVELS["write"] for scope in SCOPES}
        raise WorkflowSyntaxError(f"{where}: unsupported permissions value {value!r}")
    if isinstance(value, dict):
        result: Permissions = {}
        for scope, level in value.items():
            if not isinstance(level, str) or level not in LEVELS:
                raise WorkflowSyntaxError(f"{where}: unsupported permission level {scope}: {level!r}")
            result[scope] = LEVELS[level]
        return result
    raise WorkflowSyntaxError(f"{where}: permissions must be a mapping, read-all or write-all")


def default_grant(default_workflow_permissions: str) -> Permissions:
    """Token permissions when a workflow declares none (the repository Actions setting)."""
    if default_workflow_permissions == "write":
        grant = {scope: LEVELS["write"] for scope in SCOPES}
        grant["id-token"] = LEVELS["none"]
        grant["metadata"] = LEVELS["read"]
        return grant
    if default_workflow_permissions == "read":
        return {"contents": LEVELS["read"], "packages": LEVELS["read"], "metadata": LEVELS["read"]}
    raise ValueError(f"unknown default workflow permissions: {default_workflow_permissions!r}")


def _with_metadata_floor(grant: Permissions) -> Permissions:
    result = dict(grant)
    result["metadata"] = max(result.get("metadata", 0), LEVELS["read"])
    return result


def format_permissions(permissions: Permissions) -> str:
    if not permissions:
        return "(none)"
    return ", ".join(f"{scope}: {LEVEL_NAMES[level]}" for scope, level in sorted(permissions.items()))


@dataclass(frozen=True)
class Request:
    scope: str
    level: int
    origin: str


@dataclass(frozen=True)
class Grant:
    permissions: Permissions
    origin: str


@dataclass(frozen=True)
class Edge:
    caller: Path
    job: str
    callee: Path
    grant: Grant
    requests: tuple[Request, ...]
    # Workflow files from the top-level run down to ``caller``; longer than one entry for nested calls.
    chain: tuple[str, ...]

    @property
    def site(self) -> tuple[Path, str]:
        return (self.caller, self.job)


def _jobs(document: dict, where: str) -> dict:
    jobs = document.get("jobs")
    if jobs is None:
        return {}
    if not isinstance(jobs, dict):
        raise WorkflowSyntaxError(f"{where}: jobs must be a mapping")
    return {name: job for name, job in jobs.items() if isinstance(job, dict)}


def _job_uses(job: dict) -> Optional[str]:
    uses = job.get("uses")
    return uses if isinstance(uses, str) else None


def is_local_reusable(uses: Optional[str]) -> bool:
    return bool(uses) and uses.startswith(LOCAL_USES_PREFIX)


def is_directly_runnable(document: dict) -> bool:
    """True when some trigger other than ``workflow_call`` can start this workflow on its own."""
    triggers = document.get("on")
    if isinstance(triggers, str):
        names = {triggers}
    elif isinstance(triggers, (list, dict)):
        names = set(triggers)
    else:
        return False
    return bool(names - {"workflow_call"})


def resolve_callee(uses: str, workflows_dir: Path) -> Path:
    return workflows_dir / uses[len(LOCAL_USES_PREFIX) :]


def callee_requests(document: dict, label: str) -> list[Request]:
    """Every scope the callee declares anywhere, at the highest level it asks for."""
    highest: dict[str, Request] = {}

    def record(block: Optional[Permissions], origin: str) -> None:
        if block is None:
            return
        for scope, level in block.items():
            current = highest.get(scope)
            if current is None or level > current.level:
                highest[scope] = Request(scope, level, origin)

    record(
        normalize_permissions(document.get("permissions"), f"{label} workflow-level permissions"),
        f"{label} workflow-level permissions",
    )
    for job_name, job in _jobs(document, label).items():
        record(
            normalize_permissions(job.get("permissions"), f"{label} job '{job_name}' permissions"),
            f"{label} job '{job_name}' permissions",
        )
    return sorted(highest.values(), key=lambda request: request.scope)


def job_grant(
    document: dict,
    job: dict,
    label: str,
    job_name: str,
    inherited: Optional[Grant],
    default_workflow_permissions: str,
) -> Grant:
    """What the token handed to ``job`` may do: job block, else workflow block, else inherited/default."""
    job_level = normalize_permissions(job.get("permissions"), f"{label} job '{job_name}' permissions")
    if job_level is not None:
        return Grant(_with_metadata_floor(job_level), f"{label} job '{job_name}' permissions")
    workflow_level = normalize_permissions(document.get("permissions"), f"{label} workflow-level permissions")
    if workflow_level is not None:
        return Grant(_with_metadata_floor(workflow_level), f"{label} workflow-level permissions")
    if inherited is not None:
        return Grant(inherited.permissions, f"{inherited.origin} (inherited)")
    return Grant(
        default_grant(default_workflow_permissions),
        f"repository default workflow permissions ({default_workflow_permissions})",
    )


def check_workflows_dir(workflows_dir: Path, default_workflow_permissions: str) -> tuple[list[Edge], list[str]]:
    """Return every checked local call and the failures GitHub would raise at startup.

    Directly runnable workflows are walked as top-level runs; a ``workflow_call``-only file is
    checked in the context of each caller (its grant may be inherited), and one nobody calls is
    checked on its own so no ``uses:`` site is silently skipped.
    """
    edges: list[Edge] = []
    failures: list[str] = []
    seen: set[tuple[tuple[str, ...], str, str]] = set()
    workflows = sorted(path for path in workflows_dir.iterdir() if path.suffix in {".yml", ".yaml"} and path.is_file())
    parsed: dict[Path, dict] = {}
    called: set[Path] = set()

    def load(path: Path) -> dict:
        if path not in parsed:
            parsed[path] = parse_workflow(path)
        return parsed[path]

    def check_call(caller: Path, job_name: str, job: dict, grant: Grant, chain: tuple[Path, ...]) -> None:
        uses = _job_uses(job)
        if not is_local_reusable(uses):
            return
        assert uses is not None
        callee = resolve_callee(uses, workflows_dir)
        chain_names = tuple(path.name for path in chain)
        key = (chain_names, job_name, uses)
        if key in seen:
            return
        seen.add(key)
        via = "" if len(chain) == 1 else f" (reached via {' -> '.join(chain_names[:-1])})"
        prefix = f"{caller.name}{via}: job '{job_name}' uses {uses}"
        if not callee.is_file():
            failures.append(f"{prefix}, but that workflow file does not exist")
            return
        if callee in chain:
            loop = " -> ".join(path.name for path in (*chain, callee))
            failures.append(f"{prefix}, which closes a reusable-workflow cycle ({loop})")
            return
        called.add(callee)
        callee_document = load(callee)
        requests = tuple(callee_requests(callee_document, callee.name))
        edges.append(Edge(caller, job_name, callee, grant, requests, chain_names))
        for request in requests:
            allowed = grant.permissions.get(request.scope, LEVELS["none"])
            if request.level > allowed:
                failures.append(
                    f"{prefix}, which requests '{request.scope}: {LEVEL_NAMES[request.level]}' "
                    f"({request.origin}) but the calling job only allows "
                    f"'{request.scope}: {LEVEL_NAMES[allowed]}' ({grant.origin}). "
                    "GitHub rejects the caller at startup; reduce the callee or widen the calling job."
                )
        for nested_name, nested_job in _jobs(callee_document, callee.name).items():
            if not is_local_reusable(_job_uses(nested_job)):
                continue
            nested_grant = job_grant(
                callee_document, nested_job, callee.name, nested_name, grant, default_workflow_permissions
            )
            check_call(callee, nested_name, nested_job, nested_grant, (*chain, callee))

    def walk_top_level(caller: Path) -> None:
        document = load(caller)
        for job_name, job in _jobs(document, caller.name).items():
            if not is_local_reusable(_job_uses(job)):
                continue
            grant = job_grant(document, job, caller.name, job_name, None, default_workflow_permissions)
            check_call(caller, job_name, job, grant, (caller,))

    runnable = [path for path in workflows if is_directly_runnable(load(path))]
    for caller in runnable:
        walk_top_level(caller)
    for orphan in workflows:
        if orphan in runnable or orphan in called:
            continue
        walk_top_level(orphan)
    return edges, failures


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--workflows-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / ".github" / "workflows",
        help="directory holding the workflow files (default: this repository's .github/workflows)",
    )
    parser.add_argument(
        "--default-workflow-permissions",
        choices=("read", "write"),
        default="write",
        help=(
            "GITHUB_TOKEN default for callers that declare no permissions; mirrors the repository "
            "Actions setting (manaflow-ai/cmux: write). Use read to model a restricted repository."
        ),
    )
    parser.add_argument("--verbose", action="store_true", help="print every checked call")
    args = parser.parse_args(argv)

    if not args.workflows_dir.is_dir():
        print(f"FAIL: workflows directory not found: {args.workflows_dir}", file=sys.stderr)
        return 2
    try:
        edges, failures = check_workflows_dir(args.workflows_dir, args.default_workflow_permissions)
    except WorkflowSyntaxError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2

    if args.verbose:
        for edge in edges:
            requested = ", ".join(f"{r.scope}: {LEVEL_NAMES[r.level]}" for r in edge.requests) or "(inherits caller)"
            via = "" if len(edge.chain) == 1 else f" (reached via {' -> '.join(edge.chain[:-1])})"
            print(
                f"{edge.caller.name}{via}: job '{edge.job}' -> {edge.callee.name}\n"
                f"  grant   [{edge.grant.origin}]: {format_permissions(edge.grant.permissions)}\n"
                f"  request: {requested}"
            )
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sites = len({edge.site for edge in edges})
    callers = len({edge.caller for edge in edges})
    if failures:
        print(
            f"FAIL: {len(failures)} reusable-workflow permission mismatch(es) across "
            f"{sites} local call site(s) in {args.workflows_dir}",
            file=sys.stderr,
        )
        return 1
    print(
        f"PASS: every local reusable-workflow call stays within its caller's permissions "
        f"({sites} call site(s) in {callers} caller workflow(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
