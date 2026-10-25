#!/usr/bin/env python3
"""Every actions/upload-artifact step keeps its artifact 3 days or less, and big ones go to R2.

The org's Actions artifact storage quota filled on 2026-10-24 ("Artifact storage quota has been
hit"), and Leo's order was to keep big and long-lived artifacts on R2 or the fleet SSDs
(2026-10-25: "just use the fucking r2 or the ssds wtf"). This repository is public, so its
artifacts are not billed today, but a step copied into a private repository, or a visibility or
discount change, would bill them; the rule holds here so it holds everywhere. A step in
.github/workflows/*.yml or .github/actions/*/action.yml fails when:

- it sets no retention-days (the repository default is 90 days), or a value that is not a
  number of days from 1 to 3 (an expression counts as unknown), or
- its artifact is a known-large kind (an app, a dSYM, an xcresult, a capture, a zip, a DMG, an
  IPA or an xcframework, by name or path), whatever its retention,

unless tests/upload_artifact_retention_allowlist.json lists the step with a reason. An entry is
"<workflow file>::<job id>::<artifact name as written>". An entry that no longer matches a
failing step fails too, so the list only shrinks. Same-run handoffs use retention-days: 1;
anything a later run or a person reads goes to R2 (scripts/ci/upload-r2-object.py), PR and
capture objects under ci-tmp/.
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / "tests/upload_artifact_retention_allowlist.json"
MAX_DAYS = 3
LARGE_TOKENS = {"app", "dsym", "dsyms", "xcresult", "capture", "captures", "zip", "dmg",
                "ipa", "xcframework"}
LARGE_SUFFIXES = (".app", ".zip", ".dmg", ".ipa", ".xcresult", ".dsym", ".xcframework", ".xcarchive")


def workflow_files(root: Path = ROOT) -> list[Path]:
    files = sorted((root / ".github/workflows").glob("*.yml"))
    files += sorted((root / ".github/workflows").glob("*.yaml"))
    files += sorted((root / ".github/actions").glob("*/action.yml"))
    return files


def upload_steps(path: Path, root: Path = ROOT):
    """(key, step `with:` mapping) for every upload-artifact step in one file."""
    doc = yaml.safe_load(path.read_text()) or {}
    rel = path.relative_to(root).as_posix()
    if "runs" in doc:
        jobs = {"(composite)": {"steps": (doc.get("runs") or {}).get("steps") or []}}
    else:
        jobs = doc.get("jobs") or {}
    for job_id, job in jobs.items():
        for step in (job or {}).get("steps") or []:
            uses = str(step.get("uses", ""))
            if not uses.startswith("actions/upload-artifact@"):
                continue
            options = step.get("with") or {}
            yield f"{rel}::{job_id}::{options.get('name', '')}", options


def tokens(text: str) -> set[str]:
    return {t for t in re.split(r"[^a-z0-9]+", text.lower()) if t}


def is_large(options: dict) -> bool:
    name = str(options.get("name", ""))
    # Drop ${{ ... }} expressions: their contents name inputs, not the artifact's kind.
    name = re.sub(r"\$\{\{.*?\}\}", "-", name)
    if tokens(name) & LARGE_TOKENS:
        return True
    for line in str(options.get("path", "")).splitlines():
        line = line.strip().rstrip("/").lower()
        if line.startswith("!"):
            continue
        if line.endswith(LARGE_SUFFIXES) or line.endswith(tuple(s + "/*" for s in LARGE_SUFFIXES)):
            return True
    return False


def problems(options: dict) -> list[str]:
    out = []
    days = options.get("retention-days")
    if days is None:
        out.append("no retention-days (the repository default keeps it 90 days)")
    elif not isinstance(days, int) or isinstance(days, bool) or not 1 <= days <= MAX_DAYS:
        out.append(f"retention-days {days!r} is not 1..{MAX_DAYS}")
    if is_large(options):
        out.append("a large artifact kind (app, dSYM, xcresult, capture, zip, DMG, IPA, xcframework) "
                   "belongs on R2 or the fleet SSD store")
    return out


def violations(root: Path = ROOT) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for path in workflow_files(root):
        for key, options in upload_steps(path, root):
            issues = problems(options)
            if issues:
                found.setdefault(key, [])
                found[key].extend(i for i in issues if i not in found[key])
    return found


def load_allowlist(path: Path = ALLOWLIST) -> dict[str, str]:
    entries = json.loads(path.read_text())["allow"]
    return {entry["step"]: entry["reason"] for entry in entries}


class RuleTests(unittest.TestCase):
    def test_a_missing_or_long_retention_fails(self):
        self.assertTrue(problems({"name": "receipt"}))
        self.assertTrue(problems({"name": "receipt", "retention-days": 14}))
        self.assertTrue(problems({"name": "receipt", "retention-days": "${{ inputs.days }}"}))
        self.assertEqual(problems({"name": "receipt", "retention-days": 1}), [])
        self.assertEqual(problems({"name": "receipt", "retention-days": 3}), [])

    def test_large_kinds_fail_by_name_or_path(self):
        for options in ({"name": "cmux-nightly-unsigned-app"}, {"name": "nightly-next-dsyms-${{ x }}"},
                        {"name": "ui-tests-xcresult"}, {"name": "cmux-next-capture-1"},
                        {"name": "out", "path": "build/cmux.zip"}, {"name": "out", "path": "a.dSYM/"}):
            options["retention-days"] = 1
            self.assertTrue(problems(options), options)
        self.assertEqual(problems({"name": "approval-receipt", "retention-days": 1}), [])
        self.assertEqual(problems({"name": "happy-path", "retention-days": 1}), [])
        self.assertEqual(problems({"name": "receipt-${{ inputs.app }}", "retention-days": 1}), [])


class WorkflowTests(unittest.TestCase):
    def test_every_upload_is_short_lived_and_small_or_allowlisted(self):
        allow = load_allowlist()
        found = violations()
        unlisted = {k: v for k, v in found.items() if k not in allow}
        self.assertEqual(unlisted, {}, "\n".join(
            [f"{k}: {'; '.join(v)}" for k, v in sorted(unlisted.items())]
            + ["Use retention-days: 1 for a same-run handoff and R2 (scripts/ci/upload-r2-object.py) "
               "for anything bigger or longer-lived, or add the step to "
               "tests/upload_artifact_retention_allowlist.json with a reason."]))

    def test_the_allowlist_has_reasons_and_no_stale_entries(self):
        allow = load_allowlist()
        found = violations()
        self.assertTrue(all(reason.strip() for reason in allow.values()))
        stale = sorted(set(allow) - set(found))
        self.assertEqual(stale, [], "these allowlist entries match no failing step; remove them")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--baseline":
        print(json.dumps(violations(), indent=1, sort_keys=True))
        sys.exit(0)
    unittest.main()
