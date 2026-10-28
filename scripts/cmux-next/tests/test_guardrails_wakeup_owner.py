#!/usr/bin/env python3
"""guardrails.py's main-wakeup-owner rule (sequence-manager-DESIGN.md S1): a push may not add a `MainWakeUpQueue(`,
`MainDeadlineScheduler(` or `MainWorkScheduler(` in Sources outside the composition root (CmuxNextApp.swift,
AppServices.swift, LaunchOrder.swift), CmuxNextWakeups and the *TestSupport targets. No escape comment works; a line already there is base debt.

The rule runs on in-memory changes, as check() builds them. Not on CI (Lawrence 2026-10-23: no new CI tests): run it
yourself after a change to the rule:

  python3 scripts/cmux-next/tests/test_guardrails_wakeup_owner.py
"""
from __future__ import annotations

import collections
import difflib
import importlib.util
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_seqmgr_s1", SCRIPTS / "guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

SRC = "Packages/macOS/CmuxNext/Sources/"
RULE = next(rule for rule in guardrails.RULES if rule.id == "main-wakeup-owner")


def hits(path: str, head: str, base: str = "") -> list[int]:
    """The 1-based head lines the rule refuses when a push turns BASE into HEAD at PATH, read from its -U0 diff."""
    head_lines, base_lines = head.split("\n"), base.split("\n") if base else []
    diff = "\n".join(difflib.unified_diff(base_lines, head_lines, f"a/{path}", f"b/{path}", n=0, lineterm=""))
    change = guardrails.parse_diff(f"diff --{'g' + 'it'} a/{path} b/{path}\n{diff}\n")[path]
    change.head_lines, change.base_lines = head_lines, base_lines
    return [hit.number for hit in RULE.find([change], collections.Counter())]


class MainWakeUpOwnerTests(unittest.TestCase):
    def test_a_new_queue_or_deadline_placer_in_an_owner_is_refused(self):
        self.assertEqual(hits(SRC + "CmuxNextSidebar/Rows.swift",
                              "final class Rows {\n    let queue = MainWakeUpQueue(energy: EnergyPolicySource())\n}"), [2])
        self.assertEqual(hits(SRC + "CmuxNextPages/Page.swift",
                              "init(deadlines: MainDeadlineScheduler = MainDeadlineScheduler(work: work)) {}"), [1])
        self.assertEqual(hits(SRC + "CmuxNextPalette/P.swift",
                              "init(mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget())) {}"), [1])
        self.assertEqual(hits(SRC + "CmuxNextPalette/P.swift", "let work = MainWorkScheduler.testing { _ in Link() }"), [1])

    def test_no_escape_comment_lets_one_through(self):
        line = "    let queue = MainWakeUpQueue(energy: energy) // main-wakeup-owner-allow: tests only"
        self.assertEqual(hits(SRC + "CmuxNextTerminal/T.swift", line), [1])

    def test_the_closed_list_may_make_them(self):
        for path in (SRC + "CmuxNextApp/CmuxNextApp.swift", SRC + "CmuxNextApp/AppServices.swift",
                     SRC + "CmuxNextLaunch/LaunchOrder.swift", SRC + "CmuxNextWakeups/MainWorkScheduler.swift", SRC + "CmuxNextWakeupsTestSupport/Rig.swift",
                     SRC + "CmuxNextPagesTestSupport/Host.swift"):
            with self.subTest(path=path):
                self.assertEqual(hits(path, "let q = MainWakeUpQueue(energy: e)\nlet d = MainDeadlineScheduler(work: w)"), [])

    def test_other_app_files_are_not_on_the_list(self):
        self.assertEqual(hits(SRC + "CmuxNextApp/AppServices+Chromium.swift", "let q = MainWakeUpQueue(energy: e)"), [1])

    def test_a_type_name_a_comment_or_a_member_is_not_a_construction(self):
        text = ("/// let deadlines = MainDeadlineScheduler(work: mainWork)\n"
                "init(deadlines: MainDeadlineScheduler, queue: MainWakeUpQueue) {}\n"
                "let q = deadlines.wakeUpQueue\nlet d: MainDeadlineScheduler = .testing()")
        self.assertEqual(hits(SRC + "CmuxNextPages/Page.swift", text), [])

    def test_a_site_already_in_the_file_is_base_debt(self):
        base = "let d = MainDeadlineScheduler(work: mainWork)\nlet a = 1"
        head = "let d = MainDeadlineScheduler(work: mainWork)\nlet a = 2"
        self.assertEqual(hits(SRC + "CmuxNextSidebar/S.swift", head, base), [])
        moved = "let a = 2\nlet d = MainDeadlineScheduler(work: self.mainWork)"
        self.assertEqual(hits(SRC + "CmuxNextSidebar/S.swift", moved, base), [])
        second = base + "\nlet e = MainDeadlineScheduler(work: other)"
        self.assertEqual(hits(SRC + "CmuxNextSidebar/S.swift", second, base), [3])


if __name__ == "__main__":
    unittest.main()
