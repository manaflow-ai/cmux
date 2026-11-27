"""diff-page-frames.py's failure dump: a diff tab that drew no file leaves what the app showed, and a read that
fails is kept as its error instead of failing the dump (the step's evidence for an open that never drew)."""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("diff_page_frames", os.path.join(os.path.dirname(HERE), "diff-page-frames.py"))
dpf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dpf)


class FakeApp:
    def call(self, method, params=None, timeout=None):
        if method == "debug.surfaces":
            raise RuntimeError("socket closed")
        return {"method": method, "action": (params or {}).get("action")}


class FailureDumpTest(unittest.TestCase):
    def test_reads_kept_and_a_failed_read_is_its_error(self):
        dump = dpf.failure_dump(FakeApp(), None, "base-1", None)
        self.assertEqual(dump["pages"]["action"], "list")
        self.assertEqual(dump["diff_page_state"]["action"], "state")
        self.assertEqual(dump["diff_page_text"]["action"], "query")
        self.assertEqual(dump["surfaces"], {"error": "socket closed"})
        self.assertNotIn("screenshot", dump)

    def test_log_tails_from_the_scratch_home(self):
        with tempfile.TemporaryDirectory() as root:
            scratch = os.path.join(root, "scratch")
            os.makedirs(os.path.join(scratch, "home"))
            with open(os.path.join(scratch, "home", "app.log"), "w") as handle:
                handle.write("x" * 9000 + "openDiff failed: no repository")
            dump = dpf.failure_dump(FakeApp(), os.path.join(root, "dumps"), "head-1", scratch)
            with open(dump["logs"]) as handle:
                text = handle.read()
            self.assertIn("openDiff failed: no repository", text)
            self.assertLess(len(text), 7000)


if __name__ == "__main__":
    unittest.main()
