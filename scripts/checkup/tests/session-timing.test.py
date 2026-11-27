#!/usr/bin/env python3
"""session-timing.py's checks on stand-in `acpmux history --json` answers, and its CLI on a stand-in acpmux.

The checks: a clean history reads clean with its p50/p95/max and idle time; a missing stamp counts as unknown,
never zero, and a measured zero stays zero; each broken invariant (another session's id, ended before start, wall
not end minus start, phases longer than the turn, negative or repeated values) is a finding; the send budget flags
a slow send and 0 turns it off; an unreadable history exits 2, never 0; a name and an id of one chat read once.
Run: python3 -I scripts/checkup/tests/session-timing.test.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "session-timing.py"
spec = importlib.util.spec_from_file_location("session_timing", SCRIPT)
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)

SID = "01a201a9-4d25-70d6-8406-37e6b3fff598"


def turn(seq, started, wall=None, send=None, first=None, **extra):
    t = {"seq": seq, "startedAt": started, "prompt": "p", "status": "completed" if wall is not None else "running"}
    if wall is not None:
        t["endedAt"] = started + wall
        t["wallMs"] = wall
    if send is not None:
        t["toAgentMs"] = send
    if first is not None:
        t["firstModelMs"] = first
    t.update(extra)
    return t


def kinds(report):
    return sorted(f["kind"] for f in report["findings"])


class CheckHistory(unittest.TestCase):
    def test_clean_history_breakdown(self):
        history = {
            "sessionId": SID,
            "turns": [
                turn(1, 1_000, wall=10_000, send=5, first=2_000, agentStart={"firstPromptMs": 400, "readyMs": 390, "steps": []}),
                turn(2, 20_000, wall=4_000, send=1, first=1_500),
                turn(3, 30_000, send=3),
            ],
        }
        report = st.check_history(history, SID)
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["turns"], 3)
        self.assertEqual(report["open"], 1)
        self.assertEqual(report["sendDelayMs"], {"n": 3, "p50": 3.0, "p95": 5.0, "max": 5.0})
        self.assertEqual(report["firstOutputMs"]["max"], 2_000.0)
        # Idle: 11_000 -> 20_000 and 24_000 -> 30_000.
        self.assertEqual(report["idleMs"], 15_000)
        self.assertEqual(report["agentStart"]["firstPromptMs"], 400)
        # The open turn has no first output yet: unknown, and its missing wall is not counted.
        self.assertEqual(report["unknown"], {"toAgentMs": 0, "firstModelMs": 1, "wallMs": 0})
        self.assertIn("clean", st.render(report))

    def test_missing_is_unknown_and_zero_stays_zero(self):
        report = st.check_history({"sessionId": SID, "turns": [turn(1, 0, wall=100, send=0), turn(2, 200, wall=100)]}, SID)
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["sendDelayMs"]["p50"], 0.0)
        self.assertEqual(report["unknown"]["toAgentMs"], 1)
        self.assertEqual(report["unknown"]["firstModelMs"], 2)
        self.assertIn("first output 2", st.render(report))
        self.assertEqual(st.fmt_ms(None), "unknown")

    def test_wrong_session_is_a_finding(self):
        report = st.check_history({"sessionId": "11111111-2222-3333-4444-555555555555", "turns": []}, SID)
        self.assertEqual(kinds(report), ["wrong_session"])
        # A name resolves to an id, so it is not compared.
        self.assertEqual(st.check_history({"sessionId": SID, "turns": []}, "coord")["findings"], [])

    def test_broken_invariants(self):
        history = {
            "sessionId": SID,
            "turns": [
                {"seq": 1, "startedAt": 5_000, "endedAt": 4_000, "wallMs": 0},
                turn(2, 10_000, wall=1_000, send=5) | {"wallMs": 999},
                turn(3, 20_000, wall=1_000, send=600, first=600),
                turn(4, 30_000, wall=1_000, send=-1),
                turn(4, 40_000, wall=1_000, first="soon"),
                {"seq": 6, "prompt": "no start"},
            ],
        }
        report = st.check_history(history, SID, send_budget_ms=0)
        self.assertEqual(
            kinds(report),
            ["bad_duration", "bad_duration", "bad_stamp", "ended_before_start", "phases_exceed_wall", "repeated_seq", "wall_mismatch"],
        )

    def test_budgets(self):
        history = {"sessionId": SID, "turns": [turn(1, 0, wall=60_000, send=2_500, first=40_000)]}
        self.assertEqual(kinds(st.check_history(history, SID)), ["slow_send"])
        self.assertEqual(kinds(st.check_history(history, SID, send_budget_ms=0)), [])
        self.assertEqual(
            kinds(st.check_history(history, SID, send_budget_ms=0, first_output_budget_ms=30_000)), ["slow_first_output"]
        )

    def test_not_a_history(self):
        self.assertFalse(st.check_history({"error": "x"}, SID)["readable"])


class Cli(unittest.TestCase):
    """The script end to end, on a stand-in `acpmux` first on PATH."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        bin_dir = Path(self.dir.name)
        history = {"sessionId": SID, "turns": [turn(1, 0, wall=1_000, send=2, first=300)]}
        (bin_dir / "history.json").write_text(json.dumps(history))
        fake = bin_dir / "acpmux"
        fake.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = ls ]; then echo \'{"sessions":[{"name":"coord"},{"name":"peer-host/far"},'
            '{"name":"relayed","peer":"huge-blue","via":"relay"}]}\'; exit 0; fi\n'
            'case "$2" in\n'
            f'  coord|{SID}) cat "{bin_dir}/history.json" ;;\n'
            '  *) echo \'{"error":{"message":"no session matches"}}\' >&2; exit 4 ;;\n'
            "esac\n"
        )
        fake.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}

    def tearDown(self):
        self.dir.cleanup()

    def run_script(self, *args):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, env=self.env, timeout=60)

    def test_clean_exits_zero_and_reads_one_chat_once(self):
        done = self.run_script("coord", SID)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(done.stdout.count("1 turns"), 1)
        self.assertIn(f"coord ({SID})", done.stdout)

    def test_unreadable_exits_two(self):
        done = self.run_script("coord", "missing")
        self.assertEqual(done.returncode, 2)
        self.assertIn("missing: UNREADABLE: no session matches", done.stdout)

    def test_all_skips_peer_chats_and_json_schema(self):
        done = self.run_script("--all", "--json")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        answer = json.loads(done.stdout)
        self.assertEqual(answer["schema"], "cmux-checkup-session-timing/v1")
        self.assertEqual([r["session"] for r in answer["reports"]], [SID])

    def test_from_file_findings_exit_one(self):
        bad = Path(self.dir.name) / "bad.json"
        bad.write_text(json.dumps({"sessionId": SID, "turns": [turn(1, 0, wall=10, send=50)]}))
        done = self.run_script("--from-file", str(bad))
        self.assertEqual(done.returncode, 1)
        self.assertIn("FINDING phases_exceed_wall", done.stdout)

    def test_no_arguments_is_usage(self):
        self.assertEqual(self.run_script().returncode, 2)


if __name__ == "__main__":
    unittest.main()
