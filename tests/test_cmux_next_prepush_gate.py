#!/usr/bin/env python3
"""The pre-push hook refuses a push that adds a cmux-next static-check violation.

Each test builds a throwaway repository with the real hook installer, the real
scripts/cmux-next checks and a small CmuxNext package, then pushes to a bare
`origin` through the real `git push`, so the installed trusted hook copy is what
runs. The base already carries a `try!` (base debt): only what a push adds counts.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import git_fixture_env  # disables git auto maintenance


SOURCE = Path(__file__).resolve().parents[1]
INSTALLER = "scripts/install-git-hooks.sh"
GATE = "scripts/cmux-next/prepush-gate.py"
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID",
              "CODEX_SANDBOX", "CMUX_WEB_LINT_SKIP_REASON", "CMUX_NEXT_CHECKS_SKIP_REASON")
PKG = "Packages/macOS/CmuxNext"
# The pinned tools are downloaded once per machine; the fixture HOME must not hide that cache.
if os.uname().sysname == "Darwin":
    TOOLS = Path.home() / "Library" / "Caches" / "cmux-lint-tools"
else:
    TOOLS = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-lint-tools"
TOOLS = Path(os.environ.get("CMUX_LINT_TOOLS_DIR", TOOLS))

PACKAGE = """// swift-tools-version: 6.2
import PackageDescription
let uiSwiftSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(name: "CmuxNextApp", swiftSettings: uiSwiftSettings),
        .target(name: "CmuxNextKit", swiftSettings: uiSwiftSettings),
    ]
)
"""
APP = """import Foundation
func start() { ChildSignalDefaults.installAppSignalPolicy() }
"""
OLD = """import Foundation
struct Old {
    let regex = try! NSRegularExpression(pattern: "a+")
    func name() -> String { "old" }
}
"""
NEW_WITH_TRY = """import Foundation
struct Fresh {
    func load(_ url: URL) -> Data {
        try! Data(contentsOf: url)
    }
}
"""
NEW_CLEAN = """import Foundation
struct Fresh {
    func load(_ url: URL) async throws -> Data {
        try await Task.detached { try Data(contentsOf: url) }.value
    }
}
"""

INTENT = """import AppIntents
struct RecordChiefVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Voice Note for Chief"
    static let description = IntentDescription("It is transcribed on this device and sent to your Chief.")
}
"""

class PrePushGateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-prepush-gate-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.origin = self.root / "origin.git"
        self.global_config = self.root / "gitconfig"
        self.global_config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key not in AGENT_VARS}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.global_config),
                        HOME=str(self.root), CMUX_LINT_TOOLS_DIR=str(TOOLS))
        git_fixture_env.without_auto_maintenance(self.env)

        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=feat-cmux-next", str(self.origin)],
                       env=self.env, check=True, capture_output=True)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("remote", "add", "origin", str(self.origin))
        self.copy_sources()
        self.write(f"{PKG}/Package.swift", PACKAGE)
        self.write(f"{PKG}/Sources/CmuxNextApp/CmuxNextApp.swift", APP)
        self.write(f"{PKG}/Sources/CmuxNextKit/Old.swift", OLD)  # base debt: one try! already there
        self.commit("base")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        installed = subprocess.run(["bash", INSTALLER], cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)

    def copy_sources(self):
        tracked = subprocess.run(["git", "-C", str(SOURCE), "ls-files", "scripts/cmux-next"],
                                 text=True, capture_output=True, check=True).stdout.split()
        checks = [p for p in tracked if "/" not in p[len("scripts/cmux-next/"):] or p.startswith("scripts/cmux-next/lint/")]
        for relative in (
            "scripts/git-hooks",
            INSTALLER,
            "scripts/web_lint_prepush.py",
            "scripts/ci/base_merge_warning.py",
            "scripts/web-lint.sh",
            "scripts/merge-xcstrings.py",
            "scripts/merge-pbxproj.py",
            "scripts/merge-baseline.py",
            "scripts/merge-daemon-capabilities.py",
            "scripts/ci/merge_main_resolver.py",
            "scripts/ci/validate_test_execution_registry.py",
            "scripts/ci/test_execution_registry.py",
            "scripts/ci/workload_entrypoints.py",
            "scripts/normalize-pbxproj.py",
            *checks,
        ):
            source, target = SOURCE / relative, self.repo / relative
            if not source.exists():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)
                shutil.copymode(source, target)

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              text=True, capture_output=True, check=check)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def push(self, **env):
        return subprocess.run(["git", "-C", str(self.repo), "push", "origin", "feat-cmux-next"],
                              env={**self.env, **env}, text=True, capture_output=True)

    def remote_head(self):
        return subprocess.run(["git", "-C", str(self.origin), "rev-parse", "feat-cmux-next"],
                              env=self.env, text=True, capture_output=True).stdout.strip()

    def test_install_adds_the_gate_to_the_pre_push_hook(self):
        hooks = Path(self.git("config", "--get", "core.hooksPath").stdout.strip())
        self.assertTrue((hooks / "cmux_next_prepush_gate.py").is_file())

    def test_push_that_adds_a_try_bang_is_refused(self):
        before = self.remote_head()
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_TRY)
        self.commit("adds a try!")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the bad commit must not reach origin")
        self.assertIn("Fresh.swift", output)
        self.assertIn("try!", output)
        self.assertNotIn("Old.swift", output, "base debt in an untouched file must not be reported")

    def test_push_that_names_an_apple_device_in_an_app_intent_is_refused(self):
        # ITMS-90626 (2026-10-20): Apple rejected cmux INTERNAL builds after upload for this text.
        before = self.remote_head()
        self.write("cmux-next-ios/App/ChiefVoiceIntents.swift", INTENT.replace("this device", "this iPhone"))
        self.commit("intent text names the iPhone")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the rejected text must not reach origin")
        self.assertIn("90626-reserved-term", output)

    def test_push_with_device_neutral_app_intent_text_passes(self):
        self.write("cmux-next-ios/App/ChiefVoiceIntents.swift", INTENT)
        self.commit("intent text for every device")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_push_that_adds_conflict_markers_is_refused_even_with_a_skip_reason(self):
        # c779988d57d (2026-10-22) landed an unresolved merge in a test file; no scanner reads tests.
        before = self.remote_head()
        self.write(f"{PKG}/Tests/CmuxNextKitTests/MergedTests.swift",
                   "struct T {\n<<<<<<< HEAD\n    let a = 1\n=======\n    let a = 2\n>>>>>>> abc1234 (other)\n}\n")
        self.commit("unresolved merge")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="unrelated")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before, "the conflicted file must not reach origin")
        self.assertIn("Merge conflict markers", output)
        self.assertIn("MergedTests.swift:2: <<<<<<< HEAD", output)

    SIDEBAR_VIEW = f"{PKG}/Sources/CmuxNextSidebar/Views/RowView.swift"

    def test_a_sidebar_view_change_without_a_sidebar_look_trailer_is_refused_even_with_a_skip_reason(self):
        # 233 sidebar commits in four days undid each other (Lawrence 2026-10-23): the owner keeps the look.
        before = self.remote_head()
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: move the title")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="unrelated")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("Sidebar look owner", output)
        self.assertIn("no `Sidebar-Look:` trailer", output)

    def test_a_visual_sidebar_change_must_update_the_owner_note(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: move the title\n\nSidebar-Look: Lawrence 11405 text as left as possible")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("must update plans/cmux-next/sidebar-owner.md", output)

    def test_a_visual_sidebar_change_with_the_note_passes(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 6\n}\n")
        self.write("plans/cmux-next/sidebar-owner.md", "# owner\n- titles at the inset (Lawrence 11405)\n")
        self.commit("sidebar: title at the inset\n\nSidebar-Look: Lawrence 11405 text as left as possible")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_sidebar_change_marked_no_visual_change_passes_without_the_note(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let cache = [Int]()\n}\n")
        self.commit("sidebar: cache the rows\n\nSidebar-Look: no visual change")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_later_commit_does_not_launder_an_earlier_sidebar_change(self):
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 22\n}\n")
        self.commit("sidebar: move the title")
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let inset = 23\n}\n")
        self.write("plans/cmux-next/sidebar-owner.md", "# owner\n")
        self.commit("sidebar: tweak\n\nSidebar-Look: Lawrence said so")

        result = self.push()

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("sidebar: move the title", output)

    def test_a_sidebar_change_the_owner_logged_passes_in_the_ci_sweep(self):
        # dcd4316ef5c (2026-10-23) reached the branch from an old hook copy; the owner logs it once.
        self.write(self.SIDEBAR_VIEW, "struct RowView {\n    let flash = true\n}\n")
        self.commit("scrollers: flash on enter")
        first = self.git("rev-parse", "HEAD").stdout.strip()
        base = self.git("rev-parse", "HEAD^").stdout.strip()
        gate = self.repo / "scripts/cmux-next/prepush-gate.py"
        sweep = lambda: subprocess.run(["python3", "-I", str(gate), "--only", "sidebar", "--commits", f"{base}..HEAD"],
                                       cwd=self.repo, env=self.env, text=True, capture_output=True)
        unlogged = sweep()
        self.assertNotEqual(unlogged.returncode, 0, unlogged.stdout + unlogged.stderr)
        self.write("plans/cmux-next/sidebar-owner.md", f"# owner\n- {first[:11]} scrollers (a595), no look change\n")
        self.commit("plans: log the scroller commit")

        logged = sweep()

        self.assertEqual(logged.returncode, 0, logged.stdout + logged.stderr)

    def test_a_fixture_that_mentions_one_marker_passes(self):
        self.write("docs/merging.md", "Git writes a line such as\n<<<<<<< HEAD\nat the top of a hunk.\n")
        self.commit("docs mention a marker")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_push_that_touches_a_file_with_old_debt_passes(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Old.swift", OLD.replace('"old"', '"renamed"'))
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("edits next to an old try!, adds clean code")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_head(), self.git("rev-parse", "HEAD").stdout.strip())

    def test_branch_checker_changes_are_not_executed_by_the_installed_hook(self):
        marker = self.root / "branch-checker-ran"
        self.write(
            "scripts/cmux-next/check-concurrency.sh",
            f"#!/bin/bash\necho branch-controlled > {marker}\nexit 0\n",
        )
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("branch replaces a pre-push checker")

        self.push()

        self.assertFalse(marker.exists(), "the installed trusted hook executed the branch-controlled checker")

    def test_an_installed_lexer_older_than_origin_s_is_named_as_stale(self):
        # guardrails.py loads count-swift-code-lines.py from the installed copy; an old one counts unlike CI.
        lexer = "scripts/cmux-next/count-swift-code-lines.py"
        self.write(lexer, (self.repo / lexer).read_text() + "# changed upstream\n")
        self.commit("the lexer changes on feat-cmux-next")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("clean")

        pushed = self.push()

        self.assertIn("count-swift-code-lines.py", pushed.stdout + pushed.stderr)
        self.assertIn("installed hook copy", pushed.stdout + pushed.stderr)

    def test_push_from_a_linked_worktree_leaves_the_repository_alone(self):
        # git runs the hook with GIT_DIR=<repo>/.git/worktrees/<name>: the gate's own temp-tree
        # git calls must not inherit it (2026-10-19: it set core.bare=true on the shared clone and
        # staged the deletion of every file in the pushing worktree's index).
        linked = self.root / "linked"
        self.git("worktree", "add", "--quiet", "-b", "linked-work", str(linked), "feat-cmux-next")
        (linked / f"{PKG}/Sources/CmuxNextKit/Fresh.swift").write_text(NEW_CLEAN)
        run = lambda *args: subprocess.run(["git", "-C", str(linked), *args], env=self.env,
                                           text=True, capture_output=True)
        run("add", "-A")
        run("commit", "--quiet", "--no-verify", "-m", "clean change from a linked worktree")

        result = run("push", "origin", "linked-work:feat-cmux-next")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git("config", "--get", "core.bare").stdout.strip(), "false")
        self.assertEqual(run("diff", "--cached", "--name-only").stdout, "", "the pushing worktree's index must not change")
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, "")

    def test_skip_reason_lets_the_push_through_and_says_so(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_TRY)
        self.commit("adds a try!")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: the try! is in a file this push does not touch")

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("SKIPPED", output)

    def test_ci_commits_mode_names_the_commit_pushed_with_no_verify(self):
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_CLEAN)
        self.commit("clean commit")
        self.write(f"{PKG}/Sources/CmuxNextKit/Fresh.swift", NEW_WITH_TRY)
        self.commit("sneaks in a try!")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")

        result = subprocess.run(["python3", "-I", GATE, "--commits", "HEAD~2..HEAD"], cwd=self.repo,
                                env=self.env, text=True, capture_output=True)

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("sneaks in a try!", output)
        self.assertNotIn("clean commit adds", output)
        self.assertIn("2 commit(s) checked, 1 add violations", output)


    # Ghostty's default split keys (Lawrence 2026-10-20, after 2f3e1f95983 made Cmd-Opt-Left / Right
    # sidebar keys): the gate refuses a push whose exported keymap gives one to another action.
    RESERVED = {"reserved": [{"key": "cmd+opt+left", "command": "focusLeft", "ghostty": "goto_split:left"}],
                "scopedOwners": {"keys": ["codeEditorFocused"]}, "scopedActions": []}

    @staticmethod
    def surfaces(sidebar_alias):
        left = {"key": "\uf702", "modifiers": ["opt", "cmd"]}
        prev = {"id": "prevSidebarTab", "default_shortcut": {"key": "[", "modifiers": ["ctrl", "cmd"]},
                "default_aliases": [{"keys": [left], "when": None}] if sidebar_alias else []}
        focus = {"id": "focusLeft", "default_shortcut": left, "default_aliases": []}
        return {"version": 1, "actions": [focus, prev]}

    def reserved_base(self):
        import json
        self.write("schemas/keybindings/ghostty-reserved-keys.json", json.dumps(self.RESERVED))
        self.write("plans/cmux-next/action-surfaces.json", json.dumps(self.surfaces(False)))
        self.commit("reserved keys")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.write("plans/cmux-next/action-surfaces.json", json.dumps(self.surfaces(True)))

    def test_push_that_gives_a_ghostty_key_to_another_action_is_refused_even_with_a_skip_reason(self):
        self.reserved_base()
        before = self.remote_head()
        self.commit("Cmd-Opt-Left selects the previous sidebar item")

        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: unrelated base failure")

        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertEqual(self.remote_head(), before)
        self.assertIn("prevSidebarTab takes Ghostty's cmd+opt+left", output)
        self.assertIn("does not skip", output)

    def test_a_ghostty_defaults_ok_trailer_lets_the_change_through(self):
        self.reserved_base()
        self.commit("Cmd-Opt-Left selects the previous sidebar item\n\nGhostty-defaults-OK: \"fixture: yes, rebind it\"")

        result = self.push()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
