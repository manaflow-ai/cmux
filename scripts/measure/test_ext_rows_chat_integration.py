"""A route-only success must never close the chat-widget drawing row."""
import contextlib
import importlib.util
import io
import sys
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


if __name__ == "__main__":
    unittest.main()
