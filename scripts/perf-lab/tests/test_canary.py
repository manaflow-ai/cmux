#!/usr/bin/env python3
"""canary.py: the scratch history, its T0 lane and the three checks of done check 10.

  python3 -m unittest scripts/perf-lab/tests/test_canary.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent
ROOT = LAB.parents[1]


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


canary = _load("perf_lab_canary", LAB / "canary.py")
store = _load("perf_lab_store", LAB / "store.py")
scheduler = _load("perf_lab_scheduler", LAB / "scheduler.py")
lab = _load("perf_lab_lab", LAB / "lab.py")

T0 = datetime(2026, 10, 26, 12, 0, tzinfo=timezone.utc)
RUN_ID = "20261026T120000Z-0123456789ab"
BASE_POS = 1000


def _git(*args: str, cwd: Path) -> str:
    done = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True)
    return done.stdout.strip()


class LayoutTests(unittest.TestCase):
    def test_default_layout_has_six_batches_on_each_side_of_the_injected_one(self):
        layout = canary.Layout()
        self.assertEqual((layout.batches, layout.batch_commits, layout.injected_batch), (13, 4, 6))
        self.assertEqual(layout.total, 52)
        self.assertEqual(canary.ALERT_WITHIN_BATCHES, 7)

    def test_injected_commit_is_never_a_batch_tip(self):
        with self.assertRaises(canary.CanaryError):
            canary.Layout(injected_offset=3)
        for seed in range(50):
            layout = canary.choose_layout(random.Random(seed))
            self.assertLess(layout.injected_offset, layout.batch_commits - 1)
        self.assertEqual(canary.choose_layout(random.Random(1), at=2).injected_index, 6 * 4 + 2)

    def test_seed_picks_the_same_commit(self):
        self.assertEqual(canary.choose_layout(random.Random(7)), canary.choose_layout(random.Random(7)))


class ScratchRefTests(unittest.TestCase):
    def test_refuses_every_ref_outside_the_canary_namespace(self):
        refused = ["refs/heads/feat-cmux-next", "refs/heads/perf/chrome-parity", "refs/heads/main",
                   "refs/heads/perf-lab/canary/feat-cmux-next", "refs/heads/perf-lab/canary/../../main",
                   f"refs/heads/perf-lab/canary/{RUN_ID}/x", f"refs/tags/perf-lab/canary/{RUN_ID}"]
        calls = []
        for ref in refused:
            with self.assertRaises(canary.CanaryError, msg=ref):
                canary.push_scratch(Path("."), "origin", "a" * 40, ref, git=lambda *a, cwd: calls.append(a) or "")
        self.assertEqual(calls, [])
        with self.assertRaises(canary.CanaryError):
            canary.scratch_ref("feat-cmux-next")
        self.assertEqual(canary.scratch_ref(RUN_ID), f"refs/heads/perf-lab/canary/{RUN_ID}")

    def test_run_id_is_utc_stamp_and_tip(self):
        tip = "0123456789ab" + "c" * 28
        self.assertEqual(canary.run_id_for(T0, tip), RUN_ID)


class TurnOnTests(unittest.TestCase):
    def test_turns_the_shipped_feature_on_in_every_channel_and_keeps_the_rest(self):
        text = (ROOT / canary.FEATURE_FILE).read_text(encoding="utf-8")
        before, after = json.loads(text), json.loads(canary.turn_on(text))
        self.assertEqual(before["defaults"], {"dev": False, "nightly": False, "release": False})
        self.assertEqual(after["defaults"], {"dev": True, "nightly": True, "release": True})
        self.assertEqual({k: v for k, v in after.items() if k != "defaults"},
                         {k: v for k, v in before.items() if k != "defaults"})

    def test_refuses_another_feature(self):
        other = (ROOT / "schemas/features/features.d/perfLabKillProbe.json").read_text(encoding="utf-8")
        with self.assertRaises(canary.CanaryError):
            canary.turn_on(other)

    def test_the_real_generator_writes_the_flip(self):
        """The flip commit regenerates the Swift registry with the tree's own gen-features.py."""
        with tempfile.TemporaryDirectory() as temp:
            tree = Path(temp)
            for rel in ("schemas/features", "scripts/perf-lab/stories.d"):
                shutil.copytree(ROOT / rel, tree / rel)
            for rel in (canary.GENERATOR, "plans/cmux-next/OWNERS.md", "plans/cmux-next/perf-lead.md",
                        "Packages/macOS/CmuxNext/Package.swift", canary.GENERATED_SWIFT):
                (tree / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / rel, tree / rel)
            path = tree / canary.FEATURE_FILE
            path.write_text(canary.turn_on(path.read_text(encoding="utf-8")), encoding="utf-8")
            canary.regenerate_registry(tree)
            swift = (tree / canary.GENERATED_SWIFT).read_text(encoding="utf-8")
        block = swift[swift.index("public static let perfLabCanary"):]
        block = block[:block.index(")\n\n")]
        self.assertIn("defaults: FeatureDefaults(dev: true, nightly: true, release: true)", block)


class BuildScratchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.remote = root / "remote.git"
        self.repo = root / "repo"
        _git("init", "--quiet", "--bare", str(self.remote), cwd=root)
        _git("init", "--quiet", "-b", "feat-cmux-next", str(self.repo), cwd=root)
        feature = self.repo / canary.FEATURE_FILE
        feature.parent.mkdir(parents=True)
        shutil.copy2(ROOT / canary.FEATURE_FILE, feature)
        generated = self.repo / canary.GENERATED_SWIFT
        generated.parent.mkdir(parents=True)
        generated.write_text("dev: false\n", encoding="utf-8")
        _git("add", "-A", cwd=self.repo)
        _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "base", cwd=self.repo)
        _git("remote", "add", "origin", str(self.remote), cwd=self.repo)
        _git("push", "--quiet", "origin", "feat-cmux-next", cwd=self.repo)
        self.tip = _git("rev-parse", "HEAD", cwd=self.repo)

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def regenerate(tree: Path) -> None:
        defaults = json.loads((tree / canary.FEATURE_FILE).read_text(encoding="utf-8"))["defaults"]
        (tree / canary.GENERATED_SWIFT).write_text(f"dev: {str(defaults['dev']).lower()}\n", encoding="utf-8")

    def test_one_flip_commit_inside_its_batch_and_empty_commits_around_it(self):
        layout = canary.Layout(injected_offset=1)
        scratch = canary.build_scratch(self.repo, self.tip, RUN_ID, layout, git=canary.git_runner(),
                                       regenerate=self.regenerate)
        self.assertEqual(len(scratch.batches), 13)
        commits = [sha for batch in scratch.batches for sha in batch.commits]
        self.assertEqual(len(commits), 52)
        self.assertEqual(scratch.injected, commits[6 * 4 + 1])
        self.assertNotIn(scratch.injected, [batch.tip for batch in scratch.batches])
        self.assertEqual(_git("rev-list", "--first-parent", "--reverse", f"{self.tip}..{commits[-1]}", cwd=self.repo)
                         .split(), commits)
        changed = {sha: _git("diff-tree", "--no-commit-id", "--name-only", "-r", sha, cwd=self.repo).split()
                   for sha in commits}
        self.assertEqual({sha for sha, files in changed.items() if files}, {scratch.injected})
        self.assertEqual(sorted(changed[scratch.injected]), sorted([canary.FEATURE_FILE, canary.GENERATED_SWIFT]))
        on = json.loads(_git("show", f"{scratch.injected}:{canary.FEATURE_FILE}", cwd=self.repo))
        off = json.loads(_git("show", f"{scratch.injected}^:{canary.FEATURE_FILE}", cwd=self.repo))
        self.assertEqual((on["defaults"]["dev"], off["defaults"]["dev"]), (True, False))
        self.assertEqual(_git("show", f"{commits[-1]}:{canary.GENERATED_SWIFT}", cwd=self.repo), "dev: true")
        self.assertEqual(len(_git("worktree", "list", "--porcelain", cwd=self.repo).split("\n\n")), 1)

        canary.push_scratch(self.repo, "origin", commits[-1], canary.scratch_ref(RUN_ID), git=canary.git_runner())
        heads = _git("for-each-ref", "--format=%(refname) %(objectname)", cwd=self.remote).splitlines()
        self.assertEqual(sorted(heads), sorted([f"refs/heads/feat-cmux-next {self.tip}",
                                                f"refs/heads/perf-lab/canary/{RUN_ID} {commits[-1]}"]))
        self.assertEqual(_git("rev-parse", f"refs/perf-lab/canary/{RUN_ID}", cwd=self.repo), commits[-1])

    def test_a_tip_without_the_feature_is_refused_and_leaves_no_worktree(self):
        _git("rm", "--quiet", canary.FEATURE_FILE, cwd=self.repo)
        _git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "drop", cwd=self.repo)
        tip = _git("rev-parse", "HEAD", cwd=self.repo)
        with self.assertRaises(canary.CanaryError):
            canary.build_scratch(self.repo, tip, RUN_ID, canary.Layout(), git=canary.git_runner(),
                                 regenerate=self.regenerate)
        self.assertEqual(len(_git("worktree", "list", "--porcelain", cwd=self.repo).split("\n\n")), 1)


