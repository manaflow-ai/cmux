"""Real git-object feedback and sandboxed changed-test execution for the bounded tier."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TIER = ROOT / "scripts/cmux-next/prepush_fast_tier.py"
SOURCE = "webviews/src/agent-session/acpmux/goal.ts"
TEST = "webviews/src/agent-session/acpmux/goal.test.ts"


class TierTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "CMUX_FAST_TIER_DISABLED"):
            self.env.pop(key, None)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("config", "gc.auto", "0")
        for path in (SOURCE, TEST):
            self.write(path, (ROOT / path).read_text())
        self.write("check.py", "value = 1\n")
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True,
                              text=True, check=True, env=self.env).stdout

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def tier(self, **extra):
        run = subprocess.run([sys.executable, "-I", str(TIER), "--repo", str(self.repo),
                              "--base", self.base, "--head", "HEAD"], capture_output=True,
                             text=True, env={**self.env, **extra}, timeout=8)
        return run.returncode, json.loads(run.stdout)

    def test_committed_syntax_error_not_hidden_by_working_tree_fix(self):
        self.write("check.py", "value =\n")
        self.commit()
        self.write("check.py", "value = 2\n")
        code, receipt = self.tier()
        self.assertEqual(code, 1)
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["head"], self.git("rev-parse", "HEAD").strip())
        saved = json.loads((self.repo / ".git/cmux-inner-loop.json").read_text())
        self.assertIsNone(saved["first_edit_at"])
        self.assertEqual(saved["prepush"]["head"], receipt["head"])

    def test_kill_switch_is_deferred_and_does_not_fake_pass(self):
        self.write("check.py", "value =\n")
        self.commit()
        code, receipt = self.tier(CMUX_FAST_TIER_DISABLED="1")
        self.assertEqual(code, 0)
        self.assertEqual(receipt["status"], "deferred")

    def test_edit_timestamp_survives_commits_and_resets_on_branch_change(self):
        spec = importlib.util.spec_from_file_location("timing_test", TIER.with_name("inner_loop_timing.py"))
        timing = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(timing)
        timing.record(self.repo, edit=True)
        path = self.repo / ".git/cmux-inner-loop.json"
        first = json.loads(path.read_text())["first_edit_at"]
        self.write("check.py", "value = 2\n")
        self.commit()
        timing.record(self.repo, edit=True)
        self.assertEqual(json.loads(path.read_text())["first_edit_at"], first)
        self.git("checkout", "-qb", "other")
        timing.record(self.repo, prepush={"head": self.git("rev-parse", "HEAD").strip()})
        self.assertIsNone(json.loads(path.read_text())["first_edit_at"])

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("bwrap") and shutil.which("bun"),
                         "needs the Linux sandbox and warm Bun")
    def test_changed_unit_suite_runs_without_host_files_environment_or_network(self):
        test = '''import { expect, test } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";
import { taskGoal } from "./goal";
test("sandbox and changed source", async () => {
  expect(taskGoal({objective: "x", status: "active"})?.objective).toBe("x");
  expect(process.env.TIER_SECRET).toBeUndefined();
  expect(existsSync("/home")).toBe(false);
  expect(existsSync("/src/.env")).toBe(false);
  expect(existsSync("/src/.git")).toBe(false);
  expect(() => writeFileSync("/src/escape", "bad")).toThrow();
  await expect(fetch("http://127.0.0.1:9")).rejects.toThrow();
});
'''
        self.write(TEST, test)
        self.commit()
        self.write(".env", "TIER_SECRET=do-not-read")
        code, receipt = self.tier(TIER_SECRET="do-not-read")
        unit = next(c for c in receipt["checks"] if c["name"] == "selected unit suites")
        if unit["status"] == "deferred":
            self.skipTest(unit["detail"])
        self.assertEqual(code, 0, receipt)
        self.assertEqual(unit["status"], "passed", receipt)
        self.assertIn("1 pass", unit["detail"])
        self.assertFalse((self.repo / "escape").exists())
        # A pushed failing assertion is a red even with an uncommitted green test.
        self.write(TEST, test.replace('toBe("x")', 'toBe("wrong")'))
        self.commit()
        self.write(TEST, test)
        code, receipt = self.tier()
        self.assertEqual(code, 1, receipt)
        self.assertEqual(receipt["status"], "failed")


if __name__ == "__main__":
    unittest.main()
