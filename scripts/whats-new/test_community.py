#!/usr/bin/env python3
"""Tests for community.py: the X post fits 280 characters, Discord lists every entry."""
import json, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import community  # noqa: E402


def fixture():
    with open(os.path.join(HERE, "fixtures/good/1.0.0-nightly.42.json"), encoding="utf-8") as f:
        return json.load(f)


class CommunityTests(unittest.TestCase):
    def test_x_post_fits_and_names_the_release(self):
        document = fixture()
        document["entries"] = document["entries"] * 12
        text = community.x_post(document, "https://cmux.com/whats-new/1.0.0-nightly.42")
        self.assertLessEqual(len(text), community.X_LIMIT)
        self.assertTrue(text.startswith("cmux Nightly 1.0.0-nightly.42: "))
        self.assertTrue(text.endswith("https://cmux.com/whats-new/1.0.0-nightly.42"))

    def test_discord_lists_every_entry_by_category(self):
        text = community.discord_post(fixture(), "")
        self.assertLess(text.index("__New__"), text.index("__Fixed__"))
        self.assertIn("**Smoother sidebar scrolling**", text)

    def test_no_entries_no_summary(self):
        document = fixture()
        document["entries"] = []
        self.assertIsNone(community.summary(document))
        self.assertIn("Nothing posts this automatically", community.summary(fixture()))


if __name__ == "__main__":
    unittest.main()
