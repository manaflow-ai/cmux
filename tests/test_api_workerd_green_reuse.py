#!/usr/bin/env python3
"""The api-workerd green reuse (backend.yml) keys on every path the shard's tests read, and fails closed.

A shard that passed is recorded under scripts/ci/receipt_input_key.py's key of scripts/ci/receipt-inputs/api-workerd.txt,
and a later run of it with the same key skips its tests. These hold that:
  - every relative path the Worker's code and tests, the backend packages, the client, the cmux VM SDK and the shared
    libs name (an import, a readFileSync, a new URL) lands inside a tree row, so no read outside the rows can let a
    stale green stand;
  - in the job, every step that sets up or runs the tests is skipped only on the reuse step's `skip`, the verdict the
    `test` gate reads is still recorded on a reuse, and the marker is saved and looked up under one key, only after
    this run's own tests passed on a miss.
"""
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import receipt_input_key as rik  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "backend.yml"
SOURCE = re.compile(r"\.(ts|tsx|mts|js|mjs|cjs|json|jsonc)$")
RELATIVE = re.compile(r"""['"`]((?:\.\./)+[^'"`\s?#]*)""")
# Code the api-workerd shards never run: Node-only tests (test-node, the test job), the database's own suites, and
# the generator and lint scripts under backend/scripts and packages/*/scripts (the test job and catalog:check).
NOT_RUN = re.compile(r"(^|/)(test-node|test-pg|test-mysql)/|^backend/scripts/|^backend/packages/[^/]+/scripts/")
SKIP = "${{ steps.green.outputs.skip != 'true' }}"


def tree_rows():
    return [rel for unit, kind, rel in rik.load_inputs("api-workerd") if kind == "tree"]


def job_steps():
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["api-workerd"]["steps"]


class InputsTest(unittest.TestCase):
    def test_every_path_the_code_names_is_an_input(self):
        trees = tree_rows()
        files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", *trees], capture_output=True,
                               check=True).stdout.decode().split("\0")
        missing = {}
        for rel in files:
            if not SOURCE.search(rel) or NOT_RUN.search(rel) or "/node_modules/" in rel:
                continue
            try:
                text = (ROOT / rel).read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            for match in RELATIVE.finditer(text):
                target = Path(os.path.normpath((ROOT / rel).parent / match.group(1)))
                try:
                    named = target.relative_to(ROOT).as_posix()
                except ValueError:
                    continue
                if named == "." or not any(named == t or named.startswith(t + "/") for t in trees):
                    missing.setdefault(named, rel)
        self.assertEqual({}, missing, "paths the api-workerd tests' code names outside "
                         "scripts/ci/receipt-inputs/api-workerd.txt (add a row for each)")

    def test_the_rows_cover_the_scripts_the_job_runs(self):
        rows = {rel for _, _, rel in rik.load_inputs("api-workerd")}
        for rel in (".github/workflows/backend.yml", "scripts/ci/api-workerd-shard.sh", "scripts/ci/toolchain-r2.sh",
                    "scripts/ci/receipt_input_key.py", "scripts/ci/receipt-inputs/api-workerd.txt", "backend"):
            self.assertIn(rel, rows)

    def test_the_key_is_computed_here(self):
        key, material = rik.input_key("api-workerd", [])
        self.assertRegex(key, r"^[0-9a-f]{64}$")
        self.assertIsNotNone(material["inputs"]["backend"])


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.steps = job_steps()
        self.by_id = {s["id"]: s for s in self.steps if "id" in s}

    def test_setup_and_tests_skip_only_on_a_reuse(self):
        reuse = self.steps.index(self.by_id["green"])
        shard = self.steps.index(self.by_id["shard"])
        self.assertLess(reuse, shard)
        for step in self.steps[reuse + 1:shard + 1]:
            self.assertEqual(SKIP, step.get("if"), step.get("name") or step.get("uses") or step.get("run"))

    def test_the_key_and_lookup_fail_closed(self):
        key, lookup, reuse = self.by_id["green-key"], self.by_id["green-lookup"], self.by_id["green"]
        self.assertTrue(key["continue-on-error"])
        self.assertTrue(lookup["continue-on-error"])
        self.assertIn("head.repo.full_name == github.repository", key["if"])
        self.assertIn("steps.green-key.outcome == 'success'", lookup["if"])
        self.assertTrue(lookup["with"]["lookup-only"])
        self.assertNotIn("restore-keys", lookup["with"])
        self.assertIn("steps.green-lookup.outcome == 'success'", reuse["if"])
        self.assertIn("cache-hit == 'true'", reuse["if"])
        self.assertIn("GITHUB_RUN_ID % 10 == 0", reuse["run"])

    def test_a_reuse_still_records_a_success_verdict(self):
        record = next(s for s in self.steps if s.get("name") == "Record the shard's test verdict")
        upload = next(s for s in self.steps if s.get("name") == "Upload the shard's test verdict")
        for step in (record, upload):
            self.assertIn("steps.green.outputs.skip == 'true'", step["if"])
        self.assertIn("steps.green.outputs.skip == 'true' && 'success'", record["run"])

    def test_the_marker_is_saved_after_a_pass_on_a_miss_under_the_lookup_key(self):
        mark, lookup = self.by_id["green-mark"], self.by_id["green-lookup"]
        save = self.steps[self.steps.index(mark) + 1]
        self.assertIn("steps.shard.outcome == 'success'", mark["if"])
        self.assertIn("cache-hit != 'true'", mark["if"])
        self.assertTrue(save["uses"].startswith("actions/cache/save@"))
        self.assertEqual(lookup["with"]["key"], save["with"]["key"])
        self.assertEqual(lookup["with"]["path"], save["with"]["path"])
        self.assertIn("${{ matrix.shard }}", save["with"]["key"])


if __name__ == "__main__":
    unittest.main()
