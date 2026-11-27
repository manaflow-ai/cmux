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

unless tests/upload_artifact_retention_allowlist.json lists the step with a reason. The allowlist
excuses a longer retention or a large kind, never a missing one: every step, listed or not, sets
retention-days itself, so no artifact falls back to the 90-day default by omission (HQ#5230). An
entry is
"<workflow file>::<job id>::<artifact name as written>", with "#2", "#3" ... appended for a later
step of the same job that writes the same name, so each step is listed on its own. An entry that
no longer matches a
failing step fails too, so the list only shrinks. Same-run handoffs use retention-days: 1;
anything a later run or a person reads goes to R2 (scripts/ci/upload-r2-object.py), PR and
capture objects under ci-tmp/.

An allowlisted step is bounded too: its retention-days is a number from 1 to 7 (MAX_ALLOWED_DAYS), never a
longer period and never an expression, except `${{ inputs.retention_days }}` of a reusable workflow, whose
default is 1 to 3 days and whose every caller passes a number from 1 to 7. The 2026-11-14 quota fill came from
long-retention steps that an allowlist reason excused (14, 21, 30 and 90 days), not only from missing ones.
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
MAX_ALLOWED_DAYS = 7
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
    # A composite action may sit at any depth (.github/actions/a/b/action.yml).
    files += sorted((root / ".github/actions").rglob("action.yml"))
    files += sorted((root / ".github/actions").rglob("action.yaml"))
    return files


UPLOAD_USES = re.compile(r"actions/upload(-pages)?-artifact(/merge)?@")
INPUT_DAYS = re.compile(r"^\$\{\{\s*inputs\.([A-Za-z0-9_-]+)\s*\}\}$")


def reusable_workflow_findings(root: Path = ROOT) -> list[str]:
    """Problems with `retention-days: ${{ inputs.X }}` in a reusable workflow, whose value a caller sets.

    The input's default must be a number from 1 to MAX_DAYS and every caller (a job `uses:` this file)
    that passes it passes a number from 1 to MAX_ALLOWED_DAYS. Any other expression is a finding.
    """
    findings: list[str] = []
    callers: dict[str, list[tuple[str, dict]]] = {}
    docs: dict[Path, dict] = {}
    for path in workflow_files(root):
        docs[path] = doc = yaml.safe_load(path.read_text()) or {}
        for job_id, job in (doc.get("jobs") or {}).items():
            uses = str((job or {}).get("uses", ""))
            if uses.startswith("./.github/workflows/"):
                callers.setdefault(uses[2:], []).append(
                    (f"{path.relative_to(root).as_posix()}::{job_id}", (job or {}).get("with") or {}))
    for path, doc in docs.items():
        rel = path.relative_to(root).as_posix()
        for key, options in upload_steps(path, root):
            days = options.get("retention-days")
            match = INPUT_DAYS.match(days) if isinstance(days, str) else None
            if not match:
                continue
            name = match.group(1)
            inputs = ((doc.get("on") or doc.get(True) or {}).get("workflow_call") or {}).get("inputs") or {}
            default = (inputs.get(name) or {}).get("default")
            if not isinstance(default, int) or isinstance(default, bool) or not 1 <= default <= MAX_DAYS:
                findings.append(f"{key}: input {name} defaults to {default!r}, not 1..{MAX_DAYS}")
            for caller, passed in callers.get(rel, []):
                if name in passed:
                    value = passed[name]
                    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= MAX_ALLOWED_DAYS:
                        findings.append(f"{caller} passes {name}: {value!r}, not 1..{MAX_ALLOWED_DAYS}")
    return sorted(set(findings))


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
            if not UPLOAD_USES.match(uses):
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

    def test_every_upload_sets_retention_days_even_when_allowlisted(self):
        # The class is deliberate per step: 1 day for a same-run handoff, 3 for a report a person
        # reads, longer only for a listed handoff (e.g. one that waits on an environment approval).
        missing = sorted(key for path in workflow_files() for key, options in upload_steps(path)
                         if options.get("retention-days") in (None, ""))
        self.assertEqual(missing, [], "these upload steps set no retention-days, so they keep the "
                         "90-day default; set it explicitly (an allowlist entry does not excuse it)")

    def test_an_allowlisted_step_is_bounded_to_seven_days(self):
        # The allowlist excuses a retention above MAX_DAYS (a handoff that waits on an approval) but
        # not an unbounded one: a number from 1 to MAX_ALLOWED_DAYS, or a reusable workflow's input
        # that the next test bounds at its default and at every caller.
        too_long = {}
        for path in workflow_files():
            for key, options in upload_steps(path):
                days = options.get("retention-days")
                if isinstance(days, str) and INPUT_DAYS.match(days):
                    continue
                if isinstance(days, str) and days.lstrip().startswith("${{"):
                    # A conditional such as fromJSON(cond && '7' || '3'): every quoted number is bounded.
                    numbers = [int(n) for n in re.findall(r"'(\d+)'", days)]
                    if numbers and all(1 <= n <= MAX_ALLOWED_DAYS for n in numbers):
                        continue
                if not isinstance(days, int) or isinstance(days, bool) or not 1 <= days <= MAX_ALLOWED_DAYS:
                    too_long[key] = days
        self.assertEqual(too_long, {}, f"retention-days must be 1..{MAX_ALLOWED_DAYS} on every upload step")

    def test_a_reusable_workflow_retention_input_is_bounded_at_default_and_callers(self):
        self.assertEqual(reusable_workflow_findings(), [])

    def test_reusable_workflow_findings_catch_a_long_caller_and_default(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            wf = root / ".github/workflows"
            wf.mkdir(parents=True)
            (wf / "lib.yml").write_text(
                "on:\n  workflow_call:\n    inputs:\n      keep:\n        default: 30\n        type: number\n"
                "jobs:\n  j:\n    steps:\n      - uses: actions/upload-artifact@v4\n        with:\n"
                "          name: x\n          retention-days: ${{ inputs.keep }}\n")
            (wf / "caller.yml").write_text(
                "jobs:\n  c:\n    uses: ./.github/workflows/lib.yml\n    with:\n      keep: 30\n")
            found = reusable_workflow_findings(root)
            self.assertEqual(len(found), 2, found)

    def test_nested_composite_actions_and_pages_uploads_are_scanned(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github/workflows").mkdir(parents=True)
            nested = root / ".github/actions/a/b"
            nested.mkdir(parents=True)
            (nested / "action.yml").write_text(
                "runs:\n  using: composite\n  steps:\n    - uses: actions/upload-pages-artifact@v3\n"
                "      with:\n        name: site\n")
            self.assertEqual(list(violations(root)), [".github/actions/a/b/action.yml::(composite)::site"])

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
