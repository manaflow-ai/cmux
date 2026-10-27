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

    def story(self, story_id: str, *command: str) -> None:
        self.file(f"{orphans.STORIES_DIR}/{story_id}.json", json.dumps({"id": story_id, "command": list(command)}))

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
        t.file("scripts/cmux-next/sub/deep-bench.py")  # subdirectories are not scanned
        self.assertEqual(self.orphan_paths(), ["scripts/cmux-next/bench_idle.py", "scripts/cmux-next/tab-switch-matrix.py"])

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

    def test_a_script_that_a_covered_script_runs_is_covered_transitively(self) -> None:
        t = self.tree
        t.file("scripts/measure/split-spring.sh",
               "#!/usr/bin/env bash\npython3 scripts/cmux-next/split-spring-frames.py \"$@\"\n")
        t.file("scripts/cmux-next/split-spring-frames.py",
               BENCH_PY + 'SUITE = os.path.join(HERE, "cef-idle-probe.py")\n')
        t.file("scripts/cmux-next/cef-idle-probe.py")
        t.story("split-spring", "scripts/measure/split-spring.sh")
        report = t.report()
        self.assertEqual(report.orphans, ())
        self.assertEqual(report.covered["scripts/cmux-next/cef-idle-probe.py"],
                         "via scripts/cmux-next/split-spring-frames.py")

    def test_a_mention_in_a_comment_or_docstring_does_not_cover(self) -> None:
        t = self.tree
        t.file("scripts/cmux-next/tab-switch-stages.py",
               '#!/usr/bin/env python3\n"""Run by scripts/measure/tab-switch.sh."""\n'
               '# scripts/measure/tab-switch.sh passes its arguments here\nif __name__ == "__main__":\n    pass\n')
        t.file("scripts/measure/tab-switch.sh", "#!/usr/bin/env bash\n# runs tab-switch-stages.py\n")
        t.file("scripts/measure/other.sh", "#!/usr/bin/env bash\n# tab-switch-stages.py\ntrue\n")
        t.story("tab-switch-stages", "scripts/cmux-next/tab-switch-stages.py")
        self.assertEqual(self.orphan_paths(), ["scripts/measure/other.sh", "scripts/measure/tab-switch.sh"])

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


if __name__ == "__main__":
    unittest.main()
