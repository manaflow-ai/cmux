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
"<workflow file>::<job id>::<artifact name as written>", with "#2", "#3" ... appended for a later
step of the same job that writes the same name, so each step is listed on its own. An entry that
no longer matches a
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
# Path words that name an archive or a bundle: a shell step may build `<name>.app.zip` and upload it
# through an expression (`${{ steps.dogfood-artifact.outputs.archive }}`, `media-app/app.tar`).
LARGE_PATH_TOKENS = LARGE_TOKENS | {"archive", "tar", "tgz", "xcarchive"}
# Handoffs whose name and path do not say what they hold: a directory of a signed zip, an
# xcarchive zip or a prepared bundle, read by a later job. A new generic-path handoff of that kind
# belongs here (or on R2); the name and path heuristics cannot see inside a directory.
KNOWN_LARGE = re.compile(r"^(cmux-next-dev-daily-signed|cmux-mobile-internal-archive-|"
                         r"cmux-nightly-identity-pending-bundle$|cmux-nightly-identity-signed$|"
                         r"cmux-nightly-recovered-variant-|nightly-next-pending-(?!state-))")
SMALL_SUFFIXES = (".log", ".json", ".txt", ".md", ".sha256", ".patch")
LARGE_SUFFIXES = (".app", ".zip", ".dmg", ".ipa", ".xcresult", ".dsym", ".xcframework", ".xcarchive")


def workflow_files(root: Path = ROOT) -> list[Path]:
    files = sorted((root / ".github/workflows").glob("*.yml"))
    files += sorted((root / ".github/workflows").glob("*.yaml"))
    files += sorted((root / ".github/actions").glob("*/action.yml"))
    files += sorted((root / ".github/actions").glob("*/action.yaml"))
    return files


def upload_steps(path: Path, root: Path = ROOT):
    """(key, step `with:` mapping) for every upload-artifact step in one file."""
    doc = yaml.safe_load(path.read_text()) or {}
    rel = path.relative_to(root).as_posix()
    if "runs" in doc:
        jobs = {"(composite)": {"steps": (doc.get("runs") or {}).get("steps") or []}}
    else:
        jobs = doc.get("jobs") or {}
    seen: dict[str, int] = {}
    for job_id, job in jobs.items():
        for step in (job or {}).get("steps") or []:
            uses = str(step.get("uses", "")).strip()
            # actions/upload-artifact@REF and actions/upload-artifact/merge@REF both store an artifact.
            if not re.match(r"actions/upload-artifact(/merge)?@", uses):
                continue
            options = step.get("with") or {}
            key = f"{rel}::{job_id}::{options.get('name', '')}"
            seen[key] = seen.get(key, 0) + 1
            yield (key if seen[key] == 1 else f"{key}#{seen[key]}"), options


def tokens(text: str) -> set[str]:
    return {t for t in re.split(r"[^a-z0-9]+", text.lower()) if t}


def is_large(options: dict) -> bool:
    # Expression contents count too: `${{ inputs.app }}` may well name an app.
    name = str(options.get("name", ""))
    if KNOWN_LARGE.match(name) or tokens(name) & LARGE_TOKENS:
        return True
    for line in str(options.get("path", "")).splitlines():
        line = line.strip().lower()
        if line.startswith("!"):
            continue
        # Any segment: build/cmux.app/Contents/**, a.xcarchive/dSYMs, out/*.zip, x.dSYM/.
        for segment in line.split("/"):
            if segment.rstrip("*").endswith(LARGE_SUFFIXES):
                return True
        # A word counts unless the path ends in a small text file (an archive's log or receipt).
        if tokens(line) & LARGE_PATH_TOKENS and not line.endswith(SMALL_SUFFIXES):
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
                        {"name": "out", "path": "build/cmux.zip"}, {"name": "out", "path": "a.dSYM/"},
                        {"name": "out", "path": "x/cmux.xcarchive/dSYMs"}, {"name": "out", "path": "b/cmux.app/Contents/**"},
                        {"name": "out", "path": "out/*.dmg"}, {"name": "receipt-${{ inputs.app }}"},
                        {"name": "${{ steps.dogfood-artifact.outputs.artifact_name }}",
                         "path": "${{ steps.dogfood-artifact.outputs.archive }}"},
                        {"name": "${{ steps.build_base.outputs.artifact }}", "path": "${{ runner.temp }}/media-app/app.tar"},
                        {"name": "products", "path": "${{ runner.temp }}/cmux-release-product.tar.gz"},
                        {"name": "cmux-next-dev-daily-signed", "path": "signed-handoff/*"},
                        {"name": "cmux-mobile-internal-archive-${{ github.run_id }}", "path": "${{ runner.temp }}/handoff/"}):
            options["retention-days"] = 1
            self.assertTrue(problems(options), options)
        self.assertEqual(problems({"name": "approval-receipt", "retention-days": 1}), [])
        self.assertEqual(problems({"name": "happy-path", "retention-days": 1}), [])
        self.assertEqual(problems({"name": "out", "path": "!x.zip\nreport.json", "retention-days": 1}), [])
        self.assertEqual(problems({"name": "archive-log", "path": "x/ios-archive.log", "retention-days": 1}), [])

    def test_a_repeated_name_in_one_job_is_listed_per_step(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github/workflows").mkdir(parents=True)
            step = "      - uses: actions/upload-artifact@v4\n        with:\n          name: same\n"
            merge = "      - uses: actions/upload-artifact/merge@v4\n        with:\n          name: same\n"
            (root / ".github/workflows/w.yml").write_text("jobs:\n  j:\n    steps:\n" + step + step + merge)
            self.assertEqual(sorted(violations(root)), [".github/workflows/w.yml::j::same",
                                                        ".github/workflows/w.yml::j::same#2",
                                                        ".github/workflows/w.yml::j::same#3"])


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
