#!/usr/bin/env python3
"""A quit scheduled on the run loop goes through NSApplication.terminateFromRunLoop.

A bare `RunLoop.main.perform { NSApp.terminate(nil) }` is exit(0) in the Swift test helper, whose
app never runs: one test's quit ended the whole CmuxNextAppTests run with status 0 and hundreds of
tests never finished. terminateFromRunLoop refuses there and names the caller.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Packages/macOS/CmuxNext/Sources"
HELPER = SOURCES / "CmuxNextCompat/NSApplication+TerminateFromRunLoop.swift"
PERFORM = re.compile(r"RunLoop\.main\.perform\b|DispatchQueue\.main\.async\b")
TERMINATE = re.compile(r"\b(NSApp|NSApplication\.shared)\.terminate\(")
# Lines after a perform that still count as its block.
WINDOW = 6


class DeferredTerminate(unittest.TestCase):
    def test_no_bare_terminate_is_scheduled_on_the_main_run_loop(self):
        offenders = []
        for path in sorted(SOURCES.rglob("*.swift")):
            if path == HELPER:
                continue
            lines = path.read_text().splitlines()
            for number, line in enumerate(lines):
                if PERFORM.search(line) and any(TERMINATE.search(l) for l in lines[number:number + WINDOW]):
                    offenders.append(f"{path.relative_to(ROOT)}:{number + 1}")
        self.assertEqual(offenders, [], "use NSApplication.terminateFromRunLoop")

    def test_the_helper_refuses_when_the_app_never_ran(self):
        text = HELPER.read_text()
        self.assertIn("guard NSApp.isRunning else", text)


if __name__ == "__main__":
    unittest.main()
