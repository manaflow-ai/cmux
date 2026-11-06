"""The Blacksmith Linux size table (.github/runners.json `linux_sizes`), for tests that check a job's label.

One declared source: a test that pins a job's Blacksmith size reads it here instead of naming the label
itself, so a resize edits the table and the workflow, and every test follows.
"""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNERS = ROOT / ".github" / "runners.json"


def table() -> dict:
    return json.loads(RUNNERS.read_text(encoding="utf-8"))["linux_sizes"]


def label(size: int) -> str:
    return f"blacksmith-{size}vcpu-ubuntu-2404"


def entry(workflow: str, job: str) -> dict:
    return table()["jobs"][f"{workflow}#{job}"]


def size_label(workflow: str, job: str) -> str:
    """The job's Blacksmith label."""
    return label(entry(workflow, job)["size"])


def failover_label(workflow: str, job: str) -> str:
    """The label the job takes while the overflow switch's CI_CLOUD_OVERFLOW_SAVED record is set."""
    return label(entry(workflow, job)["failover"])


def blacksmith_route(workflow: str, job: str) -> str:
    """The tail of the job's runs-on: its failover while the switch has failed over, else its size."""
    return f"vars.CI_CLOUD_OVERFLOW_SAVED && '{failover_label(workflow, job)}' || '{size_label(workflow, job)}'"
