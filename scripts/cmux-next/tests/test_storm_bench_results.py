#!/usr/bin/env python3
"""The CLI and daemon storm benches on perf_stats and result-v1 (p12-perf-process-056).

1. bench_cli_storm.py: summarize keeps its report keys and takes its percentiles from perf_stats.pct; a storm with
   no sample fails "no request completed" instead of crashing; the next profile stops debug.frames with `raw` and
   keeps only the summary in the report; `samples` holds only the answered requests' latency by category, and error
   replies are counted apart; Client still imports under `python3 -I` (input-replay.py and the other importers).
2. cli-storm-session.py: the session comes from --session, else $PERF_LAB_SESSION, else light; the storm's raw samples
   become cli_storm.* series, written by a real BenchApp.record into cli-storm or cli-storm-stress and stored by the
   real perf-lab ingest; the stored storm report drops the raw samples.
3. script-storm-bench.py: distribution() is typing_report.distribution; a valid phase of a Session built by its
   real __init__ records script_storm.<phase>.* at the top of --out, where ingest reads; an invalid phase records
   nothing; --session picks one session.
4. bench_daemon_spawn.py: --app names the daemon and the build, --out needs --app; each round's raw create and read
   latencies and the reap results become daemon_spawn.* series; main() with a stub daemon writes them from
   measured_build into --out, and a bundle with no sha exits before the daemon starts.
5. The four benches leave the bench-migration queue (MQ1, MQ2, MQ3), every written metric fullmatches its story's
   patterns with the story's engine and session, and each story's needs name the debug methods its run calls.

Linux and macOS; no app, no daemon, no GUI session.

    python3 -m unittest scripts/cmux-next/tests/test_storm_bench_results.py
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = ROOT / "scripts/perf-lab"
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_launch as bl  # noqa: E402
from test_bench_launch import FEATURES, HOST, record_bundle, result_lines  # noqa: E402

import bench_cli_storm  # noqa: E402
import bench_frames  # noqa: E402
import storm_bench_results as results  # noqa: E402
import typing_report  # noqa: E402

session_bench = bl.load_by_path("cli_storm_session", str(HERE / "cli-storm-session.py"))
spawn = bl.load_by_path("bench_daemon_spawn", str(HERE / "bench_daemon_spawn.py"))
perf_stats = bl.load_by_path("perf_stats", str(PERF_LAB / "perf_stats.py"))
ingest = bl.load_by_path("perf_lab_ingest", str(PERF_LAB / "ingest.py"))
queues = bl.load_by_path("perf_lab_queues", str(PERF_LAB / "queues.py"))
BENCHES = ("bench_cli_storm.py", "cli-storm-session.py", "script-storm-bench.py", "bench_daemon_spawn.py")
SHA = "d" * 40
VECTOR = [3.1, 4.7, 5.0, 5.2, 6.8, 7.4, 8.0, 9.9, 12.5, 30.2]


def load_script_storm(argv):
    """script-storm-bench.py parses its arguments at import; loaded fresh with `argv`."""
    sys.modules.pop("script_storm_bench", None)
    with mock.patch.object(sys, "argv", ["script-storm-bench.py", *argv]):
        return bl.load_by_path("script_storm_bench", str(HERE / "script-storm-bench.py"))


def story_file(story_id):
    return json.loads((PERF_LAB / "stories.d" / f"{story_id}.json").read_text())


def storm_report(frames_raw=True):
    """A bench_cli_storm.py report as main() writes it (next profile)."""
    return {"bench": "cli-storm", "throughput_rps": 412.5,
            "latency": {"read": {"count": 3}}, "frames": {"p99_ms": 9.1},
            "criteria": {"unanswered": 0, "request_errors": 1, "stalls_over_50ms": 2, "pty_leaked": 0,
                         "footprint_after_vs_baseline": 1.04, "p99_frame_ms": 9.1},
            "samples": {"latency_ms": {"read": [1.0, 2.0, 3.5], "create": [40.0, 51.0], "send": [0.4],
                                       "rename": [2.2, 2.4], "close": [8.0]},
                        "frame_interval_ms": [8.3, 8.4, 16.7] if frames_raw else [],
                        "main_busy_ms": [1.0, 2.0, 6.5] if frames_raw else []}}


class RecordingCase(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="storm-bench-")
        self.out = os.path.join(self.folder, "out")

    def tearDown(self):
        shutil.rmtree(self.folder, ignore_errors=True)

    def bench(self, tag, session="light"):
        bench = bl.BenchApp(record_bundle(self.folder, tag, commit=SHA), out=self.out, teardown=False,
                            host=lambda: dict(HOST), perf_session=session)
        bench.features = FEATURES  # what launch() read
        return bench

    def ingest(self):
        """The out folder through the real perf-lab ingest: {run id: (engine, session, {metric: samples})}."""
        db = ingest.store.Store(Path(self.folder) / "lab.sqlite3")
        db.migrate()
        try:
            report = ingest.ingest_paths(db, [self.out],
                                         commit_positions={SHA: ingest.CommitPosition(1, mainline=True)}.get)
            self.assertEqual([r.line() for r in report.rejected], [])
            runs = db._db.execute("SELECT run_uuid, engine, session FROM runs").fetchall()
            return {row["run_uuid"].split("/", 1)[1]: (row["engine"], row["session"], db.run_metrics(row["run_uuid"]))
                    for row in runs}
        finally:
            db.close()

    def assert_story_contract(self):
        lines = result_lines(self.out)
        self.assertTrue(lines)
        for line in lines:
            story = story_file(line["story"])
            matched = [m for m in story["metrics"] if re.fullmatch(m["name"], line["metric"])]
            self.assertTrue(matched, f"{line['story']} declares no {line['metric']}")
            self.assertEqual((line["unit"], line["better"]), (matched[0]["unit"], matched[0]["better"]), line["metric"])
            self.assertEqual((line["engine"], line["session"]), (story["engine"], story["session"]), line["metric"])
        return lines


class CliStormDriverTests(unittest.TestCase):
    def test_summarize_keeps_its_keys_and_uses_perf_stats(self):
        samples = [("read", "snapshot.get", v / 1000, "ok") for v in VECTOR] + [("close", "tab close", 0.002, "busy")]
        report = bench_cli_storm.summarize(samples)
        self.assertEqual(set(report), {"read", "close", "all"})
        self.assertEqual(set(report["read"]), {"count", "p50_ms", "p95_ms", "p99_ms", "max_ms", "outcomes"})
        self.assertEqual(set(report["all"]), {"count", "p50_ms", "p95_ms", "p99_ms", "max_ms"})
        for key, q in (("p50_ms", 0.5), ("p95_ms", 0.95), ("p99_ms", 0.99)):
            self.assertAlmostEqual(report["read"][key], perf_stats.pct(VECTOR, q), places=9)
        self.assertAlmostEqual(report["read"]["max_ms"], 30.2, places=9)
        self.assertEqual(report["read"]["outcomes"], {"ok": 10})
        self.assertEqual(report["close"]["outcomes"], {"busy": 1})
        self.assertEqual(report["all"]["count"], 11)

    def test_a_storm_with_no_sample_fails_and_does_not_crash(self):
        # Every worker's Client() failed to connect: no request recorded. The old report said max 0 and failed.
        report = bench_cli_storm.summarize([])
        self.assertEqual(report, {"all": {"count": 0, "p50_ms": None, "p95_ms": None, "p99_ms": None, "max_ms": None}})
        self.assertEqual(bench_cli_storm.request_failures(report),
                         ["no request completed (every client failed before its first request)"])
        self.assertEqual(bench_cli_storm.outcome_totals(report), (0, 0))
        self.assertEqual(bench_cli_storm.latency_line(report), "latency: all p50 - p99 - max -")

    def test_a_request_past_the_deadline_fails(self):
        late = (bench_cli_storm.DEADLINE_S + 0.5)
        report = bench_cli_storm.summarize([("read", "m", 0.002, "ok"), ("read", "m", late, "ok")])
        [failure] = bench_cli_storm.request_failures(report)
        self.assertIn("a request waited 2500 ms", failure)
        self.assertEqual(bench_cli_storm.request_failures(bench_cli_storm.summarize([("read", "m", 0.002, "ok")])), [])

    def test_error_replies_and_timeouts_are_counted_never_a_latency(self):
        samples = [("read", "m", 0.010, "ok"), ("read", "m", 0.0001, "busy"), ("read", "m", 0.0002, "daemon_error"),
                   ("create", "m", 5.0, "client_timeout"), ("create", "m", 0.0, "connection:ConnectionResetError"),
                   ("create", "m", 0.040, "ok")]
        self.assertEqual(bench_cli_storm.answered_latencies(samples), {"create": [40.0], "read": [10.0]})
        self.assertEqual(bench_cli_storm.outcome_totals(bench_cli_storm.summarize(samples)), (2, 2))

    def test_the_old_nearest_rank_against_perf_stats_on_the_fixed_vector(self):
        # The commit message's table: the deleted percentile() picked index round((n - 1) * p) (round half to even).
        def old(values, p):
            ordered = sorted(values)
            return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))]
        self.assertEqual([old(VECTOR, q) for q in (0.5, 0.95, 0.99)], [6.8, 30.2, 30.2])
        self.assertEqual([round(perf_stats.pct(VECTOR, q), 3) for q in (0.5, 0.95, 0.99)], [7.1, 22.235, 28.607])

    def test_latencies_keep_request_order_per_category(self):
        samples = [("read", "m", 0.003, "ok"), ("create", "m", 0.040, "ok"), ("read", "m", 0.001, "ok")]
        self.assertEqual(bench_cli_storm.latencies_by_category(samples), {"create": [40.0], "read": [3.0, 1.0]})

    def test_the_next_profile_asks_raw_frames_and_reports_the_summary(self):
        class Control:
            def __init__(self):
                self.calls = []

            def call(self, method, params=None):
                self.calls.append((method, params))
                if method == "debug.frames":
                    return {"ok": True, "result": {"p99_ms": 9.0, "intervals_ms": [8.3, 8.5], "main_ms": [1.5, 2.0],
                                                   "layout_per_frame": [0, 1]}}
                return {"ok": True, "result": {"count": 0}}
        control = Control()
        frames, raw, hangs, queue = bench_cli_storm.NextProfile("/nowhere", "t").end_measure(control)
        self.assertEqual(control.calls[0], ("debug.frames", {"action": "stop", "raw": True}))
        self.assertEqual(frames, {"p99_ms": 9.0})
        self.assertEqual(raw, {"intervals_ms": [8.3, 8.5], "main_ms": [1.5, 2.0]})
        self.assertEqual((hangs, queue), ({"count": 0}, {"count": 0}))
        legacy = bench_cli_storm.LegacyProfile("/nowhere", "t").end_measure(control)
        self.assertEqual(legacy, (None, {"intervals_ms": [], "main_ms": []}, None, None))

    def test_client_imports_under_isolated_mode(self):
        code = ("import sys; sys.path.insert(0, sys.argv[1]); from bench_cli_storm import Client, MAX_PTY_LIMIT, "
                "daemon_socket, ptys_in_use; print(Client.__name__, MAX_PTY_LIMIT)")
        done = subprocess.run([sys.executable, "-I", "-c", code, str(HERE)], cwd="/", capture_output=True, text=True,
                              timeout=60)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "Client 300"), done.stderr)

    def test_input_replay_still_imports(self):
        # input-replay.py's own imports, under -I from /, through test_bench_launch's import-only harness.
        from test_bench_launch import IMPORT_ONLY
        done = subprocess.run([sys.executable, "-I", "-c", IMPORT_ONLY, str(HERE / "input-replay.py")], cwd="/",
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr[-2000:])
        self.assertIsNone(json.loads(done.stdout)["error"])


class CliStormSessionTests(RecordingCase):
    def test_the_session_comes_from_the_flag_then_the_runner_then_light(self):
        argv = ["--app", "/a.app", "--out", self.out]
        self.assertEqual(session_bench.parse(argv, environ={}).session, "light")
        self.assertEqual(session_bench.parse(argv, environ={"PERF_LAB_SESSION": "stress"}).session, "stress")
        self.assertEqual(session_bench.parse(argv + ["--session", "light"],
                                             environ={"PERF_LAB_SESSION": "stress"}).session, "light")
        with redirect_stdout(io.StringIO()), mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
            session_bench.parse(argv, environ={"PERF_LAB_SESSION": "corpus:x"})

    def test_storm_args_pass_through(self):
        opts = session_bench.parse(["--app", "/a.app", "--out", self.out, "--tag", "t", "--", "--requests", "50",
                                    "--clients", "4"], environ={})
        self.assertEqual(opts.storm_args, ["--requests", "50", "--clients", "4"])

    def test_the_stored_storm_report_drops_raw_samples(self):
        path = os.path.join(self.folder, "storm.json")
        with open(path, "w") as f:
            json.dump(storm_report(), f)
        storm, series = session_bench.storm_report(path)
        self.assertNotIn("samples", storm)
        self.assertEqual(storm["throughput_rps"], 412.5)
        self.assertTrue(series)
        missing, none = session_bench.storm_report(os.path.join(self.folder, "missing.json"))
        self.assertIn("error", missing)
        self.assertEqual(none, [])

    def test_series_names_units_and_kept_samples(self):
        series = {s.metric: s for s in results.cli_storm_series(storm_report())}
        self.assertEqual(series["cli_storm.request.read"].samples, [1.0, 2.0, 3.5])
        self.assertEqual(series["cli_storm.frame_interval"].samples, [8.3, 8.4, 16.7])
        self.assertEqual((series["cli_storm.stalls"].unit, series["cli_storm.stalls"].samples), ("count", [2]))
        self.assertEqual((series["cli_storm.request_errors"].unit, series["cli_storm.request_errors"].samples),
                         ("count", [1]))
        self.assertEqual(series["cli_storm.footprint_growth"].unit, "ratio")
        self.assertEqual((series["cli_storm.throughput"].unit, series["cli_storm.throughput"].better), ("per_s", "higher"))

    def test_an_unseen_criterion_is_no_series_never_a_zero(self):
        report = storm_report(frames_raw=False)
        report["criteria"].update({"stalls_over_50ms": None, "footprint_after_vs_baseline": None})
        metrics = {s.metric for s in results.cli_storm_series(report)}
        self.assertFalse(metrics & {"cli_storm.stalls", "cli_storm.footprint_growth", "cli_storm.frame_interval",
                                    "cli_storm.main_busy"})
        self.assertIn("cli_storm.unanswered", metrics)

    def test_light_and_stress_record_into_their_stories_and_ingest(self):
        for session in ("light", "stress"):
            app = self.bench(f"storm-{session}", session)
            story = results.CLI_STORM_STORIES[session]
            written = results.record_all(app, story, results.SESSION_ENGINES[session],
                                         results.cli_storm_series(storm_report()), log=lambda _: None)
            self.assertFalse([v for v in written.values() if v.startswith("not recorded")], written)
        self.assert_story_contract()
        runs = self.ingest()
        self.assertEqual(sorted((engine, session) for engine, session, _ in runs.values()),
                         [("chromium", "stress"), ("none", "light")])
        for _, _, metrics in runs.values():
            self.assertEqual(metrics["cli_storm.request.create"], [40.0, 51.0])

    def test_a_series_with_no_features_is_not_recorded(self):
        app = self.bench("storm-nofeatures")
        app.features = None
        written = results.record_all(app, "cli-storm", "none", results.cli_storm_series(storm_report()),
                                     log=lambda _: None)
        self.assertTrue(all(v.startswith("not recorded") for v in written.values()))
        self.assertFalse(os.path.isdir(self.out) and list(Path(self.out).glob("*.ndjson")))


class ScriptStormTests(RecordingCase):
    def test_distribution_is_perf_stats_with_the_old_keys(self):
        bench = load_script_storm(["--app", "/a.app", "--out", self.out])
        self.assertIs(bench.distribution, typing_report.distribution)
        self.assertIs(bench.split_raw_frames, bench_frames.split_raw_frames)
        self.assertIsNone(bench.distribution([]))
        row = bench.distribution(VECTOR)
        self.assertEqual(set(row), {"n", "p50", "p95", "p99", "max", "mean"})
        self.assertEqual((row["p50"], row["p95"], row["p99"], row["max"]),
                         tuple(round(v, 2) for v in (perf_stats.pct(VECTOR, 0.5), perf_stats.pct(VECTOR, 0.95),
                                                      perf_stats.pct(VECTOR, 0.99), 30.2)))

    def test_session_overrides_sessions_and_unknown_sessions_are_refused(self):
        self.assertEqual(load_script_storm(["--app", "/a.app", "--out", self.out, "--session", "stress"]).opts.sessions,
                         "stress")
        with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
            load_script_storm(["--app", "/a.app", "--out", self.out, "--sessions", "light,heavy"])

    def phase_entry(self, invalid=()):
        return {"invalid": list(invalid), "frame_evidence": {"missed": 3}, "hangs": {"count": 1}}

    def session(self, bench, name):
        """A Session from its real __init__ (its BenchApp, its out folder), given what launch() would read."""
        session = bench.Session(name)
        self.addCleanup(shutil.rmtree, session.app.scratch, True)
        session.app.read_host = lambda: dict(HOST)
        session.app.features = FEATURES
        return session

    def test_a_valid_phase_records_its_series_and_an_invalid_one_nothing(self):
        bench = load_script_storm(["--app", record_bundle(self.folder, "script", commit=SHA), "--out", self.out])
        raw = {"intervals_ms": [8.3, 8.4], "main_ms": [2.0, 3.0]}
        for name in ("light", "stress"):
            session = self.session(bench, name)
            self.assertEqual((session.app.out, session.app.log_path),
                             (os.path.abspath(self.out), os.path.join(os.path.abspath(self.out), f"app-{name}.log")))
            self.assertTrue(os.path.isdir(os.path.join(self.out, name)))  # its storm plans, logs and signposts
            written = session.record("script", self.phase_entry(), [4.5, 5.5, 6.0], raw)
            self.assertEqual(set(written), {f"script_storm.script.{s}" for s in
                                            ("key_to_contents", "frame_interval", "main_busy", "missed_frames", "stalls")})
            self.assertEqual(session.record("idle", self.phase_entry(["storm not applied"]), [4.0], raw), {})
        for name in ("light", "stress"):
            self.assertEqual(list(Path(self.out, name).glob("*.ndjson")), [], name)  # ingest does not look there
        lines = self.assert_story_contract()
        self.assertFalse([line for line in lines if line["metric"].startswith("script_storm.idle.")])
        runs = self.ingest()
        self.assertEqual(sorted((engine, session) for engine, session, _ in runs.values()),
                         [("chromium", "stress"), ("none", "light")])
        for _, _, metrics in runs.values():
            self.assertEqual(metrics["script_storm.script.key_to_contents"], [4.5, 5.5, 6.0])
            self.assertEqual(metrics["script_storm.script.missed_frames"], [3])


class DaemonSpawnTests(RecordingCase):
    def rounds(self):
        return [{"create": {"errors": {}}, "reap": {"all_reaped_seconds": 31.5, "hosts_left": 0},
                 "samples": {"create_ms": [12.0, 14.0, 90.0], "read_ms": [0.5, 0.7]}},
                {"create": {"errors": {"busy": 2}}, "reap": {"all_reaped_seconds": None, "hosts_left": 1},
                 "samples": {"create_ms": [11.0], "read_ms": [0.6]}}]

    def test_app_names_the_daemon_and_out_needs_app(self):
        opts = spawn.parse(["--app", "/x/cmux DEV t.app", "--out", self.out, "--session", "light", "--tag", "t"])
        self.assertEqual(opts.binary, os.path.join(os.path.realpath("/x/cmux DEV t.app"), "Contents/Resources/bin/cmux-tui"))
        self.assertEqual(opts.json, os.path.join(self.out, "daemon-spawn-spawn.json"))
        self.assertEqual(spawn.parse(["--binary", "/b/cmux-tui"]).json, None)
        for argv in (["--binary", "/b/cmux-tui", "--out", self.out], []):
            with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                spawn.parse(argv)

    def test_rounds_become_series_and_write_without_an_app(self):
        series = {s.metric: s for s in results.daemon_spawn_series(self.rounds(), leaked=[4242])}
        self.assertEqual(series["daemon_spawn.create"].samples, [12.0, 14.0, 90.0, 11.0])
        self.assertEqual(series["daemon_spawn.read"].samples, [0.5, 0.7, 0.6])
        self.assertEqual((series["daemon_spawn.all_reaped"].unit, series["daemon_spawn.all_reaped"].samples), ("s", [31.5]))
        self.assertEqual(series["daemon_spawn.create_errors"].samples, [0, 2])
        self.assertEqual(series["daemon_spawn.hosts_left"].samples, [0, 1])
        self.assertEqual(series["daemon_spawn.hosts_leaked"].samples, [1])
        build = results.perf_result.Build(sha=SHA, config="bench", measure_version=bl.PERF_LAB_MEASURE_VERSION)
        results.write_headless(self.out, results.DAEMON_SPAWN_STORY, spawn.SESSION, list(series.values()), build,
                               results.perf_result.Host.from_dict(dict(HOST)), root=str(ROOT))
        lines = self.assert_story_contract()
        self.assertEqual({line["features_hash"] for line in lines}, {None})
        [(engine, session, metrics)] = self.ingest().values()
        self.assertEqual((engine, session, metrics["daemon_spawn.create"]), ("none", "light", [12.0, 14.0, 90.0, 11.0]))

    def test_the_create_report_keeps_its_keys(self):
        report = spawn.latency_report([12.0, 14.0, 6000.0], [0.5, 0.7])
        self.assertEqual(set(report), {"create_ms", "read_ms"})
        self.assertEqual(set(report["create_ms"]), {"p50", "p95", "p99", "max", "over_5s"})
        self.assertEqual(set(report["read_ms"]), {"count", "p50", "p95", "p99", "max"})
        self.assertEqual((report["create_ms"]["p50"], report["create_ms"]["max"], report["create_ms"]["over_5s"]),
                         (14.0, 6000.0, 1))
        self.assertEqual(report["read_ms"]["count"], 2)
        empty = spawn.latency_report([], [])
        self.assertEqual((empty["create_ms"]["max"], empty["read_ms"]["max"], empty["read_ms"]["count"]), (0, 0, 0))

    def run_main(self, argv):
        """spawn.main(argv) with a stub daemon and one round: (exit code, the daemons started, stdout)."""
        started = []

        class StubDaemon:
            def __init__(self, binary, reap_grace):
                self.binary, self.reap_grace, self.socket, self.pid = binary, reap_grace, "/nowhere.sock", 4242

            def start(self):
                started.append(self)

            def hosts(self):
                return set()

            def stop(self):
                pass

        [first, _] = self.rounds()
        created = {"creates": 3, "ok": 3, "errors": first["create"]["errors"], **spawn.latency_report(
            first["samples"]["create_ms"], first["samples"]["read_ms"])}
        version = mock.Mock(run=mock.Mock(return_value=mock.Mock(stdout="cmux-tui 1.0\n")))
        printed = io.StringIO()
        with mock.patch.object(spawn, "Daemon", StubDaemon), mock.patch.object(spawn, "ptys_in_use", return_value=0), \
                mock.patch.object(spawn, "Connection"), mock.patch.object(spawn, "first_pane"), \
                mock.patch.object(spawn, "storm", return_value=(created, ["s1"], first["samples"])), \
                mock.patch.object(spawn, "close_and_reap", return_value=first["reap"]), \
                mock.patch.object(spawn, "subprocess", version), \
                mock.patch.object(bl, "read_host", return_value=dict(HOST)), \
                redirect_stdout(printed), self.assertRaises(SystemExit) as exit:
            spawn.main(argv)
        return exit.exception.code, started, printed.getvalue()

    def test_main_writes_the_rounds_from_the_measured_build(self):
        bundle = record_bundle(self.folder, "spawn", commit=SHA)
        code, started, _ = self.run_main(["--app", bundle, "--out", self.out])
        self.assertEqual((code, len(started)), (0, 1))
        report = json.loads(Path(self.out, "daemon-spawn-spawn.json").read_text())
        self.assertEqual(set(report["rounds"][0]["create"]["create_ms"]), {"p50", "p95", "p99", "max", "over_5s"})
        self.assertEqual(Path(report["results"]["path"]).parent, Path(self.out).resolve())
        lines = self.assert_story_contract()
        self.assertEqual({(line["build"]["sha"], line["build"]["config"]) for line in lines},
                         {(SHA, bl.build_config(bundle, bl.main_binary(bundle)))})
        [(engine, session, metrics)] = self.ingest().values()
        self.assertEqual((engine, session, metrics["daemon_spawn.create"]), ("none", "light", [12.0, 14.0, 90.0]))
        self.assertEqual(sorted(metrics), sorted(report["results"]["metrics"]))

    def test_a_bundle_with_no_sha_exits_before_the_daemon_starts(self):
        bundle = record_bundle(self.folder, "nosha")
        environ = {k: v for k, v in os.environ.items() if k != "CMUX_CI_SHA"}
        with mock.patch.dict(os.environ, environ, clear=True):
            code, started, _ = self.run_main(["--app", bundle, "--out", self.out])
        self.assertIn("no result-v1 can name this run", str(code))
        self.assertEqual(started, [])
        self.assertFalse(os.path.isdir(self.out) and list(Path(self.out).iterdir()))


class QueueAndStoryTests(unittest.TestCase):
    def test_the_benches_leave_the_bench_migration_queue(self):
        names = {f"scripts/cmux-next/{name}" for name in BENCHES + ("storm_bench_results.py", "bench_frames.py")}
        for query in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
            self.assertEqual(sorted(names & {item.key for item in query(str(ROOT))}), [], query.__name__)

    def test_no_bench_defines_a_private_percentile(self):
        for name in BENCHES:
            text = (HERE / name).read_text()
            self.assertNotRegex(text, r"def (pct|percentile|percentiles|quantile|median)\(", name)

    # Debug methods each story's run calls, from the command files' string literals. Stress builds go through
    # perf-stress-session.Stress.build (size_window -> place_window: debug.window_frame; shown_window: debug.layers;
    # summary: debug.cef); script-storm-bench.py --hidden N (its own debug methods) is not part of a story.
    STRESS_BUILD = {"debug.window_frame", "debug.layers", "debug.cef"}
    NOT_IN_A_STORY = {"script-storm-bench.py": {"debug.drain_cost", "debug.main_budget", "debug.layout_counters",
                                                "debug.observations"}}
    COMMAND_FILES = {"cli-storm-session.py": ("cli-storm-session.py", "bench_cli_storm.py"),
                     "script-storm-bench.py": ("script-storm-bench.py",), "bench_daemon_spawn.py": ("bench_daemon_spawn.py",)}

    def literal_methods(self, files):
        found = set()
        for name in files:
            found |= set(re.findall(r'"(debug\.[a-z_]+)"', (HERE / name).read_text()))
        return found

    def test_needs_name_every_debug_method_the_run_calls(self):
        for story_id in ("cli-storm", "cli-storm-stress", "script-storm", "script-storm-stress", "daemon-spawn"):
            story = story_file(story_id)
            command = os.path.basename(story["command"][0])
            reached = self.literal_methods(self.COMMAND_FILES[command]) - self.NOT_IN_A_STORY.get(command, set())
            if story["session"] == "stress":
                reached |= self.STRESS_BUILD
            needed = {n.removeprefix("debug:") for n in story["needs"] if n.startswith("debug:")}
            self.assertEqual(needed, reached, story_id)

    def test_each_story_names_one_session_and_its_engine(self):
        for sessions, prefix in ((results.CLI_STORM_STORIES, "cli"), (results.SCRIPT_STORM_STORIES, "script")):
            for session, story_id in sessions.items():
                story = story_file(story_id)
                self.assertEqual((story["session"], story["engine"]), (session, results.SESSION_ENGINES[session]),
                                 story_id)
                self.assertIn(session, story["command"], story_id)
                self.assertTrue(story_id.startswith(prefix))
        self.assertEqual(story_file(results.DAEMON_SPAWN_STORY)["session"], spawn.SESSION)


if __name__ == "__main__":
    unittest.main()
