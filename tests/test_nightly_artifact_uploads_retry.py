#!/usr/bin/env python3
"""Every artifact upload a nightly needs gets one retry.

Run 42294393260 lost a NEXT nightly to one `Failed to CreateArtifact: Unable to make request: ETIMEDOUT` while
uploading the cmux-next source archive: a single-shot upload, so the build was thrown away. The unsigned app's
upload already had a retry (run 40460194731). Each upload-artifact step in nightly.yml that the run needs (no
continue-on-error of its own) is now a first try with continue-on-error, followed by a retry step that runs on
its failure with the same inputs and `overwrite: true`, replacing a partial first upload.

The retry's `if` is `!cancelled() && steps.<id>.outcome == 'failure'` plus the first step's own condition: without a
status function GitHub adds an implicit success(), so a first try that ran under always() after an earlier failure
(the notarization recovery artifact) would fail with no retry; and the first step's guards (already_published) stay.
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
        if ".outcome == 'failure'" in condition:
            continue  # a retry step
        if not step.get("continue-on-error"):
            failures.append(f"{job_name}: {name!r} uploads once; give it continue-on-error and a retry step")
            continue
        step_id = step.get("id")
        retry = steps[index + 1] if index + 1 < len(steps) else {}
        retry_if = str(retry.get("if", ""))
        if not step_id or f"steps.{step_id}.outcome == 'failure'" not in retry_if:
            # An optional upload (continue-on-error with no retry) predates this rule and fails nothing.
            continue
        first_if = str(step.get("if", "")).strip()
        if first_if.startswith("${{") and first_if.endswith("}}"):
            first_if = first_if[3:-2].strip()
        if not retry_if.startswith(f"!cancelled() && steps.{step_id}.outcome == 'failure'"):
            failures.append(f"{job_name}: {name!r} retry must start with !cancelled() so an earlier failure does not skip it")
        if first_if and f"({first_if})" not in retry_if:
            failures.append(f"{job_name}: {name!r} retry must keep the first try's condition")
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
