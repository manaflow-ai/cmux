#!/usr/bin/env python3
"""ingest.py and lab.py: result-v1 ingest, the perf-cron history import and the command dispatcher.

  python3 -m unittest scripts/perf-lab/tests/test_ingest.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

PERF_LAB = Path(__file__).resolve().parent.parent
LAB_PY = PERF_LAB / "lab.py"


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ingest = load("perf_lab_ingest", PERF_LAB / "ingest.py")
lab = load("perf_lab_lab", LAB_PY)
alerts = load("perf_lab_alerts", PERF_LAB / "alerts.py")
sheriff = load("perf_lab_sheriff", PERF_LAB / "sheriff.py")
pr = ingest.perf_result
store = ingest.store

SHA_A = "a" * 40
SHA_B = "b" * 40
SHA_C = "c" * 40
SHA_SIDE = "5" * 40  # a commit of a side branch: its first-parent count is no mainline position
POSITIONS = {SHA_A: ingest.CommitPosition(100, mainline=True), SHA_B: ingest.CommitPosition(101, mainline=True),
             SHA_C: ingest.CommitPosition(102, mainline=True), SHA_SIDE: ingest.CommitPosition(101, mainline=False)}
CHIP = "Apple M4 Pro"
HOST = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=120), chip=CHIP,
               macos="26.1", macos_build="25B78", display_hz=120)
STORY = "terminal.key-frame.light"


def result(*, metric="key_to_frame_ms", samples=(4.0, 5.0, 6.0), sha=SHA_A, config="bench", run_id="run1",
           started="2026-10-25T12:00:00.123456Z", host=HOST, story=STORY, features_hash="fh1"):
    return pr.Result(story=story, metric=metric, unit="ms", better="lower", samples=list(samples),
                     build=pr.Build(sha=sha, config=config, measure_version=1), host=host, engine="webkit",
                     session="light", run=pr.Run(id=run_id, started_at=started),
                     features={"perfPath.x": pr.Feature(state="on", source="default")}, features_hash=features_hash,
                     safe_mode="inactive")


def row_counts(path: Path) -> dict[str, int]:
    with sqlite3.connect(path) as db:
        tables = [row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
        return {table: db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] for table in tables}


def cron_state() -> dict:
    """The shape of a real perf-cron-state artifact (run 40237177179, 2026-10-25): the oldest history entry of each
    row has no sha (written from last_good before entries carried one), one Mac row is stored without its host."""
    diff = "diff.stream.p95@blacksmith-32vcpu-ubuntu-2404"
    mac = "panes.1x2.split.frame"
    return {
        "schema": 1,
        "history": [{"sha": SHA_A, "kind": "tip", "at": "2026-10-23T14:54:03Z", "status": "first"},
                    {"sha": SHA_B, "kind": "tip", "at": "2026-10-24T20:32:51Z", "status": "ok"}],
        "last_good": {"sha": SHA_B, "measured_at": "2026-10-24T20:32:51Z",
                      "rows": {diff: {"p50": 22.11, "p95": 22.11, "unit": "ms"},
                               f"{mac}@cmux20-bench": {"p50": 7.0, "p95": 8.3, "unit": "ms"}}},
        "row_history": {
            diff: [{"at": "2026-10-23T14:54:03Z", "p95": 21.0},
                   {"at": "2026-10-24T20:32:51Z", "p95": 22.11, "sha": SHA_B}],
            mac: [{"at": "2026-10-24T20:32:51Z", "p95": 8.3, "sha": SHA_B}],
        },
    }


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.db_path = self.root / "lab.sqlite3"
        self.db = store.Store(self.db_path)
        self.db.migrate()
        self.results = self.root / "results"

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def ingest(self, *paths, **kwargs):
        return ingest.ingest_paths(self.db, list(paths) or [self.results], commit_positions=POSITIONS.get, **kwargs)

    def key(self, *, config="bench", metric="key_to_frame_ms", host_class=None, story=STORY, engine="webkit",
            macos_major=26):
        return store.series_key(story=story, metric=metric, engine=engine, host_class=host_class or HOST.host_class,
                                macos_major=macos_major, build_config=config)


class IngestTests(StoreCase):
    def test_malformed_file_is_rejected_with_path_and_reason_and_the_rest_is_stored(self):
        good = pr.write_ndjson(self.results, [result()])
        other = pr.write_ndjson(self.results, [result(metric="frames_dropped", samples=[0, 1])])
        bad = self.results / "result-bad.ndjson"
        broken = result(run_id="run9").to_dict()
        broken["samples"] = []
        bad.write_text(json.dumps(result(run_id="run9").to_dict()) + "\n" + json.dumps(broken) + "\n")
        report = self.ingest()
        self.assertEqual([(r.source, r.reason) for r in report.rejected],
                         [(str(bad), "line 2: samples: empty; a result needs at least one raw sample")])
        self.assertEqual((report.added_runs, report.added_results), (1, 2))
        self.assertEqual(self.db.run_metrics("run1/" + STORY),
                         {"key_to_frame_ms": [4.0, 5.0, 6.0], "frames_dropped": [0, 1]})
        self.assertEqual(self.db.run_metrics("run9/" + STORY), {})
        self.assertTrue(good.exists() and other.exists())

    def test_run_with_a_rejected_file_is_stored_whole_after_the_fix_never_in_part(self):
        pr.write_ndjson(self.results, [result()])
        bad = self.results / "result-bad.ndjson"
        broken = result(metric="frames_dropped", samples=[0, 1]).to_dict()
        broken["unit"] = "furlongs"
        bad.write_text(json.dumps(broken) + "\n")
        first = self.ingest()
        self.assertEqual(first.added_runs, 0)
        self.assertEqual([r.source for r in first.rejected][0], str(bad))
        self.assertIn(f"{bad} holds results of this run and was rejected", first.rejected[1].reason)
        self.assertEqual(self.db.run_metrics("run1/" + STORY), {})
        bad.unlink()
        pr.write_ndjson(self.results, [result(metric="frames_dropped", samples=[0, 1])])
        second = self.ingest()
        self.assertEqual((second.rejected, second.added_runs, second.added_results), ([], 1, 2))
        self.assertEqual(self.db.run_metrics("run1/" + STORY),
                         {"key_to_frame_ms": [4.0, 5.0, 6.0], "frames_dropped": [0, 1]})

    def test_file_that_names_no_run_holds_back_its_folder_only(self):
        pr.write_ndjson(self.results, [result()])
        (self.results / "result-junk.ndjson").write_text('{"run": {"id": "run1", "start\n')
        elsewhere = self.root / "elsewhere"
        pr.write_ndjson(elsewhere, [result(run_id="run2", started="2026-10-25T13:00:00Z")])
        report = self.ingest(self.results, elsewhere)
        self.assertEqual(report.added_runs, 1)
        self.assertEqual(self.db.run_metrics("run1/" + STORY), {})
        self.assertIn("in the same folder was rejected", report.rejected[1].reason)
        self.assertEqual(self.db.run_metrics("run2/" + STORY), {"key_to_frame_ms": [4.0, 5.0, 6.0]})

    def test_started_at_on_no_calendar_rejects_that_run_and_stores_the_rest(self):
        pr.write_ndjson(self.results, [result()])
        pr.write_ndjson(self.results, [result(run_id="leap", started="2026-12-31T23:59:60Z")])
        pr.write_ndjson(self.results, [result(run_id="feb30", started="2026-02-30T12:00:00Z")])
        report = self.ingest()
        self.assertEqual(report.added_runs, 1)
        reasons = sorted(r.reason for r in report.rejected)
        self.assertEqual(len(reasons), 2)
        self.assertTrue(reasons[0].startswith("run.started_at '2026-02-30T12:00:00Z' is not a valid time: "), reasons)
        self.assertTrue(reasons[1].startswith("run.started_at '2026-12-31T23:59:60Z' is not a valid time: "), reasons)
        self.assertEqual(self.db.run_metrics("run1/" + STORY), {"key_to_frame_ms": [4.0, 5.0, 6.0]})

    def test_side_branch_commit_is_no_waterfall_point_but_a_try_run(self):
        pr.write_ndjson(self.results, [result(sha=SHA_SIDE)])
        report = self.ingest()
        self.assertEqual(report.added_runs, 0)
        self.assertIn("is not on the mainline's first-parent chain", report.rejected[0].reason)
        self.assertEqual(self.ingest(kind="try").added_runs, 1)
        self.assertEqual(self.db.series_points(self.key()), [])

    def test_one_point_per_run_with_summary_from_perf_stats(self):
        pr.write_ndjson(self.results, [result(samples=[1, 2, 3, 4, 100])])
        self.ingest()
        [point] = self.db.series_points(self.key())
        self.assertEqual(point.summary, ingest.perf_stats.summary([1, 2, 3, 4, 100]))
        self.assertEqual((point.sha, point.commit_pos, point.features_hash, point.macos_build, point.safe_mode),
                         (SHA_A, 100, "fh1", "25B78", "inactive"))
        self.assertEqual(alerts.judged_points([point]), [point])

    def test_debug_result_never_lands_in_a_bench_series(self):
        pr.write_ndjson(self.results, [result(sha=SHA_A, run_id="bench1")])
        pr.write_ndjson(self.results, [result(sha=SHA_B, config="debug", run_id="debug1",
                                              started="2026-10-25T12:05:00Z", samples=[40.0])])
        pr.write_ndjson(self.results, [result(sha=SHA_C, run_id="bench2", started="2026-10-25T12:10:00Z")])
        report = self.ingest()
        self.assertEqual(report.rejected, [])
        bench = self.db.series_points(self.key(config="bench"))
        debug = self.db.series_points(self.key(config="debug"))
        self.assertNotEqual(self.key(config="bench"), self.key(config="debug"))
        self.assertEqual([p.run_uuid for p in bench], ["bench1/" + STORY, "bench2/" + STORY])
        self.assertEqual([p.run_uuid for p in debug], ["debug1/" + STORY])
        self.assertTrue(all(40.0 not in p.samples for p in bench))

    def test_double_ingest_adds_zero_rows(self):
        pr.write_ndjson(self.results, [result(), result(metric="frames_dropped", samples=[0])])
        pr.write_ndjson(self.results, [result(run_id="run2", sha=SHA_B, started="2026-10-25T13:00:00Z")])
        first = self.ingest()
        before = row_counts(self.db_path)
        second = self.ingest()
        self.assertEqual((first.added_runs, first.added_results), (2, 3))
        self.assertEqual((second.added_runs, second.added_results, second.unchanged_runs), (0, 0, 2))
        self.assertEqual(row_counts(self.db_path), before)

    def test_changed_replay_of_a_stored_run_is_rejected(self):
        pr.write_ndjson(self.results, [result()])
        self.ingest()
        other = self.root / "replay"
        pr.write_ndjson(other, [result(samples=[9.0])])
        report = self.ingest(other)
        self.assertEqual(len(report.rejected), 1)
        self.assertIn("already stored with other content", report.rejected[0].reason)
        self.assertEqual(self.db.run_metrics("run1/" + STORY), {"key_to_frame_ms": [4.0, 5.0, 6.0]})

    def test_results_of_one_run_that_disagree_are_rejected_together(self):
        pr.write_ndjson(self.results, [result()])
        pr.write_ndjson(self.results, [result(metric="frames_dropped", sha=SHA_B)])
        pr.write_ndjson(self.results, [result(run_id="run2", started="2026-10-25T13:00:00Z")])
        report = self.ingest()
        self.assertEqual(len(report.rejected), 1)
        self.assertIn("run run1/" + STORY, report.rejected[0].source)
        self.assertIn("disagrees with the run's other results on build", report.rejected[0].reason)
        self.assertEqual(report.added_runs, 1)
        self.assertEqual(self.db.run_metrics("run1/" + STORY), {})

    def test_one_run_with_two_stories_is_two_store_runs(self):
        pr.write_ndjson(self.results, [result(), result(story="home.key-frame")])
        report = self.ingest()
        self.assertEqual(report.added_runs, 2)
        self.assertEqual(len(self.db.series_points(self.key(story="home.key-frame"))), 1)

    def test_metric_recorded_twice_in_one_run_is_rejected(self):
        pr.write_ndjson(self.results, [result()])
        pr.write_ndjson(self.results, [result(samples=[7.0])])
        report = self.ingest()
        self.assertEqual(report.added_runs, 0)
        self.assertIn("recorded twice", report.rejected[0].reason)

    def test_unknown_commit_is_rejected_and_other_runs_are_stored(self):
        pr.write_ndjson(self.results, [result(sha="d" * 40)])
        pr.write_ndjson(self.results, [result(run_id="run2", started="2026-10-25T13:00:00Z")])
        report = self.ingest()
        self.assertEqual(report.added_runs, 1)
        self.assertIn(f"commit {'d' * 40} is not in the lab's checkout", report.rejected[0].reason)

    def test_host_class_that_does_not_match_chip_and_hz_is_rejected(self):
        wrong = pr.Host(fingerprint="f" * 64, host_class=store.host_class(chip=CHIP, memory_gb=24, display_hz=60),
                        chip=CHIP, macos="26.1", macos_build="25B78", display_hz=120)
        pr.write_ndjson(self.results, [result(host=wrong)])
        report = self.ingest()
        self.assertEqual(report.added_runs, 0)
        self.assertIn("does not match chip", report.rejected[0].reason)

    def test_features_hash_change_is_a_point_inside_the_same_series(self):
        pr.write_ndjson(self.results, [result(run_id="r1", sha=SHA_A, features_hash="fh1")])
        pr.write_ndjson(self.results, [result(run_id="r2", sha=SHA_B, features_hash="fh2",
                                              started="2026-10-25T13:00:00Z")])
        self.ingest()
        self.assertEqual([p.features_hash for p in self.db.series_points(self.key())], ["fh1", "fh2"])

    def test_linux_runner_class_is_its_own_series_host_class(self):
        linux = pr.Host(fingerprint="e" * 64, host_class="blacksmith-32vcpu-ubuntu-2404", chip="x86_64", macos=None,
                        macos_build=None, display_hz=None)
        pr.write_ndjson(self.results, [result(host=linux, story="diff.viewer")])
        report = self.ingest(host_name="blacksmith")
        self.assertEqual(report.rejected, [])
        key = self.key(story="diff.viewer", host_class="blacksmith-32vcpu-ubuntu-2404", macos_major=0)
        self.assertEqual(len(self.db.series_points(key)), 1)

    def test_bisect_runs_are_stored_but_are_not_waterfall_points(self):
        pr.write_ndjson(self.results, [result()])
        report = self.ingest(kind="bisect")
        self.assertEqual(report.added_runs, 1)
        self.assertEqual(self.db.series_points(self.key()), [])

    def test_runs_link_to_the_lab_job_that_produced_them(self):
        job_id = self.db._db.execute(
            "INSERT INTO jobs (kind, state, created_at, updated_at) VALUES ('bisect', 'running', 'now', 'now')").lastrowid
        pr.write_ndjson(self.results, [result(run_id="run1"), result(run_id="run2", started="2026-10-25T12:00:01Z")])
        report = self.ingest(kind="bisect", job_id=job_id)
        self.assertEqual(report.added_runs, 2)
        linked = self.db._db.execute("SELECT kind, job_id FROM runs ORDER BY id").fetchall()
        self.assertEqual([tuple(row) for row in linked], [("bisect", job_id), ("bisect", job_id)])
        self.assertEqual(self.ingest(kind="bisect", job_id=job_id).unchanged_runs, 2)  # a replay adds nothing

    def test_missing_path_is_rejected(self):
        report = self.ingest(self.root / "nope")
        self.assertEqual(report.rejected[0].reason, "no such file or folder")


class PerfCronImportTests(StoreCase):
    def legacy_key(self, row, host):
        cron = ingest._cron_module()
        return store.series_key(story=ingest.LEGACY_STORY_PREFIX + cron.part_for_row(row), metric=row, engine="none",
                                host_class=ingest.LEGACY_HOST_PREFIX + host, macos_major=0,
                                build_config=ingest.LEGACY_CONFIG)

    def test_history_becomes_legacy_points_that_are_never_judged(self):
        report = ingest.import_perf_cron(self.db, cron_state(), commit_positions=POSITIONS.get)
        self.assertEqual(report.rejected, [])
        self.assertEqual(report.added_runs, 3)
        points = self.db.series_points(self.legacy_key("diff.stream.p95", "blacksmith-32vcpu-ubuntu-2404"))
        self.assertEqual([(p.sha, p.samples, p.summary["p95"]) for p in points],
                         [(SHA_A, [], 21.0), (SHA_B, [], 22.11)])
        for point in points:
            self.assertTrue(point.summary["legacy_p95_only"] and point.summary["legacy_stat"])
            self.assertTrue(point.measure_version.startswith("legacy"))
        # The detector's and the sheriff's own rules, each by one of its checks: no raw samples, legacy version, flags.
        self.assertEqual(alerts.judged_points(points), [])
        self.assertEqual(sheriff.judged_batches(points, after_pos=0), [])
        with_samples = [ingest.store.Point(**{**p.__dict__, "samples": [p.summary["p95"]]}) for p in points]
        self.assertEqual(alerts.judged_points(with_samples), [])
        unflagged = [ingest.store.Point(**{**p.__dict__, "summary": {"p95": p.summary["p95"]}}) for p in with_samples]
        self.assertEqual(alerts.judged_points(unflagged), [])

    def test_row_stored_before_host_keys_gets_the_cron_bench_host(self):
        ingest.import_perf_cron(self.db, cron_state(), commit_positions=POSITIONS.get)
        [point] = self.db.series_points(self.legacy_key("panes.1x2.split.frame", "cmux20-bench"))
        self.assertEqual((point.sha, point.samples, point.summary["p95"], point.host_name),
                         (SHA_B, [], 8.3, "cmux20-bench"))

    def test_legacy_series_are_never_lab_bench_series(self):
        ingest.import_perf_cron(self.db, cron_state(), commit_positions=POSITIONS.get)
        with sqlite3.connect(self.db_path) as db:
            rows = db.execute("SELECT build_config, host_class, story FROM series").fetchall()
        self.assertTrue(rows)
        for config, host_class, story in rows:
            self.assertEqual(config, "debug")
            self.assertTrue(host_class.startswith(ingest.LEGACY_HOST_PREFIX))
            self.assertTrue(story.startswith(ingest.LEGACY_STORY_PREFIX))

    def test_double_import_adds_zero_rows_also_from_a_newer_artifact(self):
        ingest.import_perf_cron(self.db, cron_state(), commit_positions=POSITIONS.get)
        before = row_counts(self.db_path)
        again = ingest.import_perf_cron(self.db, cron_state(), commit_positions=POSITIONS.get)
        self.assertEqual((again.added_runs, again.unchanged_runs), (0, 3))
        self.assertEqual(row_counts(self.db_path), before)
        newer = cron_state()
        newer["row_history"]["diff.stream.p95@blacksmith-32vcpu-ubuntu-2404"].append(
            {"at": "2026-10-25T10:29:56Z", "p95": 20.5, "sha": SHA_C})
        later = ingest.import_perf_cron(self.db, newer, commit_positions=POSITIONS.get)
        self.assertEqual((later.added_runs, later.unchanged_runs), (1, 3))

    def test_bad_entries_are_rejected_one_by_one(self):
        state = cron_state()
        state["row_history"]["diff.stream.p95@blacksmith-32vcpu-ubuntu-2404"] += [
            {"at": "2026-10-25T00:00:00Z", "p95": 1.0},  # no sha and no history entry at that time
            {"at": "yesterday", "p95": 1.0, "sha": SHA_C},
            {"at": "2026-10-25T00:00:00Z", "p95": "fast", "sha": SHA_C},
        ]
        state["row_history"]["mystery.row@cmux20-bench"] = [{"at": "2026-10-24T20:32:51Z", "p95": 1.0, "sha": SHA_B}]
        report = ingest.import_perf_cron(self.db, state, commit_positions=POSITIONS.get)
        self.assertEqual(report.added_runs, 3)
        reasons = sorted(r.reason for r in report.rejected)
        self.assertEqual(len(reasons), 4)
        self.assertIn("no commit is known for the measurement at 2026-10-25T00:00:00Z", reasons)
        self.assertIn("no perf-cron part measures this row", reasons)

    def test_not_a_state_is_rejected(self):
        report = ingest.import_perf_cron(self.db, {"schema": 1}, commit_positions=POSITIONS.get)
        self.assertEqual(report.rejected[0].reason, "not a perf-cron state: no row_history object")
        report = ingest.import_perf_cron(self.db, {**cron_state(), "schema": 99}, commit_positions=POSITIONS.get)
        self.assertIn("state schema 99", report.rejected[0].reason)


class GitCommitPositionsTests(unittest.TestCase):
    def test_mainline_position_side_branch_commit_and_unknown_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]

            def sha(ref):
                done = subprocess.run([*git, "rev-parse", ref], check=True, capture_output=True, text=True)
                return done.stdout.strip()

            subprocess.run([*git, "init", "-q", "-b", "trunk"], check=True)
            subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "one"], check=True)
            subprocess.run([*git, "checkout", "-q", "-b", "side"], check=True)
            subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "side one"], check=True)
            subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "side two"], check=True)
            subprocess.run([*git, "checkout", "-q", "trunk"], check=True)
            subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "two"], check=True)
            subprocess.run([*git, "merge", "-q", "--no-ff", "-m", "merge side", "side"], check=True)
            positions = ingest.GitCommitPositions(repo, mainline="trunk")
            self.assertEqual(positions(sha("trunk")), ingest.CommitPosition(3, mainline=True))
            self.assertEqual(positions(sha("trunk~1")), ingest.CommitPosition(2, mainline=True))
            # side two is an ancestor of trunk through the merge's second parent; its count 3 collides with the merge.
            self.assertEqual(positions(sha("side")), ingest.CommitPosition(3, mainline=False))
            self.assertIsNone(positions("0" * 40))
            with self.assertRaises(ingest.IngestError):
                ingest.GitCommitPositions(repo, mainline="no-such-branch")

    def test_not_a_checkout_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ingest.IngestError):
                ingest.GitCommitPositions(Path(tmp) / "none")


class LabDispatcherTests(unittest.TestCase):
    def test_ingest_commands_are_discovered_without_importing_their_modules(self):
        commands = lab.discover()
        self.assertEqual(commands["ingest"][0].name, "ingest.py")
        self.assertEqual(commands["import-perf-cron"][0].name, "ingest.py")

    def test_new_command_module_is_a_new_file_not_an_edit(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "hello.py").write_text(textwrap.dedent("""
                LAB_COMMANDS = {"hello": "say hello"}
                def add_arguments(command, parser):
                    parser.add_argument("name")
                def run(command, args):
                    print(f"{command} {args.name}")
                    return 3
            """))
            Path(tmp, "not_a_command.py").write_text("raise SystemExit('never imported')\n")
            done = subprocess.run([sys.executable, "-I", "-c",
                                   "import importlib.util, sys; s = importlib.util.spec_from_file_location('lab', sys.argv[1]);"
                                   "m = importlib.util.module_from_spec(s); s.loader.exec_module(m);"
                                   "from pathlib import Path; sys.exit(m.main(['hello', 'cmux'], directory=Path(sys.argv[2])))",
                                   str(LAB_PY), tmp], capture_output=True, text=True)
            self.assertEqual((done.returncode, done.stdout), (3, "hello cmux\n"), done.stderr)

    def test_duplicate_command_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("a.py", "b.py"):
                Path(tmp, name).write_text('LAB_COMMANDS = {"same": "x"}\n')
            with self.assertRaises(lab.LabError):
                lab.discover(Path(tmp))

    def test_cli_ingest_and_import_end_to_end_under_isolated_python(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git = ["git", "-C", tmp, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
            subprocess.run([*git, "init", "-q"], check=True)
            subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "one"], check=True)
            head = subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
            results = root / "results"
            pr.write_ndjson(results, [result(sha=head)])
            (results / "result-junk.ndjson").write_text('{"run": {"id": "junk"}}\n')  # names another run
            db = root / "lab.sqlite3"
            env = {**os.environ, ingest.DB_ENV: str(db)}

            def lab_cli(*args):
                return subprocess.run([sys.executable, "-I", str(LAB_PY), *args, "--repo", tmp, "--mainline", "HEAD",
                                       "--json"], capture_output=True, text=True, env=env)

            first = lab_cli("ingest", str(results))
            self.assertEqual(first.returncode, 1, first.stderr)
            report = json.loads(first.stdout)
            self.assertEqual((report["added_runs"], report["added_results"]), (1, 1))
            self.assertEqual([r["source"] for r in report["rejected"]], [str(results / "result-junk.ndjson")])
            self.assertTrue(report["rejected"][0]["reason"].startswith("line 1: "))
            before = row_counts(db)
            second = lab_cli("ingest", str(results / Path(next(results.glob("result-[0-9a-f]*.ndjson")).name)))
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(json.loads(second.stdout)["unchanged_runs"], 1)
            self.assertEqual(row_counts(db), before)

            state = cron_state()
            for history in state["row_history"].values():
                for entry in history:
                    entry.pop("sha", None)
            state["history"] = [{"sha": head, "kind": "tip", "at": at, "status": "ok"}
                                for at in ("2026-10-23T14:54:03Z", "2026-10-24T20:32:51Z")]
            state["last_good"]["sha"] = head
            state_path = root / "state.json"
            state_path.write_text(json.dumps(state))
            imported = lab_cli("import-perf-cron", str(state_path))
            self.assertEqual(imported.returncode, 0, imported.stderr)
            self.assertEqual(json.loads(imported.stdout)["added_runs"], 3)
            again = lab_cli("import-perf-cron", str(state_path))
            self.assertEqual(json.loads(again.stdout)["added_runs"], 0)

    def test_cli_without_a_store_exits_2(self):
        env = {k: v for k, v in os.environ.items() if k != ingest.DB_ENV}
        done = subprocess.run([sys.executable, "-I", str(LAB_PY), "ingest", "x"], capture_output=True, text=True,
                              env=env)
        self.assertEqual(done.returncode, 2)
        self.assertIn(ingest.DB_ENV, done.stderr)


if __name__ == "__main__":
    unittest.main()
