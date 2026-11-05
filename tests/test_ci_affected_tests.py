#!/usr/bin/env python3
"""scripts/ci/affected_tests.py: the fleet steps `cmux-ci test --affected` runs for a change.

Runs against this checkout's own tree (the maps are derived from it), with explicit
changed paths, and needs only git and python3 (no cargo, swift or bun).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import affected_tests  # noqa: E402

BASE = "a" * 40
HEAD = "b" * 40


def plan(files, everything=False, shards=4):
    return affected_tests.plan(ROOT, BASE, HEAD, files, shards, everything)


def names(result):
    return [u["name"] for u in result["units"]]


class AffectedTests(unittest.TestCase):
    def test_rust_change_sends_the_affected_scope_with_shards(self):
        result = plan(["cmux-tui/crates/cmux-config/src/lib.rs"])
        self.assertFalse(result["all"], result["reasons"])
        rust = [u for u in result["units"] if u["kind"] == "rust"]
        self.assertEqual(len(rust), 1)
        argv = rust[0]["argv"]
        self.assertIn(f"--arg=@affected={BASE}", argv)
        self.assertIn("--arg=test", argv)
        self.assertEqual(argv[argv.index("--os") + 1], "linux")
        self.assertEqual(argv[argv.index("--shards") + 1], "4")
        self.assertEqual(argv[argv.index("--ref") + 1], HEAD)

    def test_one_shard_sends_no_shards_flag(self):
        argv = plan(["cmux-tui/crates/cmux-config/src/lib.rs"], shards=1)["units"][0]["argv"]
        self.assertNotIn("--shards", argv)

    def test_docs_select_nothing(self):
        result = plan(["cmux-tui/AGENTS.md"])
        self.assertFalse(result["all"])
        self.assertEqual(result["units"], [])

    def test_unmapped_path_runs_everything(self):
        # Built at run time, so no test file (this one included) names the path.
        result = plan(["/".join(("zz-unmapped", "nothing", "names" + "-this.bin"))])
        self.assertTrue(result["all"])
        self.assertTrue(any("no rule maps it" in r for r in result["reasons"]), result["reasons"])
        self.assertIn("rust", names(result))
        rust = next(u for u in result["units"] if u["kind"] == "rust")
        self.assertNotIn(f"--arg=@affected={BASE}", rust["argv"])

    def test_a_change_to_the_planner_runs_everything(self):
        for path in ("scripts/ci/affected_tests.py", "scripts/ci/cargo_affected.py", "scripts/ci/cmux-tui-rust-check.sh"):
            with self.subTest(path=path):
                self.assertTrue(plan([path])["all"])

    def test_all_is_every_suite(self):
        result = plan([], everything=True)
        self.assertEqual(result["reasons"], ["--all"])
        kinds = {u["kind"] for u in result["units"]}
        self.assertTrue({"rust", "swift", "web", "python"} <= kinds, kinds)
        swift = [u for u in result["units"] if u["kind"] == "swift"]
        cmux_next = [u for u in swift if "--arg=Packages/macOS/CmuxNext" in u["argv"]]
        listed = {t for u in cmux_next for t in u["argv"][-1].removeprefix("--arg=").split(",")}
        self.assertEqual(listed, set(affected_tests.swift_test_targets(ROOT, "Packages/macOS/CmuxNext")))

    def test_too_many_paths_runs_everything(self):
        files = [f"cmux-tui/AGENTS-{i}.md" for i in range(affected_tests.MAX_FILES + 1)]
        self.assertTrue(plan(files)["all"])

    def test_changed_python_test_runs_itself_on_the_linux_lane(self):
        result = plan(["tests/test_ci_affected_tests.py"])
        py = [u for u in result["units"] if u["kind"] == "python"]
        self.assertEqual(len(py), 1)
        argv = py[0]["argv"]
        self.assertEqual(argv[:4], ["test", "--setup", "none", "--"])
        self.assertIn("tests/test_ci_affected_tests.py", argv)
        self.assertEqual(argv[argv.index("--lane") + 1], "linux-guard")

    def test_python_on_a_macos_lane_is_listed_not_dropped(self):
        lanes = affected_tests.python_lane_tests(ROOT)
        mac = sorted(p for p, lane in lanes.items() if lane.startswith("macos-"))
        self.assertTrue(mac)
        result = plan([mac[0]])
        self.assertIn(mac[0], [n["what"] for n in result["not_run"]])

    def test_webviews_source_runs_the_tests_that_import_it(self):
        tests = affected_tests.web_tests(ROOT)
        self.assertTrue(tests)
        target = "webviews/" + tests[0]
        result = plan([target])
        web = [u for u in result["units"] if u["kind"] == "web"]
        self.assertTrue(web)
        files = "\n".join(arg for u in web for arg in u["argv"] if arg.startswith("CMUX_WEB_TEST_FILES="))
        self.assertIn(tests[0], files)

    def test_swift_shards_split_targets_without_loss(self):
        targets = affected_tests.swift_test_targets(ROOT, "Packages/macOS/CmuxNext")
        parts = affected_tests.split(targets, 4)
        self.assertEqual(len(parts), 4)
        self.assertEqual(sorted(t for part in parts for t in part), targets)
        self.assertEqual(affected_tests.split(["a"], 4), [["a"]])

    def test_cli_prints_json(self):
        out = subprocess.run([sys.executable, str(ROOT / "scripts/ci/affected_tests.py"), "--base", "HEAD", "--head", "HEAD",
                              "--files", "cmux-tui/AGENTS.md"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
        data = json.loads(out)
        self.assertEqual(data["units"], [])
        self.assertRegex(data["head"], r"^[0-9a-f]{40}$")


class RustCheckAffectedScope(unittest.TestCase):
    SCRIPT = ROOT / "scripts/ci/cmux-tui-rust-check.sh"

    def run_script(self, *args):
        env = {**os.environ, "CMUX_CI_STEP_KEY": "unit-test"}
        return subprocess.run(["bash", str(self.SCRIPT), *args], cwd=ROOT, env=env, capture_output=True, text=True,
                              timeout=60)

    def test_refuses_a_short_base(self):
        result = self.run_script("test", "@affected=abc")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("40-hex", result.stderr)

    def test_refuses_another_mode(self):
        result = self.run_script("clippy", f"@affected={BASE}")
        self.assertEqual(result.returncode, 2, result.stderr)


class PythonLanePaths(unittest.TestCase):
    RUNNER = ROOT / "scripts/ci/run_python_test_lane.py"

    def test_path_limits_the_lane(self):
        out = subprocess.run([sys.executable, str(self.RUNNER), "--lane", "linux-guard", "--list",
                              "--path", "tests/test_ci_affected_tests.py"], cwd=ROOT, check=True,
                             capture_output=True, text=True).stdout.split()
        self.assertEqual(out, ["tests/test_ci_affected_tests.py"])

    def test_unknown_path_fails(self):
        result = subprocess.run([sys.executable, str(self.RUNNER), "--lane", "linux-guard", "--list",
                                 "--path", "tests/no_such_test.py"], cwd=ROOT, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tests/no_such_test.py", result.stderr)


if __name__ == "__main__":
    unittest.main()
