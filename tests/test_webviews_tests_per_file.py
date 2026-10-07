#!/usr/bin/env python3
"""scripts/ci/run-webviews-tests.sh runs each webviews test file in its own bun process.

A full `bun test` in webviews stalled in a different file each run (ui-menu,
markdown-viewer-shell, chips/linkChips) until the job timeout, and each stalled
file passes alone. Per-file processes with a wall-clock timeout name the stuck
file and fail the step instead of hanging the job. A fake `bun` stands in for
the real one, so no web test runs here.
"""

import os
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "ci" / "run-webviews-tests.sh"
WORKFLOW = ROOT / ".github" / "workflows" / "ci-web.yml"

FAKE_BUN = """#!/usr/bin/env bash
[ "$1" = test ] || exit 9
printf '%s\\n' "$2" >> "$BUN_CALLS"
case "$2" in
  *hang*) sleep 60 ;;
  *fail*) echo "(fail) a broken test"; exit 1 ;;
  *) echo "(pass) $2" ;;
esac
"""


class PerFileRunner(unittest.TestCase):
    def run_runner(self, files):
        temp = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory()))
        web = temp / "webviews"
        for name in files:
            path = web / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("", encoding="utf-8")
        (web / "src" / "helper.ts").parent.mkdir(parents=True, exist_ok=True)
        (web / "src" / "helper.ts").write_text("", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(temp)], check=True)
        subprocess.run(["git", "-C", str(temp), "add", "-A"], check=True)
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        (bin_dir / "bun").write_text(FAKE_BUN, encoding="utf-8")
        (bin_dir / "bun").chmod(0o755)
        calls = temp / "calls"
        calls.write_text("", encoding="utf-8")
        env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "BUN_CALLS": str(calls),
               "CMUX_WEB_TEST_FILE_TIMEOUT": "2", "CMUX_WEB_TEST_JOBS": "4"}
        started = time.monotonic()
        result = subprocess.run(["bash", str(RUNNER)], cwd=web, env=env, capture_output=True, text=True, timeout=40)
        return result, time.monotonic() - started, sorted(calls.read_text(encoding="utf-8").split())

    def test_a_stuck_file_is_named_and_fails_without_hanging(self):
        files = ["test/a.test.ts", "test/hang.test.tsx", "src/pages/fail.test.ts", "src/b.test.tsx"]
        result, elapsed, calls = self.run_runner(files)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertLess(elapsed, 20, output)
        self.assertEqual(calls, sorted(f"./{name}" for name in files))
        self.assertRegex(output, r"TIMEOUT[^\n]*test/hang\.test\.tsx")
        self.assertRegex(output, r"FAIL[^\n]*src/pages/fail\.test\.ts")
        self.assertNotRegex(output, r"(FAIL|TIMEOUT)[^\n]*test/a\.test\.ts")
        self.assertIn("(fail) a broken test", output)

    def test_passing_files_pass(self):
        result, _, calls = self.run_runner(["test/a.test.ts", "src/b.test.tsx"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, ["./src/b.test.tsx", "./test/a.test.ts"])

    def test_no_test_files_is_an_error(self):
        result, _, _ = self.run_runner([])
        self.assertNotEqual(result.returncode, 0)

    def test_ci_runs_webviews_tests_per_file(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        step = text[text.index("      - name: Test webviews\n"):]
        step = step[: step.index("\n      - name:", 10)]
        self.assertIn("scripts/ci/run-webviews-tests.sh", step)
        self.assertNotIn("bun run test", step)


if __name__ == "__main__":
    unittest.main()
