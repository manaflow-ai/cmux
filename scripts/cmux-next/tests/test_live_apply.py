#!/usr/bin/env python3
"""live_apply.py: what a running cmux NEXT app could take from a PR without a new build.

Runs on any host (Linux included): no app, no fleet.

    python3 -m unittest scripts/cmux-next/tests/test_live_apply.py
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import live_apply  # noqa: E402

VIEW = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"
# A module the app's live code build does not patch (docs/cmux-next/live-code.md: CmuxNextApp only).
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneView.swift"
SHELL = "Prototypes/ViewShell/Sources/ViewShell/Badge.swift"


class ClassifyTests(unittest.TestCase):
    def verdict(self, files, diffs=None):
        return live_apply.classify(files, diffs or {})["verdict"]

    def test_tests_docs_and_ci_change_nothing_in_the_app(self):
        self.assertEqual(self.verdict([("M", "docs/x.md"), ("M", ".github/workflows/a.yml"),
                                       ("A", "scripts/cmux-next/tests/test_x.py")]), "no-app")

    def test_a_web_change_is_live(self):
        self.assertEqual(self.verdict([("M", "webviews/src/agent-pane/Composer.tsx"), ("M", "docs/a.md")]), "web-live")

    def test_rust_is_a_daemon_restart_and_outweighs_web(self):
        self.assertEqual(self.verdict([("M", "cmux-tui/src/main.rs"), ("M", "webviews/src/a.tsx")]), "daemon")

    def test_lockfiles_bundled_scripts_and_web_config_are_not_no_app(self):
        self.assertEqual(self.verdict([("M", "cmux-tui/Cargo.lock")]), "daemon")
        self.assertEqual(self.verdict([("M", "acpmux/Cargo.toml")]), "daemon")
        self.assertEqual(self.verdict([("M", "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/upgrade.sh")]), "rebuild")
        self.assertEqual(self.verdict([("M", "webviews/vite.config.mjs"), ("M", "webviews/bun.lock")]), "web-live")
        self.assertEqual(self.verdict([("M", "scripts/cmux-next/x.sh"), ("M", "README.txt")]), "no-app")

    def test_a_body_only_swift_edit_is_swift_live(self):
        diffs = {VIEW: [("-", "        Text(\"old\")"), ("+", "        Text(\"new\")")]}
        self.assertEqual(self.verdict([("M", VIEW)], diffs), "swift-live")

    def test_a_stored_property_needs_a_rebuild(self):
        result = live_apply.classify([("M", VIEW)], {VIEW: [("+", "    var isPinned = false")]})
        self.assertEqual(result["verdict"], "rebuild")
        self.assertEqual(result["reasons"], {"stored property": [VIEW]})

    def test_a_changed_signature_needs_a_rebuild_and_a_new_function_does_not(self):
        changed = {VIEW: [("-", "    func draw(_ a: Int) {"), ("+", "    func draw(_ a: Int, b: Int) {")]}
        self.assertEqual(self.verdict([("M", VIEW)], changed), "rebuild")
        added = {VIEW: [("+", "    func helper() -> Int {"), ("+", "        1"), ("+", "    }")]}
        self.assertEqual(self.verdict([("M", VIEW)], added), "swift-live")

    def test_new_types_enum_cases_and_resources_need_a_rebuild(self):
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "struct Chip: View {")]}), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "    case pinned")]}), "rebuild")
        self.assertEqual(self.verdict([("M", "Resources/Localizable.xcstrings")]), "rebuild")
        self.assertEqual(self.verdict([("M", "Packages/macOS/CmuxNext/Package.swift")]), "rebuild")

    def test_a_new_swift_file_is_live_unless_it_is_an_entry_point(self):
        new = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Chip.swift"
        diffs = {new: [("+", "struct Chip: View {"), ("+", "    let title: String"), ("+", "    var body: some View { Text(title) }"), ("+", "}")],
                 VIEW: [("+", "        Chip(title: name)")]}
        self.assertEqual(self.verdict([("A", new), ("M", VIEW)], diffs), "swift-live")
        self.assertEqual(self.verdict([("A", new)], {new: [("+", "@main"), ("+", "struct App {}")]}), "rebuild")
        self.assertEqual(self.verdict([("A", "Packages/macOS/CmuxNext/Sources/CmuxNextApp/main.swift")]), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "@main")]}), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "@MainActor @main")]}), "rebuild")
        self.assertEqual(self.verdict([("A", new)], {new: [("+", "@available(macOS 14, *) @main struct App {}")]}), "rebuild")

    def test_swift_outside_the_live_code_modules_needs_a_rebuild(self):
        body = [("-", "        Text(\"old\")"), ("+", "        Text(\"new\")")]
        result = live_apply.classify([("M", PANE)], {PANE: body})
        self.assertEqual(result["verdict"], "rebuild")
        self.assertEqual(result["reasons"], {"outside the live code modules (CmuxNextAgentPane)": [PANE]})
        new = "Packages/macOS/CmuxNext/Sources/CmuxNextUI/Chip.swift"
        self.assertEqual(self.verdict([("A", new)], {new: [("+", "struct Chip {}")]}), "rebuild")
        self.assertEqual(self.verdict([("M", "Packages/Shared/CmuxKit/Sources/CmuxKit/A.swift")], {}), "rebuild")
        # The view shell's inject.sh patches its own module.
        self.assertEqual(self.verdict([("M", SHELL)], {SHELL: body}), "swift-live")
        # A deleted file leaves its code in the binary unused, whatever its module.
        self.assertEqual(self.verdict([("D", PANE)]), "swift-live")

    def test_a_deleted_swift_file_is_live_and_ios_alone_leaves_the_mac_app(self):
        self.assertEqual(self.verdict([("D", VIEW)]), "swift-live")
        self.assertEqual(self.verdict([("M", "cmux-next-ios/App/Root.swift")]), "ios-only")

    def test_the_heaviest_file_wins(self):
        diffs = {VIEW: [("+", "    var x = 1")]}
        self.assertEqual(self.verdict([("M", "webviews/src/a.tsx"), ("M", VIEW)], diffs), "rebuild")


class GitRangeTests(unittest.TestCase):
    def test_classify_range_reads_the_diff_from_git(self):
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)
            git("init", "-q")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "t")
            view = Path(repo, VIEW)
            view.parent.mkdir(parents=True)
            view.write_text("struct V {\n    var body: some View {\n        Text(\"old\")\n    }\n}\n")
            git("add", "-A")
            git("commit", "-qm", "base")
            view.write_text("struct V {\n    var body: some View {\n        Text(\"new\")\n    }\n}\n")
            git("commit", "-qam", "body")
            self.assertEqual(live_apply.classify_range(repo, "HEAD~1", "HEAD")["verdict"], "swift-live")
            view.write_text("struct V {\n    var pinned = false\n    var body: some View {\n        Text(\"new\")\n    }\n}\n")
            git("commit", "-qam", "stored")
            self.assertEqual(live_apply.classify_range(repo, "HEAD~1", "HEAD")["verdict"], "rebuild")


if __name__ == "__main__":
    unittest.main()
