#!/usr/bin/env python3
"""whats-new-gallery.yml runs on nightly-next pushes too, so a highlight an earlier run failed to
render gets another try on the next promote (run 45963430187 failed and nothing retried it)."""
import os, re, unittest

WORKFLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "workflows", "whats-new-gallery.yml")


class GalleryTriggerTests(unittest.TestCase):
    def test_push_runs_on_feat_cmux_next_and_nightly_next(self):
        text = open(WORKFLOW).read()
        on = text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        branches = re.search(r"^  push:\n(?:    #.*\n)*    branches: \[([^\]]*)\]", on, re.M)
        self.assertIsNotNone(branches, on)
        names = {b.strip() for b in branches.group(1).split(",")}
        self.assertTrue({"feat-cmux-next", "nightly-next"} <= names, names)

    def test_publish_environment_admits_every_push_branch(self):
        # publish runs in pr-media, which admits only main, feat-cmux-next and nightly-next.
        text = open(WORKFLOW).read()
        self.assertIn("environment: pr-media", text)
        self.assertIn("(main, feat-cmux-next, nightly-next)", text)


if __name__ == "__main__":
    unittest.main()
