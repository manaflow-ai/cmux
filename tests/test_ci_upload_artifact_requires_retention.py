#!/usr/bin/env python3
"""Every actions/upload-artifact step sets retention-days, so no artifact falls back to the 90-day default.

The org's Actions artifact storage quota filled again on 2026-11-14 ("Artifact storage quota has been
hit"); main still carried 25 upload steps with no retention-days. A step in .github/workflows/*.yml or
.github/actions/*/action.yml fails when its `with:` has no retention-days (an expression counts as set).
Pick the shortest period the step needs: 1 for a same-run handoff, 3 for logs and screenshots, more only
when a later run or a person reads it. Handbook: docs/handbook/artifact-retention.md in cmuxterm-hq.
"""
from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def steps_of(doc):
    if not isinstance(doc, dict):
        return
    for job in (doc.get("jobs") or {}).values():
        for step in (job or {}).get("steps") or []:
            yield step
    for step in ((doc.get("runs") or {}).get("steps")) or []:
        yield step


def missing():
    files = sorted((ROOT / ".github/workflows").glob("*.y*ml")) + sorted((ROOT / ".github/actions").glob("*/action.y*ml"))
    out = []
    for f in files:
        doc = yaml.safe_load(f.read_text())
        for step in steps_of(doc):
            if str(step.get("uses", "")).startswith("actions/upload-artifact@") and "retention-days" not in (step.get("with") or {}):
                out.append(f"{f.relative_to(ROOT)}: {step.get('name') or (step.get('with') or {}).get('name')}")
    return out


if __name__ == "__main__":
    bad = missing()
    for b in bad:
        print("upload-artifact without retention-days:", b)
    if bad:
        print("add `retention-days: N` (shortest the step needs; see the docstring)")
    sys.exit(1 if bad else 0)
