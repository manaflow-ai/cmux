#!/usr/bin/env python3
"""Refuse a job gated on `always()` in a run a concurrency group can cancel.

GitHub still schedules an `if: always()` job after its run is cancelled. On a
saturated runner label that job sits `queued` for hours, the cancelled run
never completes, and the run keeps its concurrency group. The newer run the
cancel was meant to make room for then waits `pending` with no jobs at all.

That is what held cmux#46109 for 7 hours on 2026-11-19: `rust workspaces`
(per-ref group, cancel-in-progress on pull requests) cancelled the run at the
old head, its `summary` job (`if: ${{ always() }}`) queued on a saturated
runner label, and the new head's run never got a job
(cmuxterm-hq#14963). 1,373 runs of that workflow were queued at the time.

`!cancelled()` keeps what such a summary job is for: it still runs when a job
it needs failed or was skipped, and it does not run once the run is cancelled.
`always() && !cancelled()` is the same thing and passes.

A run is cancellable when its workflow-level `concurrency` sets a
`cancel-in-progress` that is not literally false. A reusable workflow a
cancellable run calls (`uses: ./.github/workflows/x.yml`) is cancelled with it,
so its jobs are checked too. Only job-level `if:` counts: an `always()` step
runs on a runner the job already holds and queues for nothing.

A job that must run after a cancel (it releases a lease or deletes a VM the
cancelled jobs took) says so with a `# runs-after-cancel: <reason>` comment
inside the job. The reason must not be empty.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
ALWAYS = re.compile(r"\balways\(\s*\)")
NOT_CANCELLED = re.compile(r"!\s*cancelled\(\s*\)")
MARKER =re.compile(r"#\s*runs-after-cancel:\s*(\S.*)$")
LOCAL_CALL = re.compile(r"^\./\.github/workflows/([^@\s]+\.ya?ml)$")


def _can_cancel(concurrency: Any) -> bool:
    if not isinstance(concurrency, dict):
        return False
    value = concurrency.get("cancel-in-progress", False)
    if value is False or value is None:
        return False
    return str(value).strip().lower() != "false"


def runs_after_cancel(condition: Any) -> bool:
    """True when a job `if:` uses `always()` without also requiring `!cancelled()`.

    `always() && !cancelled()` is false once the run is cancelled, so it is fine.
    """
    if condition is None:
        return False
    text = str(condition)
    return bool(ALWAYS.search(text)) and not NOT_CANCELLED.search(text)


def _job_spans(text: str) -> dict[str, str]:
    """The raw text of each job under the top-level `jobs:` key, by job id."""
    spans: dict[str, list[str]] = {}
    in_jobs = False
    current: str | None = None
    indent: int | None = None
    for line in text.splitlines():
        if re.match(r"^jobs:\s*(#.*)?$", line):
            in_jobs, current, indent = True, None, None
            continue
        if not in_jobs:
            continue
        if line and not line[0].isspace() and not line.startswith("#"):
            in_jobs, current = False, None
            continue
        header = re.match(r"^( +)([A-Za-z0-9_-]+):\s*(#.*)?$", line)
        if header and (indent is None or len(header.group(1)) == indent):
            indent = len(header.group(1))
            current = header.group(2)
            spans[current] = []
            continue
        if current is not None:
            spans[current].append(line)
    return {job: "\n".join(lines) for job, lines in spans.items()}


def load(path: Path) -> tuple[dict, str]:
    text = path.read_text(encoding="utf-8")
    data = yaml.safe_load(text)
    return (data if isinstance(data, dict) else {}), text


def cancellable_workflows(docs: dict[str, dict]) -> set[str]:
    """Workflow file names whose runs a concurrency group can cancel."""
    result = {name for name, doc in docs.items() if _can_cancel(doc.get("concurrency"))}
    frontier = list(result)
    while frontier:
        name = frontier.pop()
        for job in (docs[name].get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            match = LOCAL_CALL.match(str(job.get("uses", "")).strip())
            if match and match.group(1) in docs and match.group(1) not in result:
                result.add(match.group(1))
                frontier.append(match.group(1))
    return result


def problems_in(docs: dict[str, dict], texts: dict[str, str]) -> list[str]:
    found: list[str] = []
    for name in sorted(cancellable_workflows(docs)):
        spans = _job_spans(texts[name])
        for job_id, job in (docs[name].get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            condition = job.get("if")
            if not runs_after_cancel(condition):
                continue
            if any(MARKER.search(line) for line in spans.get(str(job_id), "").splitlines()):
                continue
            found.append(
                f".github/workflows/{name}: job `{job_id}` has `if: {condition}` in a run its "
                "concurrency group can cancel; a cancelled run still queues it and keeps the "
                "group. Use `!cancelled()`, or mark the job `# runs-after-cancel: <reason>`."
            )
    return found


def scan(workflows: Path = WORKFLOWS) -> list[str]:
    docs: dict[str, dict] = {}
    texts: dict[str, str] = {}
    for path in sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")]):
        docs[path.name], texts[path.name] = load(path)
    return problems_in(docs, texts)


def main() -> int:
    found = scan()
    for line in found:
        print(line, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
