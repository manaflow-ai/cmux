#!/usr/bin/env python3
"""mvp_tick.py: the split-spring report -> result-v1 conversion and the tick loop, with a fake fleet and repo.

  python3 -m unittest scripts/perf-lab/tests/test_mvp_tick.py
"""
from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


mvp = _load("mvp_tick", LAB / "mvp_tick.py")
perf_result = sys.modules["perf_result"]
bench_launch = mvp._bench_launch()

CHIP = "Apple M4"
MEMORY = 16 * 2**30
FACTS = {"cmux20-bench": {"chip": CHIP, "memory_bytes": MEMORY, "macos": "27.0", "macos_build": "27A123"}}
SHA_A, SHA_B, SHA_C = ("a" * 40, "b" * 40, "c" * 40)
SCRIPT_TEXT = "set -euo pipefail\nSPLIT_SPRING_MEASURE_VERSION=4  # 4: STRESS sessions\n"
NOW = datetime(2026, 10, 26, 3, 0, tzinfo=timezone.utc)


def _round(direction: str, index: int, refresh: float = 8.33) -> dict:
    return {"label": f"{direction} #{index}", "direction": direction, "errors": [], "missed": index,
            "frames_max_ms": 20.0 + index, "frames_p99_ms": 12.0 + index, "frames_p50_ms": 8.3,
            "frames_p95_ms": 9.0 + index, "frames": 140, "moving_frames": 40, "refresh_ms": refresh,
            "layout_max_ms": 3.0, "layout_p95_ms": 2.0, "layout_p50_ms": 1.0, "grid_reports": 6,
            "resizes_sent": 6, "hangs": 0}


def report(macos: str = "27.0", refresh: float | None = 8.33) -> dict:
    return {"tag": "split-spring", "stream": False, "scrollback": 20000, "presses": 5, "interval_ms": 100,
            "runs": [_round(d, i) for d in ("right", "down") for i in range(3)],
            "display": {"requested_hz": 120.0, "vdisplay": refresh is not None, "refresh_ms": refresh,
                        "line": "ready 25 8.33 main=25"},
            "macos": macos}


def job(job_id: str = "0123456789abcdef01234567", sha: str = SHA_A, state: str = "done",
        worker: str = "cmux20-bench") -> dict:
    return {"id": job_id, "kind": "ci-step", "ref": sha, "state": state, "worker": worker,
            "started_at": "2026-10-26T03:01:02.5Z", "created_at": "2026-10-26T03:00:00Z", "exit_code": 0,
            "script": "scripts/measure/split-spring.sh", "args": ["--config=bench", "--vdisplay=120"]}


