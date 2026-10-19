#!/usr/bin/env python3
"""The Linux tests lane runs the test files an agent names at a pushed commit, on Blacksmith Linux.

Agents ran webview, bun and browser tests on a shared dev box because CI had
no lane for an ad-hoc run of a few files. linux-tests.yml is that lane, and
scripts/run-linux-tests.sh dispatches it in one command.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "linux-tests.yml"
WRAPPER = ROOT / "scripts" / "run-linux-tests.sh"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import linux_test_files  # noqa: E402


class PlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for path in ("webviews/package.json", "webviews/bun.lock", "webviews/test/a.test.tsx",
                     "webviews/test/b.test.ts", "web/package.json", "web/bun.lock", "web/lib/x.test.ts",
                     "webviews/src/notatest.ts"):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text("")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_files_group_by_their_package(self) -> None:
        plan = linux_test_files.plan(self.root, "webviews/test/a.test.tsx web/lib/x.test.ts\nwebviews/test/b.test.ts")
        self.assertEqual(plan, {"web": ["lib/x.test.ts"], "webviews": ["test/a.test.tsx", "test/b.test.ts"]})

    def test_a_path_relative_to_webviews_is_accepted(self) -> None:
        self.assertEqual(linux_test_files.plan(self.root, "test/a.test.tsx"), {"webviews": ["test/a.test.tsx"]})

    def test_bad_paths_are_refused(self) -> None:
        for files in ("../etc/passwd.test.ts", "webviews/test/missing.test.ts", "webviews/src/notatest.ts",
                      "/abs/a.test.ts", "webviews/test/a.test.tsx; rm -rf /", ""):
            with self.subTest(files=files), self.assertRaises(linux_test_files.PlanError):
                linux_test_files.plan(self.root, files)


class WorkflowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = yaml.safe_load(WORKFLOW.read_text())

    def test_it_is_a_dispatch_with_a_ref_and_files(self) -> None:
        inputs = self.workflow[True]["workflow_dispatch"]["inputs"]
        self.assertTrue(inputs["ref"]["required"])
        self.assertTrue(inputs["files"]["required"])
        self.assertIn("blacksmith-8vcpu-ubuntu-2404", inputs["runner"]["options"])

    def test_no_input_is_spliced_into_a_script(self) -> None:
        for job in self.workflow["jobs"].values():
            for step in job["steps"]:
                self.assertNotIn("inputs.", step.get("run", ""), step.get("name"))

    def test_it_holds_no_write_token(self) -> None:
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})


class WrapperTests(unittest.TestCase):
    """Argument errors stop before any GitHub call (gh is not on PATH here)."""

    def run_wrapper(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(WRAPPER), *args], capture_output=True, text=True, check=False,
                              env={"PATH": "/usr/bin:/bin"})

    def test_no_files_is_an_error(self) -> None:
        done = self.run_wrapper("--ref", "abc")
        self.assertEqual(done.returncode, 2)
        self.assertIn("at least one test file", done.stderr)

    def test_an_unknown_size_is_an_error(self) -> None:
        done = self.run_wrapper("--runner", "64", "test/a.test.ts")
        self.assertEqual(done.returncode, 2)
        self.assertIn("4, 8, 16 or 32", done.stderr)

    def test_help_prints_the_usage(self) -> None:
        done = self.run_wrapper("--help")
        self.assertEqual(done.returncode, 0)
        self.assertIn("--ref SHA", done.stdout)


if __name__ == "__main__":
    unittest.main()