def _record(injected_batch: int = 6) -> "canary.RunRecord":
    batches = []
    for index in range(13):
        first = f"{index:02d}" + "a" * 38
        tip = f"{index:02d}" + "f" * 38
        batches.append({"first": first, "tip": tip, "commits": [first, tip], "build_requested": False, "t0_at": None})
    return canary.RunRecord(RUN_ID, canary._stamp(T0), "origin", "b" * 40, "06" + "c" * 38, BASE_POS + 6 * 4 + 2,
                            injected_batch, batches)


STORIES = (scheduler.StorySpec("terminal-key", "T0", 60, "bench"), scheduler.StorySpec("switch", "T0", 40, "bench"),
           scheduler.StorySpec("cold-launch", "T1", 300, "bench"))
SHARDS = scheduler.ShardMap.from_document({"classes": {"m6": {"tiers": ["T0", "T1"], "shards": [
    {"index": 0, "stories": {"T0": ["terminal-key"], "T1": ["cold-launch"]}},
    {"index": 1, "stories": {"T0": ["switch"]}}]}}})
HOSTS = [scheduler.Host("cmux15", "waterfall", "m6", "apple-m6/16gb/120hz", shard=0),
         scheduler.Host("cmux16", "waterfall", "m6", "apple-m6/16gb/120hz", shard=1),
         scheduler.Host("cmux17", "pinpoint", "m6", "apple-m6/16gb/120hz")]


