#!/usr/bin/env python3
"""features_arms.py: perfPath features whose registry file or story paths changed in 24 h are scheduler arms.

  python3 -m unittest scripts/perf-lab/tests/test_features_arms.py

Each test builds a small git repository with dated commits (GIT_COMMITTER_DATE), so a test can show that commit
dates do not decide what changed, and a lab store (store.py) whose waterfall runs say which commit the lab measured
when. The acceptance test drives scheduler.plan() with the selection the way labd's tick does.
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
store = _load("store")
lab = _load("lab")

NOW = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)  # lab day 2026-10-26 started at 09:00 UTC
HOST = store.Host(name="cmux15", chip="Apple M6", memory_gb=24, display_hz=120, fingerprint="fp-1")


class LabStore:
    """A lab store holding the runs that say which commit the lab measured when."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.runs = 0
        self.positions: dict[str, int] = {}

    def measured(self, sha: str, when: datetime, *, kind: str = "waterfall") -> None:
        self.runs += 1
        position = self.positions.setdefault(sha, len(self.positions) + 1)
        lab_store = store.Store(self.path)
        try:
            lab_store.migrate()
            run = store.Run(run_uuid=f"run-{self.runs}", kind=kind, measure_version="1", story="s-a",
                            engine="chromium", macos_major=26, macos_build="26.7 (25H1)", features_hash="f0",
                            safe_mode="off", started_at=when, tier="T0")
            lab_store.insert_run(run, build=store.Build(sha=sha, config="bench", commit_pos=position), host=HOST,
                                 metrics=[store.Metric("frame_ms", "ms", "lower", [1.0, 1.1, 0.9])])
        finally:
            lab_store.close()


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
        path.mkdir(parents=True, exist_ok=True)
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
        self.repo = Repo(Path(self.tmp.name) / "repo")
        self.base = self.repo.commit(NOW - timedelta(days=3), base_files(), "base")

    def select(self, sha: str = "HEAD", now: datetime = NOW, base: str | None = None):
        """The selection of `sha`, diffed against `base` (default: the base commit, measured three days ago)."""
        return arms.feature_arms(self.repo.path, sha, now, base=base or self.base)

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

    def test_change_already_in_the_base_gets_no_arm(self):
        measured = self.repo.commit(NOW - timedelta(hours=25),
                                    {"schemas/features/features.d/pathA.json": feature("pathA", release=True)})
        self.assertEqual(self.select(base=measured).arms, ())
        self.assertEqual(self.select(base=measured).base, measured)
        self.assertEqual([a.feature for a in self.select().arms], ["pathA"])

    def test_merged_topic_counts_even_when_its_commits_are_older(self):
        self.repo.git("checkout", "--quiet", "-b", "topic")
        self.repo.commit(NOW - timedelta(days=4), {"scripts/bench/a.py": "print('old topic work')\n"})
        self.repo.git("checkout", "--quiet", "main")
        self.repo.git("merge", "--quiet", "--no-ff", "-m", "merge topic", "topic", when=NOW - timedelta(hours=3))
        selection = self.select()
        self.assertEqual([(a.feature, a.changed) for a in selection.arms], [("pathA", ("scripts/bench/a.py",))])

    def test_fast_forwarded_old_dated_commit_and_the_commit_below_it_both_count(self):
        """Regression: a date-filtered first-parent log dropped the old-dated commit and stopped its walk there, so
        it also lost the recent commit below it."""
        self.repo.commit(NOW - timedelta(hours=2),
                         {"schemas/features/features.d/pathA.json": feature("pathA", release=True)}, "recent1")
        self.repo.git("checkout", "--quiet", "-b", "topic")
        self.repo.commit(NOW - timedelta(days=2), {"scripts/bench/b.py": "print('old-dated topic work')\n"}, "old")
        self.repo.git("checkout", "--quiet", "main")
        self.repo.git("merge", "--quiet", "--ff-only", "topic")
        self.repo.commit(NOW - timedelta(hours=1), {"README.md": "recent2\n"}, "recent2")
        selection = self.select()
        self.assertEqual([(a.feature, a.changed) for a in selection.arms],
                         [("pathA", ("schemas/features/features.d/pathA.json",)), ("pathB", ("scripts/bench/b.py",))])
        self.assertEqual(selection.problems, ())

    def test_no_base_is_a_problem_and_no_arm(self):
        self.repo.commit(NOW - timedelta(hours=2),
                         {"schemas/features/features.d/pathA.json": feature("pathA", release=True)})
        selection = arms.feature_arms(self.repo.path, "HEAD", NOW, base=None)
        self.assertEqual((selection.arms, selection.base), ((), None))
        self.assertEqual(selection.problems, ("no commit measured at or before 2026-10-25T12:00:00Z is known, so "
                                              "there is nothing to diff against: no feature arms",))

    def test_measured_base_is_the_newest_waterfall_run_at_or_before_the_window_start(self):
        lab_store = LabStore(Path(self.tmp.name) / "lab.sqlite3")
        older = self.repo.commit(NOW - timedelta(days=2), {"README.md": "older\n"})
        at_start = self.repo.commit(NOW - timedelta(hours=30), {"README.md": "at start\n"})
        inside = self.repo.commit(NOW - timedelta(hours=10), {"README.md": "inside\n"})
        lab_store.measured(older, NOW - timedelta(days=2))
        lab_store.measured(at_start, NOW - timedelta(hours=24))
        lab_store.measured(inside, NOW - timedelta(hours=9))
        lab_store.measured("d" * 40, NOW - timedelta(hours=30), kind="try")  # a try run measures no branch commit
        since = NOW - timedelta(hours=24)
        self.assertEqual(arms.measured_base(lab_store.path, since), at_start)
        self.assertEqual(arms.measured_base(lab_store.path, since - timedelta(microseconds=1)), older)
        self.assertIsNone(arms.measured_base(lab_store.path, NOW - timedelta(days=3)))
        with self.assertRaises(arms.ArmsError):
            arms.measured_base(Path(self.tmp.name) / "no-such.sqlite3", since)

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
            self.select(base="f" * 40)
        with self.assertRaises(arms.ArmsError):
            self.select(now=NOW.replace(tzinfo=None))

    def test_batch_read_reports_missing_files_and_trees_as_none(self):
        tree = arms.GitTree(self.repo.path, self.base)
        contents = tree.read(["scripts/bench/a.py", "no/such/file", "scripts/bench", "scripts/bench/b.py"])
        self.assertEqual(contents, {"scripts/bench/a.py": b"print('a')\n", "no/such/file": None,
                                    "scripts/bench": None, "scripts/bench/b.py": b"print('b')\n"})

    def test_changed_feature_gets_one_pair_per_lab_day_and_unchanged_none(self):
        """Acceptance: hourly ticks over three lab days; pathA changed once at 10:00 on day one and the lab measured
        that commit at 10:20, after measuring the base commit on the day it landed."""
        lab_store = LabStore(Path(self.tmp.name) / "lab.sqlite3")
        lab_store.measured(self.base, NOW - timedelta(days=3, minutes=-20))
        sha = self.repo.commit(datetime(2026, 10, 26, 10, 0, tzinfo=timezone.utc),
                               {"schemas/features/features.d/pathA.json": feature("pathA", release=True)})
        lab_store.measured(sha, datetime(2026, 10, 26, 10, 20, tzinfo=timezone.utc))
        state = scheduler.State(last_t0_sha=sha)
        pairs: dict[tuple[str, str], list[str]] = {}
        moment = datetime(2026, 10, 26, 9, 30, tzinfo=timezone.utc)
        while moment < datetime(2026, 10, 29, 9, 0, tzinfo=timezone.utc):
            base = arms.measured_base(lab_store.path, moment - arms.WINDOW)
            selection = arms.feature_arms(self.repo.path, sha, moment, base=base)
            result = scheduler.plan(state, moment, [], scheduler.Builds(), (), stories=(),
                                    shard_map=scheduler.ShardMap({}), arms=selection.inputs)
            state = result.state
            for arm in result.arms:
                self.assertEqual((arm.sha, arm.stories), (sha, ("s-a",)))
                pairs.setdefault((scheduler.lab_day(moment), arm.feature), []).append(arm.value)
            moment += timedelta(hours=1)
        # Day one and day two up to 10:20: the base is self.base, so pathA is armed once per day. From the 10:30
        # tick of day two the base is sha itself, so day three gets no arm. pathB never changed.
        self.assertEqual(pairs, {("2026-10-26", "pathA"): ["on", "off"], ("2026-10-27", "pathA"): ["on", "off"]})


class CommandTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Repo(Path(self.tmp.name) / "repo")
        self.base = self.repo.commit(NOW - timedelta(days=3), base_files(), "base")
        self.head = self.repo.commit(NOW - timedelta(hours=2), {"scripts/bench/a.py": "print('a2')\n"})
        self.store = LabStore(Path(self.tmp.name) / "lab.sqlite3")
        self.store.measured(self.base, NOW - timedelta(days=3, minutes=-20))
        self.store.measured(self.head, NOW - timedelta(minutes=90))

    def lab(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lab.main(["feature-arms", "--root", str(self.repo.path), "--now", NOW.isoformat(), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_lab_command_prints_json(self):
        code, out, _ = self.lab("--db", str(self.store.path), "--json")
        self.assertEqual(code, 0)
        document = json.loads(out)
        self.assertEqual(document["arms"],
                         [{"feature": "pathA", "stories": ["s-a"], "changed": ["scripts/bench/a.py"]}])
        self.assertEqual((document["base"], document["since"], document["until"]),
                         (self.base, "2026-10-25T12:00:00Z", "2026-10-26T12:00:00Z"))

    def test_lab_command_prints_text_and_a_shorter_window(self):
        code, out, _ = self.lab("--db", str(self.store.path))
        self.assertEqual(code, 0)
        self.assertIn(f"changes since {self.base[:12]}", out)
        self.assertIn("  pathA [s-a]: scripts/bench/a.py", out)
        code, out, _ = self.lab("--db", str(self.store.path), "--hours", "1")  # the lab measured head 90 min ago
        self.assertEqual(code, 0)
        self.assertNotIn("pathA", out)

    def test_lab_command_takes_an_explicit_base(self):
        code, out, _ = self.lab("--base", self.base, "--json")
        self.assertEqual((code, [a["feature"] for a in json.loads(out)["arms"]]), (0, ["pathA"]))
        code, out, _ = self.lab("--base", self.head, "--json")
        self.assertEqual((code, json.loads(out)["arms"]), (0, []))

    def test_lab_command_without_a_base_reports_the_problem(self):
        code, out, _ = self.lab()
        self.assertEqual(code, 0)
        self.assertIn("changes since no base", out)
        self.assertIn("problem: no commit measured at or before 2026-10-25T12:00:00Z is known", out)
        self.assertNotIn("pathA [", out)

    def test_lab_command_refuses_bad_input(self):
        self.assertEqual(self.lab("--base", self.base, "--hours", "0")[0], 2)
        code, _, err = self.lab("--base", self.base, "--ref", "no-such-ref")
        self.assertEqual(code, 2)
        self.assertIn("feature-arms: git rev-parse", err)
        code, _, err = self.lab("--db", str(Path(self.tmp.name) / "missing.sqlite3"))
        self.assertEqual(code, 2)
        self.assertIn("feature-arms: lab store", err)


if __name__ == "__main__":
    unittest.main()
