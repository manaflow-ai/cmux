#!/usr/bin/env python3
"""Portable checks for rendered-chat evidence and WebKit PID attribution."""
import importlib.util
import argparse
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import MagicMock, patch


spec = importlib.util.spec_from_file_location("memory_chat_bench", Path(__file__).resolve().parents[1] / "bench_memory.py")
bm = importlib.util.module_from_spec(spec)
with patch("ctypes.CDLL", return_value=MagicMock()):
    spec.loader.exec_module(bm)


class ChatMeasurements(unittest.TestCase):
    def setUp(self):
        bm._observed_webkit.clear()
        self.chats = bm.FakeChats.__new__(bm.FakeChats)
        self.chats.app = MagicMock()
        self.chats.app_pid = 50
        self.chats.expected_engine = "default"
        self.chats.sessions = {"ws_chat": "session_expected"}
        self.chats.pages = {}

    def test_observation_waits_for_the_expected_session_before_capturing_pid(self):
        self.chats.app.rpc.side_effect = [
            {"pane": "pane_chat", "sessionId": "session_previous", "lastAssistant": {"text": "previous"}},
            {"pane": "pane_chat", "sessionId": "session_expected", "lastAssistant": {"text": "answer"}, "rows": 2},
            {"pane": "pane_chat", "engine": "webkit:own-host"},
            {"pane": "pane_chat", "pid": 70},
        ]
        with patch.object(bm, "process_table", return_value=[(70, 1, "com.apple.WebKit.WebContent")]), \
                patch.object(bm, "process_started", return_value="birth"), patch.object(bm.time, "sleep"):
            self.chats.observe("ws_chat")
        self.assertEqual(self.chats.pages["ws_chat"]["session"], "session_expected")
        self.assertEqual(self.chats.pages["ws_chat"]["renderer_pid"], 70)
        self.assertEqual(bm._observed_webkit, {50: {70: "birth"}})

    def test_observed_renderer_is_counted_when_launch_responsibility_is_elsewhere(self):
        bm._observed_webkit[50] = {70: "birth"}
        with patch.object(bm, "process_table", return_value=[(70, 1, "com.apple.WebKit.WebContent")]), \
                patch.object(bm, "_responsible", return_value=999), \
                patch.object(bm, "process_started", return_value="birth"):
            self.assertIn(70, bm.owned(50, "/app"))
            self.assertNotIn(70, bm.owned(51, "/app"))

    def test_explicit_webkit_run_rejects_a_real_chromium_page(self):
        self.chats.expected_engine = "webkit"
        self.chats.app.rpc.side_effect = [
            {"pane": "pane_chat", "sessionId": "session_expected", "lastAssistant": {"text": "answer"}},
            {"pane": "pane_chat", "engine": "cef"},
        ]
        with self.assertRaisesRegex(RuntimeError, "expected webkit, rendered cef"):
            self.chats.observe("ws_chat")
        self.assertEqual(self.chats.pages, {})

    def test_chromium_is_verified_from_the_rendered_page(self):
        self.chats.expected_engine = "chromium"
        self.chats.app.rpc.side_effect = [
            {"pane": "pane_chat", "sessionId": "session_expected", "lastAssistant": {"text": "answer"}},
            {"pane": "pane_chat", "engine": "cef"},
        ]
        self.chats.observe("ws_chat")
        self.assertEqual(self.chats.pages["ws_chat"]["engine"], "cef")

    def test_reused_pid_is_excluded(self):
        bm._observed_webkit[50] = {70: "birth"}
        with patch.object(bm, "process_table", return_value=[(70, 1, "com.apple.WebKit.WebContent")]), \
                patch.object(bm, "_responsible", return_value=999), \
                patch.object(bm, "process_started", return_value="later birth"):
            self.assertNotIn(70, bm.owned(50, "/app"))

    def test_chat_count_and_distinct_surviving_renderers_are_separate(self):
        self.chats.sessions["ws_other"] = "session_other"
        self.chats.pages = {w: {"engine": "webkit:own-host", "renderer_pid": 70} for w in self.chats.sessions}
        result = {"processes": [], "kinds": {}}
        got = self.chats.observation(["ws_chat", "ws_other"], result)
        self.assertEqual(got["count"], 2)
        self.assertEqual(got["rendered_count"], 2)
        self.assertEqual(got["observed_webkit_renderer_pids"], [70])
        self.assertEqual(got["surviving_webkit_renderer_pids"], [])
        self.assertEqual(got["webkit_webcontent_count"], 0)

    def test_unrendered_chat_fails_instead_of_silently_lowering_counts(self):
        with self.assertRaisesRegex(RuntimeError, "never observed rendering"):
            self.chats.observation(["ws_chat"], {"processes": [], "kinds": {}})


