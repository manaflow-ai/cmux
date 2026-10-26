#!/usr/bin/env python3
"""perf-gate.py's bench migration (p12-perf-process-067): its percentiles are perf_stats.pct (old against new on a
fixed vector), it launches through bench_launch.BenchApp (the env and config it had, the saved session kept across
the relaunch scenario), and each scenario's failed checks go to result-v1 under the perf-gate story with the names
perf-cron.py reads from perf-gate.json.

Runs on any host (Linux included): no app, no daemon, no fleet, no network.

    python3 -m unittest scripts/cmux-next/tests/test_perf_gate.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = HERE.parent.parent
PERF_LAB = HERE.parent / "perf-lab"
GATE_REL = "scripts/cmux-next/perf-gate.py"


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


gate = load("perf_gate_under_test", HERE / "perf-gate.py")
perf_stats = load("perf_stats", PERF_LAB / "perf_stats.py")
perf_result = load("perf_result", PERF_LAB / "perf_result.py")
queues = load("perf_lab_queues", PERF_LAB / "queues.py")
cron = load("perf_cron", HERE / "perf-cron.py")

# 40 samples (the gate's 40 tab switches) with a long tail, unsorted as the app reports them.
VECTOR = [1.2, 0.8, 1.5, 2.1, 0.9, 1.1, 1.3, 4.8, 1.0, 1.4, 1.6, 0.7, 1.2, 2.6, 1.1, 0.9, 1.8, 1.3, 1.0, 12.5,
          1.5, 1.2, 0.8, 1.9, 1.1, 1.4, 3.2, 1.0, 1.3, 1.7, 0.9, 1.2, 2.2, 1.6, 1.1, 1.0, 1.4, 6.4, 1.3, 1.5]
HOST = sys.modules["bench_launch"].host_record("Apple M4 Pro", 48 * 2**30, "26.1", "25B78", 120)
FEATURES = ({"tabSwitchFastPath": {"state": "on", "source": "default"}}, "fh-1", "off")


def story():
    with open(PERF_LAB / "stories.d" / "perf-gate.json") as handle:
        return json.load(handle)


def bundle(folder: str, tag: str) -> str:
    """A `cmux DEV <tag>.app` with an Info.plist that names its commit and an empty main executable (a release kind)."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    os.makedirs(os.path.join(app, "Contents/MacOS"))
    with open(os.path.join(app, "Contents/Info.plist"), "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": f"com.cmuxterm.app.debug.{tag}", "CFBundleExecutable": "cmux DEV",
                       "CMUXCommit": "a" * 40}, handle)
    open(os.path.join(app, "Contents/MacOS/cmux DEV"), "w").close()
    return app


