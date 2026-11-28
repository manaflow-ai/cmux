"""cmux/ui-proof says no look ran instead of sitting pending for ever (ui_proof_verdict.py no-look)."""
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ui_proof_verdict as v  # noqa: E402


class NoLook(unittest.TestCase):
    def test_description_says_why_and_how(self):
        d = v.no_look_description(62216, "step ab cancelled after 10800 s in the queue: not started within 3h0m0s")
        self.assertTrue(d.startswith("Visual change, no look ran (step ab cancelled"))
        self.assertLessEqual(len(d), 140)

    def test_a_pending_gate_is_annotated(self):
        posted = []
        with mock.patch.object(v, "api", return_value=[{"context": v.STATUS_CONTEXT, "state": "pending"}]), \
                mock.patch.object(v, "post_status", side_effect=lambda *a, **k: posted.append(a) or True):
            out = v.no_look(1, "capped", "o/r", "abc", ["t"])
        self.assertEqual(posted[0][0], "pending")
        self.assertIn("no look ran (capped)", out)

    def test_a_pass_or_failure_stays(self):
        for state in ("success", "failure"):
            with mock.patch.object(v, "api", return_value=[{"context": v.STATUS_CONTEXT, "state": state}]), \
                    mock.patch.object(v, "post_status") as post:
                out = v.no_look(1, "capped", "o/r", "abc", ["t"])
            post.assert_not_called()
            self.assertTrue(out.startswith(f"left as {state}"))


if __name__ == "__main__":
    unittest.main()
