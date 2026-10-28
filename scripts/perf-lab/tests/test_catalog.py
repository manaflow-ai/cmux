#!/usr/bin/env python3
"""catalog.py: stories.d/, targets.json, owners, hot paths and the lints, on the checkout and on fixture trees.

  python3 -m unittest scripts/perf-lab/tests/test_catalog.py
"""
from __future__ import annotations

import argparse
import ast
import copy
import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = HERE.parents[2]
CATALOG_PY = LAB / "catalog.py"

_SPEC = importlib.util.spec_from_file_location("perf_lab_catalog_under_test", CATALOG_PY)
catalog = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = catalog
_SPEC.loader.exec_module(catalog)

_CRON_SPEC = importlib.util.spec_from_file_location("perf_cron_for_catalog_test", REPO_ROOT / catalog.PERF_CRON_PATH)
perf_cron = importlib.util.module_from_spec(_CRON_SPEC)
_CRON_SPEC.loader.exec_module(perf_cron)

OWNERS_MD = """# owners

| Area | Paths | Owner | Read first |
|---|---|---|---|
| Sidebar | `x/` | a590 (sidebar-owner agent) | [doc](doc.md) |
| Layout motion | `y/` | PL-motion-core | [doc](doc.md) |
| Perf gate | `z/` | Aziz's agent and the Performance Lead | [doc](doc.md) |
| Daemon | `d/` | PL-daemon (session cmux-b6): request speed | [doc](doc.md) |
"""

PERF_CRON_PY = """
LAUNCH_BUDGETS = {"first_window_frame_committed": 1000}
DIFF_BUDGETS = {"diff.sidecar.read_ms_per_gib": 1024 * 1000 / 500.0}
PARTS = [
    {"name": "build", "args": ["--build-only"]},
    {"name": "motion", "args": ["--suite=budgets"]},
]
ROW_PARTS = [(r"^panes\\.", "motion")]
"""

BUDGETS_JSON = {"rows": {"panes\\..*\\.frame": {"p95": 8.33, "unit": "ms", "floor": 1.0, "what": "pane frame"}}}

HOT_JSON = {"paths": {"motion-frame": {"what": "a motion frame", "bench": "bench.py", "owner": "PL-motion-core"},
                      "key-dispatch": {"what": "a key", "bench": "typing.py", "owner": "PL-typing"}}}


def story(story_id: str, **changes) -> dict:
    doc = {
        "id": story_id, "tier": "T1", "description": "A fixture story.", "command": ["bench.py", "--rounds", "2"],
        "session": "light", "engine": "none", "config": "bench",
        "metrics": [{"name": "panes\\.[^.]+\\.frame", "unit": "ms", "better": "lower",
                     "target_ref": {"path": "budgets.json", "key": "/rows/panes\\..*\\.frame/p95"},
                     "floor_ref": {"path": "budgets.json", "key": "/rows/panes\\..*\\.frame/floor"}}],
        "repeats": 1, "seconds": 60, "needs": [], "owner": "PL-motion-core", "component": "Layout>Motion",
    }
    doc.update(changes)
    return doc


def claim(row_id: str, pattern: str, unit: str = "count") -> dict:
    return {"name": pattern, "unit": unit, "better": "lower", "target_ref": {"target": row_id}}


