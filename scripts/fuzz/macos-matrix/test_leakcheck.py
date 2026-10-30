#!/usr/bin/env python3
"""leakcheck.parse on `leaks` output in its list and tree formats, and on its errors; the smoke's leaks row
through a fake guest.

python3 -I scripts/fuzz/macos-matrix/test_leakcheck.py (no Mac needed).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import leakcheck  # noqa: E402
import smoke  # noqa: E402

HEADER = """Process:         cmux DEV [4242]
Path:            /Applications/cmux DEV.app/Contents/MacOS/cmux DEV
leaks Report Version: 4.0
Process 4242: 812345 nodes malloced for 98765 KB
"""

LIST = HEADER + """Process 4242: 4 leaks for 240 total leaked bytes.

Leak: 0x600001e74000  size=128  zone: DefaultMallocZone_0x104a1c000   __NSDictionaryM  ObjC  CoreFoundation
Leak: 0x600001e74100  size=48  zone: DefaultMallocZone_0x104a1c000   __NSArrayM  ObjC  CoreFoundation
Leak: 0x600001e74200  size=48  zone: DefaultMallocZone_0x104a1c000   __NSArrayM  ObjC  CoreFoundation
Leak: 0x600001e74300  size=16  zone: DefaultMallocZone_0x104a1c000
"""

TREE = HEADER + """Process 4242: 3 leaks for 192 total leaked bytes.

    3 (192 bytes) << TOTAL >>

      2 (176 bytes) ROOT CYCLE: <CmuxNext.TabModel 0x600002f0c000> [160]
         1 (16 bytes) 0x600000c04010 [16]
            CYCLE BACK TO <CmuxNext.TabModel 0x600002f0c000> [160]

      1 (16 bytes) ROOT LEAK: <malloc in foo 0x600000c04020> [16]
