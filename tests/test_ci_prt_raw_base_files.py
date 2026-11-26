#!/usr/bin/env python3
"""The pull_request_target checks read their base files over raw at a sha before any checkout.

risk evidence, merge freeze, language-boundaries and intent warn run from main's copy on every
feat-cmux-next pull request event. A sparse blobless actions/checkout of one or two files took 30
to 180 s of each job on Blacksmith (the promisor blob fetch at `git checkout`, or a ref listing the
git mirror proxy answered with a 502 after 90 s). Each job now reads those files from
raw.githubusercontent.com at a commit sha first, and actions/checkout runs only when that read
fails. This pins:

- the raw read comes before the checkout, never fails the job, and names a sha from the base side
  (never the pull request's head, a refs/pull ref or a branch name in the URL);
- the checkout still exists, gated only on the raw read not succeeding;
- the raw read fetches the same files the checkout's sparse list names (bar api_call_log, off
  since 2026-11-23);
- the job names and the later steps are unchanged.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

CASES = {
    "risk-tier.yml": ("evidence", "Checkout the classifier at the tip of the pull request's base branch"),
    "merge-freeze.yml": ("check", "Checkout the checker from main"),
    "language-boundaries.yml": ("language-boundaries", "Check out the check and the manifest from the base commit"),
    "intent-familiar-review.yml": ("warn", "Check out the warning script from the base commit"),
}

JOB_NAMES = {
    "risk-tier.yml": "risk evidence",
    "merge-freeze.yml": "merge freeze",
    "language-boundaries.yml": "language-boundaries",
}

GATE = "steps.raw.outputs.ok != 'true'"
BASE_SHAS = {
    "risk-tier.yml": None,  # resolves the base branch tip with a git ls-refs request
    "merge-freeze.yml": "${{ github.sha }}",
    "language-boundaries.yml": "${{ github.event.pull_request.base.sha }}",
    "intent-familiar-review.yml": "${{ github.event.pull_request.base.sha }}",
}


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text())


class RawBaseFilesTest(unittest.TestCase):
    def test_raw_read_precedes_a_gated_checkout(self) -> None:
        for name, (job_id, checkout_name) in CASES.items():
            with self.subTest(workflow=name):
                steps = load(name)["jobs"][job_id]["steps"]
                ids = [s.get("id") for s in steps]
                self.assertIn("raw", ids)
                raw_index = ids.index("raw")
                raw = steps[raw_index]
                names = [s.get("name") for s in steps]
                self.assertIn(checkout_name, names)
                checkout_index = names.index(checkout_name)
                self.assertLess(raw_index, checkout_index)
                checkout = steps[checkout_index]
                self.assertTrue(checkout["uses"].startswith("actions/checkout@"))
                self.assertEqual(checkout.get("if"), GATE)
                self.assertIs(raw.get("continue-on-error"), True)
                self.assertLessEqual(int(raw.get("timeout-minutes", 99)), 2)
                # Nothing else reads the raw step's output, so the later steps are as before.
                for other in steps:
                    if other is not checkout:
                        self.assertNotIn("steps.raw", str(other.get("if", "")))

    def test_raw_read_names_a_base_sha_and_never_the_head(self) -> None:
        for name, (job_id, _) in CASES.items():
            with self.subTest(workflow=name):
                steps = load(name)["jobs"][job_id]["steps"]
                raw = next(s for s in steps if s.get("id") == "raw")
                text = yaml.safe_dump(raw)
                for forbidden in ("head.sha", "head.ref", "refs/pull", "github.head_ref", "pull/"):
                    self.assertNotIn(forbidden, text)
                self.assertIn('"https://raw.githubusercontent.com/$REPO/$SHA/$f")" || code=000', raw["run"])
                # Anything but a 200 (or a 404 for a file the checkout may also find absent) falls back.
                self.assertIn('elif [ "$code" != 200 ]' if "OPTIONAL_FILES" in raw["env"] else 'if [ "$code" != 200 ]', raw["run"])
                self.assertIn('[[ "$SHA" =~ ^[0-9a-f]{40}$ ]]', raw["run"])
                self.assertEqual(raw["env"]["RAW_TOKEN"], "${{ github.token }}")
                self.assertIn('-H "Authorization: token $RAW_TOKEN"', raw["run"])
                self.assertEqual(raw["run"].count("$RAW_TOKEN"), 1)
                self.assertIn('echo "ok=true" >> "$GITHUB_OUTPUT"', raw["run"])
                # Files land in the workspace only after every read succeeded.
                self.assertLess(raw["run"].index("done"), raw["run"].index('cp -R "$part"/. .'))
                expected = BASE_SHAS[name]
                if expected is None:
                    self.assertIn('"https://github.com/$REPO.git/git-upload-pack"', raw["run"])
                    self.assertIn('ref-prefix refs/heads/$BASE_REF', raw["run"])
                    self.assertNotIn("git ls-remote", raw["run"])
                    self.assertEqual(raw["env"]["BASE_REF"], "${{ github.event.pull_request.base.ref }}")
                else:
                    self.assertEqual(raw["env"]["SHA"], expected)

    def test_raw_read_fetches_the_checkout_files(self) -> None:
        for name, (job_id, checkout_name) in CASES.items():
            with self.subTest(workflow=name):
                steps = load(name)["jobs"][job_id]["steps"]
                raw = next(s for s in steps if s.get("id") == "raw")
                checkout = next(s for s in steps if s.get("name") == checkout_name)
                sparse = {
                    line.strip()
                    for line in checkout["with"]["sparse-checkout"].splitlines()
                    if line.strip() and line.strip() != "scripts/ci/api_call_log"
                }
                read = set(raw["env"]["FILES"].split()) | set(raw["env"].get("OPTIONAL_FILES", "").split())
                self.assertEqual(read, sparse)

    def test_language_boundaries_keeps_a_repository_for_its_merge_fetch(self) -> None:
        steps = load("language-boundaries.yml")["jobs"]["language-boundaries"]["steps"]
        raw = next(s for s in steps if s.get("id") == "raw")
        self.assertIn("git init -q .", raw["run"])
        self.assertIn('git remote add origin "https://github.com/$REPO"', raw["run"])
        check = next(s for s in steps if s.get("name") == "Check the changed files against the language boundaries")
        self.assertIn("refs/pull/$PR/merge", check["run"])

    def test_job_names_unchanged(self) -> None:
        for name, expected in JOB_NAMES.items():
            with self.subTest(workflow=name):
                job_id = CASES[name][0]
                job_name = load(name)["jobs"][job_id]["name"]
                self.assertTrue(re.search(rf"'{re.escape(expected)}' \}}\}}$|^{re.escape(expected)}$", job_name), job_name)


if __name__ == "__main__":
    unittest.main()
