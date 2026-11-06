#!/usr/bin/env python3
"""Every artifact upload a nightly needs gets one retry.

Run 42294393260 lost a NEXT nightly to one `Failed to CreateArtifact: Unable to make request: ETIMEDOUT` while
uploading the cmux-next source archive: a single-shot upload, so the build was thrown away. The unsigned app's
upload already had a retry (run 40460194731). Each upload-artifact step in nightly.yml that the run needs (no
continue-on-error of its own) is now a first try with continue-on-error, followed by a retry step that runs on
its failure with the same inputs and `overwrite: true`, replacing a partial first upload.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DOC = yaml.safe_load((ROOT / ".github" / "workflows" / "nightly.yml").read_text())
failures: list[str] = []

for job_name, job in DOC["jobs"].items():
    steps = job.get("steps") or []
    for index, step in enumerate(steps):
        if "actions/upload-artifact@" not in str(step.get("uses", "")):
            continue
        name = step.get("name") or step.get("with", {}).get("name")
        condition = str(step.get("if", ""))
        if condition.startswith("steps.") and condition.endswith(".outcome == 'failure'"):
            continue  # a retry step
        if not step.get("continue-on-error"):
            failures.append(f"{job_name}: {name!r} uploads once; give it continue-on-error and a retry step")
            continue
        step_id = step.get("id")
        retry = steps[index + 1] if index + 1 < len(steps) else {}
        if not step_id or str(retry.get("if", "")) != f"steps.{step_id}.outcome == 'failure'":
            # An optional upload (continue-on-error with no retry) predates this rule and fails nothing.
            continue
        first, again = dict(step.get("with") or {}), dict(retry.get("with") or {})
        if "actions/upload-artifact@" not in str(retry.get("uses", "")) or again.pop("overwrite", None) is not True:
            failures.append(f"{job_name}: {name!r} retry must upload again with overwrite: true")
        first.pop("overwrite", None)
        if first != again:
            failures.append(f"{job_name}: {name!r} retry must upload the same artifact as the first try")

if failures:
    print("FAIL: nightly artifact uploads retry once\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly artifact uploads retry once")
