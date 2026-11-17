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
import importlib.util  # noqa: E402
import os  # noqa: E402

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

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
        self.assertEqual(self.verdict([("M", "images/cmux-vm/inputs.lock.json")]), "no-app")
        self.assertEqual(self.verdict([("M", "Packages/macOS/CmuxNext/ci-target-graph.json")]), "no-app")
        self.assertEqual(self.verdict([("M", "examples/extensions/activity/src/main.ts")]), "no-app")
        self.assertEqual(self.verdict([("M", "design/terminal-chat-toggle-gallery.html")]), "no-app")
        # The screen detector under cmux-tui/bindings/examples/ ships in the app: a daemon restart, not no-app.
        self.assertEqual(self.verdict([("M", "cmux-tui/bindings/examples/rust-agent-screen-detection/src/lib.rs")]),
                         "daemon")

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
        one_line = {VIEW: [("-", "    func gap() -> CGFloat { 8 }"), ("+", "    func gap() -> CGFloat { 10 }")]}
        self.assertEqual(self.verdict([("M", VIEW)], one_line), "swift-live")

    def test_new_types_enum_cases_and_resources_need_a_rebuild(self):
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "struct Chip: View {")]}), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "    case pinned")]}), "rebuild")
        self.assertEqual(self.verdict([("M", "Resources/Localizable.xcstrings")]), "rebuild")
        self.assertEqual(self.verdict([("M", "Packages/macOS/CmuxNext/Package.swift")]), "rebuild")

    def test_native_sources_need_a_rebuild_except_the_ones_cmux_tui_builds(self):
        self.assertEqual(self.verdict([("M", "cmux-tui/crates/cmux-remote-browser-host/csrc/rb_shim.mm")]), "daemon")
        self.assertEqual(self.verdict([("M", "cmux-tui/bindings/zig/src/raw/generated/protocol.zig")]), "daemon")
        self.assertEqual(self.verdict([("M", "ghostty/src/main.zig")]), "rebuild")
        self.assertEqual(self.verdict([("M", "Packages/macOS/CmuxNext/CEFShim/src/shim_client.mm")]), "rebuild")
        self.assertEqual(self.verdict([("M", "Sources/CmuxNextApp/Bridge.m")]), "rebuild")

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
        kit = "Packages/Shared/CmuxKit/Sources/CmuxKit/A.swift"
        result = live_apply.classify([("M", kit)], {kit: body})
        self.assertEqual(result["verdict"], "rebuild")
        self.assertEqual(result["reasons"], {"outside the live code modules (CmuxKit)": [kit]})
        new = "Packages/Shared/CmuxKit/Sources/CmuxKit/Chip.swift"
        self.assertEqual(self.verdict([("A", new)], {new: [("+", "struct Chip {}")]}), "rebuild")
        # Every CmuxNext module is patchable (#36522).
        self.assertEqual(self.verdict([("M", PANE)], {PANE: body}), "swift-live")
        # The view shell's inject.sh patches its own module.
        self.assertEqual(self.verdict([("M", SHELL)], {SHELL: body}), "swift-live")
        # A deleted file leaves its code in the binary unused, whatever its module.
        self.assertEqual(self.verdict([("D", PANE)]), "swift-live")

    def test_a_deleted_swift_file_is_live_and_ios_alone_leaves_the_mac_app(self):
        self.assertEqual(self.verdict([("D", VIEW)]), "swift-live")
        self.assertEqual(self.verdict([("M", "cmux-next-ios/App/Root.swift")]), "ios-only")

    def test_a_type_extension_or_conformance_added_whole_is_live(self):
        # T1 (research/2026-11-04-hot-swap-architecture.md): new symbols the patch carries.
        added = [("@", "@@ -40,0 +41,6 @@"), ("+", "private struct Chip: View {"), ("+", "    let title: String"),
                 ("+", "    case odd"), ("+", "    var body: some View { Text(\"}\") }"), ("+", "}"),
                 ("+", "extension HomeHostView: Sendable {}")]
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: added}), "swift-live")
        one_line = [("+", "private enum Tint { static let red = NSColor.systemRed }")]
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: one_line}), "swift-live")
        # Not whole in its hunk: a header that changed, or a type whose body has a removed line.
        header = [("-", "final class A: B {"), ("+", "final class A: B, C {")]
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: header}), "rebuild")
        split = [("+", "struct Chip {"), ("+", "    let a: Int"), ("@", "@@"), ("+", "}")]
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: split}), "rebuild")
        # The diff slid an appended type by one brace: the brace above it shows as added instead of its own.
        old = ["struct A {", "    let a = 1", "}"]
        new = old + ["", "struct B {", "    let b = 2", "}"]
        slid = [("+", "}", 3), ("+", "", 4), ("+", "struct B {", 5), ("+", "    let b = 2", 6)]
        self.assertEqual(live_apply.classify([("M", VIEW)], {VIEW: slid}, {VIEW: (old, new)})["verdict"], "swift-live")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: slid}), "rebuild")  # without the file, unknown
        # The same type removed and added again (rewritten): its layout may differ.
        rewritten = [("-", "struct Chip {"), ("-", "    let a: Int"), ("-", "}"),
                     ("+", "struct Chip {"), ("+", "    let a: Int"), ("+", "    let b: Int"), ("+", "}")]
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: rewritten}), "rebuild")

    def test_an_added_static_or_global_let_is_live_a_changed_one_is_not(self):
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "    private static let gap: CGFloat = 8")]}), "swift-live")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "let homeGap: CGFloat = 8")]}), "swift-live")
        changed = [("-", "    static let gap: CGFloat = 8"), ("+", "    static let gap: CGFloat = 10")]
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: changed}), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "    static var count = 0")]}), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "    let title: String")]}), "rebuild")

    def test_a_changed_signature_is_live_when_only_the_patch_calls_it_directly(self):
        old = ["final class HomeHostView: NSView {", "    func layoutChips(_ a: Int) {", "    }",
               "    private func tint() {", "    }", "}", "class Base {", "    func draw() {", "    }", "}"]
        new = ["final class HomeHostView: NSView {", "    func layoutChips(_ a: Int, b: Int = 0) {", "    }",
               "    private func tint(alpha: Double) {", "    }", "}", "class Base {", "    func draw(_ a: Int) {", "    }",
               "    func added() {", "    }", "}"]

        def reasons(pairs, named=False):
            return live_apply.classify([("M", VIEW)], {VIEW: pairs}, {VIEW: (old, new)},
                                       lambda name: named)["reasons"]
        member = [("-", old[1], 2), ("+", new[1], 2)]
        self.assertEqual(reasons(member), {})
        self.assertEqual(reasons(member, named=True), {"signature": [VIEW]})
        private = [("-", old[3], 4), ("+", new[3], 4)]
        self.assertEqual(reasons(private, named=True), {})
        # A class that is not final reaches its members through a vtable: changed or new, a rebuild.
        self.assertEqual(reasons([("-", old[7], 8), ("+", new[7], 8)]), {"signature": [VIEW]})
        self.assertEqual(reasons([("+", new[9], 10)]), {"signature": [VIEW]})
        override = [("-", "    override func layout() {", 2), ("+", "    override func layout(_ x: Int) {", 2)]
        self.assertEqual(reasons(override), {"signature": [VIEW]})
        init = [("-", "    init(a: Int) {", 2), ("+", "    init(a: Int, b: Int) {", 2)]
        self.assertEqual(reasons(init), {"signature": [VIEW]})

    def test_parse_diff_numbers_lines_and_marks_hunks(self):
        text = ("diff --git a/V.swift b/V.swift\n--- a/V.swift\n+++ b/V.swift\n@@ -3,0 +4,2 @@\n+a\n+b\n"
                "@@ -9 +11 @@\n--- old\n+new\n")
        self.assertEqual(live_apply.parse_diff(text)["V.swift"],
                         [("@", "@@ -3,0 +4,2 @@"), ("+", "a", 4), ("+", "b", 5), ("@", "@@ -9 +11 @@"),
                          ("-", "-- old", 9), ("+", "new", 11)])

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
            # A new type and a changed signature of a final class's member that only this file calls.
            other = Path(repo, VIEW).with_name("Other.swift")
            view.write_text("final class V {\n    func tint(_ a: Int) -> Int { a }\n    func draw() -> Int { tint(1) }\n}\n")
            other.write_text("struct W { let v = V() }\n")
            git("add", "-A")
            git("commit", "-qm", "class")
            view.write_text("final class V {\n    func tint(_ a: Int, b: Int = 2) -> Int { a + b }\n"
                            "    func draw() -> Int { tint(1) + Chip().x }\n}\n\nstruct Chip {\n    let x = 1\n}\n")
            git("commit", "-qam", "t1")
            result = live_apply.classify_range(repo, "HEAD~1", "HEAD")
            self.assertEqual((result["verdict"], result["reasons"]), ("swift-live", {}))
            # Another file calls it: that call the patch does not compile may reach the old one.
            other.write_text("struct W { let v = V(); func f() -> Int { v.tint(3) } }\n")
            git("commit", "-qam", "caller")
            view.write_text("final class V {\n    func tint(_ a: Int, c: Int = 2) -> Int { a + c }\n"
                            "    func draw() -> Int { tint(1) + Chip().x }\n}\n\nstruct Chip {\n    let x = 1\n}\n")
            git("commit", "-qam", "t1 again")
            self.assertEqual(live_apply.classify_range(repo, "HEAD~1", "HEAD")["reasons"], {"signature": [VIEW]})


if __name__ == "__main__":
    unittest.main()
