#!/usr/bin/env python3
"""bench_power.py as the perf lab's T1 power story (p12-perf-process-239): package power from pool.json's one
powermetrics command under sudo -n (decision D3), a refusal with sudo's reason and nothing written without the
right, and every window's series as cmux-perf-result/v1 that the story's metric patterns claim."""

from __future__ import annotations

import io
import json
import plistlib
import re
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
import bench_power as bp  # noqa: E402

STORY_FILE = ROOT / "scripts/perf-lab/stories.d/power.json"
POOL = ROOT / "scripts/perf-lab/pool.json"
RUNNER = ["--app", "/x/cmux DEV power.app", "--tag", "power", "--out", "/x/out"]


def plist_sample(cpu: float, gpu: float, combined: float | None = None, elapsed_ns: int = 1_000_000_000) -> bytes:
    processor = {"cpu_power": cpu, "gpu_power": gpu, "ane_power": 0.0}
    if combined is not None:
        processor["combined_power"] = combined
    return plistlib.dumps({"elapsed_ns": elapsed_ns, "processor": processor})


def window(label: str, samples: list[dict], mw: float = 3.5, wakeups: float = 12.0) -> dict:
    return {"label": label, "total": {"mw": mw, "cpu_pct": 0.1, "wakeups_per_s": wakeups, "footprint_mb": 1.0},
            "package_samples": samples}


class PowermetricsRightTests(unittest.TestCase):
    def test_the_command_is_pool_jsons_privileged_argv_under_sudo_n(self):
        argv = json.loads(POOL.read_text())["privileged"]["powermetrics"]
        self.assertEqual(bp.powermetrics_command(str(POOL)), ["sudo", "-n", *argv])

    def test_the_right_is_listed_for_the_exact_argv_and_runs_nothing(self):
        calls = []

        def run(argv, **_kwargs):
            calls.append(argv)
            return SimpleNamespace(returncode=0, stdout="/usr/bin/powermetrics", stderr="")

        command = bp.powermetrics_command(str(POOL))
        self.assertIsNone(bp.powermetrics_refusal(command, run=run))
        self.assertEqual(calls, [["sudo", "-n", "-l", *command[2:]]])

    def test_a_missing_right_names_sudos_reason_and_the_setup_that_grants_it(self):
        def run(_argv, **_kwargs):
            return SimpleNamespace(returncode=1, stdout="", stderr="sudo: a password is required")

        reason = bp.powermetrics_refusal(bp.powermetrics_command(str(POOL)), run=run)
        self.assertIn("sudo: a password is required", reason)
        self.assertIn("host-setup.sh --grant-privileged", reason)

    def test_require_refuses_auto_goes_on_without_and_off_never_asks(self):
        with mock.patch.object(bp, "powermetrics_refusal", lambda command: "no right"):
            with self.assertRaises(bp.Refused) as refused:
                bp.package_power("require", attribute=False)
            self.assertIn("no right", str(refused.exception))
            self.assertEqual(bp.package_power("auto", attribute=False), (None, "no right"))
        with mock.patch.object(bp, "powermetrics_refusal", lambda command: self.fail("asked sudo")):
            self.assertEqual(bp.package_power("off", attribute=False)[0], None)
            self.assertEqual(bp.package_power("auto", attribute=True)[0], None)
        with mock.patch.object(bp, "powermetrics_refusal", lambda command: None):
            sampler, reason = bp.package_power("require", attribute=False)
            self.assertIsInstance(sampler, bp.PackagePower)
            self.assertIsNone(reason)

    def test_the_story_refuses_before_any_launch_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as out, \
                mock.patch.object(bp, "powermetrics_refusal", lambda command: "sudo: a password is required"), \
                mock.patch.object(bp.sys, "platform", "darwin"), \
                mock.patch.object(bp, "BenchApp", side_effect=AssertionError("launched")), \
                mock.patch.object(bp, "wipe_state", side_effect=AssertionError("wiped")):
            story = json.loads(STORY_FILE.read_text())
            code = bp.main(story["command"][1:] + ["--app", "/x/cmux DEV power.app", "--out", out])
            self.assertEqual(code, 2)
            self.assertEqual(list(Path(out).iterdir()), [])