class ConvertTests(unittest.TestCase):
    def test_one_story_per_direction_and_one_sample_per_round(self):
        results = mvp.convert(report(), job=job(), worker="cmux20-bench", facts=FACTS, measure_version=4)
        stories = sorted({r.story for r in results})
        self.assertEqual(stories, ["split-spring.down", "split-spring.right"])
        self.assertEqual(len(results), 2 * len(mvp.METRICS))
        missed = next(r for r in results if r.story == "split-spring.right" and r.metric == "missed")
        self.assertEqual(missed.samples, [0, 1, 2])
        self.assertEqual((missed.unit, missed.better, missed.engine, missed.session),
                         ("count", "lower", "none", "light"))
        p99 = next(r for r in results if r.story == "split-spring.down" and r.metric == "frames_p99_ms")
        self.assertEqual(p99.samples, [12.0, 13.0, 14.0])

    def test_build_run_and_host_are_the_lab_contract(self):
        result = mvp.convert(report(), job=job(), worker="cmux20-bench", facts=FACTS, measure_version=4)[0]
        self.assertEqual(result.build.to_dict(), {"sha": SHA_A, "config": "bench", "measure_version": 4})
        self.assertEqual(result.run.to_dict(),
                         {"id": "0123456789abcdef01234567", "started_at": "2026-10-26T03:01:02.5Z"})
        expected = bench_launch.host_record(CHIP, MEMORY, "27.0", "27A123", 120)
        self.assertEqual(result.host.to_dict(), expected)
        self.assertEqual(result.host.host_class, "apple-m4/16gb/120hz")
        result.validate()

    def test_a_60hz_fallback_is_another_host_class(self):
        fallback = report(refresh=16.6)
        for entry in fallback["runs"]:
            entry["refresh_ms"] = 16.7
        result = mvp.convert(fallback, job=job(), worker="cmux20-bench", facts=FACTS, measure_version=4)[0]
        self.assertEqual(result.host.host_class, "apple-m4/16gb/60hz")
        self.assertNotEqual(result.host.fingerprint,
                            mvp.convert(report(), job=job(), worker="cmux20-bench", facts=FACTS,
                                        measure_version=4)[0].host.fingerprint)

    def test_refuses_what_it_cannot_describe(self):
        cases = {
            "no display": (report(refresh=None), job(), mvp.ConvertError),
            "macOS update": (report(macos="27.1"), job(), mvp.HostFactsError),
            "other worker": (report(), job(worker="cmux7s-Mac-mini.local"), mvp.ConvertError),
            "short sha": (report(), job(sha="abc123"), mvp.ConvertError),
            "no runs": ({**report(), "runs": []}, job(), mvp.ConvertError),
        }
        for name, (bad_report, bad_job, error) in cases.items():
            with self.subTest(name), self.assertRaises(error):
                mvp.convert(bad_report, job=bad_job, worker="cmux20-bench", facts=FACTS, measure_version=4)
        mixed = report()
        mixed["runs"][0]["refresh_ms"] = 16.7
        with self.assertRaises(mvp.ConvertError):
            mvp.convert(mixed, job=job(), worker="cmux20-bench", facts=FACTS, measure_version=4)
        with self.assertRaises(mvp.HostFactsError):
            mvp.convert(report(), job=job(), worker="cmux20-bench", facts={"other": FACTS["cmux20-bench"]},
                        measure_version=4)

    def test_a_metric_no_round_measured_is_left_out(self):
        partial = report()
        for entry in partial["runs"]:
            entry["layout_max_ms"] = None
        metrics = {r.metric for r in mvp.convert(partial, job=job(), worker="cmux20-bench", facts=FACTS,
                                                 measure_version=4)}
        self.assertNotIn("layout_max_ms", metrics)
        self.assertIn("layout_p95_ms", metrics)

    def test_stream_reports_are_their_own_stories(self):
        streaming = {**report(), "stream": True}
        stories = {r.story for r in mvp.convert(streaming, job=job(), worker="cmux20-bench", facts=FACTS,
                                                measure_version=4)}
        self.assertEqual(stories, {"split-spring.stream.right", "split-spring.stream.down"})

    def test_the_same_step_converts_to_the_same_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = perf_result.write_ndjson(tmp, mvp.convert(report(), job=job(), worker="cmux20-bench",
                                                              facts=FACTS, measure_version=4))
            second = perf_result.write_ndjson(tmp, mvp.convert(report(), job=job(), worker="cmux20-bench",
                                                               facts=FACTS, measure_version=4))
            self.assertEqual(first, second)
            self.assertEqual(len(perf_result.read_dir(tmp)), 2 * len(mvp.METRICS))

    def test_measure_version_of_the_real_script(self):
        text = (ROOT / mvp.SCRIPT).read_text(encoding="utf-8")
        self.assertIsInstance(mvp.measure_version(text), int)
        self.assertEqual(mvp.measure_version(SCRIPT_TEXT), 4)
        self.assertIsNone(mvp.measure_version("set -e\n"))

    def test_host_facts_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "facts.json"
            path.write_text(json.dumps(FACTS))
            self.assertEqual(mvp.load_host_facts(path), FACTS)
            for bad in ({}, {"h": {**FACTS["cmux20-bench"], "memory_bytes": "16"}},
                        {"h": {**FACTS["cmux20-bench"], "chip": ""}}):
                path.write_text(json.dumps(bad))
                with self.subTest(bad=bad), self.assertRaises(mvp.HostFactsError):
                    mvp.load_host_facts(path)


class FakeFleet:
    def __init__(self, end_state: str = "done"):
        self.submitted: list[list[str]] = []
        self.waited: list[str] = []
        self.jobs: dict[str, dict] = {}
        self.end_state = end_state
        self.reports: dict[str, dict] = {}
        self.labels_answer = ["bench", "measure"]
        self.print_id = True

    def labels(self, worker):
        return self.labels_answer

    def run_step(self, argv, log, timeout):
        self.submitted.append(list(argv))
        sha = argv[argv.index("--ref") + 1]
        key = argv[argv.index("--key") + 1]
        job_id = f"{len(self.submitted):024x}"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a") as out:
            if self.print_id:
                out.write(f"cmux-ci: step {job_id} queued (key {key})\n")
        if not self.print_id:
            return 1
        self.jobs[job_id] = job(job_id=job_id, sha=sha, state=self.end_state)
        self.reports[job_id] = report()
        return 0

    def wait(self, job_id, timeout):
        self.waited.append(job_id)

    def status(self, job_id):
        return copy.deepcopy(self.jobs[job_id])

    def artifact(self, job_id, out):
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(self.reports[job_id]))
        return None