class MatchedConfiguration(unittest.TestCase):
    def test_boolean_launch_overrides_are_kept_exactly(self):
        for enabled in [False, True]:
            config = {"agents": {"chatPages": {"enabled": enabled}}}
            self.assertEqual(bm.config_object(json.dumps(config)), config)

    def test_bad_launch_config_is_rejected(self):
        for text in ["[]", "null", "true", '"text"', "not JSON"]:
            with self.subTest(text=text), self.assertRaises(argparse.ArgumentTypeError):
                bm.config_object(text)

    @staticmethod
    def parser_source():
        # Run the wrapper's real argument parser, stopping before its first
        # filesystem/build command so this check is portable and cheap.
        script = Path(__file__).resolve().parents[2] / "measure" / "perf-10x-idle.sh"
        source = script.read_text().split('root="$(git rev-parse --show-toplevel)"', 1)[0]
        return source

    def preflight(self, *args, output='printf "%s\\n" "$agents_settle" "$agents_config" "$agents_name"'):
        source = self.parser_source()
        self.assertNotIn("scripts/reload.sh --tag", source)
        return subprocess.run(["bash", "-c", source + '\n' + output,
                               "preflight", *args], capture_output=True, text=True)

    def test_variants_have_the_same_idle_age_and_distinct_artifacts(self):
        for variant, enabled in [("off", False), ("on", True)]:
            result = self.preflight("agents_settle=370", f"agents_hibernation={variant}")
            self.assertEqual(result.returncode, 0, result.stderr)
            settle, config, name = result.stdout.splitlines()
            self.assertEqual(settle, "370")
            self.assertEqual(json.loads(config), {"agents": {"chatPages": {"enabled": enabled}}})
            self.assertEqual(name, f"agents-{variant}")

    def test_existing_default_artifact_and_idle_age_are_preserved(self):
        result = self.preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["20", "{}", "agents"])

    def test_explicit_engine_composes_with_both_policy_variants(self):
        for engine in ["webkit", "chromium"]:
            for policy, enabled in [("off", False), ("on", True)]:
                result = self.preflight(f"agents_hibernation={policy}", f"agents_engine={engine}")
                self.assertEqual(result.returncode, 0, result.stderr)
                _, config, name = result.stdout.splitlines()
                self.assertEqual(json.loads(config), {"agents": {"chatPages": {"enabled": enabled}},
                                                      "browser": {"defaultEngine": engine}})
                self.assertEqual(name, f"agents-{policy}-{engine}")

    def test_invalid_engine_fails_before_build_or_filesystem_changes(self):
        result = self.preflight("agents_engine=guess")
        self.assertEqual(result.returncode, 2)
        self.assertIn("agents_engine must be default, webkit or chromium", result.stderr)

    def test_invalid_variant_fails_before_build_or_filesystem_changes(self):
        result = self.preflight("agents_hibernation=maybe")
        self.assertEqual(result.returncode, 2)
        self.assertIn("agents_hibernation must be default, off or on", result.stderr)

    def test_wake_mode_selects_a_bench_build_without_policy_overrides(self):
        result = self.preflight("agents_wake=on", output='printf "%s\\n" "$agents_wake" "${reload_config[1]}" "$agents_config"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["on", "bench", "{}"])

    def test_wake_mode_rejects_an_incompatible_build_or_measurement(self):
        for arg in ["--config=Release", "agents=2,6,21", "agents_hibernation=off", "agents_engine=chromium"]:
            with self.subTest(arg=arg):
                result = self.preflight("agents_wake=on", arg)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_invalid_wake_mode_fails_before_build(self):
        result = self.preflight("agents_wake=maybe")
        self.assertEqual(result.returncode, 2)
        self.assertIn("agents_wake must be off or on", result.stderr)

    def test_wake_runner_keeps_failure_status_and_packages_the_available_evidence(self):
        # Execute the actual wrapper function with only its app driver replaced;
        # no macOS libraries, app, compile or measurement runs on this host.
        for status in [0, 1]:
            with self.subTest(status=status), tempfile.TemporaryDirectory(prefix="wake evidence ") as folder:
                fixture = '''
work="$WAKE_TEST_WORK"
app="/isolated app/cmux.app"
python3() {
  [[ "$CMUX_BENCH_LAUNCH" == direct && "$#" == 5 && "$1" == scripts/cmux-next/hidden-chat-wake.py && "$2" == --app && "$3" == "$app" && "$4" == --out && "$5" == "$work/hidden-chat-wake" ]] || return 90
  printf '{"test_result": %s}\\n' "$WAKE_TEST_STATUS" > "$5/report.json"
  echo "proof result=$WAKE_TEST_STATUS"
  return "$WAKE_TEST_STATUS"
}
run_agents_wake
'''
                result = subprocess.run(["bash", "-c", self.parser_source() + fixture, "wake-test", "agents_wake=on"],
                                        capture_output=True, text=True,
                                        env={**os.environ, "WAKE_TEST_WORK": folder, "WAKE_TEST_STATUS": str(status)})
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(f"proof result={status}", result.stdout)
                with tarfile.open(Path(folder) / "hidden-chat-wake.tar.gz") as archive:
                    self.assertEqual(json.load(archive.extractfile("./report.json")), {"test_result": status})
                    self.assertIn(f"proof result={status}", archive.extractfile("./check.log").read().decode())


if __name__ == "__main__":
    unittest.main()