class PackageSampleTests(unittest.TestCase):
    def test_nul_separated_documents_keep_only_complete_samples(self):
        stream = b"\0".join([
            plist_sample(100.0, 20.0, combined=125.0),
            plist_sample(80.0, 10.0),  # no combined_power: the sum of the parts
            plist_sample(999.0, 999.0, elapsed_ns=300_000_000),  # the sample SIGINT cut short
            plist_sample(90.0, 15.0)[:40],  # a document cut off mid-write
        ])
        self.assertEqual(bp.package_samples(stream), [
            {"cpu_power_mw": 100.0, "gpu_power_mw": 20.0, "ane_power_mw": 0.0, "combined_power_mw": 125.0},
            {"cpu_power_mw": 80.0, "gpu_power_mw": 10.0, "ane_power_mw": 0.0, "combined_power_mw": 90.0},
        ])

    def test_the_sampler_runs_for_the_window_and_sigint_ends_it(self):
        events = []

        class FakeProcess:
            def __init__(self, argv, **kwargs):
                events.append(("spawn", argv, kwargs.get("start_new_session")))
                self.stdout = io.BytesIO(plist_sample(50.0, 5.0) + b"\0" + plist_sample(70.0, 7.0) + b"\0")

            def send_signal(self, signum):
                events.append(("signal", signum))

            def wait(self, timeout=None):
                return 0

        sampler = bp.PackagePower(["sudo", "-n", "/usr/bin/powermetrics"], popen=FakeProcess)
        sampler.start()
        samples = sampler.stop()
        # Its own session: sudo passes on no signal sent from the command's process group.
        self.assertEqual(events[0], ("spawn", ["sudo", "-n", "/usr/bin/powermetrics"], True))
        self.assertEqual(events[1], ("signal", signal.SIGINT))
        self.assertEqual([s["combined_power_mw"] for s in samples], [55.0, 77.0])
        self.assertEqual(sampler.stop(), [], "a stopped sampler has nothing more")

    def test_a_sampler_that_ignores_sigint_gets_sigterm(self):
        signals = []

        class StubbornProcess:
            def __init__(self, argv, **kwargs):
                self.stdout = io.BytesIO(b"")

            def send_signal(self, signum):
                signals.append(signum)

            def wait(self, timeout=None):
                if signals == [signal.SIGINT]:
                    raise bp.subprocess.TimeoutExpired("sudo", timeout)
                return 0

            def kill(self):
                signals.append("kill")

        sampler = bp.PackagePower(["sudo", "-n", "/usr/bin/powermetrics"], popen=StubbornProcess)
        sampler.start()
        self.assertEqual(sampler.stop(), [])
        self.assertEqual(signals, [signal.SIGINT, signal.SIGTERM])

    def test_the_summary_is_the_shared_median(self):
        samples = [{"combined_power_mw": value} for value in (10.0, 20.0, 30.0, 40.0)]
        self.assertEqual(bp.package_summary(samples), {"combined_power_mw": 25.0, "samples": 4})
        self.assertEqual(bp.package_summary([]), {})


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class MeasureTests(unittest.TestCase):
    def test_the_package_window_brackets_the_measured_window(self):
        clock, order = FakeClock(), []

        class FakePackage:
            def start(self):
                order.append(("start", clock.now))

            def stop(self):
                order.append(("stop", clock.now))
                return [{"combined_power_mw": 40.0}, {"combined_power_mw": 60.0}]

        def counters(pid):
            order.append(("counters", clock.now))
            return (int(2e6 * clock.now), 0, 0, 0)

        with mock.patch.object(bp, "time", clock), mock.patch.object(bp, "counters", counters), \
                mock.patch.object(bp.bm, "owned", lambda pid, bundle: {pid: ("app", "cmux")}):
            result = bp.measure(42, "/Apps/cmux.app", "tab1", 60, package=FakePackage())
        self.assertEqual([event for event, _ in order], ["counters", "start", "counters", "stop"])
        self.assertEqual(result["powermetrics"], {"combined_power_mw": 50.0, "samples": 2})
        self.assertEqual(len(result["package_samples"]), 2)
        self.assertAlmostEqual(result["total"]["mw"], 2.0)

    def assert_an_early_end_stops_the_sampler(self, error: BaseException):
        events = []

        class FakeProcess:
            """sudo with the root sampler behind it: only a signal from the bench ends it."""

            def __init__(self, argv, **kwargs):
                events.append("spawn")
                self.stdout = io.BytesIO(b"")

            def send_signal(self, signum):
                events.append(signum)

            def wait(self, timeout=None):
                return 0

        def during(_seconds):
            events.append("during")
            raise error

        package = bp.PackagePower(["sudo", "-n", "/usr/bin/powermetrics"], popen=FakeProcess)
        with mock.patch.object(bp, "counters", lambda pid: (0, 0, 0, 0)), \
                mock.patch.object(bp.bm, "owned", lambda pid, bundle: {pid: ("app", "cmux")}):
            with self.assertRaises(type(error)):
                bp.measure(42, "/Apps/cmux.app", "typing", 60, during=during, package=package)
        self.assertEqual(events, ["spawn", "during", signal.SIGINT])
        self.assertIsNone(package.process, "the sampler was stopped")

    def test_a_scenario_that_raises_still_stops_the_sampler(self):
        self.assert_an_early_end_stops_the_sampler(RuntimeError("scenario failed"))

    def test_sigterm_inside_the_window_still_stops_the_sampler(self):
        # main() turns the runner's SIGTERM into KeyboardInterrupt (bench_memory.interrupted).
        self.assert_an_early_end_stops_the_sampler(KeyboardInterrupt())


