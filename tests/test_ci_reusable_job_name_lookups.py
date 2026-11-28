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

# Match either operand order, accessor style, and quote style. The right-hand
# accessor must end at the comparison, rather than continue into normalization.
NAME_ACCESS = r"""\b\w+(?:\.get\(\s*["']name["']\s*\)|\[\s*["']name["']\s*\])"""
LOOKUP = re.compile(
    rf"""{NAME_ACCESS}\s*==\s*["']([^"']+)["']"""
    rf"""|["']([^"']+)["']\s*==\s*{NAME_ACCESS}(?!\s*[.\[])"""
)


def lookup_literals(line: str) -> list[str]:
    return [forward or reverse for forward, reverse in LOOKUP.findall(line)]


def test_lookup_literals_detects_both_operand_orders() -> None:
    for quote in ('"', "'"):
        literal = f"{quote}Reusable job{quote}"
        for accessor in (f"job.get({quote}name{quote})", f"job[{quote}name{quote}]"):
            for comparison in (f"{accessor} == {literal}", f"{literal} == {accessor}"):
                assert lookup_literals(comparison) == ["Reusable job"], comparison


def test_lookup_literals_allows_normalized_names() -> None:
    for normalized in (
        'job["name"].rsplit(" / ", 1)[-1]',
        'job.get("name").rsplit(" / ", 1)[-1]',
        'str(job.get("name") or "").rsplit(" / ", 1)[-1]',
    ):
        for comparison in (
            f'{normalized} == "Reusable job"',
            f'"Reusable job" == {normalized}',
        ):
            assert lookup_literals(comparison) == [], comparison


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
                for literal in lookup_literals(line):
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
