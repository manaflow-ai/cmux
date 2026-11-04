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

    def test_jsonc_configuration_is_left_to_its_own_checker(self):
        self.write("tsconfig.json", '{"compilerOptions": {}}')
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()
        self.write("tsconfig.json", '{// JSONC is valid for TypeScript\n"compilerOptions": {}}')
        self.commit()
        code, receipt = self.tier()
        self.assertEqual(code, 0, receipt)
        self.assertFalse(any(c["name"] == "tsconfig.json" for c in receipt["checks"]))

    def test_slow_range_discovery_defers_and_supervisor_cleans_its_scratch(self):
        installed = Path(self.temp.name) / "installed"
        installed.mkdir()
        for name in ("prepush_fast_tier.py", "inner_loop_timing.py"):
            shutil.copy2(TIER.with_name(name), installed / name)
        (installed / "push_range.py").write_text(
            "import time\ndef given_range(*args):\n    time.sleep(60)\n")
        scratch = Path(self.temp.name) / "scratch"
        scratch.mkdir()
        run = subprocess.run([sys.executable, "-I", str(installed / TIER.name), "--repo", str(self.repo),
                              "--base", self.base, "--head", "HEAD"], capture_output=True,
                             text=True, env={**self.env, "TMPDIR": str(scratch)}, timeout=8)
        receipt = json.loads(run.stdout)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(receipt["status"], "deferred")
        self.assertIn("budget exhausted", receipt["checks"][0]["detail"])
        self.assertEqual(list(scratch.iterdir()), [])

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

    def test_post_tool_read_and_failed_edit_do_not_start_edit_clock(self):
        spec = importlib.util.spec_from_file_location("post_edit_timing_test", ROOT / "scripts/ci/post_edit_checks.py")
        post_edit = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(post_edit)
        payload = {"tool_name": "Read", "tool_input": {"file_path": "check.py"}}
        self.assertFalse(post_edit.is_edit_event(json.dumps(payload)))
        payload["tool_name"] = "Edit"
        self.assertTrue(post_edit.is_edit_event(json.dumps(payload)))
        self.assertEqual(post_edit.relative(self.repo, "deleted.py", None, must_exist=False), "deleted.py")
        self.assertIsNone(post_edit.relative(self.repo, "../outside.py", None, must_exist=False))
        payload["tool_response"] = {"is_error": True}
        self.assertFalse(post_edit.is_edit_event(json.dumps(payload)))

    @unittest.skipUnless(sys.platform == "linux" and shutil.which("bwrap") and shutil.which("bun")
                         and (ROOT / "webviews/node_modules/typescript/lib/tsc.js").is_file(),
                         "needs the Linux sandbox and warm TypeScript/Bun")
    def test_entire_selected_manifest_typechecks_and_runs_within_work_budget(self):
        manifest = json.loads(TIER.with_name("prepush-fast-suites.json").read_text())
        for entry in manifest["suites"]:
            for path in entry.values():
                self.write(path, (ROOT / path).read_text() + "\n// selected suite fixture\n")
        self.commit()
        modules = self.repo / "webviews/node_modules"
        modules.mkdir()
        (modules / "typescript").symlink_to(
            (ROOT / "webviews/node_modules/typescript").resolve(), target_is_directory=True)
        code, receipt = self.tier()
        self.assertEqual(code, 0, receipt)
        self.assertEqual(receipt["status"], "passed", receipt)
        self.assertTrue(any(c["name"] == "selected-file typecheck" for c in receipt["checks"]))
        self.assertTrue(any(c["name"] == "selected unit suites" for c in receipt["checks"]))

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
