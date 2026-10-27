#!/usr/bin/env python3
"""stories/shipped_nightly.py: the DMG is verified before anything of it runs, no debug.* request, and its results.

  python3 -m unittest scripts/perf-lab/tests/test_shipped_nightly.py
"""
from __future__ import annotations

import ast
import importlib.util
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
ROOT = LAB.parent.parent
SCRIPT = LAB / "stories" / "shipped_nightly.py"
STORY_FILE = LAB / "stories.d" / "shipped-nightly.json"

_SPEC = importlib.util.spec_from_file_location("perf_lab_shipped_nightly_under_test", SCRIPT)
story = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = story
_SPEC.loader.exec_module(story)
catalog = story.load_by_path("perf_lab_catalog", str(LAB / "catalog.py"))
run_story = story.load_by_path("perf_lab_run_story_under_test", str(LAB / "run_story.py"))

SHA = "a" * 40
DIGEST = "b" * 64


def done(code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


def make_bundle(folder: str, bundle_id: str = story.NEXT_BUNDLE_ID, commit: str = SHA, body: bytes = b"\0release") -> str:
    """A bundle with an Info.plist and a main executable (no bench-hooks marker unless `body` has it)."""
    app = os.path.join(folder, story.NEXT_APP_DIR)
    os.makedirs(os.path.join(app, "Contents", "MacOS"))
    with open(os.path.join(app, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "cmux NEXT", "CMUXCommit": commit}, f)
    with open(os.path.join(app, "Contents", "MacOS", "cmux NEXT"), "wb") as f:
        f.write(body)
    with open(os.path.join(app, "Contents", "MacOS", "cmux"), "wb") as f:  # a helper tool sorted before it
        f.write(b"\0tool")
    return app


def story_patterns():
    doc = json.loads(STORY_FILE.read_text())
    return [(re.compile(m["name"]), m["unit"]) for m in doc["metrics"]]


class NoDebugRequests(unittest.TestCase):
    def test_source_names_no_debug_method(self):
        tree = ast.parse(SCRIPT.read_text())
        named = [node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str)
                 and re.match(r"^debug\.[a-z_]", node.value)]
        self.assertEqual(named, [], "a debug.* method name in the story")

    def test_rpc_refuses_debug_before_the_socket(self):
        sent = []
        with tempfile.TemporaryDirectory() as tmp:
            app = story.NightlyApp(make_bundle(tmp), tmp, teardown=mock.Mock(),
                                   rpc_at=lambda path, method, params, timeout: sent.append(method) or {})
            with self.assertRaises(ValueError):
                app.rpc("debug.hangs", {"limit": 0})
            with self.assertRaises(ValueError):
                app.call("debug.cef")
            app.rpc("system.ping")
        self.assertEqual(sent, ["system.ping"])

    def test_call_shapes_replies_for_bench_idle(self):
        replies = iter([{"error": {"code": "timeout"}}, {"topology": {"workspaces": [1, 2, 3]}}])
        with tempfile.TemporaryDirectory() as tmp:
            app = story.NightlyApp(make_bundle(tmp), tmp, teardown=mock.Mock(),
                                   rpc_at=lambda path, method, params, timeout: next(replies))
            self.assertEqual(app.call("action.run", {"action": "newTab"}), {"error": {"code": "timeout"}})
            self.assertEqual(story.bench_idle().workspace_count(app), 3)

    def test_environment_is_the_bench_env_on_its_own_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = story.NightlyApp(make_bundle(tmp), tmp, teardown=mock.Mock())
            with mock.patch.dict(os.environ, {"CMUX_SOCKET_PATH": "/tmp/other.sock", "CMUX_NEXT_DEV_SENTRY": "1"}):
                env = app.environment()
            config = json.loads(Path(env["CMUX_NEXT_CONFIG_FILE"]).read_text())
        self.assertEqual(env["CMUX_NEXT_SOCKET_PATH"], app.socket)
        self.assertEqual(env["CMUX_NEXT_NO_ACTIVATE"], "1")
        self.assertNotIn("CMUX_SOCKET_PATH", env)
        self.assertNotIn("CMUX_NEXT_DEV_SENTRY", env)
        self.assertIs(config["updates"]["checkAutomatically"], False)


