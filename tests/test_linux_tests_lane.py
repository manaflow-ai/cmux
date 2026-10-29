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

    def test_a_file_whose_package_is_the_root_is_planned(self) -> None:
        (self.root / "package.json").write_text("{}")
        (self.root / "bun.lock").write_text("")
        (self.root / "tests").mkdir()
        (self.root / "tests" / "r.test.ts").write_text("")
        self.assertEqual(linux_test_files.plan(self.root, "tests/r.test.ts"), {".": ["tests/r.test.ts"]})

    def test_a_vitest_package_is_refused(self) -> None:
        (self.root / "web/package.json").write_text('{"scripts": {"test": "vitest run"}}')
        with self.assertRaisesRegex(linux_test_files.PlanError, "vitest"):
            linux_test_files.plan(self.root, "web/lib/x.test.ts")

    def test_a_link_out_of_the_checkout_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as outside:
            target = Path(outside) / "evil.test.ts"
            target.write_text("")
            (self.root / "webviews/test/link.test.ts").symlink_to(target)
            with self.assertRaisesRegex(linux_test_files.PlanError, "outside"):
                linux_test_files.plan(self.root, "webviews/test/link.test.ts")

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
            for step in job.get("steps", []):
                self.assertNotIn("inputs.", step.get("run", ""), step.get("name"))

    def test_it_holds_no_write_token(self) -> None:
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})

    def test_only_a_branch_head_of_this_repository_runs(self) -> None:
        jobs = self.workflow["jobs"]
        self.assertEqual(jobs["resolve"]["uses"], "./.github/workflows/resolve-dispatch-ref.yml")
        self.assertIn("resolve", jobs["test"]["needs"])
        steps = jobs["test"]["steps"]
        self.assertIn("trusted_ref", str(steps[0]))
        checkout = next(step for step in steps if step.get("with", {}).get("path") == "src")
        self.assertEqual(checkout["with"]["ref"], "${{ needs.resolve.outputs.sha }}")

    def test_each_file_is_named_as_a_path_not_a_filter(self) -> None:
        run = next(step["run"] for step in self.workflow["jobs"]["test"]["steps"]
                   if step.get("name") == "Run the test files")
        self.assertIn('bun test "./$file"', run)


class RunStepTests(unittest.TestCase):
    """Actions runs a step under `bash -e`, so a failing file stopped the loop: run
    39348727248 named 14 files and tested 3."""

    def test_a_failing_file_does_not_stop_the_rest(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text())
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])]
        script = next(step["run"] for step in steps if 'bun test "./$file"' in step.get("run", ""))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pkg").mkdir()
            for name in ("a.test.ts", "b.test.ts"):
                (root / "pkg" / name).write_text("")
            (root / "plan.tsv").write_text("pkg\ta.test.ts b.test.ts\n")
            bin_dir = root / "bin"
            bin_dir.mkdir()
            (bin_dir / "bun").write_text(
                '#!/usr/bin/env bash\necho "$2" >> "$RAN"\n[ "$2" != ./a.test.ts ]\n')
            (bin_dir / "bun").chmod(0o755)
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": tmp,
                   "FILE_TIMEOUT": "30", "GITHUB_STEP_SUMMARY": str(root / "summary.md"),
                   "RAN": str(root / "ran.txt")}
            result = subprocess.run(["bash", "-e", "-c", script], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual((root / "ran.txt").read_text().split(), ["./a.test.ts", "./b.test.ts"])
            summary = (root / "summary.md").read_text()
            self.assertIn("`pkg/a.test.ts` | failed (1)", summary)
            self.assertIn("`pkg/b.test.ts` | pass", summary)


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
