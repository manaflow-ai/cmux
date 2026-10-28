#!/usr/bin/env python3
"""guardrails.py's main-work-batch rule (sequence-manager-DESIGN.md S2b): a push may not add a `FrameBatchQueue(` or a
`FrameBatcher(` to MainWorkScheduler's own files (CmuxNextWakeups/MainWorkScheduler*.swift), whose posted work lives on
the sequence manager's queues. No escape comment works; other files are not judged.

The rule runs on in-memory changes, as check() builds them. Not on CI (Lawrence 2026-10-23: no new CI tests): run it
yourself after a change to the rule:

  python3 scripts/cmux-next/tests/test_guardrails_main_work_batch.py
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
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_seqmgr_s2b", SCRIPTS / "guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

SRC = "Packages/macOS/CmuxNext/Sources/"
WAKEUPS = SRC + "CmuxNextWakeups/"
RULE = next(rule for rule in guardrails.RULES if rule.id == "main-work-batch")


def hits(path: str, head: str, base: str = "") -> list[int]:
    """The 1-based head lines the rule refuses when a push turns BASE into HEAD at PATH, read from its -U0 diff."""
    head_lines, base_lines = head.split("\n"), base.split("\n") if base else []
    diff = "\n".join(difflib.unified_diff(base_lines, head_lines, f"a/{path}", f"b/{path}", n=0, lineterm=""))
    change = guardrails.parse_diff(f"diff --{'g' + 'it'} a/{path} b/{path}\n{diff}\n")[path]
    change.head_lines, change.base_lines = head_lines, base_lines
    return [hit.number for hit in RULE.find([change], collections.Counter())]


class MainWorkBatchTests(unittest.TestCase):
    def test_a_frame_batch_queue_in_the_schedulers_files_is_refused(self):
        line = '        let queue = FrameBatchQueue(owner: "MainWork.\\(mainClass)", budgeted: workClass, on: self)'
        for name in ("MainWorkScheduler.swift", "MainWorkScheduler+Post.swift", "MainWorkScheduler+Batch.swift"):
            with self.subTest(name=name):
                self.assertEqual(hits(WAKEUPS + name, "extension MainWorkScheduler {\n" + line + "\n}"), [2])
        self.assertEqual(hits(WAKEUPS + "MainWorkScheduler+Post.swift",
                              'let rows = FrameBatcher(owner: "rows", budgeted: .visible, on: self)'), [1])

    def test_no_escape_comment_lets_one_through(self):
        line = '    let q = FrameBatchQueue(owner: "x", budgeted: .visible, on: self) // main-work-batch-allow: why'
        self.assertEqual(hits(WAKEUPS + "MainWorkScheduler+Post.swift", line), [1])

    def test_other_owners_keep_their_frame_batches(self):
        line = 'visibleWork = FrameBatchQueue(owner: "Startup.afterFirstFrame", budgeted: .visible, on: mainWork)'
        for path in (WAKEUPS + "StartupScheduler.swift", WAKEUPS + "FrameBatchQueue.swift",
                     SRC + "CmuxNextApp/Control/AppControl.swift", WAKEUPS + "Sub/MainWorkScheduler.swift"):
            with self.subTest(path=path):
                self.assertEqual(hits(path, line), [])

    def test_a_mention_or_a_type_is_not_a_construction(self):
        text = ("/// The class queues were a `FrameBatchQueue(owner:budgeted:on:)` each before S2b.\n"
                "private var old: FrameBatchQueue?\nlet rows: FrameBatcher")
        self.assertEqual(hits(WAKEUPS + "MainWorkScheduler.swift", text), [])


if __name__ == "__main__":
    unittest.main()
