#!/usr/bin/env python3
"""features_arms.py: perfPath features whose registry file or story paths changed in 24 h are scheduler arms.

  python3 -m unittest scripts/perf-lab/tests/test_features_arms.py

Each test builds a small git repository with dated commits (GIT_COMMITTER_DATE), so the change window is tested
against real `git log` output, and drives scheduler.plan() with the selection the way labd's tick does.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, LAB / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


arms = _load("features_arms")
scheduler = _load("scheduler")
lab = _load("lab")

NOW = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)  # lab day 2026-10-26 started at 09:00 UTC
SHA_PLACEHOLDER = "0" * 40


def feature(name: str, kind: str = "perfPath", stories: tuple[str, ...] = ("s-a",), release: bool = False) -> dict:
    document = {
        "name": name, "owner": "Performance Lead", "description": f"{name} path.",
        "defaults": {"dev": True, "nightly": True, "release": release}, "kind": kind, "process": "app",
        "params": [], "stories": list(stories), "sticky": False, "runtimeMutable": False,
    }
    if kind == "perfPath":
        document["expires"] = "2026-12-20"
    return document


def story(story_id: str, command: str) -> dict:
    return {"id": story_id, "tier": "T1", "command": [command, "--scenario", story_id]}


class Repo:
    """A throwaway git repository whose commits carry the times the test gives them."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_AUTHOR_NAME": "lab", "GIT_AUTHOR_EMAIL": "lab@example.invalid",
                    "GIT_COMMITTER_NAME": "lab", "GIT_COMMITTER_EMAIL": "lab@example.invalid"}
        self.git("init", "--quiet", "--initial-branch=main")

    def git(self, *args: str, when: datetime | None = None) -> str:
        env = dict(self.env)
        if when is not None:
            env["GIT_AUTHOR_DATE"] = env["GIT_COMMITTER_DATE"] = when.strftime("%Y-%m-%dT%H:%M:%S+0000")
        done = subprocess.run(["git", "-C", str(self.path), "-c", "core.hooksPath=" + os.devnull, *args],
                              env=env, capture_output=True, text=True, check=True)
        return done.stdout.strip()

    def write(self, files: dict[str, dict | str]) -> None:
        for relative, content in files.items():
            target = self.path / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content if isinstance(content, str) else json.dumps(content, indent=1))

    def commit(self, when: datetime, files: dict[str, dict | str], message: str = "change") -> str:
        self.write(files)
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", message, when=when)
        return self.git("rev-parse", "HEAD")


def base_files() -> dict[str, dict | str]:
    return {
        "schemas/features/features.d/pathA.json": feature("pathA", stories=("s-a",)),
        "schemas/features/features.d/pathB.json": feature("pathB", stories=("s-b",)),
        "schemas/features/features.d/labsC.json": feature("labsC", kind="labs", stories=("s-a",)),
        "scripts/perf-lab/stories.d/s-a.json": story("s-a", "scripts/bench/a.py"),
        "scripts/perf-lab/stories.d/s-b.json": story("s-b", "scripts/bench/b.py"),
        "scripts/bench/a.py": "print('a')\n",
        "scripts/bench/b.py": "print('b')\n",
        "README.md": "fixture\n",
    }


class FeatureArmsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Repo(Path(self.tmp.name))
        self.base = self.repo.commit(NOW - timedelta(days=3), base_files(), "base")

    def select(self, sha: str = "HEAD", now: datetime = NOW):
        return arms.feature_arms(self.repo.path, sha, now)

    def test_unchanged_features_get_no_arm(self):
        self.repo.commit(NOW - timedelta(hours=2), {"README.md": "unrelated\n"})
        selection = self.select()
        self.assertEqual(selection.arms, ())
        self.assertEqual(selection.problems, ())

    def test_changed_registry_file_arms_that_feature_only(self):
        self.repo.commit(NOW - timedelta(hours=2),
                         {"schemas/features/features.d/pathA.json": feature("pathA", release=True)})
        selection = self.select()
        self.assertEqual(selection.inputs, (scheduler.FeatureArm("pathA", ("s-a",)),))
        self.assertEqual(selection.arms[0].changed, ("schemas/features/features.d/pathA.json",))

    def test_story_file_or_story_command_change_arms_every_feature_that_benches_it(self):
        self.repo.commit(NOW - timedelta(hours=5), {"scripts/bench/b.py": "print('faster b')\n"})
        self.assertEqual([a.feature for a in self.select().arms], ["pathB"])
        self.repo.commit(NOW - timedelta(hours=1), {"scripts/perf-lab/stories.d/s-a.json":
                                                    {**story("s-a", "scripts/bench/a.py"), "repeats": 7}})
        selection = self.select()
        self.assertEqual([(a.feature, a.changed) for a in selection.arms],
                         [("pathA", ("scripts/perf-lab/stories.d/s-a.json",)), ("pathB", ("scripts/bench/b.py",))])

    def test_non_perf_path_feature_never_gets_an_arm(self):
        self.repo.commit(NOW - timedelta(hours=2), {
            "schemas/features/features.d/labsC.json": feature("labsC", kind="labs", release=True),
        })
        self.assertEqual(self.select().arms, ())

    def test_change_outside_the_window_gets_no_arm(self):
        self.repo.commit(NOW - timedelta(hours=25),
                         {"schemas/features/features.d/pathA.json": feature("pathA", release=True)})
        self.assertEqual(self.select().arms, ())
        self.assertEqual([a.feature for a in self.select(now=NOW - timedelta(hours=2)).arms], ["pathA"])

    def test_merge_counts_at_merge_time_on_the_first_parent(self):
        self.repo.git("checkout", "--quiet", "-b", "topic")
        self.repo.commit(NOW - timedelta(days=2), {"scripts/bench/a.py": "print('old topic work')\n"})
        self.repo.git("checkout", "--quiet", "main")
        self.repo.git("merge", "--quiet", "--no-ff", "-m", "merge topic", "topic", when=NOW - timedelta(hours=3))
        selection = self.select()
        self.assertEqual([(a.feature, a.changed) for a in selection.arms], [("pathA", ("scripts/bench/a.py",))])

    def test_reads_the_measured_commit_not_a_later_tip(self):
        measured = self.repo.commit(NOW - timedelta(hours=4), {"README.md": "measured\n"})
        self.repo.commit(NOW - timedelta(hours=1),
                         {"schemas/features/features.d/pathB.json": feature("pathB", release=True)})
        self.assertEqual(self.select(measured).arms, ())
        self.assertEqual(self.select(measured).sha, measured)

    def test_feature_added_in_the_window_is_armed_with_its_stories(self):
        self.repo.commit(NOW - timedelta(hours=2), {
            "schemas/features/features.d/pathD.json": feature("pathD", stories=("s-a", "s-b")),
        })
        self.assertEqual(self.select().inputs, (scheduler.FeatureArm("pathD", ("s-a", "s-b")),))

    def test_feature_without_a_story_file_is_a_problem_and_gets_no_arm(self):
        self.repo.commit(NOW - timedelta(hours=2), {
            "schemas/features/features.d/pathE.json": feature("pathE", stories=("s-missing",)),
            "schemas/features/features.d/pathF.json": feature("pathF", stories=("s-a", "s-missing")),
        })
        selection = self.select()
        self.assertEqual(selection.inputs, (scheduler.FeatureArm("pathF", ("s-a",)),))
        self.assertIn("pathE: no story to bench its arms; it gets no arm", selection.problems)
        self.assertIn("pathF: no story file for s-missing in scripts/perf-lab/stories.d", selection.problems)

    def test_broken_registry_file_is_a_problem(self):
        self.repo.commit(NOW - timedelta(hours=2), {"schemas/features/features.d/broken.json": "{not json"})
        selection = self.select()
        self.assertEqual(selection.arms, ())
        self.assertEqual(len(selection.problems), 1)
        self.assertTrue(selection.problems[0].startswith("schemas/features/features.d/broken.json: not JSON"))

    def test_unknown_commit_raises(self):
        with self.assertRaises(arms.ArmsError):
            self.select("f" * 40)
        with self.assertRaises(arms.ArmsError):
            self.select(now=NOW.replace(tzinfo=None))

    def test_batch_read_reports_missing_files_and_trees_as_none(self):
        tree = arms.GitTree(self.repo.path, self.base)
        contents = tree.read(["scripts/bench/a.py", "no/such/file", "scripts/bench", "scripts/bench/b.py"])
        self.assertEqual(contents, {"scripts/bench/a.py": b"print('a')\n", "no/such/file": None,
                                    "scripts/bench": None, "scripts/bench/b.py": b"print('b')\n"})

    def test_changed_feature_gets_one_pair_per_lab_day_and_unchanged_none(self):
        """Acceptance: hourly ticks over three lab days; pathA changed once at 10:00 on day one."""
        self.repo.commit(datetime(2026, 10, 26, 10, 0, tzinfo=timezone.utc),
                         {"schemas/features/features.d/pathA.json": feature("pathA", release=True)})
        sha = self.repo.git("rev-parse", "HEAD")
        state = scheduler.State(last_t0_sha=sha)
        pairs: dict[tuple[str, str], list[str]] = {}
        moment = datetime(2026, 10, 26, 9, 30, tzinfo=timezone.utc)
        while moment < datetime(2026, 10, 29, 9, 0, tzinfo=timezone.utc):
            selection = arms.feature_arms(self.repo.path, sha, moment)
            result = scheduler.plan(state, moment, [], scheduler.Builds(), (), stories=(),
                                    shard_map=scheduler.ShardMap({}), arms=selection.inputs)
            state = result.state
            for arm in result.arms:
                self.assertEqual((arm.sha, arm.stories), (sha, ("s-a",)))
                pairs.setdefault((scheduler.lab_day(moment), arm.feature), []).append(arm.value)
            moment += timedelta(hours=1)
        # Day one: changed at 10:00, the 10:30 tick arms it. Day two: the change is still inside 24 h at 09:30.
        # Day three: the change is 47 h old, so no arm. pathB never changed.
        self.assertEqual(pairs, {("2026-10-26", "pathA"): ["on", "off"], ("2026-10-27", "pathA"): ["on", "off"]})


class CommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Repo(Path(self.tmp.name))
        self.repo.commit(NOW - timedelta(days=3), base_files(), "base")
        self.repo.commit(NOW - timedelta(hours=2), {"scripts/bench/a.py": "print('a2')\n"})

    def lab(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lab.main(["feature-arms", "--root", str(self.repo.path), "--now", NOW.isoformat(), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_lab_command_prints_json(self):
        code, out, _ = self.lab("--json")
        self.assertEqual(code, 0)
        document = json.loads(out)
        self.assertEqual(document["arms"], [{"feature": "pathA", "stories": ["s-a"], "changed": ["scripts/bench/a.py"]}])
        self.assertEqual((document["since"], document["until"]), ("2026-10-25T12:00:00Z", "2026-10-26T12:00:00Z"))

    def test_lab_command_prints_text_and_a_shorter_window(self):
        code, out, _ = self.lab()
        self.assertEqual(code, 0)
        self.assertIn("  pathA [s-a]: scripts/bench/a.py", out)
        code, out, _ = self.lab("--hours", "1")
        self.assertEqual(code, 0)
        self.assertNotIn("pathA", out)

    def test_lab_command_refuses_bad_input(self):
        self.assertEqual(self.lab("--hours", "0")[0], 2)
        code, _, err = self.lab("--ref", "no-such-ref")
        self.assertEqual(code, 2)
        self.assertIn("feature-arms: git rev-parse", err)


if __name__ == "__main__":
    unittest.main()
