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
        self.assertEqual(self.verdict([("M", ".gitattributes")]), "no-app")
        # design/ holds generator sources and design pages; the generated files the app reads are elsewhere.
        self.assertEqual(self.verdict([("M", "design/live-wallpapers-gallery/aurora.js")]), "no-app")
        self.assertEqual(self.verdict([("M", "design/icons/source/widgets.json")]), "no-app")
        # vault/ is a Go service the app never builds; capture-scratch/ is screenshot replay output.
        self.assertEqual(self.verdict([("M", "vault/internal/syncer/redact.go")]), "no-app")
        self.assertEqual(self.verdict([("A", "capture-scratch/replay/manifest.json")]), "no-app")
        self.assertEqual(self.verdict([("D", "dogfood/scenarios/copy-actions-tour.json")]), "no-app")
        self.assertEqual(self.verdict([("M", "evals/computer-use/tasks/finder-new-folder.json")]), "no-app")
        self.assertEqual(self.verdict([("A", "Native/OptChat/optchat-chief/evals/cases/upsell-a675-cloud-plan-required.json")]),
                         "no-app")
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

    def test_a_one_line_function_whose_body_changed_is_not_a_signature_change(self):
        changed = {VIEW: [("-", "    func on(_ e: [String: String]) -> Bool { e[\"k\"] == \"1\" }"),
                          ("+", "    func on(_ e: [String: String]) -> Bool { e[\"k\"] != \"0\" }")]}
        self.assertEqual(self.verdict([("M", VIEW)], changed), "swift-live")

    def test_a_changed_signature_needs_a_rebuild_and_a_new_function_does_not(self):
        changed = {VIEW: [("-", "    func draw(_ a: Int) {"), ("+", "    func draw(_ a: Int, b: Int) {")]}
        self.assertEqual(self.verdict([("M", VIEW)], changed), "rebuild")
        added = {VIEW: [("+", "    func helper() -> Int {"), ("+", "        1"), ("+", "    }")]}
        self.assertEqual(self.verdict([("M", VIEW)], added), "swift-live")

    def test_new_types_enum_cases_and_resources_need_a_rebuild(self):
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "struct Chip: View {")]}), "rebuild")
        self.assertEqual(self.verdict([("M", VIEW)], {VIEW: [("+", "    case pinned")]}), "rebuild")
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

    def test_string_catalogs_are_tried_with_no_build_and_ci_still_builds_them(self):
        catalog = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/Localizable.xcstrings"
        lab = "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Resources/CmuxHome.xcstrings"
        result = live_apply.classify([("M", catalog), ("M", lab)], {})
        self.assertEqual(result["verdict"], "strings")
        self.assertEqual(result["reasons"], {})
        self.assertEqual(result["files"], {"strings": sorted([catalog, lab])})
        # A body edit beside it is still a live code patch; web UI beside it is still a web swap.
        body = {VIEW: [("-", "        Text(\"old\")"), ("+", "        Text(\"new\")")]}
        self.assertEqual(self.verdict([("M", catalog), ("M", VIEW)], body), "swift-live")
        self.assertEqual(self.verdict([("M", catalog), ("M", "webviews/src/a.tsx")]), "web-live")
        # Compiled tables, plists and the iPhone app's catalogs keep their rules.
        self.assertEqual(self.verdict([("M", "Resources/en.lproj/Localizable.strings")]), "rebuild")
        self.assertEqual(self.verdict([("M", "Packages/iOS/CmuxMobile/Resources/Localizable.xcstrings")]), "ios-only")

    def test_typescript_only_the_web_bundles_import_is_web_live(self):
        generated = "clients/ts/cloud/src/generated.ts"
        result = live_apply.classify([("M", generated)], {})
        self.assertEqual(result["verdict"], "web-live")
        self.assertEqual(result["reasons"], {})
        self.assertEqual(self.verdict([("M", "config/vite-plus/check.ts")]), "web-live")

    def test_no_web_bundle_input_is_filed_as_an_unknown_app_file(self):
        # The router's BUNDLE_INPUTS lists what the web bundles are built from, outside webviews/ included
        # (tests/test_web_bundle_key_inputs.sh keeps it complete). None of them is native code, so none may fall
        # through to "other app file" (a rebuild), as clients/ts/cloud/src/generated.ts did. The markdown viewer's
        # scripts are also copied into the app as they are (Resources/markdown-viewer): those stay a rebuild.
        import ast
        router = Path(__file__).resolve().parents[2] / "ci" / "cmux_next_route.py"
        tree = ast.parse(router.read_text())
        inputs = next(ast.literal_eval(node.value) for node in ast.walk(tree) if isinstance(node, ast.Assign)
                      and any(getattr(t, "id", None) == "BUNDLE_INPUTS" for t in node.targets))
        self.assertIn("clients/ts/cloud/src/generated.ts", inputs)
        for spec in inputs:
            if spec.startswith("Resources/markdown-viewer/"):
                continue
            path = spec.replace("*", "x.json")
            reasons = live_apply.classify([("M", path)], {})["reasons"]
            self.assertNotIn("other app file", reasons, spec)

    def test_messages_lab_home_is_a_live_code_module(self):
        body = [("-", "        label.stringValue = old"), ("+", "        label.stringValue = new")]
        home = "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/TranscriptView.swift"
        self.assertEqual(self.verdict([("M", home)], {home: body}), "swift-live")
        # Its sibling module is not in the live code build.
        sidebar = "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabSidebar/SidebarView.swift"
        self.assertEqual(self.verdict([("M", sidebar)], {sidebar: body}), "rebuild")

    def test_a_deleted_swift_file_is_live_and_ios_alone_leaves_the_mac_app(self):
        self.assertEqual(self.verdict([("D", VIEW)]), "swift-live")
        self.assertEqual(self.verdict([("M", "cmux-next-ios/App/Root.swift")]), "ios-only")

    def test_a_deleted_file_of_no_known_kind_changes_nothing_in_the_running_app(self):
        # 3a7431d83d2 deleted the root strays OUTPUT and summary: the running app read neither.
        self.assertEqual(self.verdict([("D", "OUTPUT"), ("D", "summary")]), "no-app")
        self.assertEqual(self.verdict([("M", "summary")]), "rebuild")
        # A deleted resource or manifest still needs the new app.
        self.assertEqual(self.verdict([("D", "Packages/macOS/CmuxNext/Sources/CmuxNextIcons/Resources/cmux-icons.json")]),
                         "rebuild")

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