"""

NONE = HEADER + "Process 4242: 0 leaks for 0 total leaked bytes.\n"


class ParseTest(unittest.TestCase):
    def test_list_format_counts_types_by_bytes(self):
        row = leakcheck.parse(LIST, 1)
        self.assertEqual((row["leaks"], row["bytes"], row["blocks_read"]), (4, 240, 4))
        self.assertEqual(row["top_types"], [
            {"type": "__NSDictionaryM", "count": 1, "bytes": 128},
            {"type": "__NSArrayM", "count": 2, "bytes": 96},
            {"type": "malloc", "count": 1, "bytes": 16},
        ])

    def test_tree_format_skips_cycle_back_lines(self):
        row = leakcheck.parse(TREE, 1)
        self.assertEqual((row["leaks"], row["bytes"], row["blocks_read"]), (3, 192, 3))
        self.assertEqual([(t["type"], t["count"], t["bytes"]) for t in row["top_types"]],
                         [("CmuxNext.TabModel", 1, 160), ("malloc", 1, 16), ("malloc in foo", 1, 16)])

    def test_no_leaks(self):
        self.assertEqual(leakcheck.parse(NONE, 0), {"leaks": 0, "bytes": 0, "blocks_read": 0, "top_types": []})

    def test_error_status_is_an_error_row(self):
        row = leakcheck.parse("leaks[99]: [fatal] unable to get task for pid 4242\n", 2)
        self.assertIn("leaks exit 2", row["error"])
        self.assertIn("task for pid", row["error"])
        self.assertTrue(leakcheck.summary_line(row).startswith("leaks: not measured"))

    def test_output_without_summary_is_an_error_row(self):
        self.assertIn("error", leakcheck.parse("", 124))

    # skip-owner: PL-stability; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @unittest.skipIf(os.path.exists("/usr/bin/leaks"), "this Mac has leaks; the case needs a host without it")
    def test_run_local_without_leaks_writes_the_output_and_an_error_row(self):
        with tempfile.TemporaryDirectory() as scratch:
            out = os.path.join(scratch, "leaks.txt")
            row = leakcheck.run_local(4242, out)
            self.assertEqual(row["pid"], 4242)
            self.assertIn("leaks exit 127", row["error"])
            with open(out) as written:
                self.assertTrue(written.read())

    def test_summary_line(self):
        line = leakcheck.summary_line(leakcheck.parse(LIST, 1))
        self.assertEqual(line, "leaks: 4 blocks, 240 bytes; top __NSDictionaryM 1x 128 B, __NSArrayM 2x 96 B, malloc 1x 16 B")


class FakeVNC:
    def __init__(self, *_):
        pass

    def screenshot_png(self) -> bytes:
        return b"png"


class FakeGuest:
    """The guest of Smoke.finish: `leaks` answers the scripted status and output; the quit ends the app with status 0."""

    def __init__(self, leaks_status: int, leaks_text: str):
        self.leaks_status, self.leaks_text = leaks_status, leaks_text
        self.commands: list[str] = []
        self.quit = False

    def sh(self, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
        self.commands.append(cmd)
        if "/usr/bin/leaks" in cmd:
            out = f"{self.leaks_status}\n"
        elif cmd == f"cat {smoke.LEAKS_FILE}":
            out = self.leaks_text
        elif cmd.startswith(f"cat {smoke.EXIT_FILE}"):
            out = "0\n" if self.quit else ""
        else:
            out = ""
        return subprocess.CompletedProcess(cmd, 0, out, "")

    def pid(self) -> int | None:
        return None if self.quit else 4242

    def cmux(self, args, timeout: float = 15) -> subprocess.CompletedProcess:
        if "quitEndEverything" in args[-1]:
            self.quit = True
        return subprocess.CompletedProcess(args, 0, json.dumps({"ok": True}) + "\n", "")


class SmokeLeaks(unittest.TestCase):
    def finish(self, guest: FakeGuest) -> tuple[dict, str]:
        with tempfile.TemporaryDirectory() as out, mock.patch.object(smoke, "RFB", FakeVNC), \
                mock.patch.object(smoke, "REPORT_MINIMUM", 0), mock.patch.object(time, "sleep", lambda _: None):
            suite = smoke.Smoke(guest, "127.0.0.1:5900:pw", out)
            suite.required = ("quit",)
            suite.finish()
            with open(os.path.join(out, "leaks.txt")) as written:
                return suite.result, written.read()

    def leaks_command(self, guest: FakeGuest) -> str:
        commands = [c for c in guest.commands if "/usr/bin/leaks" in c]
        self.assertEqual(len(commands), 1, guest.commands)
        return commands[0]

    def test_the_command_writes_both_branches_out_for_zsh(self):
        guest = FakeGuest(1, LIST)
        self.finish(guest)
        command = self.leaks_command(guest)
        # zsh does not word-split an unquoted parameter: no command word may come from a variable.
        self.assertIsNone(re.search(r"(^|[;&|]|\bthen|\belse)\s*\$", command), command)
        leaks = f"/usr/bin/perl -e 'alarm shift; exec @ARGV' {leakcheck.TIMEOUT} /usr/bin/leaks -list -nocontext 4242;"
        self.assertIn(f"then sudo -n {leaks}", command)
        self.assertIn(f"else {leaks}", command)
        self.assertTrue(command.endswith(f"fi >{smoke.LEAKS_FILE} 2>&1; echo $?"), command)

    def test_the_row_is_parsed_from_the_status_and_the_output(self):
        result, written = self.finish(FakeGuest(1, LIST))
        self.assertEqual(written, LIST)
        self.assertEqual(result["leaks"], {"pid": 4242, **leakcheck.parse(LIST, 1)})
        self.assertEqual((result["leaks"]["leaks"], result["leaks"]["bytes"]), (4, 240))
        self.assertEqual(result["leaks"]["top_types"][0]["type"], "__NSDictionaryM")
        self.assertTrue(result["steps"]["quit"]["ok"])
        self.assertTrue(result["ok"])

    def test_a_leaks_error_leaves_the_quit_and_the_verdict_alone(self):
        result, _ = self.finish(FakeGuest(127, "zsh:1: command not found: sudo -n\n"))
        self.assertIn("leaks exit 127", result["leaks"]["error"])
        self.assertEqual(result["steps"]["quit"],
                         {"ok": True, "detail": {"run": {"ok": True}, "exit_status": 0, "detail": None}})
        self.assertEqual(result["failed_steps"], [])
        self.assertTrue(result["ok"])


if __name__ == "__main__":
    unittest.main()