class VerifyBeforeLaunch(unittest.TestCase):
    def test_receipt_must_name_the_downloaded_bytes(self):
        calls = []

        def run(argv, **_):
            calls.append(argv)
            return done(stdout=f"verified {DIGEST} x.dmg\n")
        self.assertEqual(story.verify_dmg("/x.dmg", DIGEST, run), f"verified {DIGEST} x.dmg")
        self.assertEqual(calls[0][1:], [story.VERIFY_DMG, "/x.dmg", "next", "--require-stapled-app"])
        with self.assertRaisesRegex(story.Refused, "downloaded DMG is"):
            story.verify_dmg("/x.dmg", "c" * 64, run)
        with self.assertRaisesRegex(story.Refused, "exit 1"):
            story.verify_dmg("/x.dmg", DIGEST, lambda argv, **_: done(1, stderr="spctl: rejected"))

    def test_prepare_verifies_before_it_mounts(self):
        calls = []
        with tempfile.TemporaryDirectory() as tmp:
            dmg = os.path.join(tmp, "n.dmg")
            Path(dmg).write_bytes(b"dmg")

            def run(argv, **_):
                calls.append(os.path.basename(argv[1] if argv[0] == "/bin/bash" else argv[0]))
                return done(1, stderr="not stapled")
            opts = story.parse_args(["--out", tmp, "--dmg", dmg])
            with self.assertRaises(story.Refused):
                story.prepare(opts, tmp, run)
        self.assertEqual(calls, ["verify-dmg-artifact.sh"])

    def test_copy_refuses_a_dmg_that_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            dmg = os.path.join(tmp, "n.dmg")
            Path(dmg).write_bytes(b"dmg")

            def run(argv, **_):
                if argv[1] == "attach":
                    os.makedirs(os.path.join(argv[-1], story.NEXT_APP_DIR))
                elif argv[1] == "detach":
                    os.rmdir(os.path.join(argv[2], story.NEXT_APP_DIR))
                return done()
            with self.assertRaisesRegex(story.Refused, "changed while it was mounted"):
                story.copy_app(dmg, tmp, DIGEST, run)

    def test_check_app_runs_codesign_and_spctl_on_the_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = make_bundle(tmp)
            calls = []
            info = story.check_app(app, lambda argv, **_: calls.append(argv[0]) or done())
            self.assertEqual(info, {"bundle_id": story.NEXT_BUNDLE_ID, "sha": SHA, "config": "release"})
            self.assertEqual(calls, ["/usr/bin/codesign", "/usr/sbin/spctl"])
            with self.assertRaisesRegex(story.Refused, "codesign refused"):
                story.check_app(app, lambda argv, **_: done(1, stderr="a sealed resource is missing"))

    def test_check_app_refuses_other_bundles(self):
        ok = lambda argv, **_: done()  # noqa: E731
        for name, kwargs, reason in (("other", {"bundle_id": "com.cmuxterm.app.nightly"}, "not cmux NEXT"),
                                     ("bench", {"body": b"CMUX_BENCH_HOOKS_BUILD"}, "not a Release bundle"),
                                     ("unstamped", {"commit": ""}, "commit stamp")):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                with self.assertRaisesRegex(story.Refused, reason):
                    story.check_app(make_bundle(tmp, **kwargs), ok)

    def test_main_never_launches_a_refused_dmg(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(story, "host_problem"), \
                mock.patch.object(story, "prepare", side_effect=story.Refused("spctl rejected")), \
                mock.patch.object(story, "NightlyApp") as launched:
            code = story.main(["--out", tmp, "--dmg", os.path.join(tmp, "n.dmg")])
            summary = json.loads(Path(tmp, story.SUMMARY).read_text())
        self.assertEqual(code, story.EXIT_REFUSED)
        launched.assert_not_called()
        self.assertEqual(summary["refused"], "spctl rejected")

    def test_fetch_refuses_a_failed_download(self):
        def opener(url, timeout):
            raise OSError("404")
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(story.Refused, "cannot download"):
                story.fetch(story.DMG_URL, tmp, opener)


class Launches(unittest.TestCase):
    def line(self, pid, message, name="launch.mark", event="signpostEvent"):
        return json.dumps({"eventType": event, "subsystem": story.SUBSYSTEM, "category": "launch",
                           "signpostName": name, "processID": pid, "eventMessage": message})

    def test_launch_event(self):
        self.assertEqual(story.launch_event(self.line(7, "first_window_frame_committed ms=412.5")),
                         (7, "first_window_frame_committed", 412.5))
        self.assertEqual(story.launch_event(json.dumps({"eventType": "lossEvent"})), "lost")
        self.assertIsNone(story.launch_event(self.line(7, "x ms=1", name="launch.main")))
        self.assertIsNone(story.launch_event("Filtering the log data"))

    def test_metrics_keep_complete_runs_and_count_the_rest(self):
        marks = {m: 10.0 * (i + 1) for i, m in enumerate(story.LAUNCH_MARKS)}
        runs = [{"mode": "cold", "marks": marks, "lost": 0, "error": None},
                {"mode": "cold", "marks": marks, "lost": 2, "error": None},
                {"mode": "warm", "marks": {"main_start": 1.0}, "lost": 0, "error": None},
                {"mode": "warm", "marks": marks, "lost": 0, "error": None}]
        metrics = story.launch_metrics(runs)
        self.assertEqual(metrics["release.launch.cold.first_window_frame_committed"], [30.0])
        self.assertEqual(metrics["release.launch.cold.missing_runs"], [1.0])
        self.assertEqual(metrics["release.launch.warm.main_start"], [10.0])
        self.assertEqual(metrics["release.launch.warm.missing_runs"], [1.0])

    def test_no_cold_run_without_the_purge(self):
        app = mock.Mock()
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(story, "launch_run", side_effect=lambda a, mode, f: {"mode": mode}):
            leg = story.launch_leg(app, 2, True, tmp, purger=lambda: "sudo: a password is required")
        self.assertEqual([r["mode"] for r in leg["runs"]], ["warm", "warm"])
        self.assertEqual(len(leg["problems"]), 2)

    def test_fresh_state_keeps_one_earlier_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            for relative in story.STATE_ROOTS:
                os.makedirs(os.path.join(tmp, relative, "tui"))
            self.assertEqual(len(story.fresh_state(tmp)), 2)
            os.makedirs(os.path.join(tmp, story.STATE_ROOTS[0]))
            story.fresh_state(tmp)
            self.assertFalse(os.path.exists(os.path.join(tmp, story.STATE_ROOTS[0])))
            self.assertFalse(os.path.exists(os.path.join(tmp, story.STATE_ROOTS[0] + story.PREV_SUFFIX, "tui")))

    def test_other_next_processes(self):
        own = "/work/cmux NEXT.app"
        table = (f"10 {own}/Contents/MacOS/cmux NEXT\n11 {own}/Contents/Resources/bin/cmux-tui --headless\n"
                 "12 /Applications/cmux NEXT.app/Contents/MacOS/cmux NEXT\n13 /bin/zsh\n")
        with mock.patch.object(story.os.path, "realpath", side_effect=lambda p: p):
            self.assertEqual(story.other_next_processes(own, table), [12])


class Session(unittest.TestCase):
    def test_idle_metrics(self):
        Usage = story.bench_idle().procs.Usage
        rows = [{"pid": 1, "kind": "app", "cpu_percent": 0.4, "wakeups_per_s": 3.0},
                {"pid": 2, "kind": "daemon", "cpu_percent": 0.1, "wakeups_per_s": 1.0},
                {"pid": 3, "kind": "cef-renderer", "cpu_percent": 0.2, "wakeups_per_s": 2.0},
                {"pid": 4, "kind": "cef-gpu", "partial": True, "note": "exited during the window"}]
        end = {1: Usage(footprint=100), 2: Usage(footprint=50), 3: Usage(footprint=25), 4: None}
        metrics = story.idle_metrics(rows, end)
        self.assertEqual(metrics["release.idle.tabs-10.app_wakeups_per_s"], 3.0)
        self.assertEqual(metrics["release.idle.tabs-10.helper_wakeups_per_s"], 2.0)
        self.assertEqual(metrics["release.idle.tabs-10.daemon_cpu_percent"], 0.1)
        self.assertEqual(metrics["release.memory.tabs-10.app_footprint"], 100.0)
        self.assertEqual(metrics["release.memory.tabs-10.total_footprint"], 175.0)
        partial = story.idle_metrics([dict(rows[0], partial=True)], {})
        self.assertNotIn("release.idle.tabs-10.app_wakeups_per_s", partial)

    def test_page_problems_need_no_debug_cef(self):
        pages = mock.Mock(loaded={"t0", "t1"}, vendors={"t0": "Google Inc.", "t1": "Apple Computer, Inc."},
                          visibility={"t0": "hidden", "t1": "visible"})
        problems = story.page_problems("chromium", {1: "app"}, pages, ["t0", "t1"])
        self.assertTrue(any("navigator.vendor" in p for p in problems))
        self.assertIn("no Chromium renderer process", problems)
        pages.vendors["t1"] = "Google Inc."
        self.assertEqual(story.page_problems("chromium", {1: "app", 2: "cef-renderer"}, pages, ["t0", "t1"]), [])

    def test_action_rounds_read_the_always_on_signposts(self):
        sp = story.signposts()
        sent = []
        app = mock.Mock(rpc=lambda method, params=None, timeout=60: sent.append((method, params["action"])) or {})
        recording = mock.Mock(stop=lambda: sp.SAMPLE.splitlines())
        with mock.patch.object(story.time, "sleep"):
            result = story.action_rounds(app, 1, 2, recording_factory=lambda pid, categories: recording)
        self.assertEqual([action for _, action in sent], list(story.ACTIONS) * 2)
        self.assertEqual({method for method, _ in sent}, {"action.run"})
        self.assertEqual(sorted(result["metrics"]), ["release.action.commit", "release.action.perform"])
        self.assertEqual(result["lost"], 1)


class Results(unittest.TestCase):
    def test_every_metric_the_story_writes_is_in_its_catalog_entry(self):
        Usage = story.bench_idle().procs.Usage
        marks = {m: 1.0 for m in story.LAUNCH_MARKS}
        names = set(story.launch_metrics([{"mode": m, "marks": marks, "lost": 0, "error": None} for m in story.MODES]))
        rows = [{"pid": 1, "kind": k, "cpu_percent": 1.0, "wakeups_per_s": 1.0} for k in ("app",)] + [
            {"pid": 2, "kind": "daemon", "cpu_percent": 1.0, "wakeups_per_s": 1.0},
            {"pid": 3, "kind": "cef-renderer", "cpu_percent": 1.0, "wakeups_per_s": 1.0}]
        names |= set(story.idle_metrics(rows, {1: Usage(footprint=1)}))
        names |= {f"{story.PREFIX}{name}" for name in story.ACTION_SERIES}
        patterns = story_patterns()
        for name in sorted(names):
            with self.subTest(name):
                units = [unit for pattern, unit in patterns if pattern.fullmatch(name)]
                self.assertEqual(units, [story.unit_of(name)])
        self.assertEqual(len(names), 2 * 4 + 6 + 2 + 2)

    def test_recorder_writes_release_result_v1(self):
        host = {"fingerprint": "f" * 64, "class": "m6-16gb-120hz", "chip": "Apple M4", "macos": "26.1",
                "macos_build": "25B78", "display_hz": 120.0}
        build = story.perf_result.Build(sha=SHA, config="release", measure_version=2)
        with tempfile.TemporaryDirectory() as tmp:
            recorder = story.Recorder(tmp, build, lambda: host, "light")
            path = recorder.record("release.action.commit", "ms", [1.0, 2.0], "chromium",
                                   ({"tabFreeze": {"state": "on", "source": "default"}}, "h" * 8, "off"))
            (result,) = story.perf_result.read_file(path)
            with self.assertRaises(story.LegError):
                recorder.record("release.action.commit", "ms", [1.0], "chromium", None)
        self.assertEqual((result.story, result.build.config, result.build.sha), ("shipped-nightly", "release", SHA))


class Catalog(unittest.TestCase):
    def test_story_lints_and_takes_the_runner_flags(self):
        loaded = catalog.load_catalog(ROOT)
        entry = next(s for s in loaded.stories if s.id == "shipped-nightly")
        self.assertEqual([p for p in loaded.problems if "shipped-nightly" in p], [])
        self.assertEqual(entry.config, "release")
        self.assertFalse(entry.measurable())  # until the scheduler has a no-build lane
        self.assertEqual(run_story.contract_problems(entry, str(ROOT)), [])

    def test_runner_flags_parse(self):
        opts = story.parse_args(["--app", "/x/cmux DEV t.app", "--tag", "t", "--out", "/tmp/o", "--purge"])
        self.assertEqual((opts.legs, opts.dmg_url, opts.purge), (["launch", "session"], story.DMG_URL, True))


if __name__ == "__main__":
    unittest.main()