class ScopeTests(unittest.TestCase):
    """classify_range reads both sides of each changed file, so it knows a function's body from a type's members."""

    def range_verdict(self, files):
        """files: [(path, before or None, after or None)] -> classify_range's verdict for that one commit."""
        with tempfile.TemporaryDirectory() as repo:
            def git(*args):
                subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True)
            git("init", "-q")
            git("config", "user.email", "t@example.com")
            git("config", "user.name", "t")
            for path, before, _ in files:
                if before is not None:
                    Path(repo, path).parent.mkdir(parents=True, exist_ok=True)
                    Path(repo, path).write_text(before)
            git("add", "-A")
            git("commit", "-qm", "base", "--allow-empty")
            for path, _, after in files:
                if after is None:
                    Path(repo, path).unlink()
                else:
                    Path(repo, path).parent.mkdir(parents=True, exist_ok=True)
                    Path(repo, path).write_text(after)
            git("add", "-A")
            git("commit", "-qm", "change")
            return live_apply.classify_range(repo, "HEAD~1", "HEAD")

    def test_a_type_declared_in_a_function_body_is_the_functions_code(self):
        before = "struct V {\n    func load() {\n        let x = 1\n    }\n}\n"
        after = ("struct V {\n    func load() {\n        struct Reply: Decodable { var stale: Bool }\n"
                 "        func name(_ id: String) -> String { id }\n        let x = 1\n    }\n}\n")
        self.assertEqual(self.range_verdict([(VIEW, before, after)])["verdict"], "swift-live")

    def test_members_of_a_type_with_any_modifier_are_still_members(self):
        before = "nonisolated public struct Flow: Sendable {\n    var a = 1\n}\n"
        after = "nonisolated public struct Flow: Sendable {\n    var a = 1\n    private var b = 2\n}\n"
        self.assertEqual(self.range_verdict([(VIEW, before, after)])["reasons"], {"stored property": [VIEW]})

    def test_a_type_moved_to_another_file_is_still_compared(self):
        # Codegen moving a struct out of a hand-written file: the build defines it and the loader compares it.
        other = VIEW.replace("HomeHostView", "Generated")
        old = "public struct Snap: Decodable {\n    public var a: Int\n}\n"
        new = "public struct Snap: Decodable {\n    public var a: Int\n    public var b: Int\n}\n"
        self.assertEqual(self.range_verdict([(VIEW, old + "struct V {}\n", "struct V {}\n"),
                                             (other, "// gen\n", "// gen\n" + new)])["verdict"], "rebuild")

    def test_a_brand_new_type_in_a_changed_file_is_live(self):
        before = "struct V {\n    var a = 1\n}\n"
        after = before + "private struct Chip {\n    var on = false\n    func f(_ x: Int) {}\n}\n"
        self.assertEqual(self.range_verdict([(VIEW, before, after)])["verdict"], "swift-live")

    def test_a_private_signature_change_is_live_unless_the_runtime_calls_it_by_name(self):
        before = "struct V {\n    private func f(_ a: Int) {}\n}\n"
        after = "struct V {\n    private func f(_ a: Int, b: Int = 0) {}\n}\n"
        self.assertEqual(self.range_verdict([(VIEW, before, after)])["verdict"], "swift-live")
        objc = [(VIEW, "final class V {\n    @objc\n    private func f(_ a: Int) {}\n}\n",
                 "final class V {\n    @objc\n    private func f(_ a: Int, b: Int) {}\n}\n")]
        self.assertEqual(self.range_verdict(objc)["verdict"], "rebuild")

    def test_a_signature_change_is_live_when_every_file_that_names_it_is_patched(self):
        caller = VIEW.replace("HomeHostView", "Caller")
        before = "enum Rules {\n    static func row(_ a: Int) -> Int { a }\n}\n"
        after = "enum Rules {\n    static func row(_ a: Int, b: Int = 0) -> Int { a + b }\n}\n"
        uses = "struct C {\n    var n: Int { Rules.row(1) }\n}\n"
        self.assertEqual(self.range_verdict([(VIEW, before, after), (caller, uses, uses + "\n")])["verdict"],
                         "swift-live")
        # An unchanged caller still calls the build's old symbol (a defaulted parameter keeps it compiling).
        self.assertEqual(self.range_verdict([(VIEW, before, after), (caller, uses, uses)])["verdict"], "rebuild")

    def test_a_method_of_a_class_that_can_be_subclassed_keeps_its_vtable_slot(self):
        before = "class V {\n    func f(_ a: Int) {}\n}\n"
        after = "class V {\n    func f(_ a: Int, b: Int) {}\n}\n"
        self.assertEqual(self.range_verdict([(VIEW, before, after)])["verdict"], "rebuild")


if __name__ == "__main__":
    unittest.main()
