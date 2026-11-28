#!/usr/bin/env python3
"""No workflow reads a fleet step id with a bare `x="$(grep ...)"` that kills the step when none is printed.

A `run:` step's default shell is `bash -e`. When the cmux-ci client prints no step id (the controller refused the job,
e.g. `HTTP 422: no registered worker can run this job`), `step="$(grep -o -E '[0-9a-f]{24}' "$log" | head -1)"`
exits non-zero under `set -o pipefail`, and -e ends the step right there: the report-only split table went red on
every feat-cmux-next PR on 2026-11-28 (06:2x-07:4xZ, incident hosted#1184) though its script says "nothing fails" and
handles an empty step on the next line.

A failure names the file and line. End the substitution with `|| true` (or `|| step=""` after it).
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
ASSIGN = re.compile(r'^\s*(?:local\s+)?[A-Za-z_][A-Za-z0-9_]*="\$\(\s*grep [^\n]*\[0-9a-f\]\{24\}[^\n]*\)"(?P<rest>.*)$')


def findings(paths: list[Path]) -> list[str]:
    out = []
    for path in sorted(paths):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = ASSIGN.match(line)
            if not match:
                continue
            guarded_inside = re.search(r"\|\|\s*(true|:)\s*\)\"", line)
            guarded_after = "||" in match.group("rest")
            if guarded_inside or guarded_after:
                continue
            rel = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
            out.append(
                f"{rel}:{number}: a step-id grep with no match ends a bash -e step: "
                f"end the substitution with `|| true`")
    return out


class StepIdGrepGuarded(unittest.TestCase):
    def test_no_workflow_reads_a_step_id_unguarded(self) -> None:
        paths = [*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]
        self.assertTrue(paths)
        self.assertEqual(findings(paths), [])

    def test_the_detector_catches_the_split_table_line(self) -> None:
        sample = ROOT / "tests" / "_step_id_grep_sample.yml"
        try:
            sample.write_text(
                "run: |\n"
                "  step=\"$(grep -o -E '\\b[0-9a-f]{24}\\b' \"$log\" | head -1)\"\n"
                "  step=\"$(grep -o -E 'step [0-9a-f]{24}' \"$log\" | head -1 | cut -d' ' -f2 || true)\"\n"
                "  step=\"$(grep -o -E 'step [0-9a-f]{24}' \"$log\" | head -1)\" || step=\"\"\n")
            self.assertEqual(len(findings([sample])), 1)
        finally:
            sample.unlink()


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