class FakeKeyApp:
    def __init__(self, reply):
        self.reply = reply
        self.keys = []

    def call(self, method, params=None, label=None, timeout=120):
        self.keys.append((method, params["key"]))
        return self.reply(len(self.keys)) if callable(self.reply) else self.reply


class TypingTests(unittest.TestCase):
    def setUp(self):
        self.records = []
        test = self

        class FakeBench:
            def record(self, story, metric, unit, samples, better, engine, target_ref=None):
                test.records.append(metric)
                return f"/out/{metric}"

        self.bench = FakeBench()

    def type_window(self, app) -> tuple[bp.KeyTyping, dict]:
        typing = bp.KeyTyping(app, clock=FakeClock())
        typing(10)
        result = window("typing", [{"cpu_power_mw": 30.0, "gpu_power_mw": 4.0, "combined_power_mw": 34.0}])
        return typing, result

    def test_keys_the_app_refuses_record_no_typing_series(self):
        typing, result = self.type_window(FakeKeyApp({"error": "no window"}))
        written = bp.judge_and_record(self.bench, "power", result, True, record=True, verdict=typing.verdict)
        self.assertEqual(self.records, [], "an idle terminal was recorded as typing power")
        self.assertEqual(result["keys"], {"sent": 80, "accepted": 0, "expected": 80, "first_error": "no window"})
        failures = bp.unrecorded({"typing": written})
        self.assertEqual(sorted(written), ["power.typing.cpu_mw", "power.typing.gpu_mw", "power.typing.package_mw",
                                           "power.typing.processes_mw", "power.typing.wakeups_per_s"])
        self.assertIn("power.typing.package_mw: not recorded: debug.key refused (no window): 0 of 80 keys accepted",
                      failures)

    def test_a_refusal_fails_the_run_without_an_out_folder_too(self):
        typing, result = self.type_window(FakeKeyApp({"error": "no window"}))
        written = bp.judge_and_record(self.bench, "power", result, False, record=False, verdict=typing.verdict)
        self.assertTrue(bp.unrecorded({"typing": written}))
        self.assertEqual(self.records, [])

    def test_mostly_refused_keys_record_nothing(self):
        typing, result = self.type_window(FakeKeyApp(lambda n: {} if n % 4 == 0 else {"error": "bad key"}))
        bp.judge_and_record(self.bench, "power", result, True, record=True, verdict=typing.verdict)
        self.assertEqual(result["keys"]["accepted"], 20)
        self.assertEqual(self.records, [])

    def test_accepted_keys_record_the_window(self):
        app = FakeKeyApp({})
        typing, result = self.type_window(app)
        written = bp.judge_and_record(self.bench, "power", result, True, record=True, verdict=typing.verdict)
        self.assertEqual(result["keys"], {"sent": 80, "accepted": 80, "expected": 80, "first_error": None})
        self.assertEqual(bp.unrecorded({"typing": written}), [])
        self.assertIn("power.typing.package_mw", self.records)
        self.assertEqual(app.keys[:3], [("debug.key", "c"), ("debug.key", "m"), ("debug.key", "u")])

    def test_a_window_without_a_verdict_and_out_folder_records_nothing(self):
        self.assertIsNone(bp.judge_and_record(self.bench, "power", window("tab1", []), False, record=False))


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.story = json.loads(STORY_FILE.read_text())

    def claimed(self, metric: str, unit: str) -> bool:
        return any(re.fullmatch(m["name"], metric) and m["unit"] == unit for m in self.story["metrics"])

    def test_every_window_series_is_claimed_by_the_story(self):
        samples = [{"cpu_power_mw": 30.0, "gpu_power_mw": 4.0, "combined_power_mw": 34.0}] * 3
        for label in ("typing", "tab1", "tab1-hidden", "scroll"):
            for metric, unit, values in bp.window_series(window(label, samples)):
                self.assertTrue(self.claimed(metric, unit), f"power.json claims no {metric} ({unit})")
                self.assertTrue(values)

    def test_a_window_writes_valid_result_v1_through_record(self):
        writer = bp.perf_result
        with tempfile.TemporaryDirectory() as out:
            build = writer.Build(sha="a" * 40, config="bench", measure_version=2)
            host = writer.Host(fingerprint="b" * 64, host_class="apple-m6/16gb/120hz", chip="Apple M6",
                               macos="26.1", macos_build="25B78", display_hz=120)
            run = writer.Run.start()

            class FakeBench:
                def record(self, story, metric, unit, samples, better, engine, target_ref=None):
                    result = writer.Result(story=story, metric=metric, unit=unit, better=better, samples=list(samples),
                                           build=build, host=host, engine=engine, session="light", run=run)
                    return writer.write_ndjson(out, [result], repo_root=ROOT)

            samples = [{"cpu_power_mw": 30.0, "gpu_power_mw": 4.0, "combined_power_mw": 34.0},
                       {"cpu_power_mw": 32.0, "gpu_power_mw": 4.5, "combined_power_mw": 36.5}]
            written = bp.record_window(FakeBench(), "power", window("tab1", samples), package_required=True)
            self.assertEqual(bp.unrecorded({"tab1": written}), [])
            stored = {r.metric: r for r in writer.read_dir(out)}
            self.assertEqual(sorted(stored), ["power.tab1.cpu_mw", "power.tab1.gpu_mw", "power.tab1.package_mw",
                                              "power.tab1.processes_mw", "power.tab1.wakeups_per_s"])
            self.assertEqual(stored["power.tab1.package_mw"].samples, [34.0, 36.5])
            self.assertEqual((stored["power.tab1.wakeups_per_s"].unit, stored["power.tab1.processes_mw"].samples),
                             ("per_s", [3.5]))
            self.assertEqual({r.engine for r in stored.values()}, {self.story["engine"]})

    def test_a_required_window_without_package_samples_is_a_failure(self):
        class FakeBench:
            def record(self, story, metric, unit, samples, better, engine, target_ref=None):
                return f"/out/{metric}"

        written = bp.record_window(FakeBench(), "power", window("scroll", []), package_required=True)
        self.assertEqual(bp.unrecorded({"scroll": written}),
                         ["power.scroll.package_mw: not recorded: powermetrics gave no complete sample"])
        relaxed = bp.record_window(FakeBench(), "power", window("scroll", []), package_required=False)
        self.assertEqual(bp.unrecorded({"scroll": relaxed}), [])

    def test_a_record_error_is_named_not_raised(self):
        class FakeBench:
            def record(self, *args, **kwargs):
                raise bp.RecordError("no build sha")

        written = bp.record_window(FakeBench(), "power", window("typing", []), package_required=False)
        self.assertIn("power.typing.processes_mw: not recorded: no build sha", bp.unrecorded({"typing": written}))


