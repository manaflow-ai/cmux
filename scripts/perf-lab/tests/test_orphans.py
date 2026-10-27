#!/usr/bin/env python3
"""orphans.py (MQ12): perf scripts, story coverage, retired.json and the task groups, on fixture trees and the checkout.

  python3 -m unittest scripts/perf-lab/tests/test_orphans.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = HERE.parents[2]

_SPEC = importlib.util.spec_from_file_location("perf_lab_orphans_under_test", LAB / "orphans.py")
orphans = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = orphans
_SPEC.loader.exec_module(orphans)

BENCH_PY = '#!/usr/bin/env python3\n"""A bench."""\nif __name__ == "__main__":\n    pass\n'


class Tree:
    """A fixture checkout: files by repository path, stories by id."""

    def __init__(self, root: Path):
        self.root = root

    def file(self, rel: str, text: str = BENCH_PY) -> str:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return rel

    def story(self, story_id: str, *command: str, runs: list | None = None) -> None:
        doc = {"id": story_id, "command": list(command)}
        if runs is not None:
            doc["runs"] = runs
        self.file(f"{orphans.STORIES_DIR}/{story_id}.json", json.dumps(doc))

    def retire(self, scripts: dict) -> None:
        self.file(orphans.RETIRED_PATH, json.dumps({"schema": orphans.RETIRED_SCHEMA, "scripts": scripts}))

    def report(self):
        return orphans.find(self.root)


class OrphansTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tree = Tree(Path(self._tmp.name))

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def orphan_paths(self) -> list[str]:
        return [s.path for s in self.tree.report().orphans]

    # ---------- what is a perf script ----------

    def test_every_measure_entry_is_a_perf_script(self) -> None:
        t = self.tree
        t.file("scripts/measure/quiet-thing.sh", "#!/usr/bin/env bash\necho hi\n")
        t.file("scripts/measure/helper-dir/probe.c", "int x;\n")
        self.assertEqual(self.orphan_paths(), ["scripts/measure/quiet-thing.sh"])

    def test_a_bench_word_at_a_word_start_makes_a_perf_script(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/tab-switch-matrix.py")
        t.file("scripts/cmux-next/bench_idle.py")
        t.file("scripts/lint-feature-flags.py")  # `lag` inside `flags` is not a bench word
        self.assertEqual(self.orphan_paths(), ["scripts/cmux-next/bench_idle.py", "scripts/cmux-next/tab-switch-matrix.py"])

    def test_bench_inside_a_word_is_a_bench_name(self) -> None:
        self.tree.file("scripts/perf-bench/xbench.py")
        self.assertEqual([(s.path, s.why) for s in self.tree.report().orphans],
                         [("scripts/perf-bench/xbench.py", "name: bench")])

    def test_benches_in_subdirectories_are_perf_scripts(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/sub/deep-bench.py")
        t.file("scripts/perf-bench/power_attribution.py")
        t.file("webviews/scripts/agent-pane/chat-load/browser_bench.mjs", "console.log(1)\n")
        t.file("cmux-tui/scripts/a/b/bench-x.sh", "#!/usr/bin/env bash\n")
        t.file("tests/automation-bench/perf/sub/soak.py")
        self.assertEqual(self.orphan_paths(), [
            "cmux-tui/scripts/a/b/bench-x.sh", "scripts/cmux-next/sub/deep-bench.py",
            "scripts/perf-bench/power_attribution.py", "tests/automation-bench/perf/sub/soak.py",
            "webviews/scripts/agent-pane/chat-load/browser_bench.mjs"])

    def test_tests_dependencies_and_the_lab_itself_are_not_perf_scripts(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/tests/test_bench_idle.py")
        t.file("webviews/scripts/node_modules/x/bench.mjs", "x()\n")
        t.file("scripts/lib/iroh-soak.test.mjs", "x()\n")
        t.file("scripts/cmux-next/oracle/driver_app_test.py", BENCH_PY + "import bench_launch\n")
        t.file("scripts/perf-lab/perf_import.py")  # the lab's own code
        t.file("scripts/perf-lab/stories/qos_static.py")  # a story implementation: an entry
        t.file("scripts/measure/blocking-probe/run.sh", "#!/usr/bin/env bash\n")  # a step's own helper
        self.assertEqual(self.orphan_paths(), ["scripts/perf-lab/stories/qos_static.py"])

    def test_writing_result_v1_makes_a_perf_script_whatever_its_name(self) -> None:
        self.tree.file("scripts/cmux-next/glass.py", BENCH_PY + "import bench_launch\n")
        report = self.tree.report()
        self.assertEqual([(s.path, s.why) for s in report.orphans],
                         [("scripts/cmux-next/glass.py", "writes result-v1: bench_launch")])

    def test_a_library_module_is_not_a_perf_script(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/typing_report.py", "def p99(values):\n    return max(values)\n")
        t.file("scripts/cmux-next/bench_story.py", "#!/usr/bin/env python3\nimport json\nSTORY = 'x'\n")
        t.file("scripts/cmux-next/bench_frames.py", "#!/usr/bin/env python3\nmain()\n")
        self.assertEqual(self.orphan_paths(), ["scripts/cmux-next/bench_frames.py"])

    # ---------- coverage ----------

    def test_a_story_command_covers_its_script(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/bench_idle.py")
        t.story("idle", "scripts/cmux-next/bench_idle.py", "--fresh")
        report = t.report()
        self.assertEqual(report.orphans, ())
        self.assertEqual(report.covered["scripts/cmux-next/bench_idle.py"], "story idle")

    def test_a_story_runs_list_covers_the_scripts_its_command_starts(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/cli-storm-session.py",
               BENCH_PY + 'subprocess.run([sys.executable, os.path.join(HERE, "bench_cli_storm.py")])\n')
        t.file("scripts/cmux-next/bench_cli_storm.py")
        t.story("cli-storm", "scripts/cmux-next/cli-storm-session.py", "--session", "light",
                runs=["scripts/cmux-next/bench_cli_storm.py"])
        report = t.report()
        self.assertEqual((report.orphans, report.problems), ((), ()))
        self.assertEqual(report.covered["scripts/cmux-next/bench_cli_storm.py"], "story cli-storm")

    def test_a_script_the_command_starts_but_the_story_does_not_declare_stays_an_orphan(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/cli-storm-session.py",
               BENCH_PY + 'subprocess.run([sys.executable, os.path.join(HERE, "bench_cli_storm.py")])\n')
        t.file("scripts/cmux-next/bench_cli_storm.py")
        t.story("cli-storm", "scripts/cmux-next/cli-storm-session.py")
        self.assertEqual(self.orphan_paths(), ["scripts/cmux-next/bench_cli_storm.py"])

    def test_a_dispatcher_branch_the_story_does_not_select_stays_an_orphan(self) -> None:
        t = self.tree
        t.file("scripts/measure/split-spring.sh",
               "#!/usr/bin/env bash\nbench=scripts/cmux-next/split-spring-terminal.py\nfor arg; do case $arg in\n"
               "  --suite=input-latency) bench=scripts/cmux-next/input-latency-bench.py ;;\n"
               "  --suite=scroll-jank) bench=scripts/cmux-next/scroll-jank-bench.py ;;\nesac; done\n"
               'python3 "$bench"\n')
        for name in ("split-spring-terminal", "input-latency-bench", "scroll-jank-bench"):
            t.file(f"scripts/cmux-next/{name}.py")
        t.story("split-spring", "scripts/measure/split-spring.sh",
                runs=["scripts/cmux-next/split-spring-terminal.py"])
        t.story("input-latency", "scripts/measure/split-spring.sh", "--suite=input-latency",
                runs=["scripts/cmux-next/input-latency-bench.py"])
        self.assertEqual(self.orphan_paths(), ["scripts/cmux-next/scroll-jank-bench.py"])

    def test_an_import_a_help_text_or_an_error_message_does_not_cover(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/every-action-sweep.py", BENCH_PY +
               'import action_signposts_bench\n'
               'parser.add_argument("--probe", help="DYLD_INSERT_LIBRARIES (scripts/measure/blocking-probe.sh)")\n'
               'raise SystemExit("needs a `reload.sh --config bench-checks` build")\n'
               'print("see trace.py")\n')
        t.file("scripts/cmux-next/action_signposts_bench.py")
        t.file("scripts/measure/blocking-probe.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/reload.sh", "#!/usr/bin/env bash\nbench_launch=1\n")
        t.file("scripts/cmux-next/trace.py", BENCH_PY + "import bench_launch\n")
        t.story("sweep", "scripts/cmux-next/every-action-sweep.py")
        self.assertEqual(self.orphan_paths(), [
            "scripts/cmux-next/action_signposts_bench.py",
            "scripts/cmux-next/trace.py", "scripts/measure/blocking-probe.sh", "scripts/reload.sh"])

    def test_a_runs_path_that_does_not_exist_is_a_problem(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/bench_idle.py")
        t.story("idle", "scripts/cmux-next/bench_idle.py", runs=["scripts/cmux-next/gone.py", 3])
        problems = "\n".join(t.report().problems)
        self.assertIn("idle.json: runs path 'scripts/cmux-next/gone.py' does not exist", problems)
        self.assertIn("idle.json: runs path 3 does not exist", problems)

    def test_a_basename_inside_a_longer_name_does_not_cover(self) -> None:
        t = self.tree
        t.file("tests/automation-bench/perf/aside_bench.py", BENCH_PY + 'X = "run aside_bench.py"\n')
        t.file("tests/automation-bench/perf/bench.py")
        t.story("aside", "tests/automation-bench/perf/aside_bench.py")
        self.assertEqual(self.orphan_paths(), ["tests/automation-bench/perf/bench.py"])

    # ---------- retired.json ----------

    def test_a_retired_script_leaves_the_queue(self) -> None:
        t = self.tree
        t.file("scripts/measure/rift-eval.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/measure/burst-bench.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/cmux-next/burst-bench.py")
        t.story("burst", "scripts/cmux-next/burst-bench.py")
        t.retire({"scripts/measure/rift-eval.sh": {"kind": "one-off", "why": "a finished evaluation"},
                  "scripts/measure/burst-bench.sh": {"kind": "duplicate", "of": "burst", "why": "fleet wrapper"}})
        report = t.report()
        self.assertEqual((report.orphans, report.problems), ((), ()))

    def test_stale_or_malformed_retired_entries_are_problems(self) -> None:
        t = self.tree
        t.file("scripts/measure/a.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/measure/b.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/measure/c.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/measure/d.sh", "#!/usr/bin/env bash\n")
        t.file("scripts/cmux-next/bench_idle.py")
        t.file("scripts/lint-feature-flags.py")
        t.story("idle", "scripts/cmux-next/bench_idle.py")
        t.retire({
            "scripts/measure/gone.sh": {"kind": "one-off", "why": "x"},
            "scripts/lint-feature-flags.py": {"kind": "not-a-bench", "why": "x"},
            "scripts/cmux-next/bench_idle.py": {"kind": "one-off", "why": "x"},
            "scripts/measure/a.sh": {"kind": "duplicate", "of": "nope", "why": "x"},
            "scripts/measure/b.sh": {"kind": "retired", "why": "x"},
            "scripts/measure/c.sh": {"kind": "one-off", "why": "  "},
            "scripts/measure/d.sh": {"kind": "duplicate", "why": "no story named"},
        })
        report = t.report()
        problems = "\n".join(report.problems)
        for expected in ("gone.sh: no such file", "lint-feature-flags.py: not a perf script",
                         "bench_idle.py: a story runs it (story idle)", "a.sh: duplicate of 'nope', which is not a story",
                         "b.sh: kind 'retired' is not one of", "c.sh: no reason", 'd.sh: a duplicate names the story'):
            self.assertIn(expected, problems)
        self.assertEqual(len(report.problems), 7)
        # An entry that fails its shape does not retire the script.
        self.assertEqual([s.path for s in report.orphans],
                         ["scripts/measure/b.sh", "scripts/measure/c.sh", "scripts/measure/d.sh"])

    def test_only_a_duplicate_names_a_story(self) -> None:
        t = self.tree
        t.file("scripts/measure/a.sh", "#!/usr/bin/env bash\n")
        t.story("s")
        t.retire({"scripts/measure/a.sh": {"kind": "one-off", "of": "s", "why": "x"}})
        self.assertIn('only a duplicate has "of"', "\n".join(t.report().problems))

    def test_a_ledger_without_the_schema_is_an_error(self) -> None:
        self.tree.file(orphans.RETIRED_PATH, json.dumps({"scripts": {}}))
        err = io.StringIO()
        self.assertEqual(orphans.run_orphans(self.tree.root, False, io.StringIO(), err), 2)
        self.assertIn(orphans.RETIRED_SCHEMA, err.getvalue())

    # ---------- the queue ----------

    def test_tasks_are_up_to_four_scripts_of_one_directory(self) -> None:
        scripts = [orphans.Script(f"scripts/measure/{n}.sh", "") for n in "abcdef"]
        scripts += [orphans.Script("cmux-tui/scripts/bench-x.py", "")]
        groups = [[s.path for s in group] for group in orphans.tasks(scripts)]
        self.assertEqual(groups, [["cmux-tui/scripts/bench-x.py"],
                                  [f"scripts/measure/{n}.sh" for n in "abcd"],
                                  ["scripts/measure/e.sh", "scripts/measure/f.sh"]])

    def test_text_output_numbers_the_tasks_and_counts(self) -> None:
        for n in "abcde":
            self.tree.file(f"scripts/measure/{n}.sh", "#!/usr/bin/env bash\n")
        out = io.StringIO()
        self.assertEqual(orphans.run_orphans(self.tree.root, False, out, io.StringIO()), 0)
        lines = out.getvalue().splitlines()
        self.assertEqual(lines[0], "1\tscripts/measure/a.sh\tentry of scripts/measure/")
        self.assertEqual(lines[4].split("\t")[:2], ["2", "scripts/measure/e.sh"])
        self.assertTrue(lines[-1].startswith("orphans: 5 in 2 tasks of up to 4"))

    def test_lab_py_stories_orphans_json_is_the_done_check_list(self) -> None:
        self.tree.file("scripts/measure/a.sh", "#!/usr/bin/env bash\n")
        self.tree.file("scripts/measure/b.sh", "#!/usr/bin/env bash\n")
        self.tree.retire({"scripts/measure/b.sh": {"kind": "one-off", "why": "x"}})
        result = subprocess.run([sys.executable, "-I", str(LAB / "lab.py"), "stories", "--orphans", "--json",
                                 "--root", str(self.tree.root)], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ["scripts/measure/a.sh"])

    def test_a_ledger_problem_exits_one_and_still_prints_the_list(self) -> None:
        self.tree.file("scripts/measure/a.sh", "#!/usr/bin/env bash\n")
        self.tree.retire({"scripts/measure/gone.sh": {"kind": "one-off", "why": "x"}})
        out, err = io.StringIO(), io.StringIO()
        self.assertEqual(orphans.run_orphans(self.tree.root, True, out, err), 1)
        self.assertEqual(json.loads(out.getvalue()), ["scripts/measure/a.sh"])
        self.assertIn("gone.sh: no such file", err.getvalue())


class CheckoutTest(unittest.TestCase):
    """The checked-in retired.json against the checkout: every entry is current."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.report = orphans.find(REPO_ROOT)

    def test_the_checked_in_ledger_has_no_problems(self) -> None:
        report = self.report
        self.assertEqual(report.problems, ())
        self.assertTrue(report.retired)
        self.assertFalse({s.path for s in report.orphans} & set(report.retired))

    def test_the_cron_parts_stories_cover_their_scripts(self) -> None:
        covered = self.report.covered
        self.assertTrue(covered["scripts/cmux-next/every-action-sweep.py"].startswith("story "))

    def test_only_the_commands_and_runs_lists_cover(self) -> None:
        covered = self.report.covered
        self.assertEqual(covered["scripts/cmux-next/bench_cli_storm.py"], "story cli-storm-stress, cli-storm")
        # The build story runs split-spring.sh --build-only: its --suite= branches are not runs.
        for path in ("scripts/cmux-next/input-latency-bench.py", "scripts/cmux-next/scroll-jank-bench.py"):
            self.assertNotIn(path, covered)

    def test_the_scan_reaches_perf_bench(self) -> None:
        self.assertIn("scripts/perf-bench/xbench.py", {s.path for s in self.report.scripts})


if __name__ == "__main__":
    unittest.main()