class FakeRepo:
    def __init__(self, tips):
        self.tips = list(tips)
        self.sentinel_at: set[str] = set()

    def fetch_tip(self, branch):
        return self.tips[0] if len(self.tips) == 1 else self.tips.pop(0)

    def has_file(self, sha, path):
        return path == mvp.STOP_SENTINEL and sha in self.sentinel_at

    def show(self, sha, path):
        return SCRIPT_TEXT


class TickerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.facts = self.dir / "facts.json"
        self.facts.write_text(json.dumps(FACTS))
        self.ingested: list[tuple[Path, str]] = []
        self.clock = [NOW]

    def tearDown(self):
        self.tmp.cleanup()

    def ticker(self, fleet, repo, local_sentinel=None):
        def ingest(path, host):
            self.ingested.append((path, host))
            return {"state": "stored", "added_runs": 2}

        def now():
            self.clock[0] += timedelta(minutes=10)
            return self.clock[0]

        return mvp.Ticker(state_dir=self.dir / "state", worker="cmux20-bench", branch="feat-cmux-next",
                          facts_path=self.facts, fleet=fleet, repo=repo, ingest=ingest, now=now,
                          local_sentinel=local_sentinel or self.dir / "no-sentinel")

    def state(self):
        return json.loads((self.dir / "state" / "state.json").read_text())

    def test_a_tick_submits_the_tip_and_stores_its_results(self):
        fleet = FakeFleet()
        outcome = self.ticker(fleet, FakeRepo([SHA_A])).tick()
        self.assertEqual(outcome.state, "stored", outcome.reason)
        argv = fleet.submitted[0]
        self.assertEqual(argv[:5], ["run", "--class", "exclusive", "--background", "--measurement"])
        for flag, value in (("--script", "scripts/measure/split-spring.sh"), ("--ref", SHA_A),
                            ("--target-worker", "cmux20-bench"), ("--artifact", "artifacts/split-spring/report.json")):
            self.assertEqual(argv[argv.index(flag) + 1], value)
        self.assertEqual([a for a in argv if a.startswith("--arg=")], ["--arg=--config=bench", "--arg=--vdisplay=120"])
        self.assertIn("--no-supersede", argv)
        self.assertEqual(argv.count("--label"), 2)
        self.assertEqual(len(self.ingested), 1)
        path, host = self.ingested[0]
        self.assertEqual(host, "cmux20-bench")
        results = perf_result.read_file(path)
        self.assertEqual({r.build.sha for r in results}, {SHA_A})
        self.assertEqual({r.host.host_class for r in results}, {"apple-m4/16gb/120hz"})
        state = self.state()
        self.assertIsNone(state["current"])
        self.assertEqual([t["state"] for t in state["ticks"]], ["stored"])

    def test_three_consecutive_ticks_measure_three_tips(self):
        fleet = FakeFleet()
        ticker = self.ticker(fleet, FakeRepo([SHA_A, SHA_B, SHA_C]))
        lines: list[str] = []
        code = mvp.run_loop(ticker, max_ticks=3, retry_seconds=0, sleep=lambda s: self.fail("no back-off"),
                            say=lines.append)
        self.assertEqual(code, 0)
        self.assertEqual([a[a.index("--ref") + 1] for a in fleet.submitted], [SHA_A, SHA_B, SHA_C])
        self.assertEqual([t["state"] for t in self.state()["ticks"]], ["stored"] * 3)
        self.assertEqual(len({t["key"] for t in self.state()["ticks"]}), 3)
        self.assertEqual(len(self.ingested), 3)

    def test_the_sentinel_at_the_tip_stops_before_a_submission(self):
        fleet, repo = FakeFleet(), FakeRepo([SHA_A])
        repo.sentinel_at.add(SHA_A)
        code = mvp.run_loop(self.ticker(fleet, repo), max_ticks=0, retry_seconds=0, sleep=lambda s: None,
                            say=lambda line: None)
        self.assertEqual(code, 0)
        self.assertEqual(fleet.submitted, [])

    def test_a_local_sentinel_stops_too(self):
        sentinel = self.dir / "SCHEDULER_LIVE"
        sentinel.touch()
        fleet = FakeFleet()
        outcome = self.ticker(fleet, FakeRepo([SHA_A]), local_sentinel=sentinel).tick()
        self.assertTrue(outcome.stop)
        self.assertEqual(fleet.submitted, [])

    def test_a_failed_commit_is_not_submitted_again(self):
        fleet = FakeFleet(end_state="failed")
        ticker = self.ticker(fleet, FakeRepo([SHA_A]))
        first = ticker.tick()
        self.assertEqual((first.state, first.counts), ("failed", True))
        again = ticker.tick()
        self.assertEqual((again.state, again.wait), ("idle", True))
        self.assertEqual(len(fleet.submitted), 1)
        self.assertEqual(self.ingested, [])

    def test_a_cancelled_step_is_submitted_again(self):
        fleet = FakeFleet(end_state="cancelled")
        ticker = self.ticker(fleet, FakeRepo([SHA_A]))
        self.assertEqual(ticker.tick().state, "yielded")
        fleet.end_state = "done"
        self.assertEqual(ticker.tick().state, "stored")
        self.assertEqual(len(fleet.submitted), 2)

    def test_a_restart_waits_for_the_step_in_flight(self):
        fleet = FakeFleet()
        fleet.jobs["f" * 24] = job(job_id="f" * 24, sha=SHA_A)
        fleet.reports["f" * 24] = report()
        state_dir = self.dir / "state"
        state_dir.mkdir()
        (state_dir / "state.json").write_text(json.dumps({
            "schema": mvp.STATE_SCHEMA, "failed_shas": [], "ticks": [],
            "current": {"key": "perf-lab-mvp-aaaa", "sha": SHA_A, "submitted_at": "2026-10-26T02:00:00Z",
                        "labels": ["bench", "measure"], "job_id": "f" * 24}}))
        outcome = self.ticker(fleet, FakeRepo([SHA_B])).tick()
        self.assertEqual(outcome.state, "stored")
        self.assertEqual(fleet.submitted, [])
        self.assertEqual(fleet.waited, ["f" * 24])
        self.assertEqual(self.state()["ticks"][0]["sha"], SHA_A)

    def test_a_step_id_in_the_log_is_found_after_a_restart(self):
        fleet = FakeFleet()
        fleet.jobs["e" * 24] = job(job_id="e" * 24, sha=SHA_A)
        fleet.reports["e" * 24] = report()
        state_dir = self.dir / "state"
        (state_dir / "steps").mkdir(parents=True)
        (state_dir / "steps" / "k1.log").write_text(f"cmux-ci: step {'e' * 24} running on cmux20-bench\n")
        (state_dir / "state.json").write_text(json.dumps({
            "schema": mvp.STATE_SCHEMA, "failed_shas": [], "ticks": [],
            "current": {"key": "k1", "sha": SHA_A, "submitted_at": "2026-10-26T02:00:00Z",
                        "labels": ["bench", "measure"]}}))
        self.assertEqual(self.ticker(fleet, FakeRepo([SHA_A])).tick().state, "stored")
        self.assertEqual(fleet.submitted, [])
        self.assertEqual(fleet.waited, ["e" * 24])

    def test_a_submission_the_controller_never_named_backs_off(self):
        fleet = FakeFleet()
        fleet.print_id = False
        outcome = self.ticker(fleet, FakeRepo([SHA_A])).tick()
        self.assertEqual((outcome.state, outcome.wait), ("yielded", True))
        self.assertIsNone(self.state()["current"])

    def test_a_running_step_is_waited_for_again(self):
        fleet = FakeFleet(end_state="running")
        ticker = self.ticker(fleet, FakeRepo([SHA_A]))
        outcome = ticker.tick()
        self.assertEqual((outcome.state, outcome.wait), ("waiting", True))
        job_id = self.state()["current"]["job_id"]
        fleet.jobs[job_id]["state"] = "done"
        self.assertEqual(ticker.tick().state, "stored")
        self.assertEqual(fleet.waited, [job_id])
        self.assertEqual(len(fleet.submitted), 1)

    def test_an_os_update_stops_the_loop_without_storing(self):
        fleet = FakeFleet()
        original = fleet.run_step

        def run_step(argv, log, timeout):
            code = original(argv, log, timeout)
            for job_id in fleet.reports:
                fleet.reports[job_id] = report(macos="27.1")
            return code

        fleet.run_step = run_step
        code = mvp.run_loop(self.ticker(fleet, FakeRepo([SHA_A, SHA_B])), max_ticks=0, retry_seconds=0,
                            sleep=lambda s: None, say=lambda line: None)
        self.assertEqual(code, 1)
        self.assertEqual(self.ingested, [])
        self.assertEqual(self.state()["ticks"][-1]["state"], "refused")

    def test_a_host_the_controller_does_not_list_starts_nothing(self):
        fleet = FakeFleet()
        fleet.labels_answer = None
        outcome = self.ticker(fleet, FakeRepo([SHA_A])).tick()
        self.assertEqual((outcome.state, outcome.wait), ("idle", True))
        self.assertEqual(fleet.submitted, [])