class LaneTests(unittest.TestCase):
    def setUp(self):
        self.now = T0
        self.ready: set = set()
        self.sent: list[dict] = []
        self.refuse: set[str] = set()
        self.lane = canary.Lane(_record(), Path("/lane"), STORIES, SHARDS, lambda: HOSTS,
                                lambda: scheduler.Builds(ready=frozenset(self.ready)), self.submit, lambda: self.now)

    def submit(self, document: dict) -> set[str]:
        self.sent.append(document)
        return {job["id"] for job in document["jobs"]} & self.refuse

    def test_requests_every_batch_tip_once_and_waits_for_the_build(self):
        self.lane.step()
        self.lane.step()
        self.assertEqual(len(self.sent), 1)
        self.assertEqual([b["sha"] for b in self.sent[0]["builds"]], [b["tip"] for b in self.lane.record.batches])
        self.assertEqual({b["config"] for b in self.sent[0]["builds"]}, {"bench"})
        self.assertEqual(self.sent[0]["lane"], {"name": f"canary/{RUN_ID}", "ref": f"refs/heads/perf-lab/canary/{RUN_ID}",
                                                "results": "/lane/results"})

    def test_one_t0_round_per_batch_on_the_shard_owners_at_most_every_batch_interval(self):
        record = self.lane.record
        self.ready = {(b["tip"], "bench") for b in record.batches}
        self.lane.step()
        jobs = self.sent[-1]["jobs"]
        self.assertEqual([(j["id"], j["host"], j["stories"], j["sha"], j["first"], j["tier"], j["kind"]) for j in jobs],
                         [(f"canary:{RUN_ID}:T0-1:m6/0", "cmux15", ["terminal-key"], record.batches[0]["tip"],
                           record.batches[0]["first"], "T0", "waterfall"),
                          (f"canary:{RUN_ID}:T0-1:m6/1", "cmux16", ["switch"], record.batches[0]["tip"],
                           record.batches[0]["first"], "T0", "waterfall")])
        sent = len(self.sent)
        self.now += scheduler.BATCH_INTERVAL - timedelta(seconds=1)
        self.lane.step()
        self.assertEqual(len(self.sent), sent)
        self.now += timedelta(seconds=1)
        self.lane.step()
        self.assertEqual(self.sent[-1]["jobs"][0]["sha"], record.batches[1]["tip"])
        for _ in range(20):
            self.now += scheduler.BATCH_INTERVAL
            self.lane.step()
        self.assertTrue(all(b["t0_at"] for b in record.batches))
        self.assertEqual(sum(1 for d in self.sent if d["jobs"]), 13)

    def test_a_refused_round_is_sent_again(self):
        self.ready = {(b["tip"], "bench") for b in self.lane.record.batches}
        self.refuse = {f"canary:{RUN_ID}:T0-1:m6/1"}
        self.lane.step()
        self.assertIsNone(self.lane.record.batches[0]["t0_at"])
        self.refuse = set()
        self.lane.step()
        self.assertIsNotNone(self.lane.record.batches[0]["t0_at"])
        self.assertEqual(self.sent[-1]["jobs"][1]["id"], f"canary:{RUN_ID}:T0-1:m6/1")

    def test_no_owner_is_an_error(self):
        lane = canary.Lane(_record(), Path("/lane"), STORIES, SHARDS, lambda: HOSTS[2:],
                           lambda: scheduler.Builds(ready=frozenset((b["tip"], "bench") for b in _record().batches)),
                           self.submit, lambda: self.now)
        with self.assertRaises(canary.CanaryError):
            lane.step()


class LaneStore:
    """A lane store with T0 points at the batch tips and the alert, bisect and verify rows a run produces."""

    HOST = store.Host("cmux15", "Apple M6", 16, 120, "fp")

    def __init__(self, path: Path, record) -> None:
        self.path, self.record = path, record
        self.db = store.Store(path)
        self.db.migrate()

    def close(self) -> None:
        self.db.close()

    def point(self, batch: int, at: datetime, value: float) -> None:
        tip = self.record.batches[batch]["tip"]
        run = store.Run(f"run-{batch}", "waterfall", "m1", "terminal-key", "none", 26, "26A1", "h", "off", at,
                        tier="T0")
        self.db.insert_run(run, build=store.Build(tip, "bench", BASE_POS + batch * 4 + 3), host=self.HOST,
                           metrics=[store.Metric("key_to_frame_ms", "ms", "lower", [value] * 5)])

    def alert(self, at: datetime, start: int, end: int) -> int:
        def write():
            raw = self.db._db
            group = raw.execute("INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) "
                                "VALUES ('new', ?, ?, ?, ?)", (start, end, canary._stamp(at), canary._stamp(at))).lastrowid
            series = raw.execute("SELECT id FROM series LIMIT 1").fetchone()[0]
            raw.execute("INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,"
                        " is_improvement, created_at) VALUES (?, ?, 'edivisive', ?, ?, 8, 10, 0, ?)",
                        (series, group, start, end, canary._stamp(at)))
            return group

        return self.db._write(write)

    def job(self, kind: str, group: int, at: datetime, result: dict, head: str | None = None) -> None:
        self.db._write(lambda: self.db._db.execute(
            "INSERT INTO jobs (kind, state, story, head_sha, alert_group_id, result_json, created_at, updated_at) "
            "VALUES (?, 'done', 'terminal-key', ?, ?, ?, ?, ?)",
            (kind, head, group, json.dumps(result), canary._stamp(at), canary._stamp(at))))

    def judge(self, now: datetime):
        db = sqlite3.connect(self.path)
        try:
            return canary.judge(db, self.record, now)
        finally:
            db.close()


