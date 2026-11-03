#!/usr/bin/env python3
"""Warn when a long, macOS or dispatched workflow can pile up runs in the queue.

On 2026-10-19 cmuxterm-hq's cmux-shadow-release-compile.yml queued about 247
sixty-minute runs: every dispatch got its own concurrency group, so nothing
ever superseded anything (fixed in cmuxterm-hq#2568).

A workflow is checked when it is triggered by workflow_dispatch,
repository_dispatch or pull_request(_target) and at least one of its jobs runs
on macOS or allows more than LONG_MINUTES minutes (timeout-minutes). Each such
job must be covered by a concurrency group, at workflow or job level, whose
group does not name a per-run value (the SHA, run id, run number or attempt):
with a per-run group every run is unique and nothing is ever cancelled or
queued behind the previous one.

A workflow that has a reason to run every dispatch goes in ALLOWLIST with that
reason. This is warn-level: it prints GitHub ::warning annotations and exits 0.
--strict exits 1 on any finding.

  python3 scripts/ci/check_workflow_concurrency.py [--strict] [--root DIR]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

LONG_MINUTES = 20
TRIGGERS = ("workflow_dispatch", "repository_dispatch", "pull_request", "pull_request_target")
# Values unique to one run or commit, looked for inside ${{ }} expressions: a
# group naming one never matches the next dispatch (github.sha, inputs.sha,
# head_sha, github.run_id, ...).
EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
PER_RUN = re.compile(r"(?i)(?:\bsha|_sha|run_id|run_number|run_attempt|head_commit|\.after)\b")


def names_a_run(group: str) -> bool:
    return any(PER_RUN.search(expression) for expression in EXPRESSION.findall(group))


MACOS = re.compile(r"mac|xcode", re.IGNORECASE)

# Workflow file name -> why it may run once per dispatch without a shared group.
ALLOWLIST: dict[str, str] = {
    # The DEV signer: its dispatcher sends one run per finished source run (at most one every
    # five minutes), and a shared group replaced each newer pending handoff while the signer
    # waited, so nothing newer ever signed (Nightly freshness, 2026-10-26).
    "cmux-next-dev-daily.yml": "one dispatch per finished DEV source run; a group evicted newer handoffs",
}


def triggers(doc: dict) -> set[str]:
    on = doc.get("on", doc.get(True))  # PyYAML reads a bare `on:` key as True
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(item) for item in on}
    if isinstance(on, dict):
        return {str(key) for key in on}
    return set()


def group_of(concurrency) -> str | None:
    if concurrency is None:
        return None
    if isinstance(concurrency, dict):
        group = concurrency.get("group")
        return None if group is None else str(group)
    return str(concurrency)


def runs_on_macos(job: dict) -> bool:
    runs_on = job.get("runs-on")
    if runs_on is None:
        return False
    if isinstance(runs_on, dict):
        runs_on = [runs_on.get("group", ""), *(runs_on.get("labels") or [])]
    text = " ".join(map(str, runs_on)) if isinstance(runs_on, list) else str(runs_on)
    if MACOS.search(text):
        return True
    # runs-on: ${{ matrix.os }} -> look at the matrix values.
    matrix = (job.get("strategy") or {}).get("matrix")
    if "matrix." in text and isinstance(matrix, dict):
        return bool(MACOS.search(yaml.safe_dump(matrix)))
    return False


def long_running(job: dict) -> bool:
    timeout = job.get("timeout-minutes")
    if isinstance(timeout, (int, float)):
        return timeout > LONG_MINUTES
    return False


def check(path: Path) -> list[str]:
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        return [f"cannot read {path.name}: {error}"]
    if not isinstance(doc, dict):
        return []
    fired_by = sorted(triggers(doc) & set(TRIGGERS))
    if not fired_by or path.name in ALLOWLIST:
        return []
    workflow_group = group_of(doc.get("concurrency"))
    uncovered, per_run, why = [], {}, set()
    for name, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict) or "uses" in job:
            continue  # a reusable workflow call is checked in its own file
        reasons = []
        if runs_on_macos(job):
            reasons.append("macOS")
        if long_running(job):
            reasons.append(f"timeout-minutes > {LONG_MINUTES}")
        if not reasons:
            continue
        group = group_of(job.get("concurrency")) or workflow_group
        if group is None:
            uncovered.append(name)
        elif names_a_run(group):
            per_run[name] = " ".join(group.split())
        else:
            continue
        why.update(reasons)
    findings = []
    context = f"{path.name} ({' and '.join(sorted(why))} jobs; on {', '.join(fired_by)})"
    fix = (
        "Repeated triggers then queue one run each. Key the group by workflow and ref or PR "
        "(no SHA or run id), or allowlist the file in scripts/ci/check_workflow_concurrency.py "
        "with a reason."
    )
    if uncovered:
        findings.append(f"{context}: no concurrency group covers job(s) {', '.join(uncovered)}. {fix}")
    for group in sorted(set(per_run.values())):
        jobs = [name for name, value in per_run.items() if value == group]
        findings.append(
            f"{context}: concurrency group {group} is unique per run for job(s) {', '.join(jobs)}. {fix}"
        )
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--strict", action="store_true", help="exit 1 on any finding")
    args = parser.parse_args(argv)
    workflows = args.root / ".github" / "workflows"
    findings = []
    for path in sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")]):
        for finding in check(path):
            findings.append((path, finding))
    for path, finding in findings:
        print(f"::warning file=.github/workflows/{path.name},title=workflow concurrency::{finding}")
    print(f"{len(findings)} workflow concurrency warning(s).", file=sys.stderr)
    return 1 if findings and args.strict else 0


if __name__ == "__main__":
    sys.exit(main())