class FixtureTree:
    """A temp repository root with the catalog's inputs; targets.json is the checkout's own unless replaced."""

    def __init__(self, stories: list[dict], targets: dict | None = None) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        self.write("plans/cmux-next/OWNERS.md", OWNERS_MD)
        self.write(catalog.PERF_CRON_PATH, PERF_CRON_PY)
        self.write(catalog.HOT_PATHS_PATH, json.dumps(HOT_JSON))
        self.write("budgets.json", json.dumps(BUDGETS_JSON))
        self.write("bench.py", "")
        real_targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
        self.write(catalog.TARGETS_PATH, json.dumps(real_targets if targets is None else targets))
        for doc in stories:
            self.write(f"{catalog.STORIES_DIR}/{doc['id']}.json", json.dumps(doc))

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def load(self):
        return catalog.load_catalog(self.root)

    def run(self, command: str, *argv: str) -> tuple[int, str, str]:
        parser = argparse.ArgumentParser()
        catalog.add_arguments(command, parser)
        args = parser.parse_args([*argv, "--root", str(self.root)])
        out, err = io.StringIO(), io.StringIO()
        code = catalog.run(command, args, out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def close(self) -> None:
        self._dir.cleanup()


def baseline_stories() -> list[dict]:
    """One story per fixture cron part, with no problems."""
    return [story("build", tier="builder", perf_cron_part="build", seconds=600),
            story("motion", perf_cron_part="motion", hot_paths=["motion-frame"])]


class FixtureTestCase(unittest.TestCase):
    def tree(self, stories: list[dict], targets: dict | None = None) -> FixtureTree:
        tree = FixtureTree(stories, targets)
        self.addCleanup(tree.close)
        return tree

    def problems(self, stories: list[dict], targets: dict | None = None) -> list[str]:
        return list(self.tree(stories, targets).load().problems)

    def assertProblem(self, problems: list[str], *fragments: str) -> None:
        self.assertTrue(any(all(f in p for f in fragments) for p in problems),
                        f"no problem with {fragments} in:\n" + "\n".join(problems))


class CheckoutCatalogTests(unittest.TestCase):
    """The catalog as committed: these hold on every push."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = catalog.load_catalog(REPO_ROOT)

    def test_lint_is_clean(self) -> None:
        self.assertEqual(list(self.catalog.problems), [])

    def test_twelve_targets_with_the_spec_text(self) -> None:
        self.assertEqual(len(self.catalog.targets), 12)
        spec = (REPO_ROOT / "plans/cmux-next/chrome-parity/p12-perf-process.md")
        if spec.is_file():
            text = spec.read_text()
            for target in self.catalog.targets:
                self.assertIn(f"   - {target.text}\n", text, target.id)

    def test_every_browser_target_has_both_engine_rows(self) -> None:
        for target in self.catalog.targets:
            engines = {row.engine for row in target.rows}
            if target.browser:
                self.assertLessEqual({"chromium", "webkit"}, engines, target.id)

    def test_omnibar_typing_and_tab_switch_have_webkit_arms(self) -> None:
        # F12 (task 228): the Chromium arms are the typing story's omnibar surface and the switch story.
        by_id = {s.id: s for s in self.catalog.stories}
        self.assertEqual(by_id["switch"].engine, "chromium")
        tab_switch, omnibar = by_id["tab-switch"], by_id["omnibar"]
        self.assertEqual((tab_switch.engine, omnibar.engine), ("webkit", "webkit"))
        self.assertEqual(tab_switch.command[0], "scripts/cmux-next/tab-switch-matrix.py")
        self.assertEqual(dict(catalog._flag_values(list(tab_switch.command)))["--kinds"], "webkit")
        self.assertEqual(omnibar.command[0], "scripts/cmux-next/typing-frame-bench.py")
        omnibar_flags = dict(catalog._flag_values(list(omnibar.command)))
        self.assertEqual((omnibar_flags["--surfaces"], omnibar_flags["--engine"]), ("omnibar", "webkit"))
        self.assertTrue(catalog.story_for_row(self.catalog, "tab_switch.webkit.10.e2e"))
        self.assertIn(omnibar, catalog.story_for_row(self.catalog, "omnibar.load.key_to_frame"))
        self.assertIn("omnibar-key", omnibar.hot_paths)
        self.assertIn("tab-switch", tab_switch.hot_paths)

    def test_typing_bench_takes_the_omnibar_engine(self) -> None:
        bench = REPO_ROOT / "scripts/cmux-next/typing-frame-bench.py"
        text = bench.read_text()
        self.assertIn('choices=("chromium", "webkit")', text)
        self.assertIn('action(f"openBrowser.{opts.engine}"', text)
        self.assertNotIn('action("openBrowser.chromium"', text)

    def test_every_perf_cron_part_has_a_story(self) -> None:
        parts = [p["name"] for p in perf_cron.PARTS]
        self.assertEqual(list(self.catalog.cron_parts), parts)
        by_part = {s.perf_cron_part: s.id for s in self.catalog.stories if s.perf_cron_part}
        self.assertEqual(sorted(by_part), sorted(parts))

    def test_every_row_parts_family_lands_in_its_parts_story(self) -> None:
        # One concrete row per ROW_PARTS family, in the names perf-cron.py and perf-budgets.py build.
        rows = ["panes.split.stress.frame", "panes.split.stress.missed", "panes.close.4x2.frame",
                "cmd_n.idle.key_to_visible", "cmd_t.idle.key_to_visible", "ctrl_backtick.idle.key_to_visible",
                "cmd_d.idle.key_to_visible", "cmd_shift_d.idle.key_to_visible", "tab_switch.terminal.10.e2e",
                "palette.command_palette.key_to_frame", "perf_gate.typing.failed_checks", "sidebar.400.scroll.frame",
                "sidebar.400.ticking.cpu_pct", "workspace_switch.click.input_to_idle", "home.typing.key_dispatch",
                "home.scroll.frame", "idle.chromium-static.app_cpu_pct", "acp.own.typing.to_frame",
                "anim.tab-new.frame", "anim.tab-new.dropped", "launch.warm.first_window_frame_committed",
                "launch.warm.sidebar_rows_shown.missing_runs", "diff.stream.p95"]
        families = {pattern for pattern, _ in perf_cron.ROW_PARTS}
        self.assertEqual(families, {p for p, _ in perf_cron.ROW_PARTS if any(re.match(p, r) for r in rows)},
                         "a ROW_PARTS family has no sample row here")
        for row in rows:
            part = perf_cron.part_for_row(row)
            stories = catalog.story_for_row(self.catalog, row)
            self.assertIn(part, {s.perf_cron_part for s in stories}, f"{row} (part {part})")

    def test_t0_fits_its_budget(self) -> None:
        t0 = [s for s in self.catalog.stories if s.tier == "T0"]
        self.assertTrue(t0)
        self.assertLessEqual(sum(s.seconds for s in t0), catalog.T0_SECONDS_MAX)

    def test_references_read_the_owning_files(self) -> None:
        budgets = json.loads((REPO_ROOT / "scripts/cmux-next/perf-budgets.json").read_text())["rows"]
        seen = 0
        for s in self.catalog.stories:
            for m in s.metrics:
                for ref in (m.target_ref, m.floor_ref):
                    if ref is None:
                        continue
                    value = catalog.resolve_ref(REPO_ROOT, ref)
                    if ref.path.endswith("perf-budgets.json"):
                        _, _, row, field = ref.key.split("/")
                        self.assertEqual(value, budgets[row][field])
                    elif ref.key.startswith("LAUNCH_BUDGETS/"):
                        self.assertEqual(value, perf_cron.LAUNCH_BUDGETS[ref.key.split("/", 1)[1]])
                    elif ref.key.startswith("DIFF_BUDGETS/"):
                        self.assertEqual(value, perf_cron.DIFF_BUDGETS[ref.key.split("/", 1)[1]])
                    seen += 1
        self.assertGreater(seen, 20)

    def test_uncovered_prints_exactly_the_unclaimed_rows(self) -> None:
        claims = catalog.claimed_checks(self.catalog)
        expected = []
        for target in self.catalog.targets:
            for row in target.rows:
                missing = list(dict.fromkeys(c.metric for c in row.checks if (row.id, c.metric) not in claims))
                if missing:
                    expected.append(f"{target.id}\t{row.id}\t{' '.join(missing)}")
        code = subprocess.run([sys.executable, "-I", str(CATALOG_PY), "targets", "--uncovered"],
                              capture_output=True, text=True)
        self.assertEqual(code.returncode, 0, code.stderr)
        self.assertEqual(code.stdout.splitlines(), expected)
        printed = {line.split("\t")[1] for line in expected}
        self.assertNotIn("motion-dropped", printed)  # pane-stress and chat-anim claim both of its checks
        self.assertNotIn("launch.warm", printed)
        self.assertNotIn("launch.cold", printed)  # launch-cold and launch-after-reboot claim it (task 033)

    def test_lab_py_command_module_protocol(self) -> None:
        tree = ast.parse(CATALOG_PY.read_text())
        literal = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                       and any(isinstance(t, ast.Name) and t.id == "LAB_COMMANDS" for t in node.targets))
        self.assertEqual(set(literal), {"stories", "targets", "hot-paths"})
        self.assertTrue(callable(catalog.add_arguments) and callable(catalog.run))

    def test_runs_under_isolated_python_with_no_third_party_imports(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(CATALOG_PY), "stories", "--lint"],
                                capture_output=True, text=True, cwd="/")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        stdlib = set(sys.stdlib_module_names)
        for node in ast.walk(ast.parse(CATALOG_PY.read_text())):
            names = [a.name for a in node.names] if isinstance(node, ast.Import) else \
                [node.module] if isinstance(node, ast.ImportFrom) and node.module else []
            for name in names:
                self.assertIn(name.split(".")[0], stdlib | {"__future__"}, name)


class StoryLintTests(FixtureTestCase):
    def test_fixture_baseline_is_clean(self) -> None:
        self.assertEqual(self.problems(baseline_stories()), [])

    def test_missing_owner_fails_the_lint(self) -> None:
        tree = self.tree([*baseline_stories(), story("orphan", owner="PL-nobody")])
        code, out, _ = tree.run("stories", "--lint")
        self.assertEqual(code, 1)
        self.assertIn("owner 'PL-nobody' is not an owner", out)

    def test_owners_come_from_the_owner_column(self) -> None:
        owners = catalog.owner_lanes(OWNERS_MD)
        self.assertEqual(owners, {"a590", "PL-motion-core", "Performance Lead", "PL-daemon"})
        for name in ("Aziz's", "Sidebar", "cmux-b6", "Owner"):
            self.assertNotIn(name, owners)

    def test_empty_owner_fails(self) -> None:
        self.assertProblem(self.problems([*baseline_stories(), story("x", owner="")]), "owner is empty")

    def test_copied_threshold_in_a_metric_fails(self) -> None:
        doc = story("copy")
        doc["metrics"][0]["p95"] = 8.33
        problems = self.problems([*baseline_stories(), doc])
        self.assertProblem(problems, "copied threshold number 8.33", "$.metrics[0].p95")

    def test_copied_threshold_in_a_command_flag_fails(self) -> None:
        for argv in (["bench.py", "--budget-ms", "16.7"], ["bench.py", "--max-frame-limit=8.33"]):
            with self.subTest(argv=argv):
                self.assertProblem(self.problems([*baseline_stories(), story("flag", command=argv)]),
                                   "copied threshold number", "command flag")

    def test_copied_threshold_in_targets_json_fails(self) -> None:
        targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
        targets["targets"][0]["rows"][0]["floor"] = 1.0
        self.assertProblem(self.problems(baseline_stories(), targets), "copied threshold number 1.0",
                           "$.targets[0].rows[0].floor")

    def test_reference_to_a_missing_file_or_key_fails(self) -> None:
        for ref, fragment in (({"path": "nope.json", "key": "/a"}, "does not exist"),
                              ({"path": "budgets.json", "key": "/rows/nope/p95"}, "no 'nope'"),
                              ({"path": "budgets.json", "key": "/rows/panes\\..*\\.frame/what"}, "not a number"),
                              ({"path": "scripts/cmux-next/perf-cron.py", "key": "NOPE/x"}, "no top-level")):
            with self.subTest(ref=ref):
                doc = story("ref")
                doc["metrics"][0]["target_ref"] = ref
                self.assertProblem(self.problems([*baseline_stories(), doc]), fragment)

    def test_python_reference_evaluates_constant_arithmetic(self) -> None:
        tree = self.tree(baseline_stories())
        ref = catalog.Ref(catalog.PERF_CRON_PATH, "DIFF_BUDGETS/diff.sidecar.read_ms_per_gib")
        self.assertEqual(catalog.resolve_ref(tree.root, ref), 2048.0)

    def test_missing_command_path_fails(self) -> None:
        self.assertProblem(self.problems([*baseline_stories(), story("x", command=["scripts/gone.py"])]),
                           "command path scripts/gone.py does not exist")

    def test_one_config_only(self) -> None:
        for config in (["bench", "release"], "debug", "fast"):
            with self.subTest(config=config):
                self.assertProblem(self.problems([*baseline_stories(), story("x", config=config)]), "config is one of")

    def test_only_a_builder_story_may_time_a_debug_build(self) -> None:
        problems = self.problems([*baseline_stories(), story("x", tier="builder", config="debug")])
        self.assertFalse(any("config is one of" in p for p in problems), problems)
        self.assertProblem(self.problems([*baseline_stories(), story("x", tier="T1", config="debug")]),
                           "config is one of")

    def test_id_must_match_the_file_name(self) -> None:
        tree = self.tree(baseline_stories())
        tree.write(f"{catalog.STORIES_DIR}/other.json", json.dumps(story("not-other")))
        self.assertProblem(list(tree.load().problems), "must equal the file name")

    def test_needs_are_typed_and_files_exist(self) -> None:
        problems = self.problems([*baseline_stories(), story("x", needs=["stress", "file:missing.py", "debug:debug.cef"])])
        self.assertProblem(problems, "need 'stress' is not")
        self.assertProblem(problems, "need file:missing.py names a file that does not exist")
        self.assertFalse(any("debug:debug.cef" in p for p in problems))

    def test_runs_lists_existing_paths_outside_the_command(self) -> None:
        tree = self.tree([*baseline_stories(), story("ok", runs=["budgets.json"])])
        self.assertEqual(list(tree.load().problems), [])
        self.assertEqual(next(s for s in tree.load().stories if s.id == "ok").runs, ("budgets.json",))
        for runs, fragment in ((["scripts/gone.py"], "runs path scripts/gone.py does not exist"),
                               (["bench.py"], "runs path bench.py is in the command already"),
                               ("bench.py", "runs is a list of repository paths")):
            with self.subTest(runs=runs):
                self.assertProblem(self.problems([*baseline_stories(), story("x", runs=runs)]), fragment)

    def test_unknown_hot_path_fails(self) -> None:
        self.assertProblem(self.problems([*baseline_stories(), story("x", hot_paths=["no-such-path"])]),
                           "hot path 'no-such-path'")

    def test_every_cron_part_needs_a_story(self) -> None:
        problems = self.problems([story("motion", perf_cron_part="motion")])
        self.assertProblem(problems, "perf-cron.py part build has no story")

    def test_t0_budget_is_480_seconds(self) -> None:
        under = [*baseline_stories(), story("a", tier="T0", seconds=240), story("b", tier="T0", seconds=240)]
        self.assertEqual(self.problems(under), [])
        over = [*baseline_stories(), story("a", tier="T0", seconds=240), story("b", tier="T0", seconds=241)]
        self.assertProblem(self.problems(over), "T0 stories sum to 481 s")

    def test_unknown_and_missing_fields_fail(self) -> None:
        doc = story("x", extra=1)
        del doc["component"]
        problems = self.problems([*baseline_stories(), doc])
        self.assertProblem(problems, "missing component")
        self.assertProblem(problems, "unknown extra")

    def test_broken_json_is_one_problem_not_a_crash(self) -> None:
        tree = self.tree(baseline_stories())
        tree.write(f"{catalog.STORIES_DIR}/broken.json", "{")
        self.assertProblem(list(tree.load().problems), "broken.json")

    def test_format_paths_lists_command_paths(self) -> None:
        code, out, _ = self.tree(baseline_stories()).run("stories", "--format=paths")
        self.assertEqual((code, out), (0, "bench.py\n"))


class TargetTests(FixtureTestCase):
    def test_uncovered_prints_exactly_the_unclaimed_rows(self) -> None:
        stories = [*baseline_stories(),
                   story("drops", metrics=[claim("motion-dropped", "panes\\.[^.]+\\.[^.]+\\.missed"),
                                           claim("motion-dropped", "anim\\.[^.]+\\.dropped")]),
                   story("crash", engine="chromium",
                         metrics=[claim("crash-survival.chromium", "crash_survival\\.chromium", "ratio")]),
                   story("keys", metrics=[claim("key-frame.light", "terminal\\.key_to_frame", "ms")])]
        tree = self.tree(stories)
        code, out, _ = tree.run("targets", "--uncovered")
        self.assertEqual(code, 0)
        rows = [line.split("\t")[1] for line in out.splitlines()]
        all_rows = [row.id for t in tree.load().targets for row in t.rows]
        claimed = {"motion-dropped", "crash-survival.chromium", "key-frame.light"}
        self.assertEqual(rows, [r for r in all_rows if r not in claimed])
        self.assertIn("crash-survival.webkit", rows)

    def test_a_row_with_one_unclaimed_check_stays_uncovered(self) -> None:
        stories = [*baseline_stories(), story("drops", metrics=[claim("motion-dropped", "anim\\.[^.]+\\.dropped")])]
        code, out, _ = self.tree(stories).run("targets", "--uncovered")
        self.assertIn("motion-dropped\tmotion-dropped\tpanes\\.[^.]+\\.[^.]+\\.missed\n", out)

    def test_check_counts_mapped_targets(self) -> None:
        stories = [*baseline_stories(),
                   story("drops", metrics=[claim("motion-dropped", "panes\\.[^.]+\\.[^.]+\\.missed"),
                                           claim("motion-dropped", "anim\\.[^.]+\\.dropped")])]
        code, out, _ = self.tree(stories).run("targets", "--check")
        self.assertEqual(code, 1)
        self.assertIn("ok motion-dropped\n", out)
        self.assertTrue(out.endswith("targets mapped: 1/12\n"))

    def test_check_passes_when_every_row_is_claimed(self) -> None:
        targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
        stories = list(baseline_stories())
        for target in targets["targets"]:
            for row in target["rows"]:
                metrics = list({c["metric"]: claim(row["id"], c["metric"], c["unit"]) for c in row["checks"]}.values())
                fields = {k: row[k] for k in ("engine", "session", "config") if k in row}
                stories.append(story(row["id"], metrics=metrics, **fields))
        tree = self.tree(stories)
        self.assertEqual(list(tree.load().problems), [])
        code, out, _ = tree.run("targets", "--check")
        self.assertEqual(code, 0, out)
        self.assertTrue(out.endswith("targets mapped: 12/12\n"))
        self.assertEqual(tree.run("targets", "--uncovered")[1], "")

    def test_claim_must_name_a_check_and_fit_the_row(self) -> None:
        bad = [story("wrong-metric", metrics=[claim("main-turn", "main_turn\\.p95", "ms")]),
               story("wrong-unit", metrics=[claim("main-turn", "main_turn\\.p99", "us")]),
               story("wrong-engine", engine="chromium",
                     metrics=[claim("crash-survival.webkit", "crash_survival\\.webkit", "ratio")]),
               story("wrong-config", metrics=[claim("main-blocking-sites", "main_blocking\\.sites")]),
               story("no-row", metrics=[claim("no-such-row", "x")])]
        problems = self.problems([*baseline_stories(), *bad])
        self.assertProblem(problems, "wrong-metric", "is not a check of target row main-turn")
        self.assertProblem(problems, "wrong-unit", "unit us differs")
        self.assertProblem(problems, "wrong-engine", "needs engine webkit")
        self.assertProblem(problems, "wrong-config", "needs config bench-checks")
        self.assertProblem(problems, "no-row", "'no-such-row' is not a targets.json row")

    def test_browser_target_without_a_webkit_row_fails(self) -> None:
        targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
        crash = next(t for t in targets["targets"] if t["id"] == "crash-survival")
        crash["rows"] = [r for r in crash["rows"] if r.get("engine") != "webkit"]
        self.assertProblem(self.problems(baseline_stories(), targets), "crash-survival needs a chromium row and a webkit row")

    def test_check_fails_when_a_browser_target_lacks_an_engine_row(self) -> None:
        for engine in catalog.BROWSER_ENGINES:
            with self.subTest(dropped=engine):
                targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
                memory = next(t for t in targets["targets"] if t["id"] == "memory-slope")
                memory["rows"] = [r for r in memory["rows"] if r.get("engine") != engine]
                code, out, err = self.tree(baseline_stories(), targets).run("targets", "--check")
                self.assertNotEqual(code, 0)
                self.assertEqual(out, "")
                self.assertIn("memory-slope needs a chromium row and a webkit row (F12)", err)

    def test_browser_target_row_without_an_engine_fails(self) -> None:
        targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
        idle = next(t for t in targets["targets"] if t["id"] == "idle-wakeups")
        idle["rows"].append({**copy.deepcopy(idle["rows"][0]), "id": "idle-wakeups.any"})
        del idle["rows"][-1]["engine"]
        self.assertProblem(self.problems(baseline_stories(), targets),
                           "row idle-wakeups.any of browser target idle-wakeups names no browser engine")

    def test_webkit_rows_must_judge_what_the_chromium_rows_judge(self) -> None:
        def loosened(change):
            targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
            idle = next(t for t in targets["targets"] if t["id"] == "idle-wakeups")
            change(next(r for r in idle["rows"] if r["engine"] == "webkit"))
            return targets
        changes = {
            "a looser limit": lambda row: row["checks"][0].update(value=2),
            "a dropped check": lambda row: row["checks"].pop(),
            "another session": lambda row: row.update(session="stress"),
        }
        for name, change in changes.items():
            with self.subTest(name):
                self.assertProblem(self.problems(baseline_stories(), loosened(change)),
                                   "idle-wakeups: its webkit rows do not judge the same checks as its chromium rows")

    def test_engine_named_in_a_metric_pattern_is_the_same_check(self) -> None:
        rows = [catalog.Row(f"crash.{e}", "crash", (catalog.Check(f"crash_survival\\.{e}", "min", ">=", 1.0, "ratio"),),
                            engine=e) for e in catalog.BROWSER_ENGINES]
        self.assertEqual(catalog.engine_row_problems("crash", rows), [])

    def test_exactly_twelve_targets(self) -> None:
        targets = json.loads((REPO_ROOT / catalog.TARGETS_PATH).read_text())
        extra = copy.deepcopy(targets)
        extra["targets"].append({**copy.deepcopy(targets["targets"][2]), "id": "thirteenth"})
        for row in extra["targets"][-1]["rows"]:
            row["id"] += "-13"
        self.assertProblem(self.problems(baseline_stories(), extra), "13 targets")

    def test_commands_refuse_a_catalog_with_problems(self) -> None:
        tree = self.tree([*baseline_stories(), story("bad", owner="nobody")])
        code, out, err = tree.run("targets", "--uncovered")
        self.assertEqual((code, out), (2, ""))
        self.assertIn("owner 'nobody'", err)


class HotPathTests(FixtureTestCase):
    def test_uncovered_lists_hot_paths_no_story_benches(self) -> None:
        code, out, _ = self.tree(baseline_stories()).run("hot-paths", "--uncovered")
        self.assertEqual(code, 0)
        self.assertEqual(out, "key-dispatch\tPL-typing\ttyping.py\n")

    def test_checkout_hot_paths_are_known_ids(self) -> None:
        loaded = catalog.load_catalog(REPO_ROOT)
        listed = set(catalog.uncovered_hot_paths(loaded))
        covered = {h for s in loaded.stories for h in s.hot_paths}
        self.assertEqual(listed | covered, set(loaded.hot_paths))
        self.assertFalse(listed & covered)


if __name__ == "__main__":
    unittest.main()
