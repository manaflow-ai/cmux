#!/usr/bin/env python3
"""scripts/ci/media_auto_tour.py decides whether a pull request event gets a native media tour.

A tour holds an owned Mac's gui runner for up to two hours, so a pull request tours once,
when someone adds the `media-tour` label, and never on its own: no tour is picked from the
changed paths, and a later push of a labeled pull request does not tour again. To tour a
newer head, remove and re-add the label or run `cmux-ci capture`.
`no-media-tour` always wins."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import media_auto_tour  # noqa: E402


def decide(labels=(), action="synchronize", label=""):
    return media_auto_tour.decide(labels=list(labels), action=action, label=label)


class DecideTests(unittest.TestCase):
    def test_adding_the_label_tours(self):
        wanted, why = decide(["media-tour"], action="labeled", label="media-tour")
        self.assertTrue(wanted)
        self.assertIn("media-tour", why)

    def test_a_draft_tours_when_labeled_too(self):
        self.assertTrue(decide(["media-tour"], action="labeled", label="media-tour")[0])

    def test_a_later_push_of_a_labeled_pull_request_does_not_tour_again(self):
        wanted, why = decide(["media-tour"], action="synchronize")
        self.assertFalse(wanted)
        self.assertIn("re-add", why)  # says how to tour the newer head

    def test_no_tour_is_picked_without_the_label(self):
        for action in ("opened", "synchronize", "reopened", "ready_for_review"):
            self.assertFalse(decide(["dev-build"], action=action)[0], action)

    def test_adding_another_label_does_not_tour(self):
        self.assertFalse(decide(["media-tour", "dev-build"], action="labeled", label="dev-build")[0])
        # media-tour-mac only moves a tour to a Mac; it never starts one by itself.
        self.assertFalse(decide(["media-tour-mac"], action="labeled", label="media-tour-mac")[0])

    def test_the_opt_out_label_wins(self):
        self.assertFalse(decide(["no-media-tour", "media-tour"], action="labeled", label="media-tour")[0])
        self.assertFalse(decide(["no-media-tour"], action="labeled", label="no-media-tour")[0])

    def test_cli_writes_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            changed, out = Path(tmp) / "changed.txt", Path(tmp) / "out"
            changed.write_text("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentPane/AgentPaneHost.swift\n")
            for action, label, want in (("labeled", "media-tour", "true"), ("synchronize", "", "false")):
                out.write_text("")
                subprocess.run([sys.executable, str(ROOT / "scripts/ci/media_auto_tour.py"), "--changed", str(changed)],
                               check=True, capture_output=True,
                               env={"LABELS": '["media-tour"]', "ACTION": action, "LABEL": label,
                                    "DRAFT": "false", "GITHUB_OUTPUT": str(out)})
                lines = dict(line.split("=", 1) for line in out.read_text().splitlines())
                self.assertEqual(lines["wanted"], want, action)


if __name__ == "__main__":
    unittest.main()