class FleetAndIngestTests(unittest.TestCase):
    def test_labels_follow_the_workers_bench_label(self):
        def run(argv, **kwargs):
            body = {"cmux20-bench": {"labels": ["bench", "measure"]}, "cmux7s": {"labels": ["measure"]}}
            return subprocess.CompletedProcess(argv, 0, json.dumps(body) + "\n{\"trailer\": 1}\n", "")

        fleet = mvp.Fleet("cmux-ci", run=run)
        self.assertEqual(fleet.labels("cmux20-bench"), ["bench", "measure"])
        self.assertEqual(fleet.labels("cmux7s"), ["measure"])
        self.assertIsNone(fleet.labels("cmux99"))

    def test_ingest_runs_lab_py_and_reads_its_report(self):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, json.dumps({"added_runs": 2, "rejected": []}), "")

        with tempfile.TemporaryDirectory() as tmp:
            lab_py = Path(tmp) / "lab.py"
            lab_py.write_text("")
            answer = mvp.Ingest("lab.sqlite3", "/repo", run=run, lab_py=lab_py)(Path("r.ndjson"), "cmux20-bench")
        self.assertEqual(answer, {"state": "stored", "added_runs": 2, "rejected": []})
        argv = calls[0]
        self.assertEqual(argv[argv.index("--host-name") + 1], "cmux20-bench")
        self.assertEqual(argv[argv.index("--kind") + 1], "waterfall")

    def test_ingest_is_pending_without_lab_py(self):
        answer = mvp.Ingest("db", "/repo", run=lambda *a, **k: self.fail("ran"),
                            lab_py=Path("/nonexistent/lab.py"))(Path("r.ndjson"), "cmux20-bench")
        self.assertEqual(answer["state"], "pending")


