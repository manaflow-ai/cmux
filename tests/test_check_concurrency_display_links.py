"""check-concurrency.sh's display-link rule (p03-rendering-010): one display link per display, made only
in CmuxNextWakeups/DisplayClock.swift and CmuxNextWakeups/VSyncHub.swift (Chrome's
DisplayLinkMac::GetForDisplay). Before it, FrameScheduler made one link per window, one for the app
and one for the budgeted scheduler, and the Wakeups module was exempt from the rule."""
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/check-concurrency.sh"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Fixture", targets: [
    .target(name: "FixtureUI", swiftSettings: uiSwiftSettings),
    .target(name: "CmuxNextWakeups", swiftSettings: coreSwiftSettings),
])
"""
LINK = """import AppKit
func link(_ window: NSWindow, _ target: NSObject) {
    _ = window.displayLink(target: target, selector: #selector(NSObject.description))
}
"""
ESCAPED = """import AppKit
func link(_ window: NSWindow, _ target: NSObject) {
    // wakeup-allow: an escape comment does not make a second link per display
    _ = window.displayLink(target: target, selector: #selector(NSObject.description))
}
"""


def run(files):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        root.mkdir(parents=True)
        (root / "Package.swift").write_text(MANIFEST)
        (root / "Sources" / "FixtureUI").mkdir(parents=True)
        for name, text in files.items():
            (root / "Sources" / name).parent.mkdir(parents=True, exist_ok=True)
            (root / "Sources" / name).write_text(text)
        return subprocess.run(["bash", str(SCRIPT), str(root)], text=True, capture_output=True, timeout=60)


class DisplayLinkRule(unittest.TestCase):
    def test_display_clock_and_vsync_hub_may_make_links(self):
        result = run({"CmuxNextWakeups/DisplayClock.swift": LINK, "CmuxNextWakeups/VSyncHub.swift": LINK})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_frame_scheduler_may_not_make_a_link(self):
        result = run({"CmuxNextWakeups/FrameScheduler.swift": LINK})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FrameScheduler.swift:3: raw display link", result.stdout)

    def test_an_escape_comment_does_not_allow_a_link(self):
        result = run({"FixtureUI/View.swift": ESCAPED})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("View.swift:4: raw display link", result.stdout)


if __name__ == "__main__":
    unittest.main()