class PercentileTests(unittest.TestCase):
    """The forms perf-gate.py had, against perf_stats.pct (linear interpolation) on VECTOR."""

    def setUp(self):
        self.ordered = sorted(VECTOR)
        self.n = len(self.ordered)

    def test_the_gate_uses_perf_stats_pct(self):
        self.assertIs(gate.pct, perf_stats.pct)

    def test_old_and_new_p99(self):
        v, n = self.ordered, self.n
        # workspaces latency_p99_ms: v[min(n - 1, int(n * 0.99))], the maximum at n < 100.
        self.assertEqual(v[min(n - 1, int(n * 0.99))], 12.5)
        # tabs latency_p99_ms (v[int(ops * 0.99) - 1]) and the tabs and new_workspaces p99 lambda
        # (v[max(0, int(n * 0.99) - 1)]): the second largest at n = 40.
        self.assertEqual(v[max(0, int(n * 0.99) - 1)], 6.4)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, .99), 10.121, places=9)

    def test_old_and_new_p95_and_p50(self):
        v, n = self.ordered, self.n
        nearest = lambda q: v[min(n - 1, max(0, int(round(n * q)) - 1))]  # noqa: E731 - pane_focus's old pct
        self.assertEqual((nearest(.5), nearest(.95)), (1.3, 4.8))
        self.assertEqual(v[n // 2], 1.3)  # the upper medians of the tab switch and new workspace lines
        self.assertAlmostEqual(perf_stats.pct(VECTOR, .95), 4.88, places=9)
        self.assertAlmostEqual(perf_stats.pct(VECTOR, .5), 1.3, places=9)

    def test_the_machine_queues_no_longer_list_the_gate(self):
        with contextlib.redirect_stderr(io.StringIO()):
            for queue in (queues.private_stats, queues.self_launch, queues.p95_without_p99):
                self.assertNotIn(GATE_REL, {item.key for item in queue(str(ROOT))}, queue.__name__)

    def test_no_private_percentile_form_is_left(self):
        text = (HERE / "perf-gate.py").read_text()
        self.assertNotRegex(text, r"\*\s*0\.9\d")
        self.assertNotRegex(text, r"\bp99\s*=\s*lambda\b|\bpct\s*=\s*lambda\b|\bcol\s*=\s*lambda\b")
        self.assertNotRegex(text, r"\[\w+\s*//\s*2\]")


class AppTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="perf-gate-test-")
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.out = os.path.join(self.folder, "out")
        self.app_path = bundle(self.folder, "gate")
        self.saved_hang = os.environ.pop("PERF_GATE_HANG_MS", None)
        self.addCleanup(self.restore_hang)

    def restore_hang(self):
        os.environ.pop("PERF_GATE_HANG_MS", None)
        if self.saved_hang is not None:
            os.environ["PERF_GATE_HANG_MS"] = self.saved_hang

    def test_it_launches_through_bench_app_with_the_gate_env_and_config(self):
        os.environ["PERF_GATE_HANG_MS"] = "40"
        app = gate.App(self.app_path, self.out, socket_only=True)
        self.assertIsInstance(app.bench, gate.BenchApp)
        self.assertTrue(app.bench.socket_only)
        self.assertEqual((app.tag, app.out, app.cli_path), ("gate", self.out, app.bench.cli))
        env = app.bench.environment()
        for key, value in {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900",
                           "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_HANG_THRESHOLD_MS": "40",
                           "CMUX_NEXT_CONFIG_FILE": app.config}.items():
            self.assertEqual(env.get(key), value, key)
        with open(app.config) as handle:
            config = json.load(handle)
        self.assertEqual(config["appearance"], gate.App.CONFIG["appearance"])
        self.assertEqual(app.bench.log_path, os.path.join(self.out, "app.log"))

    def test_the_relaunch_keeps_the_saved_session_and_arms_a_new_teardown(self):
        app = gate.App(self.app_path, self.out)
        self.assertFalse(app.bench.socket_only, "a GUI session is required unless the caller says socket-only")
        first = app.bench.teardown
        seen = []
        app.bench.stop = lambda: seen.append("stop")
        app.launch = lambda: seen.append(("launch", app.bench.fresh_state, app.bench.teardown is not first))
        self.assertTrue(app.bench.fresh_state, "the first launch starts from an empty saved session")
        app.relaunch()
        self.assertEqual(seen, ["stop", ("launch", False, True)])

    def test_a_relaunch_that_does_not_answer_keeps_the_answered_launchs_features(self):
        app = gate.App(self.app_path, self.out)
        app.bench.features = FEATURES  # the first launch answered
        app.bench.stop = lambda: None

        def silent():
            app.bench.features = None  # BenchApp.launch's first step
            raise gate.LaunchError("socket-silent", {"detail": "no answer"})

        app.launch = silent
        with self.assertRaises(gate.LaunchError):
            app.relaunch()
        self.assertEqual(app.bench.features, FEATURES)


class ResultTests(unittest.TestCase):
    CHECKS = [{"scenario": "source guard", "ok": True}, {"scenario": "tabs", "ok": True},
              {"scenario": "tabs", "ok": False}, {"scenario": "tabs", "ok": False}, {"scenario": "split", "ok": True},
              {"scenario": "relaunch tabs", "ok": False}, {"scenario": "relaunch", "ok": True}]
    RAN = ("tabs", "split", "relaunch", "status")

    def test_failed_checks_per_scenario(self):
        self.assertEqual(gate.failed_checks(self.CHECKS, self.RAN), {
            "perf_gate.relaunch.failed_checks": 0, "perf_gate.relaunch_tabs.failed_checks": 1,
            "perf_gate.source_guard.failed_checks": 0, "perf_gate.split.failed_checks": 0,
            "perf_gate.status.failed_checks": 0, "perf_gate.tabs.failed_checks": 2})

    def test_the_counts_are_perf_crons_rows(self):
        rows = cron.rows_of_part(cron.PART_BY_NAME["perf-gate"], {"checks": self.CHECKS}, cron.load_budgets_module(),
                                 {"rows": {}})
        ours = gate.failed_checks(self.CHECKS)
        self.assertEqual(len(rows), len(ours))
        for name, row in rows.items():
            self.assertEqual(ours[name.replace(" ", "_")], row["p95"], name)

    def test_the_names_are_the_storys_and_valid_result_names(self):
        spec = story()
        [metric] = spec["metrics"]
        for name in gate.failed_checks(self.CHECKS, gate.SCENARIOS):
            self.assertRegex(name, "^(?:%s)$" % metric["name"])
            self.assertRegex(name, perf_result.NAME_PATTERN)
        self.assertEqual((metric["unit"], metric["better"], spec["engine"], spec["session"], spec["id"]),
                         ("count", "lower", "none", "light", gate.STORY))
        self.assertEqual(spec["command"][0], GATE_REL)

    def test_record_writes_one_valid_result_per_scenario(self):
        folder = tempfile.mkdtemp(prefix="perf-gate-record-")
        self.addCleanup(shutil.rmtree, folder, True)
        out = os.path.join(folder, "out")
        app = gate.App(bundle(folder, "rec"), out)
        app.bench.read_host = lambda: dict(HOST)
        app.bench.features = FEATURES  # what launch() read
        with contextlib.redirect_stdout(io.StringIO()):
            written = gate.record(app, self.CHECKS, self.RAN)
        self.assertEqual(set(written), set(gate.failed_checks(self.CHECKS, self.RAN)))
        lines = [json.loads(text) for path in sorted(Path(out).glob("*.ndjson")) for text in path.read_text().splitlines()]
        for line in lines:
            self.assertEqual(perf_result.validation_errors(line), [])
        got = {line["metric"]: line["samples"] for line in lines}
        self.assertEqual(got, {name: [n] for name, n in gate.failed_checks(self.CHECKS, self.RAN).items()})
        self.assertEqual({(l["story"], l["unit"], l["better"], l["engine"], l["session"]) for l in lines},
                         {("perf-gate", "count", "lower", "none", "light")})
        self.assertEqual(len({l["run"]["id"] for l in lines}), 1, "one gate run is one result-v1 run")
        self.assertEqual(lines[0]["build"]["sha"], "a" * 40)

    def test_a_run_whose_app_never_answered_records_nothing(self):
        folder = tempfile.mkdtemp(prefix="perf-gate-record-")
        self.addCleanup(shutil.rmtree, folder, True)
        out = os.path.join(folder, "out")
        app = gate.App(bundle(folder, "none"), out)  # never launched: no features snapshot
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            written = gate.record(app, self.CHECKS, self.RAN)
        self.assertTrue(written and all(v.startswith("not recorded: ") for v in written.values()))
        self.assertEqual(printed.getvalue().count("not recorded"), 1, "one line, not one per scenario")
        self.assertEqual(list(Path(out).glob("*.ndjson")), [])


class FailedRelaunchRunTests(unittest.TestCase):
    """main() with a first launch that answers and a relaunch that does not: the scenarios before it and the launch
    failure are still written as result-v1."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="perf-gate-main-")
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.out = os.path.join(self.folder, "out")
        self.app_path = bundle(self.folder, "main")
        saved = (list(gate.failures), list(gate.warnings), dict(gate.report))
        self.addCleanup(self.restore, saved)
        gate.failures.clear()
        gate.warnings.clear()
        gate.report.clear()
        gate.report.update({"checks": [], "phases": {}})

    @staticmethod
    def restore(saved):
        for target, value in zip((gate.failures, gate.warnings), saved[:2]):
            target[:] = value
        gate.report.clear()
        gate.report.update(saved[2])

    def test_the_scenarios_before_a_failed_relaunch_are_recorded(self):
        launches = []

        def launch(app):
            app.bench.features = None  # BenchApp.launch's first step
            launches.append(app.bench.fresh_state)
            if len(launches) > 1:
                raise gate.LaunchError("crashed", {"detail": "the restored session crashed"})
            app.bench.features = FEATURES

        patches = [mock.patch.object(gate, "source_guard", lambda: None),
                   mock.patch.object(sys.modules["bench_launch"], "read_host", lambda: dict(HOST)),
                   mock.patch.object(gate.App, "launch", launch),
                   mock.patch.object(gate.App, "stop", lambda app: None),
                   mock.patch.object(gate.Gate, "workspaces", lambda g: gate.check(False, "a breach", "workspaces")),
                   mock.patch.object(gate.Gate, "tabs", lambda g: gate.check(True, "in budget", "tabs")),
                   mock.patch.object(gate.Gate, "relaunch", lambda g: g.app.relaunch())]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        with contextlib.redirect_stdout(io.StringIO()):
            code = gate.main(["--app", self.app_path, "--out", self.out, "--session", "light",
                              "--only", "workspaces,tabs,relaunch,status"])
        self.assertEqual(code, 1)
        self.assertEqual(launches, [True, False], "the relaunch keeps the saved session")
        lines = [json.loads(text) for path in sorted(Path(self.out).glob("*.ndjson"))
                 for text in path.read_text().splitlines()]
        self.assertEqual({line["metric"]: line["samples"] for line in lines},
                         {"perf_gate.workspaces.failed_checks": [1], "perf_gate.tabs.failed_checks": [0],
                          "perf_gate.launch.failed_checks": [1]})
        self.assertEqual({(line["session"], line["features_hash"]) for line in lines}, {("light", "fh-1")})


class CommandLineTests(unittest.TestCase):
    # what the story runner adds (stories.d/README.md: --app, --tag, --out and the session)
    RUNNER = ["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/x/out", "--session", "light"]

    def test_the_story_command_parses_with_the_runners_flags(self):
        opts = gate.parse(story()["command"][1:] + self.RUNNER)
        self.assertEqual((opts.app, opts.tag, opts.out, opts.frames, opts.session),
                         ("/x/cmux DEV t.app", "t", "/x/out", "auto", "light"))

    def test_the_session_reaches_bench_app(self):
        folder = tempfile.mkdtemp(prefix="perf-gate-session-")
        self.addCleanup(shutil.rmtree, folder, True)
        app = gate.App(bundle(folder, "ses"), os.path.join(folder, "out"), perf_session=gate.parse(self.RUNNER).session)
        self.assertEqual(app.bench.perf_session, "light")

    def test_unknown_scenarios_and_a_missing_app_are_refused(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                gate.parse(["--app", "/x/cmux DEV t.app", "--only", "tabs,nope"])
            with self.assertRaises(SystemExit):
                gate.parse([])
        self.assertTrue(gate.parse(["--source-guard-only"]).source_guard_only)

    def test_help_runs_under_isolated_python(self):
        done = subprocess.run([sys.executable, "-I", str(HERE / "perf-gate.py"), "--help"], capture_output=True,
                              text=True, timeout=60, cwd="/")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(re.search(r"--build-config", done.stdout))


if __name__ == "__main__":
    unittest.main()
