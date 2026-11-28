#!/usr/bin/env python3
"""base-coalesce.yml: every step that writes .base-coalesce/record makes the directory in that same step.

A pool runner's disk-floor prune can empty the job's workspace between steps, so a directory an earlier step made
may be gone: on 2026-11-25 20:11Z the coalesce job's Decide step (job 139480437957 on w2a-0015) failed
".base-coalesce/record: No such file or directory" after the window step's mkdir, and the window's retry built no tree.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/base-coalesce.yml"


def run_blocks(text: str) -> list[str]:
    """Each step's `run: |` body (the indented lines after it)."""
    blocks, lines, i = [], text.splitlines(), 0
    while i < len(lines):
        m = re.match(r"^(\s*)run: \|\s*$", lines[i])
        if not m:
            i += 1
            continue
        indent, body, i = len(m.group(1)), [], i + 1
        while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > indent):
            body.append(lines[i])
            i += 1
        blocks.append("\n".join(body))
    return blocks


class RecordDir(unittest.TestCase):
    def test_every_record_write_makes_its_directory_first(self):
        writes = [b for b in run_blocks(WORKFLOW.read_text(encoding="utf-8")) if re.search(r">\s*\.base-coalesce/record", b)]
        self.assertGreaterEqual(len(writes), 2, "the Decide and mark_failed steps write the record")
        for body in writes:
            write = re.search(r">\s*\.base-coalesce/record", body).start()
            made = body.find("mkdir -p .base-coalesce")
            self.assertTrue(0 <= made < write, body)


if __name__ == "__main__":
    unittest.main()
