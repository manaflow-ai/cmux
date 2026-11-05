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
        units = plan(["cmux-tui/crates/cmux-config/src/lib.rs"], shards=1)["units"]
        argv = next(u for u in units if u["kind"] == "rust")["argv"]
        self.assertNotIn("--shards", argv)

    def test_docs_run_only_the_guards(self):
        result = plan(["plans/cmux-next/STATUS.md"])
        self.assertFalse(result["all"])
        self.assertEqual(names(result), ["guards"])

    def test_nothing_changed_runs_nothing(self):
        self.assertEqual(plan([])["units"], [])

    def test_a_doc_a_python_test_names_selects_it(self):
        # tests/test_base_red_excuse.py reads plans/cmux-next/rust-panic-free.md.
        argv = [a for u in plan(["plans/cmux-next/rust-panic-free.md"])["units"] for a in u["argv"]]
        self.assertIn("tests/test_base_red_excuse.py", argv)

    def test_every_code_change_runs_the_whole_tree_guards(self):
        # Guards such as the short-timeout ratchet read every file, so no path map can skip them.
        for path in ("cmux-tui/crates/cmux-config/src/lib.rs", "webviews/src/agent-session/acpmux/App.tsx"):
            with self.subTest(path=path):
                guards = [u for u in plan([path])["units"] if u["kind"] == "guards"]
                self.assertEqual(len(guards), 1)
                self.assertIn(affected_tests.GUARDS_SCRIPT, guards[0]["argv"])
                self.assertIn("--all", guards[0]["argv"])
        self.assertTrue(affected_tests.guard_tests(ROOT))

    def test_webviews_source_change_runs_every_web_test_with_the_browser_lane(self):
        # Browser and gallery tests load the whole app through vite, not through imports.
        web = [u for u in plan(["webviews/src/agent-session/acpmux/App.tsx"])["units"] if u["kind"] == "web"]
        self.assertEqual(len(web), 1)
        self.assertIn("CMUX_BROWSER_TESTS=1", web[0]["argv"])
        self.assertFalse(any(a.startswith("CMUX_WEB_TEST_FILES=") for a in web[0]["argv"]))

    def test_web_lists_stay_within_the_controllers_bound(self):
        files = [t for t in affected_tests.web_tests(ROOT) if affected_tests.WEB_FILE_OK.match(t)][:200]
        p = affected_tests.Planner(ROOT, BASE, HEAD, 2)
        p.web(files)
        sent = []
        for u in p.units:
            env = next(a for a in u["argv"] if a.startswith("CMUX_WEB_TEST_FILES="))
            part = env.split("=", 1)[1].splitlines()
            self.assertLessEqual(len(part), affected_tests.WEB_FILES_PER_STEP)
            self.assertTrue(all(affected_tests.WEB_FILE_OK.match(f) for f in part))
            sent += part
        self.assertEqual(sorted(sent), sorted(files))
        self.assertEqual(len({u["name"] for u in p.units}), len(p.units))

    def test_unit_keys_change_with_the_request(self):
        a = affected_tests.plan(ROOT, BASE, HEAD, ["cmux-tui/crates/cmux-config/src/lib.rs"], 4, False)
        b = affected_tests.plan(ROOT, "c" * 40, HEAD, ["cmux-tui/crates/cmux-config/src/lib.rs"], 2, False)
        key = lambda r: next(u["argv"][u["argv"].index("--key") + 1] for u in r["units"] if u["kind"] == "rust")
        self.assertNotEqual(key(a), key(b))

    def test_a_cmux_tui_tree_input_outside_cmux_tui_sends_the_rust_step(self):
        self.assertIn("rust", names(plan(["scripts/ci/macos_stubs.py"])))

    def test_a_skill_a_crate_embeds_sends_the_rust_step(self):
        # acpmux include_str!s skills/cmux-cua/SKILL.md.
        self.assertIn("rust", names(plan(["skills/cmux-cua/SKILL.md"])))
        self.assertNotIn("rust", names(plan(["plans/cmux-next/STATUS.md"])))

    def test_no_merge_base_runs_everything(self):
        out = subprocess.run([sys.executable, str(ROOT / "scripts/ci/affected_tests.py"), "--base", "no-such-ref-zz", "--head", "HEAD",
                              "--files", "cmux-tui/AGENTS.md"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
        data = json.loads(out)
        self.assertTrue(data["all"])
        self.assertIn("no merge base", data["reasons"][0])

    def test_an_unmapped_webviews_file_runs_every_web_test_not_every_suite(self):
        result = plan(["webviews/scripts/" + "zz-unmapped-baseline.jsonl"])
        self.assertFalse(result["all"], result["reasons"])
        web = [u for u in result["units"] if u["kind"] == "web"]
        self.assertEqual(len(web), 1)
        self.assertFalse(any(a.startswith("CMUX_WEB_TEST_FILES=") for a in web[0]["argv"]))
        self.assertNotIn("rust", names(result))

    def test_unit_names_are_unique_and_web_plans_take_the_web_workflows_python_tests(self):
        for files in (["webviews/src/agent-session/acpmux/App.tsx"], ["cmux-tui/crates/cmux-config/src/lib.rs"], []):
            with self.subTest(files=files):
                result = plan(files, everything=not files)
                self.assertEqual(len(names(result)), len(set(names(result))))
        argv = [a for u in plan(["webviews/src/agent-session/acpmux/App.tsx"])["units"] for a in u["argv"]]
        for test in affected_tests.web_workflow_python_tests(ROOT):
            self.assertIn(test, argv)

    def test_no_empty_web_unit(self):
        for u in plan(["plans/cmux-next/actions.md"])["units"]:
            for a in u["argv"]:
                self.assertNotEqual(a, "CMUX_WEB_TEST_FILES=")

    def test_a_plans_file_a_swift_test_reads_selects_that_target(self):
        # ActionSurfaceParityTests reads plans/cmux-next/actions.md by path.
        swift = [u for u in plan(["plans/cmux-next/actions.md"])["units"] if u["kind"] == "swift"]
        self.assertTrue(any("--arg=CmuxNextActionsTests" in ",".join(u["argv"]) or
                            any("CmuxNextActionsTests" in a for a in u["argv"]) for u in swift), swift)

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
                              "--files", "plans/cmux-next/STATUS.md"], cwd=ROOT, check=True, capture_output=True, text=True).stdout
        data = json.loads(out)
        self.assertEqual([u["name"] for u in data["units"]], ["guards"])
        self.assertRegex(data["head"], r"^[0-9a-f]{40}$")


class Replay(unittest.TestCase):
    def setUp(self):
        import affected_tests_replay
        self.replay = affected_tests_replay

    def test_python_extra_selects_only_its_files(self):
        unit = {"kind": "python", "argv": ["test", "--setup", "none", "--", "bash", "-c", "s", "affected", "tests/test_a.py"]}
        sel = self.replay.selected({"all": False, "units": [unit]})
        self.assertEqual(sel["python"], {"tests/test_a.py"})

    def test_guard_runner_summary_names_each_red_guard(self):
        log = "##[group]Run x\nfailed: workflow-guard-tests / ci: Validate A; workflow-guard-tests / ci: Validate B\n"
        found = {(f["kind"], f["test"]) for f in self.replay.failures_in_log(log)}
        self.assertEqual(found, {("guard", "workflow-guard-tests / ci: Validate A"), ("guard", "workflow-guard-tests / ci: Validate B")})


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