def _bisect(*commits: str) -> dict:
    return {"outcome": "culprits", "culprits": [{"commits": list(commits)}]}


def _verified(state: str = "verified", strict: str = "different") -> dict:
    return {"state": state, "strict": strict, "p_value": 0.001, "median_shift": 2.0, "reason": "r"}


class JudgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.record = _record()
        self.lane = LaneStore(Path(self.temp.name) / "lab.sqlite3", self.record)
        for batch in range(13):
            self.lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0 if batch < 6 else 10.0)
        self.alerted = T0 + 12 * scheduler.BATCH_INTERVAL + timedelta(minutes=1)
        self.injected_pos = self.record.injected_pos

    def tearDown(self):
        self.lane.close()
        self.temp.cleanup()

    def test_full_pass(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted + timedelta(hours=2), _bisect(self.record.injected))
        self.lane.job("verify", group, self.alerted + timedelta(hours=3), _verified(), head=self.record.injected)
        verdict = self.lane.judge(self.alerted + timedelta(hours=4))
        self.assertEqual(verdict.to_dict()["state"], canary.PASS, verdict)
        self.assertIn("after 7 T0 batches", verdict.alert.detail)

    def test_no_alert_is_pending_until_seven_batches_are_measured(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        lane = LaneStore(Path(temp.name) / "lab.sqlite3", self.record)
        self.addCleanup(lane.close)
        for batch in range(12):
            lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0)
        self.assertEqual(lane.judge(T0 + timedelta(hours=2)).state, canary.PENDING)
        lane.point(12, T0 + 12 * scheduler.BATCH_INTERVAL, 8.0)
        verdict = lane.judge(T0 + timedelta(hours=3))
        self.assertEqual((verdict.state, verdict.alert.state), (canary.FAIL, canary.FAIL))

    def test_an_alert_after_more_than_seven_batches_fails(self):
        self.record.injected_pos = BASE_POS + 5 * 4 + 2  # in batch 6: 8 batch tips at or after it
        self.lane.alert(self.alerted, BASE_POS + 4 * 4 + 4, BASE_POS + 6 * 4 + 3)
        alert = self.lane.judge(self.alerted).alert
        self.assertEqual(alert.state, canary.FAIL)
        self.assertIn("after 8 T0 batches", alert.detail)

    def test_an_alert_whose_range_misses_the_injected_commit_does_not_count(self):
        self.lane.alert(self.alerted, BASE_POS + 7 * 4 + 4, BASE_POS + 8 * 4 + 3)
        self.assertEqual(self.lane.judge(self.alerted).alert.state, canary.FAIL)

    def test_a_bisect_to_another_commit_fails(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted + timedelta(hours=1), _bisect("06" + "a" * 38))
        bisect = self.lane.judge(self.alerted + timedelta(hours=1)).bisect
        self.assertEqual(bisect.state, canary.FAIL)
        self.assertIn("06aaaaaaaaaa", bisect.detail)

    def test_a_range_culprit_is_not_exact(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted, _bisect(self.record.injected, "06" + "f" * 38))
        self.assertEqual(self.lane.judge(self.alerted).bisect.state, canary.FAIL)

    def test_a_bisect_later_than_three_hours_fails(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.assertEqual(self.lane.judge(self.alerted + timedelta(hours=2)).bisect.state, canary.PENDING)
        self.assertEqual(self.lane.judge(self.alerted + timedelta(hours=3, seconds=1)).bisect.state, canary.FAIL)
        self.lane.job("bisect", group, self.alerted + timedelta(hours=3, minutes=1), _bisect(self.record.injected))
        self.assertEqual(self.lane.judge(self.alerted + timedelta(hours=4)).bisect.state, canary.FAIL)

    def test_verification_needs_the_strict_rule(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("bisect", group, self.alerted, _bisect(self.record.injected))
        self.assertEqual(self.lane.judge(self.alerted).verify.state, canary.PENDING)
        self.lane.job("verify", group, self.alerted, _verified("unverified", "unknown"), head=self.record.injected)
        verdict = self.lane.judge(self.alerted)
        self.assertEqual((verdict.verify.state, verdict.state), (canary.FAIL, canary.FAIL))

    def test_a_verification_of_another_commit_does_not_count(self):
        group = self.lane.alert(self.alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
        self.lane.job("verify", group, self.alerted, _verified(), head="06" + "f" * 38)
        self.assertEqual(self.lane.judge(self.alerted).verify.state, canary.PENDING)

    def test_a_run_that_never_measures_times_out_after_a_day(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        lane = LaneStore(Path(temp.name) / "lab.sqlite3", self.record)
        self.addCleanup(lane.close)
        for batch in range(8):  # two T0 batches after the injected commit, then no build comes
            lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0)
        self.assertEqual(lane.judge(T0 + canary.RUN_LIMIT).state, canary.PENDING)
        verdict = lane.judge(T0 + canary.RUN_LIMIT + timedelta(seconds=1))
        self.assertEqual((verdict.alert.state, verdict.state), (canary.FAIL, canary.FAIL))
        self.assertIn("timed out", verdict.alert.detail)


class LastTests(unittest.TestCase):
    def test_last_judges_the_newest_runs_and_passes_only_when_all_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            older = canary.RunRecord(**{**_record().__dict__, "run_id": "20261019T120000Z-0123456789ab"})
            newer = _record()
            for record in (older, newer):
                record.save(root / record.run_id)
            lane = LaneStore(root / newer.run_id / canary.DB_NAME, newer)
            try:
                for batch in range(13):
                    lane.point(batch, T0 + batch * scheduler.BATCH_INTERVAL, 8.0 if batch < 6 else 10.0)
                alerted = T0 + timedelta(hours=2, minutes=1)
                group = lane.alert(alerted, BASE_POS + 5 * 4 + 4, BASE_POS + 6 * 4 + 3)
                lane.job("bisect", group, alerted + timedelta(hours=1), _bisect(newer.injected))
                lane.job("verify", group, alerted + timedelta(hours=2), _verified(), head=newer.injected)
            finally:
                lane.close()
            now = T0 + timedelta(hours=5)
            out = io.StringIO()
            self.assertEqual(canary.report_last(root, 1, now, as_json=False, out=out), 0)
            self.assertIn("1/1 canary runs passed", out.getvalue())
            out = io.StringIO()
            self.assertEqual(canary.report_last(root, 2, now, as_json=True, out=out), 1)
            document = json.loads(out.getvalue())
            self.assertEqual([r["state"] for r in document["runs"]], [canary.PASS, canary.PENDING])
            self.assertEqual(canary.report_last(root, 3, now, as_json=False, out=io.StringIO()), 1)


class CommandTests(unittest.TestCase):
    def test_lab_lists_the_canary_command(self):
        self.assertIn("canary", lab.discover(LAB))

    def test_run_without_a_submit_command_refuses(self):
        with tempfile.TemporaryDirectory() as temp:
            parser = __import__("argparse").ArgumentParser()
            canary.add_arguments("canary", parser)
            args = parser.parse_args(["--run", "--data-dir", temp])
            self.assertEqual(canary.run("canary", args, out=io.StringIO()), 2)

    def test_last_with_no_runs_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            parser = __import__("argparse").ArgumentParser()
            canary.add_arguments("canary", parser)
            args = parser.parse_args(["--last", "3", "--data-dir", temp])
            out = io.StringIO()
            self.assertEqual(canary.run("canary", args, out=out), 1)
            self.assertIn("0/3 canary runs passed", out.getvalue())


if __name__ == "__main__":
    unittest.main()
