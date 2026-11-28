"""scripts/measure/crash-notice-nightly.py reads the restart notice the way the app exposes it.

The notice is a CmuxToast (CrashRecoveryService.presentRestartNotice): an AXGroup whose AXDescription
is the message and whose AXIdentifier is cmux.toast.app.restartNotice, with buttons that carry their
title as AXDescription. The probe once looked only at AXStaticText values and AXButton names, so on
2026-11-27 (run 46051482809, NIGHTLY 4598798383801) it read the notice as missing while its own
screenshot showed it with its Report button.
"""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "crash_notice_nightly", os.path.join(HERE, "..", "scripts", "measure", "crash-notice-nightly.py"))
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def row(role, ident="", description="", title="", value=""):
    return "\t".join([role, ident, description, title, value])


class ReadNoticeTests(unittest.TestCase):
    def test_toast_group_and_report_button_by_identifier(self):
        listing = "\n".join([
            row("AXGroup", "cmux.toast.app.restartNotice", "cmux restarted after a problem. Cause: SIGSEGV"),
            row("AXButton", "cmux.toast.app.restartNotice.secondary", "Show Crash Log"),
            row("AXButton", "cmux.toast.app.restartNotice.action", "Report"),
            row("AXButton", "cmux.toast.app.restartNotice.close", "Close"),
        ])
        seen = probe.read_notice(listing)
        self.assertEqual(seen["text"], "cmux restarted after a problem. Cause: SIGSEGV")
        self.assertTrue(seen["report_button"])

    def test_static_text_value_still_counts(self):
        listing = "\n".join([row("AXStaticText", value="cmux restarted after a problem."),
                             row("AXButton", title="Report")])
        self.assertEqual(probe.read_notice(listing),
                         {"text": "cmux restarted after a problem.", "report_button": True})

    def test_no_notice(self):
        listing = "\n".join([row("AXStaticText", value="Chief"), row("AXButton", description="Continue"),
                             row("AXButton", "cmux.toast.other.action", "Show Crash Log")])
        self.assertEqual(probe.read_notice(listing), {"text": None, "report_button": False})

    def test_short_rows_are_padded(self):
        self.assertEqual(probe.read_notice("AXGroup\tcmux.toast.app.restartNotice"),
                         {"text": None, "report_button": False})


if __name__ == "__main__":
    unittest.main()
