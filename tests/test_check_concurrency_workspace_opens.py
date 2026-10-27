"""check-concurrency.sh's workspace-open rule (p02-threads-057): every synchronous NSWorkspace open or
Finder reveal goes through CmuxNextCompatAppKit/NSWorkspace+Background.swift (Chrome posts
platform_util::OpenExternal to a blocking-allowed sequence, chrome/browser/platform_util_mac.mm).
Before it, the rule matched only a one-argument `NSWorkspace.shared.open(x)`, so the configuration and
open-with-app forms, and any call through a local or injected workspace, passed."""
import os
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
    .target(name: "CmuxNextCompat", swiftSettings: daemonSwiftSettings),
])
"""
RULE = "synchronous NSWorkspace open or reveal"

REFUSED = [
    "NSWorkspace.shared.open(url)",
    "NSWorkspace.shared.open(url, configuration: configuration)",
    "NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)",
    "NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, _ in }",
    "workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())",
    "workspace.open(url, configuration: configuration)",
    "self.workspace.open([url], withApplicationAt: app, configuration: configuration)",
    "ws.open(url, configuration: NSWorkspace.OpenConfiguration())",
    "NSWorkspace.shared.activateFileViewerSelecting([url])",
    "workspace.activateFileViewerSelecting([url])",
    "workspace.selectFile(path, inFileViewerRootedAtPath: \"\")",
    "NSWorkspace.shared.openFile(path)",
]

PASSED = [
    "NSWorkspace.shared.openInBackground(url)",
    "NSWorkspace.shared.openInBackground([url], withApplicationAt: app)",
    "workspace.openInBackground([url], withApplicationAt: app)",
    "_ = await NSWorkspace.shared.openedInBackground([url], withApplicationAt: app)",
    "NSWorkspace.shared.revealInBackground([url])",
    # Wrappers with NSWorkspace-like labels are not NSWorkspace: they open through the helpers.
    "router.open(link, withApplicationAt: app)",
    "browsers.open(url, withApplicationAt: app)",
    "workspace.open(items.map(\\.url))",
    "linkOpener.openFile(url, from: pane)",
    "_ = NSWorkspace.shared.urlForApplication(toOpen: url)",
]


def source(statement):
    return f"import AppKit\nfunc go(_ workspace: NSWorkspace, _ ws: NSWorkspace) {{\n    {statement}\n}}\n"


def run(files):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "Package"
        root.mkdir(parents=True)
        (root / "Package.swift").write_text(MANIFEST)
        (root / "Sources" / "FixtureUI").mkdir(parents=True)
        for name, text in files.items():
            (root / "Sources" / name).parent.mkdir(parents=True, exist_ok=True)
            (root / "Sources" / name).write_text(text)
        return subprocess.run(["bash", str(SCRIPT), str(root)], text=True, capture_output=True, timeout=60,
                              env={**os.environ, "CHECK_CONCURRENCY_ONLY": "crash-class"})


class WorkspaceOpenRule(unittest.TestCase):
    def test_every_synchronous_open_and_reveal_is_refused(self):
        for statement in REFUSED:
            with self.subTest(statement=statement):
                result = run({"FixtureUI/View.swift": source(statement)})
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"View.swift:3: {RULE}", result.stdout)

    def test_the_background_helpers_and_look_alikes_pass(self):
        for statement in PASSED:
            with self.subTest(statement=statement):
                result = run({"FixtureUI/View.swift": source(statement)})
                self.assertNotIn(RULE, result.stdout, result.stdout + result.stderr)

    def test_the_helper_file_may_make_the_synchronous_calls(self):
        text = source("\n    ".join(REFUSED))
        result = run({"CmuxNextCompatAppKit/NSWorkspace+Background.swift": text})
        self.assertNotIn(RULE, result.stdout, result.stdout + result.stderr)

    def test_an_escape_comment_allows_a_reviewed_call(self):
        result = run({"FixtureUI/View.swift": source(
            "// concurrency-allow: fixture\n    NSWorkspace.shared.open(url, configuration: configuration)")})
        self.assertNotIn(RULE, result.stdout, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
