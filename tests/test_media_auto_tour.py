#!/usr/bin/env python3
"""scripts/ci/media_auto_tour.py decides whether a pull request gets a native media tour
without the `media-tour` label: when it changes cmux-next Swift UI that a specific tour
covers (path_map.py: new-tab, agent-pane, now-playing, glass). The catch-all `core` tour,
web-only changes (the gallery advisory covers those) and drafts get none, so the owned
Macs' gui runners only take the pull requests a tour can show."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import media_auto_tour  # noqa: E402

AGENT_PANE_SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentPane/AgentPaneHost.swift"
CORE_SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Workspace/SplitTree.swift"
NEW_TAB_WEB = "webviews/src/agent-session/acpmux/newtab/NewTabScreen.tsx"


def decide(paths, labels=(), draft=False, action="synchronize"):
    return media_auto_tour.decide(labels=list(labels), action=action, draft=draft, paths=list(paths))


class DecideTests(unittest.TestCase):
    def test_swift_ui_a_tour_covers_tours_without_a_label(self):
        wanted, why = decide([AGENT_PANE_SWIFT, "README.md"])
        self.assertTrue(wanted)
        self.assertIn("agent-pane", why)

    def test_swift_that_only_the_core_tour_covers_does_not(self):
        wanted, why = decide([CORE_SWIFT])
        self.assertFalse(wanted)
        self.assertIn("media-tour", why)  # says how to ask for one

    def test_web_only_changes_do_not(self):
        self.assertFalse(decide([NEW_TAB_WEB])[0])

    def test_the_label_always_tours(self):
        self.assertTrue(decide([CORE_SWIFT], labels=["media-tour"])[0])
        self.assertTrue(decide([], labels=["media-tour"], draft=True)[0])

    def test_a_draft_or_the_opt_out_label_does_not(self):
        self.assertFalse(decide([AGENT_PANE_SWIFT], draft=True)[0])
        self.assertFalse(decide([AGENT_PANE_SWIFT], labels=["no-media-tour"])[0])
        self.assertFalse(decide([AGENT_PANE_SWIFT], labels=["no-media-tour", "media-tour"])[0])

    def test_cli_writes_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            changed, out = Path(tmp) / "changed.txt", Path(tmp) / "out"
            changed.write_text(AGENT_PANE_SWIFT + "\n")
            out.write_text("")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/media_auto_tour.py"), "--changed", str(changed)],
                           check=True, capture_output=True,
                           env={"LABELS": '["dev-build"]', "ACTION": "opened", "DRAFT": "false",
                                "GITHUB_OUTPUT": str(out)})
            lines = dict(line.split("=", 1) for line in out.read_text().splitlines())
            self.assertEqual(lines["wanted"], "true")


if __name__ == "__main__":
    unittest.main()
