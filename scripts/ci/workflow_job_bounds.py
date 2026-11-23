#!/usr/bin/env python3
"""Every workflow job is bounded: it has a `timeout-minutes`, and it does not run after a cancel.

A job with no `timeout-minutes` that hangs runs for GitHub's 6 h default, holding its runner and any concurrency
group. A job whose `if:` uses `always()` still queues when its run is cancelled; on a label with no free runner it
waits there, and `timeout-minutes` does not count queue time, so it holds the run and its group until GitHub drops
it (cmuxterm-hq docs/investigations/2026-11-18-boneheaded-designs.md §11; the 453-run cmux incident the same day).
`!cancelled()` runs a summary after a failed or skipped need and skips it on a cancel. A job that must run on a
cancel (one that releases a lease, or a required-check aggregator that must fail closed rather than be skipped,
since a skipped required check reads as passing) is listed with its reason.

This file is byte-identical in manaflow-ai/cmux scripts/ci/, manaflow-ai/cmuxterm-hq tests/ and
teamleaderleo/glaeda scripts/; each repo's test passes its own allowlist. It reads the YAML by indentation, with
no PyYAML, so it runs on any runner's python3.

    python3 workflow_job_bounds.py .github/workflows        # lists every finding, exit 1 if any
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ALWAYS = re.compile(r"\balways\(\s*\)")
CANCEL_GUARD = re.compile(r"!\s*cancelled\(\s*\)")  # `always() && !cancelled()` already skips on a cancel
_KEY = re.compile(r"^(\s*)(['\"]?)([A-Za-z0-9_.-]+)\2\s*:(.*)$")


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _meaningful(line: str) -> bool:
    s = line.strip()
    return bool(s) and not s.startswith("#")


def jobs(text: str) -> list[tuple[str, dict[str, str]]]:
    """(job id, {job-level key: value}) for each job under the top-level `jobs:`; a value that continues on deeper
    lines (a block scalar or a wrapped expression) is joined with spaces."""
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if re.match(r"^jobs\s*:\s*(#.*)?$", line)), None)
    if start is None:
        return []
    body: list[str] = []
    for line in lines[start + 1:]:
        if _meaningful(line) and _indent(line) == 0:
            break
        body.append(line)
    job_indent = next((_indent(line) for line in body if _meaningful(line)), None)
    if job_indent is None:
        return []
    out: list[tuple[str, dict[str, str]]] = []
    current: dict[str, str] | None = None
    key_indent: int | None = None
    last_key: str | None = None
    for line in body:
        if not _meaningful(line):
            continue
        ind = _indent(line)
        if ind == job_indent:
            m = _KEY.match(line)
            if not m:
                current = None
                continue
            current, key_indent, last_key = {}, None, None
            out.append((m.group(3), current))
            continue
        if current is None or ind < job_indent:
            continue
        if key_indent is None:
            key_indent = ind
        if ind == key_indent:
            m = _KEY.match(line)
            if m:
                last_key = m.group(3)
                current[last_key] = m.group(4).split(" #")[0].strip()
                continue
        if ind > key_indent and last_key is not None and last_key in ("if", "timeout-minutes", "uses"):
            current[last_key] = (current[last_key] + " " + line.strip()).strip()
    return out


def workflow_files(folder: Path) -> list[Path]:
    return sorted(list(folder.glob("*.yml")) + list(folder.glob("*.yaml")))


def text_bounds(name: str, text: str) -> tuple[list[str], dict[str, str]]:
    """For one workflow file's text: `name:job` of each job that runs steps with no `timeout-minutes` (a `uses:`
    caller cannot take one), and `name:job` -> `if:` of each job whose condition uses always() with no
    `!cancelled()` beside it. A caller that reads files at a git revision (a pre-push hook) uses this directly."""
    missing, unguarded = [], {}
    for job, keys in jobs(text):
        if "uses" not in keys and "timeout-minutes" not in keys:
            missing.append(f"{name}:{job}")
        cond = keys.get("if", "")
        if ALWAYS.search(cond) and not CANCEL_GUARD.search(cond):
            unguarded[f"{name}:{job}"] = cond
    return missing, unguarded


def missing_timeouts(path: Path) -> list[str]:
    return text_bounds(path.name, path.read_text(encoding="utf-8"))[0]


def always_jobs(path: Path) -> dict[str, str]:
    return text_bounds(path.name, path.read_text(encoding="utf-8"))[1]


def findings(folder: Path, always_on_cancel: dict[str, str]) -> list[str]:
    """Every problem in folder's workflows; always_on_cancel maps `file:job` to why it must run after a cancel."""
    problems: list[str] = []
    seen_always: set[str] = set()
    for path in workflow_files(folder):
        for where in missing_timeouts(path):
            problems.append(f"{where}: no timeout-minutes; size it to the job's p99 plus headroom")
        for where, cond in always_jobs(path).items():
            seen_always.add(where)
            if where not in always_on_cancel:
                problems.append(f"{where}: if: {cond} still queues on a cancelled run; use !cancelled() "
                                "(or list it with the reason it must run on a cancel)")
    for where in sorted(set(always_on_cancel) - seen_always):
        problems.append(f"{where}: listed as running on a cancel, but no such job uses always(); drop the entry")
    return problems


if __name__ == "__main__":
    found = findings(Path(sys.argv[1] if len(sys.argv) > 1 else ".github/workflows"), {})
    print("\n".join(found) or "no findings")
    sys.exit(1 if found else 0)