class StoryCommandTests(unittest.TestCase):
    def test_the_story_command_parses_with_the_runner_flags(self):
        story = json.loads(STORY_FILE.read_text())
        self.assertEqual(story["command"][0], "scripts/cmux-next/bench_power.py")
        args = bp.parse(story["command"][1:] + RUNNER)
        self.assertEqual((args.powermetrics, args.story, args.tag, args.out), ("require", "power", "power", "/x/out"))
        self.assertEqual(args.scenarios.split(","), ["typing", "tab1", "tab1-hidden", "scroll"])
        self.assertIn("privilege:powermetrics", story["needs"])
        self.assertEqual(bp.out_paths(tempfile.mkdtemp())[0].rsplit("/", 1)[-1], "bench-power.json")
        self.assertEqual(bp.out_paths("/x/report.json"), ("/x/report.json", None))

    def test_the_story_scenarios_open_no_twenty_tabs(self):
        story = json.loads(STORY_FILE.read_text())
        scenarios = bp.parse(story["command"][1:] + RUNNER).scenarios.split(",")
        self.assertFalse(bp.TWENTY_TAB_SCENARIOS.intersection(scenarios))

    def test_unknown_scenarios_and_attributed_required_power_are_refused(self):
        with mock.patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit):
                bp.parse(["--app", "x", "--scenarios", "tab1,typo"])
            with self.assertRaises(SystemExit):
                bp.parse(["--app", "x", "--attribute", "--powermetrics", "require"])


if __name__ == "__main__":
    unittest.main()
