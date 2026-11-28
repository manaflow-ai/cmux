"""Behavior tests for scripts/ci/crash_ratchet_compare.py (the PR crash-ratchet job).

A fake ratchet stands in for scripts/cmux-next/crash_ratchet.py: it prints the text in
<repo>/ratchet.out and exits with the code in <repo>/ratchet.rc, so each case states exactly what
the real ratchet would print for the head and for the base.
"""
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COMPARE = os.path.join(HERE, "..", "scripts", "ci", "crash_ratchet_compare.py")

FAKE = textwrap.dedent("""\
    import argparse, os, sys
    p = argparse.ArgumentParser()
    p.add_argument("--repo")
    p.add_argument("--exported-tree", action="store_true")
    o = p.parse_args()
    if os.path.basename(o.repo) == "base" and not o.exported_tree:
        print("the base must be scanned as an exported tree"); sys.exit(9)
    print(open(os.path.join(o.repo, "ratchet.out")).read(), end="")
    sys.exit(int(open(os.path.join(o.repo, "ratchet.rc")).read()))
""")

OK = "crash-ratchet: ok\n"
UNWRAP_3 = "crash-ratchet: rust cmux-tui: unwrap 30 -> 33\ncrash-ratchet: 1 module(s) or crate(s) gained a crash-class hit\n"
UNWRAP_31 = "crash-ratchet: rust cmux-tui: unwrap 30 -> 31\ncrash-ratchet: 1 module(s) or crate(s) gained a crash-class hit\n"
TWO = UNWRAP_3 + "crash-ratchet: swift CmuxNextApp: unchecked 5 -> 6\n"


class CrashRatchetCompare(unittest.TestCase):
    def run_case(self, head, base):
        with tempfile.TemporaryDirectory() as tmp:
            fake = os.path.join(tmp, "crash_ratchet.py")
            with open(fake, "w") as f:
                f.write(FAKE)
            for name, (text, rc) in (("head", head), ("base", base)):
                os.makedirs(os.path.join(tmp, name))
                with open(os.path.join(tmp, name, "ratchet.out"), "w") as f:
                    f.write(text)
                with open(os.path.join(tmp, name, "ratchet.rc"), "w") as f:
                    f.write(str(rc))
            out = subprocess.run([sys.executable, COMPARE, "--script", fake, "--head", os.path.join(tmp, "head"),
                                  "--base", os.path.join(tmp, "base")], capture_output=True, text=True)
            return out.returncode, out.stdout + out.stderr

    def test_green_head_passes(self):
        rc, out = self.run_case((OK, 0), ("garbage", 1))
        self.assertEqual(rc, 0, out)

    def test_head_red_on_green_base_fails_with_both_counts(self):
        rc, out = self.run_case((UNWRAP_3, 1), (OK, 0))
        self.assertEqual(rc, 1, out)
        self.assertIn("rust cmux-tui: unwrap: head 33, base ok", out)
        self.assertIn("turns the crash ratchet red", out)

    def test_base_red_and_head_not_worse_warns(self):
        rc, out = self.run_case((UNWRAP_3, 1), (UNWRAP_3, 1))
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning::", out)

    def test_head_worse_than_red_base_fails(self):
        rc, out = self.run_case((UNWRAP_3, 1), (UNWRAP_31, 1))
        self.assertEqual(rc, 1, out)
        self.assertIn("head 33, base 31", out)

    def test_new_line_on_red_base_fails(self):
        rc, out = self.run_case((TWO, 1), (UNWRAP_3, 1))
        self.assertEqual(rc, 1, out)
        self.assertIn("swift CmuxNextApp: unchecked head 6, base not red", out)

    def test_exit_zero_without_ok_line_is_not_green(self):
        rc, out = self.run_case(("Traceback: something broke\n", 0), (OK, 0))
        self.assertEqual(rc, 1, out)
        self.assertIn("did not run on the head", out)

    def test_failed_base_run_refuses_with_its_output(self):
        rc, out = self.run_case((UNWRAP_3, 1), ("crash-ratchet: refused, not a checkout\n", 2))
        self.assertEqual(rc, 1, out)
        self.assertIn("did not run on the base", out)
        self.assertIn("refused, not a checkout", out)


if __name__ == "__main__":
    unittest.main()
