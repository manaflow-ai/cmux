"""A route-only success must never close the chat-widget drawing row."""
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("chat_integration_driver", Path(__file__).with_name("ext-rows-nightly.py"))
driver = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = driver
spec.loader.exec_module(driver)


class ChatDrawingIntegrationTests(unittest.TestCase):
    def run_row(self, drawing_checks, route_ok=True, control="isolated"):
        fixture = SimpleNamespace(row_chat_widget_drawn=Mock(return_value={"checks": drawing_checks}))
        with patch.object(driver, "row_chat_widget_routes", return_value={"checks": {"matched": route_ok}}), \
                patch.object(driver, "load", return_value=fixture), contextlib.redirect_stdout(io.StringIO()):
            result = driver.run_rows(SimpleNamespace(control=control), ["chat_widget"])["chat_widget"]
        return result, fixture

    def test_route_success_cannot_hide_failed_or_missing_drawing(self):
        for checks in ({"drawn": False}, {}):
            with self.subTest(checks=checks):
                result, _ = self.run_row(checks)
                self.assertFalse(result["ok"])

    def test_drawing_success_cannot_hide_route_failure(self):
        result, _ = self.run_row({"drawn": True}, route_ok=False)
        self.assertFalse(result["ok"])

    def test_both_required_evidence_sets_pass(self):
        result, fixture = self.run_row({"drawn": True})
        self.assertTrue(result["ok"])
        fixture.row_chat_widget_drawn.assert_called_once()

    def test_headless_mode_is_skipped_not_proven(self):
        result, fixture = self.run_row({"drawn": True}, control=None)
        self.assertIsNone(result["ok"])
        self.assertIn("skipped", result)
        fixture.row_chat_widget_drawn.assert_not_called()


fixture = driver.load("chat_drawing_fixture_test", Path(__file__).with_name("ext-rows-chat-widget.py"))


class ChatFixtureEvidenceTests(unittest.TestCase):
    def test_bundled_cli_creates_local_session_and_rejects_failed_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / "Contents/Resources/bin/acpmux"
            cli.parent.mkdir(parents=True)
            cli.touch(mode=0o700)
            ctx = SimpleNamespace(app=root, work=root, rpc=Mock(side_effect=[
                {}, {"created": ["ws_fixture"]}, {}, {}]))
            with patch.object(fixture, "_agent_script", return_value=root / "agent.py"), \
                    patch.object(fixture, "_acpmux_socket", return_value="isolated.sock"), \
                    patch.object(fixture, "_read_completed_tool", return_value={"ok": True}) as completed, \
                    patch.object(fixture.subprocess, "run", return_value=SimpleNamespace(
                        returncode=0, stdout='{"sessionId":"fixture-session"}', stderr="")) as run:
                ctx.rpc.side_effect = [{"ok": True}, {"created": ["ws_fixture"]}, {}, {"ok": True}]
                self.assertTrue(fixture._start_transcript(ctx)["ok"])
                argv = run.call_args.args[0]
                self.assertEqual(argv[:2], [str(cli), "new"])
                self.assertEqual(argv[argv.index("--machine") + 1], "local")
                self.assertEqual(run.call_args.kwargs["env"]["ACPMUX_SOCKET"], "isolated.sock")
                run.return_value.returncode = 1
                self.assertFalse(fixture._start_transcript(ctx)["ok"])
                completed.assert_called_once()

    def event(self, kind, status, title="mcp__rowsprobe__get_thing", tool="widget-proof-tool"):
        return json.dumps({"dir": "in", "msg": {"method": "session/update", "params": {
            "update": {"sessionUpdate": kind, "status": status, "title": title, "toolCallId": tool}}}})

    def test_only_the_expected_completed_tool_passes(self):
        start = self.event("tool_call", "in_progress")
        done = self.event("tool_call_update", "completed")
        self.assertTrue(fixture._completed_tool_events(start + "\n" + done))
        for text in ("", start, done, start + "\n" + self.event("tool_call_update", "failed"),
                     self.event("tool_call", "completed", title="other"),
                     self.event("tool_call", "completed", tool="other"),
                     start + "\n" + done + "\nnot json"):
            with self.subTest(text=text):
                self.assertFalse(fixture._completed_tool_events(text))

    def test_final_status_overrules_earlier_completion(self):
        events = [self.event("tool_call", "completed"), self.event("tool_call_update", "failed")]
        self.assertFalse(fixture._completed_tool_events("\n".join(events)))

    def test_capture_refusal_cannot_pass_or_use_another_capture_path(self):
        base = SimpleNamespace(install_customize=Mock(return_value={"installed": True}),
                               capture_marker=Mock(return_value={"drawn": False, "error": "computer_use_off"}))
        ctx = SimpleNamespace(token="test12345")
        with patch.object(fixture, "_enable_running_copy", return_value={"ok": True}), \
                patch.object(fixture, "_start_transcript", return_value={"ok": True}), \
                patch.object(fixture, "_chat_views", return_value=[{"status": "ready"}]):
            result = fixture.row_chat_widget_drawn(ctx, base)
        self.assertFalse(result["checks"]["drawn_capture"])
        base.capture_marker.assert_called_once_with(ctx, "chat-widget", "CHATWIDGETDRAWNest12345")


if __name__ == "__main__":
    unittest.main()
