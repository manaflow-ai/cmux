#!/usr/bin/env python3
"""chromium-host-crash-reporter.cfg (p01-process task 226): Crashpad for the Chromium Host keeps every dump on
this Mac. Read the way CEF reads crash_reporter.cfg (CefCrashReporterClient::ReadCrashConfigFile,
cef/libcef/common/crash_reporter_client.cc): a comment only on its own line, `[Config]` and `[CrashKeys]`
sections, `name=value` lines."""

from __future__ import annotations

import unittest
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "chromium-host-crash-reporter.cfg"
# The [Config] names CEF reads on macOS.
KNOWN = {"ProductName", "ProductVersion", "ServerURL", "RateLimitEnabled", "MaxUploadsPerDay", "MaxDatabaseSizeInMb",
         "MaxDatabaseAgeInDays", "BrowserCrashForwardingEnabled"}


def parse(text: str) -> dict[str, dict[str, str]]:
    sections: dict[str, dict[str, str]] = {}
    current = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = sections.setdefault(line[1:-1], {})
            continue
        if "=" not in line or current is None:
            raise ValueError(f"CEF skips this line: {raw!r}")
        name, value = line.split("=", 1)
        current[name.strip()] = value.strip()
    return sections


class CrashReporterConfigTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sections = parse(CONFIG.read_text())

    def test_no_upload(self) -> None:
        self.assertIn("ServerURL", self.sections["Config"], "say it: no ServerURL means no upload")
        self.assertEqual(self.sections["Config"]["ServerURL"], "")

    def test_the_hosts_crash_still_reaches_macos(self) -> None:
        # The .ips report SystemCrashForwarder sends and the app's crash recovery reads.
        self.assertEqual(self.sections["Config"]["BrowserCrashForwardingEnabled"].lower(), "true")

    def test_every_name_is_one_cef_reads(self) -> None:
        self.assertEqual(set(self.sections), {"Config"}, "no [CrashKeys]: cmux declares no crash key of its own")
        self.assertLessEqual(set(self.sections["Config"]), KNOWN)

    def test_the_database_is_bounded(self) -> None:
        self.assertGreater(int(self.sections["Config"]["MaxDatabaseSizeInMb"]), 0)
        self.assertGreater(int(self.sections["Config"]["MaxDatabaseAgeInDays"]), 0)

    def test_no_comment_after_a_value(self) -> None:
        # CEF reads `ServerURL= # none` as the value `# none`.
        for name, value in self.sections["Config"].items():
            self.assertNotIn("#", value, name)


if __name__ == "__main__":
    unittest.main()
