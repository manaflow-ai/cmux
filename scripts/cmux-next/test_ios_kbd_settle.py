#!/usr/bin/env python3
"""ios_kbd_settle: a content that rides the keyboard scores 0 ms, a probe whose content never moves is refused
(python3 scripts/cmux-next/test_ios_kbd_settle.py)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ios_kbd_settle as iks  # noqa: E402

FRAME = 1 / 60


def trace(rides):
    """One show: the keyboard eases from 874 to 566 over 20 frames, then rests; the content's bottom follows it
    (`rides`) or stays at 754 (a dead probe)."""
    lines = ["t=1.0000 ev=willShow end=0.0,566.0,402.0,308.0 dur=0.383 curve=7"]
    for i in range(40):
        p = min(1.0, i / 20)
        kb = 874 - 308 * (1 - (1 - p) ** 3)
        cb = kb - 60 if rides else 754.45
        lines.append("t=%.4f win=402x874 kb=%.2f field=terminal.composer.field cb=%.2f off=0.00 cf=0.00,874.00 csrc=%s"
                     % (1.0 + i * FRAME, kb, cb, "drawn" if rides else "scroll"))
    return "\n".join(lines) + "\n"


class SettleTest(unittest.TestCase):
    def run_on(self, text):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "kbm-trace.txt"), "w") as fh:
                fh.write(text)
            return iks.table([("idle", d)])

    def test_riding_content_settles_with_the_keyboard(self):
        rows, dead = self.run_on(trace(rides=True))
        self.assertEqual(dead, [])
        self.assertEqual(rows[("idle", "terminal", "show")]["t1"], [0.0])

    def test_a_content_that_never_moves_is_refused(self):
        rows, dead = self.run_on(trace(rides=False))
        self.assertEqual(dead, [("idle", "terminal")])
        self.assertIn("refused", iks.render(rows, dead))


if __name__ == "__main__":
    unittest.main()
