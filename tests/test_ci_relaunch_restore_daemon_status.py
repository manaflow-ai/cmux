#!/usr/bin/env python3
"""The relaunch check reads the daemon's `acpmux status --json` whole.

`acpmux status --json` prints one indented JSON document over many lines. The first version of
scripts/ci/relaunch_restore_check.py's `daemon_status` parsed only the last line (`}`), so every daemon phase and
the session count in its phase table came out blank (cmux#45697 review F1). `status_json` reads the document from its
first `{` line on, past a notice line before it.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import relaunch_restore_check as check  # noqa: E402

STATUS = {
    "ok": True,
    "value": {
        "sessions": 3,
        "gauges": {"startup": {"bornEpochMs": 1795000000000, "phases": [{"name": "socket ready", "atMs": 5}]}},
    },
}


class StatusJson(unittest.TestCase):
    def test_an_indented_answer_is_read_whole(self) -> None:
        text = json.dumps(STATUS, indent=2) + "\n"
        self.assertEqual(text.strip().splitlines()[-1], "}")
        self.assertEqual(check.status_json(text), STATUS)
        self.assertEqual(check.unwrap(check.status_json(text))["sessions"], 3)

    def test_a_notice_line_before_the_answer_is_skipped(self) -> None:
        text = "acpmux: a newer build is installed\n" + json.dumps(STATUS, indent=2)
        self.assertEqual(check.status_json(text), STATUS)

    def test_a_one_line_answer_still_reads(self) -> None:
        self.assertEqual(check.status_json(json.dumps(STATUS)), STATUS)

    def test_no_answer_is_none(self) -> None:
        for text in ("", "\n", "not json\n", "{ broken\n", "[1, 2]\n"):
            with self.subTest(text=text):
                self.assertIsNone(check.status_json(text))


if __name__ == "__main__":
    unittest.main()
