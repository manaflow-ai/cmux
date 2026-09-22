#!/usr/bin/env python3
"""A job defined in a reusable workflow is never matched by its bare name.

GitHub reports a reusable workflow's jobs as "<caller job id> / <job name>".
Code that looks a job up in the jobs API by exact equality against the name
written in the reusable workflow therefore matches nothing, forever, on every
real run. The failure is silent whenever the lookup is advisory, so pin it
here instead of waiting for a metric to be noticed missing.
"""

import re
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
SCAN_ROOTS = (WORKFLOWS, ROOT / "scripts" / "ci")
SCAN_SUFFIXES = (".yml", ".yaml", ".py")

# job.get("name") == "literal" / job["name"] == "literal", either quote style.
LOOKUP = re.compile(
    r"""\[?["']name["']\]?\)?\s*==\s*["']([^"']+)["']"""
)


def reusable_job_names() -> dict[str, str]:
    """Job display names defined by workflows that are called by another one."""
    names: dict[str, str] = {}
    for path in sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        # PyYAML resolves the unquoted "on:" key to True.
        triggers = document.get("on", document.get(True))
        if not isinstance(triggers, dict) or "workflow_call" not in triggers:
            continue
        jobs = document.get("jobs")
        if not isinstance(jobs, dict):
            continue
        for job_id, job in jobs.items():
            if isinstance(job, dict) and isinstance(job.get("name"), str):
                names[job["name"]] = f"{path.name}:{job_id}"
    return names


def test_no_bare_name_lookup_of_a_reusable_workflow_job() -> None:
    reusable = reusable_job_names()
    assert reusable, "expected at least one named job in a reusable workflow"

    offenders: list[str] = []
    for root in SCAN_ROOTS:
        for path in sorted(root.rglob("*")):
            if path.suffix not in SCAN_SUFFIXES or not path.is_file():
                continue
            for number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(), start=1
            ):
                for literal in LOOKUP.findall(line):
                    if literal in reusable:
                        rel = path.relative_to(ROOT)
                        offenders.append(
                            f"{rel}:{number} compares a job name to "
                            f"{literal!r}, defined by {reusable[literal]}, "
                            "which GitHub reports with a caller prefix"
                        )

    assert not offenders, "\n".join(
        ["strip the caller prefix before comparing, e.g."]
        + ['  str(job.get("name") or "").rsplit(" / ", 1)[-1] == ...']
        + offenders
    )


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: reusable workflow job names are matched with their caller prefix")
