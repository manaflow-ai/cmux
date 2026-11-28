#!/usr/bin/env python3
"""Tests for scripts/ci/ios_app_build_agreement.py (RFD 0051 route 9 cutover count)."""
from __future__ import annotations

import io
import json
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_app_build_agreement as m  # noqa: E402


def line(sha="a" * 40, linux="pass", mac="pass", secs=300):
    agree = "none" if "none" in (linux, mac) else ("yes" if linux == mac else "no")
    body = {"sha": sha, "linux": linux, "linux_exit": "0", "linux_seconds": secs, "mac": mac, "agree": agree}
    # As Actions prints it: job, step, timestamp, then the line.
    return f"ios-fast\tBuild the changed iOS target\t2026-11-28T19:00:00.0Z IOS_APP_BUILD_AGREEMENT {json.dumps(body)}"


class AgreementTest(unittest.TestCase):
    def test_parses_actions_log_prefix(self):
        recs = m.records("noise\n" + line(sha="b" * 40) + "\nmore noise\n")
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]["sha"], "b" * 40)

    def test_five_agreeing_holds(self):
        v = m.judge(m.records("\n".join(line(secs=s) for s in (100, 200, 300, 400, 500))))
        self.assertEqual((v["verdict"], v["exit"], v["streak"], v["linux_seconds_median"]), ("holds", 0, 5, 300))

    def test_four_is_not_yet(self):
        v = m.judge(m.records("\n".join(line() for _ in range(4))))
        self.assertEqual((v["exit"], v["streak"]), (1, 4))

    def test_no_answer_is_not_counted_and_does_not_break_streak(self):
        text = "\n".join([line(), line(), line(linux="none"), line(), line(mac="none"), line(), line()])
        v = m.judge(m.records(text))
        self.assertEqual((v["counted"], v["no_answer"], v["streak"], v["exit"]), (5, 2, 5, 0))

    def test_fail_fail_agrees(self):
        v = m.judge(m.records("\n".join([line(linux="fail", mac="fail")] + [line()] * 4)))
        self.assertEqual(v["exit"], 0)

    def test_disagreement_is_exit_2_with_sha(self):
        text = "\n".join([line(sha="c" * 40, linux="fail", mac="pass")] + [line()] * 6)
        v = m.judge(m.records(text))
        self.assertEqual((v["exit"], v["streak"]), (2, 6))
        self.assertEqual(v["disagree"][0]["sha"], "c" * 40)

    def test_streak_resets_at_disagreement(self):
        text = "\n".join([line()] * 3 + [line(linux="pass", mac="fail")] + [line()] * 2)
        self.assertEqual(m.judge(m.records(text))["streak"], 2)

    def test_empty_is_not_yet(self):
        self.assertEqual(m.judge([])["exit"], 1)

    def test_bad_json_skipped(self):
        self.assertEqual(m.records("IOS_APP_BUILD_AGREEMENT {nope}\n"), [])

    def test_runs_read_through_gh(self):
        calls = []

        def fake(argv, **kw):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, stdout=line(sha=argv[3] * 40) + "\n", stderr="")

        out = io.StringIO()
        with redirect_stdout(out):
            code = m.main(["--run", "1", "--run", "2", "--need", "2"], run=fake)
        self.assertEqual(code, 0)
        self.assertEqual(calls[0], ["gh", "run", "view", "1", "--repo", "manaflow-ai/cmux", "--log"])
        self.assertIn("holds: 2/2", out.getvalue())

    def test_gh_failure_raises(self):
        def fake(argv, **kw):
            return subprocess.CompletedProcess(argv, 1, stdout="", stderr="not found")

        with self.assertRaises(RuntimeError):
            m.main(["--run", "9"], run=fake)

    def test_script_matches_verdict_line_format(self):
        script = (ROOT / "scripts/ci/ios_fast_verdict.sh").read_text()
        self.assertIn("printf 'IOS_APP_BUILD_AGREEMENT {\"sha\":", script)
        for key in ("linux", "linux_seconds", "mac", "agree"):
            self.assertIn(f'"{key}":', script)


if __name__ == "__main__":
    unittest.main()
