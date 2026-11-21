#!/usr/bin/env python3
"""cmux-next-dev-daily.yml deletes its signed app handoff only after every job that reads it is done.

The handoff (cmux-next-dev-daily-signed, about 208 MB) held about 515 copies on 2026-11-14 at its 3-day
retention, though only the same run's jobs read it. drop-signed-handoff deletes it at the end of a clean run.
This checks that it cannot delete it under a reader: it needs every other job of the workflow (so every reader,
including one added later), it runs only when none of them failed or was cancelled (a red run keeps it for its
re-run), nothing else in the repository reads the name from another run, and the job holds only `actions: write`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-dev-daily.yml"
NAME = "cmux-next-dev-daily-signed"
DROP = "drop-signed-handoff"


def needs_of(job: dict) -> list[str]:
    needs = job.get("needs") or []
    return [needs] if isinstance(needs, str) else list(needs)


def readers(jobs: dict) -> set[str]:
    out = set()
    for name, job in jobs.items():
        for step in job.get("steps") or []:
            if str(step.get("uses", "")).startswith("actions/download-artifact@") and \
                    (step.get("with") or {}).get("name") == NAME:
                out.add(name)
    return out


def problems() -> list[str]:
    doc = yaml.safe_load(WORKFLOW.read_text())
    jobs = doc["jobs"]
    bad = []
    if DROP not in jobs:
        return [f"{WORKFLOW.name} has no {DROP} job"]
    drop = jobs[DROP]
    found = readers(jobs)
    if not found:
        bad.append(f"no job downloads {NAME}: the reader scan matched nothing")
    others = set(jobs) - {DROP}
    if set(needs_of(drop)) != others:
        bad.append(f"{DROP} must need every other job; missing {sorted(others - set(needs_of(drop)))}")
    if not found <= set(needs_of(drop)):
        bad.append(f"{DROP} does not wait for readers {sorted(found - set(needs_of(drop)))}")
    for name, job in jobs.items():
        if DROP in needs_of(job):
            bad.append(f"{name} needs {DROP}: nothing may run after the delete")
    cond = str(drop.get("if", ""))
    for clause in ("always()", "needs.sign.outputs.signed == 'true'",
                   "!contains(needs.*.result, 'failure')", "!contains(needs.*.result, 'cancelled')"):
        if clause not in cond:
            bad.append(f"{DROP}'s if lacks {clause!r}")
    if drop.get("continue-on-error") is not True:
        bad.append(f"{DROP} must be continue-on-error (a failed delete never fails the run)")
    if drop.get("permissions") != {"actions": "write"}:
        bad.append(f"{DROP} permissions must be exactly actions: write, got {drop.get('permissions')}")
    text = yaml.safe_dump(drop)
    if "secrets." in text or "environment" in drop:
        bad.append(f"{DROP} must hold no secret or environment")
    steps = drop.get("steps") or []
    script = "\n".join(str(s.get("run", "")) for s in steps)
    if not (NAME in script and "/runs/$GITHUB_RUN_ID/artifacts" in script):
        bad.append(f"{DROP} must list {NAME} of this run only (runs/$GITHUB_RUN_ID)")
    # needs.*.result reads a failed continue-on-error job as success; the jobs API has the real conclusion.
    soft = sorted(n for n, j in jobs.items() if n != DROP and j.get("continue-on-error"))
    check = script.find("/attempts/$GITHUB_RUN_ATTEMPT/jobs")
    if soft and (check < 0 or check > script.find("-X DELETE")):
        bad.append(f"{DROP} must read this attempt's jobs before the delete: {soft} are continue-on-error, so"
                   " needs.*.result shows their failure as success")
    if f'.name != "{drop.get("name")}"' not in script:
        bad.append(f"{DROP}'s jobs filter must leave out its own name ({drop.get('name')!r}) exactly")
    for word in ('.conclusion != "success"', '.conclusion != "skipped"', "exit 0"):
        if word not in script:
            bad.append(f"{DROP}'s jobs check lacks {word!r}")
    # A reader in another workflow or script would lose the artifact: the name lives in this workflow only.
    for path in sorted((ROOT / ".github").rglob("*.y*ml")) + sorted((ROOT / "scripts").rglob("*")):
        if path == WORKFLOW or not path.is_file() or path.suffix not in (".yml", ".yaml", ".py", ".sh", ".js", ".ts"):
            continue
        if NAME in path.read_text(errors="ignore"):
            bad.append(f"{path.relative_to(ROOT)} names {NAME}: a reader outside the run; keep it, or drop it there")
    return bad


def self_check() -> None:
    jobs = {"a": {"steps": [{"uses": "actions/download-artifact@v7", "with": {"name": NAME}}]},
            "b": {"steps": [{"uses": "actions/download-artifact@v7", "with": {"name": "other"}}]},
            "c": {"steps": [{"uses": "actions/upload-artifact@v7", "with": {"name": NAME}}]}}
    assert readers(jobs) == {"a"}, readers(jobs)
    assert needs_of({"needs": "x"}) == ["x"] and needs_of({}) == []
    assert re.search(r"needs\.\*\.result", "!contains(needs.*.result, 'failure')")


if __name__ == "__main__":
    self_check()
    bad = problems()
    for b in bad:
        print("FAIL:", b)
    if not bad:
        print(f"ok: {DROP} waits for {len(readers(yaml.safe_load(WORKFLOW.read_text())['jobs']))} readers of {NAME}")
    sys.exit(1 if bad else 0)