@unittest.skipUnless((LAB / "ingest.py").is_file(), "ingest.py (p12-perf-process-005) is not in this checkout")
class StoreRoundTripTests(unittest.TestCase):
    def test_points_are_keyed_by_sha_and_host_class(self):
        ingest = _load("perf_lab_ingest", LAB / "ingest.py")
        store = sys.modules["perf_lab_store"]
        with tempfile.TemporaryDirectory() as tmp:
            for index, sha in enumerate((SHA_A, SHA_B)):
                results = mvp.convert(report(), job=job(job_id=f"{index:024x}", sha=sha), worker="cmux20-bench",
                                      facts=FACTS, measure_version=4)
                perf_result.write_ndjson(Path(tmp) / "results", results)
            db = store.Store(str(Path(tmp) / "lab.sqlite3"))
            db.migrate()
            positions = {SHA_A: 10, SHA_B: 11}
            stored = ingest.ingest_paths(db, [Path(tmp) / "results"], commit_positions=positions.get,
                                         host_name="cmux20-bench")
            self.assertEqual((stored.added_runs, stored.rejected), (4, []))
            key = store.series_key(story="split-spring.right", metric="frames_p99_ms", engine="none",
                                   host_class="apple-m4/16gb/120hz", macos_major=27, build_config="bench")
            points = db.series_points(key, limit=50)
            self.assertEqual([p.sha for p in points], [SHA_A, SHA_B])
            again = ingest.ingest_paths(db, [Path(tmp) / "results"], commit_positions=positions.get,
                                        host_name="cmux20-bench")
            self.assertEqual((again.added_runs, again.unchanged_runs), (0, 4))
            db.close()


if __name__ == "__main__":
    unittest.main()
