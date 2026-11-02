#!/usr/bin/env python3
"""cmux-next guardrails (scripts/cmux-next/guardrails.py): refuse new debt, warn on hot paths and owners.

Each test commits into a throwaway repository and checks what the commit adds. The rule tests call
`guardrails.check` directly; the hook tests install the real hooks and push through the real `git push`,
so the installed trusted copy of the gate is what runs. Not on CI (Lawrence 2026-10-23: "not to add
gates/tests in CI, but you have to run them yourself"): run it yourself after every change to guardrails.py,
prepush-gate.py's guardrails path or install-git-hooks.sh: python3 tests/test_cmux_next_guardrails.py
"""
import contextlib
import dataclasses
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest import mock


def _load_git_fixture_env():
    """tests/git_fixture_env.py by path, so `python3 -I` (no script folder on sys.path) runs this file too."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # importing it disables git auto maintenance
    return module


git_fixture_env = _load_git_fixture_env()

SOURCE = Path(__file__).resolve().parents[1]
PKG = "Packages/macOS/CmuxNext"
KIT = f"{PKG}/Sources/CmuxNextKit"
APP = f"{PKG}/Sources/CmuxNextApp"
AGENT_VARS = ("CMUX_AGENT", "CMUX_REQUIRE_FORMATTERS", "CI", "CLAUDECODE", "CODEX_CI", "CODEX_THREAD_ID",
              "CODEX_SANDBOX", "CMUX_WEB_LINT_SKIP_REASON", "CMUX_NEXT_CHECKS_SKIP_REASON",
              "CMUX_GUARDRAILS_SKIP_REASON", "GITHUB_ACTIONS")
if os.uname().sysname == "Darwin":
    TOOLS = Path.home() / "Library" / "Caches" / "cmux-lint-tools"
else:
    TOOLS = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cmux-lint-tools"
TOOLS = Path(os.environ.get("CMUX_LINT_TOOLS_DIR", TOOLS))

_spec = importlib.util.spec_from_file_location("cmux_next_guardrails", SOURCE / "scripts/cmux-next/guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

HOT = """import Foundation
final class Router {
    var count = 0
    func dispatch(_ key: Int) { // perf-hot: 2ms key-dispatch
        count += key
    }
    func cold() {
        count = 0
    }
}
"""
OWNERS = """# owners

| Area | Paths | Owner | Read first |
|---|---|---|---|
| Kit sidebar | `Packages/macOS/CmuxNext/Sources/CmuxNextKit/Sidebar/` | a590 | [sidebar-owner.md](sidebar-owner.md) |
"""
BENCHES = '{"paths": {"key-dispatch": {"bench": "scripts/cmux-next/bench-typing.py", "owner": "PL-typing"}}}'
# Base debt: one main-queue hop (the line rules' running example).
OLD = "final class Old {\n    func f() {\n        DispatchQueue.main.async { print(0) }\n    }\n}\n"
ROW = """import SwiftUI
struct WorkspaceRow: View {
    let title: String
    var body: some View { Text(title) }
}
"""

# rule id -> (file text that adds it, the same with its reviewed escape or the right pattern). Singletons,
# assumeIsolated and Notification.Name have no line rule: the arch ratchet holds them
# (scripts/cmux-next/tests/test_arch_ratchet.py); sleeps are check-concurrency.sh's (SleepRuleTests).
CASES = {
    "unchecked-sendable": ("final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
                           "// crash-allow: x is written once in init, then only read\n"
                           "final class Box: @unchecked Sendable {\n    let x = 0\n}\n"),
    "main-async": ("func f() {\n    DispatchQueue.main.async { print(1) }\n}\n",
                   "@MainActor func f() {\n    print(1)\n}\n"),
    "combine-state": ("import Combine\nfinal class Model: ObservableObject {\n    @Published var x = 0\n}\n",
                      "import Observation\n@Observable final class Model {\n    var x = 0\n}\n"),
    "generic-class-deinit": ("@MainActor final class Once<T> {\n    var value: T?\n}\n",
                             "@MainActor final class Once<T> {\n    var value: T?\n    nonisolated deinit {}\n}\n"),
    "action-wait": ("func bind(_ registry: ActionRegistry) {\n"
                    "    registry.bind(\"renamePane\", invoke: { _ in ctx.send(\"rename-pane\") { try await $0.rename() } })\n}\n",
                    "func bind(_ registry: ActionRegistry) {\n"
                    "    registry.bind(\"renamePane\", effect: { _ in daemon.intentEffect(\"rename-pane\", intent) { try await $0.rename() } })\n}\n"),
    "appkit-index": ("@objc func clicked() {\n    guard let item = browser.item(atRow: browser.clickedRow, inColumn: browser.clickedColumn) else { return }\n}\n",
                     "@objc func clicked() {\n    guard let item = browser.clickedItemIfValid else { return }\n}\n"),
    "undo-text-write": ("func build() {\n    textView.allowsUndo = true\n}\n",
                        "func build() {\n    textView.allowsUndo = true // undo-safe: TextBoxTextView.replaceText\n}\n"),
    "row-store": ("import SwiftUI\nstruct WorkspaceRow: View {\n    let title: String\n"
                  "    @Environment(SidebarStore.self) private var store\n    var body: some View { Text(title) }\n}\n",
                  "import SwiftUI\nstruct WorkspaceRow: View {\n    let title: String\n    let onSelect: () -> Void\n"
                  "    var body: some View { Text(title) }\n}\n"),
}


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cmux-guardrails-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repository"
        self.origin = self.root / "origin.git"
        config = self.root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in AGENT_VARS}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(self.root),
                        CMUX_LINT_TOOLS_DIR=str(TOOLS))
        git_fixture_env.without_auto_maintenance(self.env)
        subprocess.run(["git", "init", "--quiet", "--bare", "--initial-branch=feat-cmux-next", str(self.origin)],
                       env=self.env, check=True, capture_output=True)
        self.repo.mkdir()
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.git("remote", "add", "origin", str(self.origin))
        self.write(f"{KIT}/Router.swift", HOT)
        self.write(f"{KIT}/WorkspaceRow.swift", ROW)
        self.write(f"{KIT}/Old.swift", OLD)  # base debt
        self.write("plans/cmux-next/OWNERS.md", OWNERS)
        self.write("scripts/cmux-next/perf-hot-benches.json", BENCHES)
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=check)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def rebase_on(self, files, message="more base debt"):
        for relative, text in files.items():
            self.write(relative, text)
        self.commit(message)
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def check(self, function=None, *args):
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            return (function or guardrails.check)(self.repo, *(args or (self.base, "HEAD")))
        finally:
            os.environ.update(saved)

    def refused(self, *args):
        return [(r.id, [f"{h.path.rsplit('/', 1)[-1]}: {h.text.strip()}" for h in hits]) for r, hits in self.check(*args)[0]]

    def rebase_on(self, files, message="more base debt"):
        for relative, text in files.items():
            self.write(relative, text)
        self.commit(message)
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def report(self, skip, refusals):
        os.environ[guardrails.SKIP_ENV] = skip
        try:
            return guardrails.format_report(refusals, [])
        finally:
            del os.environ[guardrails.SKIP_ENV]


class RuleTests(Fixture):
    def test_each_rule_refuses_what_a_push_adds_and_passes_the_right_pattern(self):
        for rule, (bad, good) in CASES.items():
            with self.subTest(rule=rule):
                self.git("reset", "--quiet", "--hard", self.base)
                target = f"{KIT}/WorkspaceRow.swift" if rule == "row-store" else f"{KIT}/Added.swift"
                self.write(target, bad)
                self.commit(f"adds {rule}")
                refusals, _ = self.check()
                self.assertIn(rule, [r.id for r, _ in refusals], f"{rule} not refused")
                text, refused = guardrails.format_report(refusals, [])
                self.assertTrue(refused)
                self.assertIn("why:", text)
                self.assertIn("do:", text)
                self.assertIn(guardrails.SKIP_ENV, text)

                self.git("reset", "--quiet", "--hard", self.base)
                self.write(target, good)
                self.commit(f"right pattern for {rule}")
                refusals, _ = self.check()
                self.assertEqual([r.id for r, _ in refusals], [], f"{rule}: the right pattern was refused")

    def test_base_debt_and_moved_lines_never_count(self):
        self.git("mv", f"{KIT}/Old.swift", f"{KIT}/Moved.swift")
        self.write(f"{KIT}/Router.swift", HOT.replace("var count = 0", "var count = 1"))
        self.commit("moves the old main hop and edits elsewhere")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def test_editing_a_line_that_already_has_debt_adds_none(self):
        before = {
            f"{KIT}/Box.swift": "final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
        }
        self.rebase_on(before)
        after = {
            f"{KIT}/Old.swift": OLD.replace("print(0)", "print(1)"),
            f"{KIT}/Box.swift": "final class Box: Equatable, @unchecked Sendable {\n    var x = 0\n}\n",
        }
        for relative, text in after.items():
            self.write(relative, text)
        self.commit("edits lines that already had debt")
        refusals, _ = self.check()
        self.assertEqual([(r.id, [h.text.strip() for h in hits]) for r, hits in refusals], [])

    def test_an_edit_does_not_hide_a_second_new_hit_in_the_same_file(self):
        self.write(f"{KIT}/Old.swift", "final class Old {\n    func f() {\n        DispatchQueue.main.async { print(2) }\n"
                                       "    }\n    func g() {\n        DispatchQueue.main.async { print(3) }\n    }\n}\n")
        self.commit("edits one main hop and adds another")
        refusals, _ = self.check()
        self.assertEqual([(r.id, len(hits)) for r, hits in refusals], [("main-async", 1)])

    # rule id -> (file with justified debt, the escape line) for every rule whose escape sits above the line.
    ESCAPED = {
        "unchecked-sendable": ("// crash-allow: x is written once in init, then only read\n"
                               "final class Box: @unchecked Sendable {\n    let x = 0\n}\n",
                               "// crash-allow: x is written once in init, then only read\n"),
        "main-async": ("func f() {\n    // main-async-allow: AppKit's sheet callback API forces a GCD hop\n"
                       "    DispatchQueue.main.async { print(1) }\n}\n",
                       "    // main-async-allow: AppKit's sheet callback API forces a GCD hop\n"),
        "row-store": ("import SwiftUI\nstruct WorkspaceRow: View {\n    // row-snapshot-allow: one row, never in a list\n"
                      "    @Environment(SidebarStore.self) private var store\n    var body: some View { Text(\"x\") }\n}\n",
                      "    // row-snapshot-allow: one row, never in a list\n"),
        "generic-class-deinit": ("// generic-class-allow: its target is nonisolated by default\nfinal class Once<T> {\n    var value: T?\n}\n",
                                 "// generic-class-allow: its target is nonisolated by default\n"),
        "action-wait": ("func bind(_ registry: ActionRegistry) {\n    // action-wait-allow: only the server can answer\n"
                        "    registry.bind(\"renamePane\", invoke: { _ in ctx.send(\"rename-pane\") { try await $0.rename() } })\n}\n",
                        "    // action-wait-allow: only the server can answer\n"),
        "task-priority": ("func start() {\n    // qos-allow: the work inherits nothing and has no deadline\n"
                          "    Task.detached { await work() }\n}\n",
                          "    // qos-allow: the work inherits nothing and has no deadline\n"),
    }

    def test_removing_only_the_escape_comment_is_new_debt(self):
        start = self.base
        for rule, (text, escape) in self.ESCAPED.items():
            for name, after in (("deleted", text.replace(escape, "")),
                                ("reworded", text.replace(escape, escape.split("//")[0] + "// reviewed once\n"))):
                with self.subTest(rule=rule, how=name):
                    self.git("reset", "--quiet", "--hard", start)
                    self.rebase_on({f"{KIT}/Escaped.swift": text}, "justified debt")
                    self.assertEqual(self.refused(guardrails.check, self.base, "HEAD"), [])
                    self.write(f"{KIT}/Escaped.swift", after)
                    self.commit(f"{name} the escape only")
                    self.assertEqual([r for r, _ in self.refused()], [rule])

    def test_editing_the_escape_reason_or_a_line_above_old_debt_adds_none(self):
        start = self.base
        for rule, (text, escape) in self.ESCAPED.items():
            with self.subTest(rule=rule):
                self.git("reset", "--quiet", "--hard", start)
                self.rebase_on({f"{KIT}/Escaped.swift": text}, "justified debt")
                self.write(f"{KIT}/Escaped.swift", text.replace(escape, escape.replace("\n", " (reviewed again)\n")))
                self.commit("rewords the reason, keeps the escape")
                self.assertEqual(self.refused(), [])
        self.git("reset", "--quiet", "--hard", start)
        self.write(f"{KIT}/Old.swift", "final class Old {\n    // the old cache\n    static let shared = Old()\n}\n")
        self.commit("a comment above old unescaped debt")
        self.assertEqual(self.refused(), [], "base debt the push only comments on is not new")

    def test_an_edit_next_to_the_comment_block_above_old_debt_adds_none(self):
        # Old unescaped debt under a two-line doc comment, a code line above that. The head side reaches the edit
        # through the comment block; the base side must judge the same unchanged line, or old debt reads as new.
        start = self.base
        for rule, (text, escape) in self.ESCAPED.items():
            indent = escape.split("//")[0]
            code = f"{indent}func g() {{}}\n" if indent else "let y = 2\n"
            old = text.replace(escape, f"{code}{indent}/// doc\n{indent}/// more doc\n")
            edits = {
                "deletes the code line above the block": old.replace(code, ""),
                "replaces the code line above the block with a comment": old.replace(code, f"{indent}// gone\n"),
                "inserts a comment line inside the block": old.replace(f"{indent}/// doc\n",
                                                                     f"{indent}/// doc\n{indent}/// inserted\n"),
                "inserts a code line above the block": old.replace(code, f"{code}{code.replace('g', 'h').replace('y', 'z')}"),
            }
            for how, after in edits.items():
                with self.subTest(rule=rule, how=how):
                    self.git("reset", "--quiet", "--hard", start)
                    self.rebase_on({f"{KIT}/OldDebt.swift": old}, "old unescaped debt")
                    self.write(f"{KIT}/OldDebt.swift", after)
                    self.commit(how)
                    self.assertEqual(self.refused(), [], "the push only edits next to old debt")

    def test_a_new_block_opened_around_old_debt_adds_none(self):
        # A context rule judges an unchanged line again when one of its openers changed. The base copy of that
        # line is judged too: a store in a row that a new nested row now wraps was debt before and after.
        body = "    let a = 0\n    let b = 0\n    @Environment(SidebarStore.self) private var store\n}\n"
        self.rebase_on({f"{KIT}/Entry.swift": "import SwiftUI\nstruct EntryRow: View {\n" + body}, "old debt")
        self.write(f"{KIT}/Entry.swift", "import SwiftUI\nstruct EntryRow: View {\nstruct InnerRow: View {\n" + body + "}\n")
        self.commit("a nested row around the old store")
        self.assertEqual(self.refused(), [])

    def test_an_edit_of_the_opener_around_old_debt_adds_none(self):
        row = ("import SwiftUI\nstruct EntryRow: View {\n    @Environment(SidebarStore.self) private var store\n"
               "    var body: some View { Text(\"x\") }\n}\n")
        self.rebase_on({f"{KIT}/Entry.swift": row})
        self.write(f"{KIT}/Old.swift", OLD.replace("final class Old {", "final class Old: Sendable {"))
        self.write(f"{KIT}/Entry.swift", row.replace("struct EntryRow: View {", "struct EntryRow: View, Equatable {"))
        self.commit("edits the class and row lines around old debt")
        self.assertEqual(self.refused(), [])

    def test_a_view_renamed_to_a_row_around_a_store_is_refused(self):
        view = ("import SwiftUI\nstruct EntryView: View {\n    @Environment(SidebarStore.self) private var store\n"
                "    var body: some View { Text(\"x\") }\n}\n")
        self.rebase_on({f"{KIT}/Entry.swift": view})
        self.write(f"{KIT}/Entry.swift", view.replace("EntryView", "EntryRow"))
        self.commit("renames the view to a row")
        self.assertEqual([rule for rule, _ in self.refused()], ["row-store"])

    def test_a_removed_escaped_line_does_not_pay_for_an_unescaped_one(self):
        self.rebase_on({f"{KIT}/Box.swift": "// crash-allow: x is written once in init, then only read\n"
                                            "final class Box: @unchecked Sendable {\n    let x = 0\n}\n"})
        self.write(f"{KIT}/Box.swift", "final class Other: @unchecked Sendable {\n    var y = 0\n}\n")
        self.commit("swaps a justified box for an unjustified one")
        self.assertEqual([rule for rule, _ in self.refused()], ["unchecked-sendable"])

    def test_a_removed_line_pays_once_not_also_as_a_move(self):
        self.rebase_on({f"{KIT}/Cache.swift": "func a() {\n    DispatchQueue.main.async { print(1) }\n}\n"})
        self.write(f"{KIT}/Cache.swift", "func a() {\n    DispatchQueue.main.async { print(1, 2) }\n}\n")
        self.write(f"{KIT}/Store.swift", "func b() {\n    DispatchQueue.main.async { print(1) }\n}\n")
        self.commit("edits one main hop and copies its old line into another file")
        self.assertEqual(self.refused(), [("main-async", ["Cache.swift: DispatchQueue.main.async { print(1, 2) }"])])

    def test_a_no_prefix_diff_config_still_applies_the_rules(self):
        self.git("config", "diff.noprefix", "true")
        self.git("config", "diff.mnemonicPrefix", "true")
        self.write(f"{KIT}/Added.swift", CASES["main-async"][0])
        self.write(f"{KIT}/Conflict.swift", "<<<<<<< HEAD\nlet a = 1\n=======\nlet a = 2\n>>>>>>> topic\n")
        self.commit("a main hop and a conflict")
        self.assertEqual([rule for rule, _ in self.refused()], ["main-async"])
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate", SOURCE / "scripts/cmux-next/prepush-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            markers = gate.conflict_markers(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)
        self.assertEqual(len(markers), 2, markers)

    def test_a_user_inter_hunk_context_does_not_shift_the_line_numbers(self):
        # diff.interHunkContext joins nearby -U0 hunks with the unchanged lines between them; those must count,
        # or every line after them is misnumbered (the rules then fail open, the conflict markers move).
        self.git("config", "diff.interHunkContext", "3")
        self.rebase_on({f"{KIT}/E.swift": "func f() {\n    print(1)\n    print(2)\n}\n",
                        f"{KIT}/Conflict.swift": "let a = 1\nlet b = 1\n"}, "plain code")
        self.write(f"{KIT}/E.swift", "func f() {\n    print(0)\n    print(2)\n    DispatchQueue.main.async { }\n}\n")
        self.write(f"{KIT}/Conflict.swift", "<<<<<<< HEAD\nlet a = 1\n=======\nlet a = 2\n>>>>>>> topic\nlet b = 1\n")
        self.commit("an edit and a main hop two lines apart, and a conflict")
        refusals, warnings = self.check()
        self.assertEqual([(r.id, [(h.number, h.text.strip()) for h in hits]) for r, hits in refusals],
                         [("main-async", [(4, "DispatchQueue.main.async { }")])], warnings)
        self.assertEqual([w for w in warnings if w[0] == "guardrails"], [])
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate", SOURCE / "scripts/cmux-next/prepush-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            markers = gate.conflict_markers(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)
        self.assertEqual(markers, [f"{KIT}/Conflict.swift:1: <<<<<<< HEAD", f"{KIT}/Conflict.swift:5: >>>>>>> topic"])

    def test_lines_brought_in_from_feat_cmux_next_never_count(self):
        self.git("checkout", "--quiet", "-b", "topic")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{KIT}/Landed.swift", CASES["main-async"][0])
        self.commit("debt that landed past the guardrails (a skip reason, a clone without hooks)")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.assertEqual(self.refused(guardrails.check, pushed, "HEAD"),
                         [("main-async", ["Landed.swift: DispatchQueue.main.async { print(1) }"])],
                         "control: the plain range has it")
        self.assertEqual(self.refused(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"), [], "merged")
        self.write(f"{KIT}/Own.swift", "func own() {\n    DispatchQueue.main.async { print(2) }\n}\n")
        self.commit("the branch's own main hop")
        self.assertEqual(self.refused(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"),
                         [("main-async", ["Own.swift: DispatchQueue.main.async { print(2) }"])])
        self.git("reset", "--quiet", "--hard", pushed)
        self.git("rebase", "--quiet", "feat-cmux-next")
        # The hook's base for a force push is the merge base of the new and the old head: the old fork point.
        fork = self.git("merge-base", "HEAD", pushed).stdout.strip()
        self.assertEqual(self.refused(guardrails.check, fork, "HEAD"),
                         [("main-async", ["Landed.swift: DispatchQueue.main.async { print(1) }"])],
                         "control: the plain range has it")
        self.assertEqual(self.refused(guardrails.check_push, fork, "HEAD", "feat-cmux-next"), [], "rebased")

    def test_a_merge_cannot_use_an_upstream_removal_to_pay_for_the_branch_s_own_main_hop(self):
        # Upstream removes a main hop from Shared.swift; the branch adds one there and merges upstream in. Over the
        # old remote head the removal (upstream's) pays for the branch's hop: a per-file count ratchet.
        shared = "func a() {\n    DispatchQueue.main.async { print(1) }\n}\n\nfunc b() {}\nfunc c() {}\nfunc d() {}\n"
        self.write(f"{KIT}/Shared.swift", shared)
        self.commit("a main hop on the base")
        self.git("checkout", "--quiet", "-b", "topic")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{KIT}/Shared.swift", shared.replace("    DispatchQueue.main.async { print(1) }\n", ""))
        self.commit("upstream removes the main hop")
        self.git("checkout", "--quiet", "topic")
        self.write(f"{KIT}/Shared.swift", shared + "func e() {\n    DispatchQueue.main.async { print(2) }\n}\n")
        self.commit("the branch's own main hop in Shared.swift")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.assertEqual(self.refused(guardrails.check, pushed, "HEAD"), [], "control: over the old remote head it is paid")
        self.assertEqual(self.refused(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"),
                         [("main-async", ["Shared.swift: DispatchQueue.main.async { print(2) }"])])

    def test_owner_globs_do_not_cross_folders_with_a_single_star(self):
        self.assertTrue(guardrails.glob_match("A/Motion/Spring.swift", "A/Motion/"))
        self.assertTrue(guardrails.glob_match("A/MotionGate.swift", "A/Motion*.swift"))
        self.assertFalse(guardrails.glob_match("A/Motion/Spring.swift", "A/Motion*.swift"))
        self.assertTrue(guardrails.glob_match("A/B/C/D.swift", "A/**/D.swift"))
        self.assertTrue(guardrails.glob_match("A/D.swift", "A/**/D.swift"), "`**/` is zero or more folders")

    def test_a_moved_line_that_only_gains_an_access_modifier_is_no_new_debt(self):
        self.rebase_on({f"{KIT}/Box.swift": "final class Box: @unchecked Sendable {\n    var x = 0\n}\n"})
        (self.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextOther").mkdir(parents=True)
        self.git("mv", f"{KIT}/Box.swift", "Packages/macOS/CmuxNext/Sources/CmuxNextOther/Box.swift")
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextOther/Box.swift",
                   "package final class Box: @unchecked Sendable {\n    package var x = 0\n}\n")
        self.commit("git mv into another package; access internal -> package")
        self.assertEqual(self.refused(), [])

    def test_the_bench_configuration_is_refused_in_shipped_build_settings(self):
        self.write(".github/workflows/nightly.yml", "jobs:\n  build:\n    steps:\n      - run: ./scripts/reload.sh --config bench\n")
        self.write("config/Release.xcconfig", "OTHER_SWIFT_FLAGS = $(inherited) -DCMUX_BENCH_HOOKS\n")
        self.write("scripts/measure/pane-perf.sh", "./scripts/reload.sh --config bench\n")
        self.commit("bench flags in shipped settings, and in a measure script")
        self.assertEqual(self.refused(), [("bench-hooks-shipped", [
            "nightly.yml: - run: ./scripts/reload.sh --config bench",
            "Release.xcconfig: OTHER_SWIFT_FLAGS = $(inherited) -DCMUX_BENCH_HOOKS"])])

    def test_the_generic_class_rule_reads_test_targets_and_honors_nonisolated(self):
        tests = "Packages/macOS/CmuxNext/Tests/CmuxNextFooTests"
        self.write(f"{tests}/Wait.swift", "final class Once<T> {\n    var value: T?\n}\n")
        self.write(f"{KIT}/Free.swift", "nonisolated final class Box<T> {\n    var value: T?\n}\n"
                   "final class Mailbox<T> { // generic-class-allow: a nonisolated target\n    var value: T?\n}\n")
        self.commit("generic classes in a test target and Sources")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Wait.swift: final class Once<T> {"])])

    def test_the_generic_class_rule_reads_generic_context_and_refuses_an_isolated_deinit(self):
        # 6bf522e6cdd fixed ObservedMap.Slot by hand: a non-generic class nested in a generic one is
        # generic by context, and the rule only read `class Name<`. An `isolated deinit` is the
        # isolated deinit the compiler crashes on, so it is no fix.
        self.write(f"{KIT}/Cache.swift",
                   "@MainActor final class Cache<Key, Value> {\n"
                   "    final class Slot {\n        var value: Value?\n    }\n"
                   "    nonisolated deinit {}\n}\n")
        self.write(f"{KIT}/Box.swift",
                   "@MainActor final class Box<T> {\n    var value: T?\n    isolated deinit { flush() }\n}\n")
        self.write(f"{KIT}/Store.swift",
                   "struct Store<Item> {\n    var items: [Item]\n}\n"
                   "extension Store {\n    final class Reader {\n        var item: Item?\n    }\n}\n")
        self.write(f"{KIT}/Tree.swift", "func walk<Node>(_ node: Node) {\n    final class Visit {\n"
                   "        var node: Node?\n    }\n}\n")
        self.commit("classes generic by context, and an isolated deinit")
        self.assertEqual(sorted(self.refused()[0][1]), [
            "Box.swift: @MainActor final class Box<T> {",
            "Cache.swift: final class Slot {",
            "Store.swift: final class Reader {",
            "Tree.swift: final class Visit {",
        ])

    def test_the_generic_class_rule_reads_an_extension_of_a_generic_type_in_another_file(self):
        self.rebase_on({f"{KIT}/Ledger.swift": "struct Ledger<Entry> {\n    var entries: [Entry]\n}\n"})
        self.write(f"{KIT}/Ledger+Cursor.swift",
                   "extension Ledger {\n    final class Cursor {\n        var entry: Entry?\n    }\n}\n")
        self.commit("a class in an extension of a generic type declared in an unchanged file")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Ledger+Cursor.swift: final class Cursor {"])])

    def test_the_generic_class_rule_passes_nonisolated_deinits_and_non_generic_context(self):
        self.write(f"{KIT}/Cache.swift",
                   "@MainActor final class Cache<Key, Value> {\n"
                   "    final class Slot {\n        var value: Value?\n        nonisolated deinit {}\n    }\n"
                   "    nonisolated final class Entry {\n        var key: Key?\n    }\n"
                   "    nonisolated deinit {}\n}\n")
        self.write(f"{KIT}/Plain.swift", "final class Plain {\n    final class Inner {\n        var x = 0\n    }\n}\n"
                   "extension Plain {\n    final class Other {\n        var y = 0\n    }\n}\n"
                   "final class Holder<T> {\n    class func make() -> Holder { Holder() }\n    class var name: String { \"\" }\n"
                   "    nonisolated deinit {}\n}\n")
        self.write(f"{KIT}/Box.swift", "final class Box<T> { var value: T?; nonisolated deinit {} }\n")
        self.commit("the right patterns")
        self.assertEqual(self.refused(), [])

    def test_making_an_outer_type_generic_counts_its_nested_classes(self):
        self.rebase_on({f"{KIT}/Pool.swift": "final class Pool {\n    final class Lease {\n        var id = 0\n    }\n"
                                             "    nonisolated deinit {}\n}\n"})
        self.write(f"{KIT}/Pool.swift", "final class Pool<Resource> {\n    final class Lease {\n        var id = 0\n    }\n"
                   "    nonisolated deinit {}\n}\n")
        self.commit("Pool becomes generic")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Pool.swift: final class Lease {"])])

    def test_a_plain_deinit_is_no_fix(self):
        # 136798fb6f3 took a plain `deinit` as the fix. In a uiSwiftSettings target it takes the
        # default isolation (#20408 215fe45c7a2; check-concurrency.sh refuses it there), so it is the
        # isolated deinit the 6.3.3 inliner crashes on. Every known fix is `nonisolated deinit`.
        self.write(f"{KIT}/Cache.swift", "@MainActor final class Cache<K, V> {\n    var values: [K: V] = [:]\n"
                   "    deinit {}\n}\n")
        self.write("Packages/macOS/CmuxNext/Tests/CmuxNextFooTests/Seen.swift",
                   "final class Seen<T> {\n    var v: T?\n    deinit {}\n}\n")
        self.commit("generic classes with plain deinits")
        self.assertEqual(sorted(self.refused()[0][1]), [
            "Cache.swift: @MainActor final class Cache<K, V> {",
            "Seen.swift: final class Seen<T> {",
        ])

    def test_changing_only_the_deinit_of_an_existing_generic_class_to_isolated_is_refused(self):
        # The rule judged a class only when its declaration line changed, so an edit of the deinit
        # line alone was never judged.
        self.rebase_on({f"{KIT}/Box.swift": "@MainActor final class Box<T> {\n    var value: T?\n"
                                            "    nonisolated deinit {}\n}\n"})
        self.write(f"{KIT}/Box.swift", "@MainActor final class Box<T> {\n    var value: T?\n"
                   "    isolated deinit { print(1) }\n}\n")
        self.commit("the deinit becomes isolated")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Box.swift: @MainActor final class Box<T> {"])])

    def test_deleting_only_the_nonisolated_deinit_of_an_existing_generic_class_is_refused(self):
        # A deletion-only push has no changed head line, so the rule returned before reading context.
        self.rebase_on({f"{KIT}/Box.swift": "@MainActor final class Box<T> {\n    var value: T?\n"
                                            "    nonisolated deinit {}\n}\n"})
        self.write(f"{KIT}/Box.swift", "@MainActor final class Box<T> {\n    var value: T?\n}\n")
        self.commit("the nonisolated deinit goes")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Box.swift: @MainActor final class Box<T> {"])])

    def test_deleting_the_deinit_of_a_class_in_an_extension_of_a_generic_type_in_another_file_is_refused(self):
        self.rebase_on({f"{KIT}/Ledger.swift": "struct Ledger<Entry> {\n    var entries: [Entry]\n}\n",
                        f"{KIT}/Ledger+Cursor.swift": "extension Ledger {\n    final class Cursor {\n"
                                                      "        var entry: Entry?\n        nonisolated deinit {}\n"
                                                      "    }\n}\n"})
        self.write(f"{KIT}/Ledger+Cursor.swift",
                   "extension Ledger {\n    final class Cursor {\n        var entry: Entry?\n    }\n}\n")
        self.commit("the cursor's nonisolated deinit goes")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Ledger+Cursor.swift: final class Cursor {"])])

    def test_making_a_type_generic_counts_the_classes_in_its_extensions_in_untouched_files(self):
        # The push changes only Ledger.swift (`struct Ledger {` -> `struct Ledger<Entry> {`); the class in
        # Ledger+Cursor.swift becomes generic by context without its file changing. The push owns it.
        self.rebase_on({f"{KIT}/Ledger.swift": "struct Ledger {\n    var count = 0\n}\n",
                        f"{KIT}/Ledger+Cursor.swift": "extension Ledger {\n    final class Cursor {\n"
                                                      "        var index = 0\n    }\n}\n"})
        self.write(f"{KIT}/Ledger.swift", "struct Ledger<Entry> {\n    var count = 0\n}\n")
        self.commit("Ledger becomes generic")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Ledger+Cursor.swift: final class Cursor {"])])
        hit = self.check()[0][0][1][0]
        self.assertIn("Ledger.swift:1", getattr(hit, "cause", ""))
        # A generic type that only changes its parameters adds nothing: its extension was already debt.
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.write(f"{KIT}/Ledger.swift", "struct Ledger<Entry, Key> {\n    var count = 0\n}\n")
        self.commit("Ledger gains a parameter")
        self.assertEqual(self.refused(), [])

    def test_editing_a_class_that_already_has_the_debt_adds_none(self):
        # Touching the body of a class that is base debt pairs with the base: base debt never blocks.
        self.rebase_on({f"{KIT}/Box.swift": "@MainActor final class Box<T> {\n    var value: T?\n"
                                            "    var count = 0\n}\n"})
        self.write(f"{KIT}/Box.swift", "@MainActor final class Box<T> {\n    var value: T?\n"
                   "    func reset() { value = nil }\n}\n")
        self.commit("a member changes")
        self.assertEqual(self.refused(), [])
        self.write(f"{KIT}/Box.swift", "@MainActor final class Box<T> {\n    var value: T?\n"
                   "    func reset() { value = nil }\n    func clear() { value = nil }\n}\n")
        self.commit("a member is added")
        self.assertEqual(self.refused(), [])

    def test_deleting_a_line_next_to_the_opener_of_old_debt_adds_none(self):
        # A deletion marks the lines around it on both sides, so an old store in the row around it pairs.
        self.rebase_on({f"{KIT}/Entry.swift": "import SwiftUI\nstruct EntryRow: View {\n    let id = 0\n"
                                              "    @Environment(SidebarStore.self) private var store\n}\n"})
        self.write(f"{KIT}/Entry.swift", "import SwiftUI\nstruct EntryRow: View {\n"
                   "    @Environment(SidebarStore.self) private var store\n}\n")
        self.commit("a line in the row goes")
        self.assertEqual(self.refused(), [])

    def test_the_generic_class_rule_reads_the_target_isolation_like_check_concurrency(self):
        # One crash class, one detector: a class in a daemonSwiftSettings target is nonisolated by
        # default, so its implicit deinit is too, unless the class is `@MainActor` (check-concurrency.sh).
        self.rebase_on({"Packages/macOS/CmuxNext/Package.swift":
                        'let package = Package(name: "CmuxNext", targets: [\n'
                        '    .target(name: "CmuxNextKit", swiftSettings: daemonSwiftSettings),\n'
                        '    .testTarget(name: "CmuxNextFooTests", swiftSettings: uiSwiftSettings),\n])\n'},
                       "the manifest")
        self.write(f"{KIT}/Race.swift", "private final class Race<T: Sendable>: Sendable {\n    var value: T?\n}\n"
                   "@MainActor final class Box<T> {\n    var value: T?\n}\n")
        self.write("Packages/macOS/CmuxNext/Tests/CmuxNextFooTests/Wait.swift",
                   "final class Once<T> {\n    var value: T?\n}\n")
        self.commit("generic classes in a daemon target and a UI test target")
        self.assertEqual(sorted(self.refused()[0][1]), ["Race.swift: @MainActor final class Box<T> {",
                                                       "Wait.swift: final class Once<T> {"])

    def test_the_generic_class_rule_reads_each_target_call_alone(self):
        # Package.swift's CmuxNextMallocZone and CmuxNextTestExitTrace shapes: a target with no swiftSettings is
        # nonisolated by default and does not take the next target's settings, and a target's `path:` names
        # its folder. The manifest regex gave CmuxNextZone the next target's uiSwiftSettings, and read
        # Tests/Support/CmuxNextTrace as a target named Support (unknown, so main actor).
        self.rebase_on({"Packages/macOS/CmuxNext/Package.swift":
                        'let package = Package(name: "CmuxNext", targets: [\n'
                        '    .target(name: "CmuxNextZone"),\n'
                        '    .target(\n        name: "CmuxNextKit",\n'
                        '        dependencies: [.target(name: "CmuxNextZone")],\n'
                        '        swiftSettings: uiSwiftSettings\n    ),\n'
                        '    .target(name: "CmuxNextTrace", path: "Tests/Support/CmuxNextTrace"),\n'
                        '    .testTarget(name: "CmuxNextKitTests", dependencies: ["CmuxNextTrace"], '
                        'swiftSettings: uiSwiftSettings),\n])\n'},
                       "the manifest")
        box = "final class Box<T> {\n    var value: T?\n}\n"
        self.write(f"{PKG}/Sources/CmuxNextZone/Zone.swift", box)
        self.write(f"{KIT}/Kit.swift", box)
        self.write(f"{PKG}/Tests/Support/CmuxNextTrace/Trace.swift", box)
        self.write(f"{PKG}/Tests/CmuxNextKitTests/KitTests.swift", box)
        self.commit("generic classes in settings-less and uiSwiftSettings targets")
        self.assertEqual(self.refused(), [("generic-class-deinit", ["Kit.swift: final class Box<T> {",
                                                                    "KitTests.swift: final class Box<T> {"])])

    def test_other_rules_do_not_read_test_targets(self):
        self.write("Packages/macOS/CmuxNext/Tests/CmuxNextFooTests/Fake.swift",
                   "func fake() {\n    DispatchQueue.main.async { print(1) }\n}\n")
        self.commit("a main hop in a test target")
        self.assertEqual(self.refused(), [])

    def test_every_untyped_bind_shape_and_a_waiting_effect_are_refused_and_the_escape_passes(self):
        bad = ['registry.bind("a", run: { _ in })', 'registry.bind("a", unavailable: { nil }) { _ in }',
               'registry.bind("a", handler: { })', 'CloudHandlers.bind("a", registry, reason: r) { invocation in }',
               'return .waiting(.network, work)', 'return daemon.waitingEffect("x") { _ in }']
        for line in bad:
            with self.subTest(line=line):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", f"func f() {{\n    {line}\n}}\n")
                self.commit("adds a waiting handler")
                self.assertIn("action-wait", [r.id for r, _ in self.check()[0]])
        good = ['registry.bindEffect("a", effect: { _ in .done })', 'registry.bindUnavailable("a", reason: "x")',
                'return .waiting(.network, work) // action-wait-allow: the cloud decides the machine',
                'registry.bindEffect("a", requires: cap, daemon: d, effect: { _ in .done })']
        for line in good:
            with self.subTest(line=line):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", f"func f() {{\n    {line}\n}}\n")
                self.commit("adds a typed handler")
                self.assertNotIn("action-wait", [r.id for r, _ in self.check()[0]])

    def test_skip_reason_lets_the_push_through_and_is_printed(self):
        self.write(f"{KIT}/Added.swift", CASES["main-async"][0])
        self.commit("adds a main hop")
        refusals, warnings = self.check()
        os.environ[guardrails.SKIP_ENV] = "main-async: test"
        try:
            text, refused = guardrails.format_report(refusals, warnings)
        finally:
            del os.environ[guardrails.SKIP_ENV]
        self.assertFalse(refused)
        self.assertIn("SKIPPED", text)

    def test_a_rule_that_raises_is_off_for_that_push_and_the_others_still_refuse(self):
        self.write(f"{KIT}/Added.swift", CASES["main-async"][0])
        self.commit("adds a main hop")

        def broken(changes, moved):
            raise RuntimeError("boom")

        for failing in ("app-size", "main-async"):
            with self.subTest(failing=failing):
                rules = tuple(dataclasses.replace(r, find=broken) if r.id == failing else r for r in guardrails.RULES)
                with mock.patch.object(guardrails, "RULES", rules):
                    refusals, warnings = self.check()
                self.assertEqual([r.id for r, _ in refusals], [] if failing == "main-async" else ["main-async"])
                failed = [text for kind, text in warnings if kind == "guardrails"]
                self.assertEqual(len(failed), 1, warnings)
                self.assertIn(f"rule {failing} failed (RuntimeError: boom at test_cmux_next_guardrails.py:", failed[0])
        with mock.patch.object(guardrails, "perf_hot_warnings", broken):
            refusals, warnings = self.check()
        self.assertEqual([r.id for r, _ in refusals], ["main-async"])
        self.assertIn("perf-hot failed (RuntimeError: boom", " ".join(text for _, text in warnings))
        # The installed hook copies scripts/cmux-next; a CI edit of the lexer next to guardrails.py that no
        # longer loads turns off the App rules (app-size, app-type) only, never the whole module (and so every rule).
        installed = self.root / "installed"
        installed.mkdir()
        # As scripts/install-git-hooks.sh installs it: every top-level file of scripts/cmux-next, so the modules
        # guardrails.py loads at import (swift_scope.py, which check-concurrency.sh shares, and what it loads)
        # are next to it, as in the hook.
        for script in (SOURCE / "scripts/cmux-next").glob("*.py"):
            shutil.copy(script, installed)
        (installed / "count-swift-code-lines.py").write_text("raise ImportError('a lexer that does not load')\n")
        spec = importlib.util.spec_from_file_location("cmux_next_guardrails_broken_lexer", installed / "guardrails.py")
        copy = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = copy
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(copy)
        self.write(f"{APP}/Grown.swift", "struct Grown {}\n")
        self.commit("an App file, so app-size reads the lexer")
        refusals, warnings = self.check(copy.check)
        self.assertEqual([r.id for r, _ in refusals], ["main-async"], "the other line rules still refuse")
        failed = [text for kind, text in warnings if kind == "guardrails"]
        self.assertEqual(len(failed), 2, warnings)  # app-size and app-type read the lexer
        self.assertIn("rule app-size failed (ImportError: a lexer that does not load", failed[0])
        self.assertIn("rule app-type failed (ImportError: a lexer that does not load", failed[1])

    def test_a_refusal_names_only_crash_ratchet_options_that_exist(self):
        # The unchecked-sendable refusal sends the author to crash_ratchet.py: every option it names must run.
        self.write(f"{KIT}/Added.swift", CASES["unchecked-sendable"][0])
        self.commit("adds an unchecked Sendable")
        refusals, _ = self.check()
        self.assertEqual([r.id for r, _ in refusals], ["unchecked-sendable"])
        text, refused = guardrails.format_report(refusals, [])
        self.assertTrue(refused, text)
        self.assertIn("crash_ratchet.py", text)
        named = [option for options in re.findall(r"crash_ratchet\.py((?:\s+--[\w-]+)+)", text)
                 for option in options.split()]
        usage = subprocess.run([sys.executable, "-I", str(SOURCE / "scripts/cmux-next/crash_ratchet.py"), "--help"],
                               capture_output=True, text=True, check=True).stdout
        for option in named:
            self.assertRegex(usage, rf"(^|\s|\[){re.escape(option)}\b", f"{option} is not a crash_ratchet.py option")

    def test_a_rule_that_raises_only_on_the_pushed_range_of_a_merge_is_warned_once(self):
        # A branch that merged feat-cmux-next in: check_push checks the branch's range over the merged upstream and
        # takes off what the old remote head already had (its range over the upstream it started from).
        self.git("checkout", "--quiet", "-b", "topic")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{APP}/Landed.swift", "struct Landed {}\n")
        self.commit("landed on feat-cmux-next")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.write(f"{KIT}/Own.swift", "func own() {\n    DispatchQueue.main.async { print(2) }\n}\n")
        # app-size sees only App files: a comment line (no growth) puts one in the branch's own range.
        self.write(f"{APP}/Landed.swift", "struct Landed {}\n// the branch's note\n")
        self.commit("the branch's own main hop")
        original = next(r for r in guardrails.RULES if r.id == "app-size")

        def only_pushed(changes, moved):  # Landed.swift's note is in the branch's range, not in what it pushed before
            if not any(c.path.endswith("/Landed.swift") for c in changes):
                raise RuntimeError("boom")
            return original.find(changes, moved)

        def always(changes, moved):
            raise RuntimeError("boom")

        for name, find in (("the range taken off only", only_pushed), ("both ranges", always)):
            with self.subTest(failing=name):
                rules = tuple(dataclasses.replace(r, find=find) if r.id == "app-size" else r for r in guardrails.RULES)
                with mock.patch.object(guardrails, "RULES", rules):
                    _, branch_warnings = self.check(guardrails.check, "feat-cmux-next", "HEAD")
                    refusals, warnings = self.check(guardrails.check_push, pushed, "HEAD", "feat-cmux-next")
                if find is only_pushed:
                    self.assertEqual([t for k, t in branch_warnings if k == "guardrails"], [],
                                     "control: the rule runs on the branch's own range")
                self.assertEqual([(r.id, [h.path.rsplit("/", 1)[-1] for h in hits]) for r, hits in refusals],
                                 [("main-async", ["Own.swift"])])
                failed = [text for kind, text in warnings if kind == "guardrails"]
                self.assertEqual(len(failed), 1, warnings)
                self.assertIn("rule app-size failed (RuntimeError: boom at test_cmux_next_guardrails.py:", failed[0])

    def test_skip_reason_skips_only_the_named_rules(self):
        self.write(f"{KIT}/Added.swift", CASES["unchecked-sendable"][0] + CASES["main-async"][0])
        self.commit("adds an unchecked box and a main hop")
        refusals, _ = self.check()
        self.assertEqual(sorted(r.id for r, _ in refusals), ["main-async", "unchecked-sendable"])
        text, refused = self.report("unchecked-sendable: a fixture", refusals)
        self.assertTrue(refused, text)
        self.assertIn("[main-async]", text)
        self.assertIn("SKIPPED", text)
        text, refused = self.report("unchecked-sendable, main-async: a fixture", refusals)
        self.assertFalse(refused, text)
        for bad, error in (("unchecked: typo", "names no rule unchecked"), ("unchecked-sendable", "must be"),
                           ("unchecked-sendable:   ", "must be")):
            with self.subTest(skip=bad):
                text, refused = self.report(bad, refusals)
                self.assertTrue(refused, text)
                self.assertIn(error, text)


def swift_body(lines, tag):
    """LINES physical lines of realistic Swift, unique to TAG: functions with a guard, braces and blank lines. Every
    eighth line is blank (no source line); of the source lines, `}` and `return 0` are generic (every file has them)."""
    out, i = [], 0
    while len(out) < lines:
        out += [f"    func {tag}Value{i}(_ value: Int) -> Int {{", f"        let {tag}Scaled{i} = value * {i + 2}",
                f"        guard {tag}Scaled{i} > 0 else {{", "            return 0", "        }",
                f"        return {tag}Scaled{i}", "    }", ""]
        i += 1
    return "".join(line + "\n" for line in out[:lines])


def code(text):
    """Source lines of TEXT made of swift_body/host_file lines (no comments there): its non-blank lines."""
    if not isinstance(text, str):
        text = "".join(text)
    return sum(1 for line in text.splitlines() if line.strip())


def swift_type(name, lines, kind="struct", head=""):
    """A top-level KIND NAME of LINES physical lines (swift_body inside, unique to NAME); HEAD goes before `struct`.

    Its braces balance, as in real Swift (app-type's brace scan reads them): the lines a whole swift_body function
    does not fill are `let` lines (no blank line, so the source count is swift_body's)."""
    tag, body = name[0].lower() + name[1:], lines - 2
    whole = body - body % 8
    rest = "".join(f"    let {tag}Extra{k} = {k}\n" for k in range(body - whole))
    return f"{head}{kind} {name} {{\n" + swift_body(whole, tag) + rest + "}\n"


def host_file(lines, domain="Foo", declare=True):
    """A Host file of LINES physical lines (one blank): one-line forwards in `extension AppServices: <Domain>Host`."""
    head = ["import CmuxNext" + domain, "", "@MainActor",
            f"extension AppServices{': ' + domain + 'Host' if declare else ''} {{"]
    body = [f"    func {domain.lower()}Forward{i}() {{ {domain.lower()}.forward{i}() }}" for i in range(lines - len(head) - 1)]
    return "\n".join(head + body + ["}"]) + "\n"


class AppSizeTests(Fixture):
    """`app-size`: a push grows CmuxNextApp's root only by its wiring budget and adds App files only as moves
    (refusals); App growth is a warning (guardrails.py "app-size"), in source lines."""

    def setUp(self):
        super().setUp()
        self.rebase_on({
            f"{APP}/AppDelegate.swift": swift_body(200, "delegate"),
            f"{APP}/AppServices.swift": swift_body(200, "services"),
            f"{APP}/AppServices+Glass.swift": swift_body(50, "glass"),
            f"{APP}/CmuxNextApp.swift": swift_body(40, "main"),
            f"{APP}/Cloud/AppServices+Cloud.swift": swift_body(80, "cloud"),
            f"{APP}/TextBox/TextBoxView.swift": swift_body(120, "textBox"),
            f"{APP}/Quit/QuitCoordinator.swift": swift_body(300, "quit"),
            f"{APP}/Resources/Strings.xcstrings": "{}\n",
        }, "an App")
        self.quit = swift_body(300, "quit").splitlines(keepends=True)

    def append(self, relative, text):
        with open(self.repo / relative, "a") as handle:
            handle.write(text)

    def shrink_quit(self, keep=200):
        """Delete QuitCoordinator's lines after KEEP (moved to a package: out of the App's scope); returns how many
        source lines that pays for."""
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:keep]))
        return code(self.quit[keep:])

    def hits(self, *args):
        """The push's app-size and app-type refusals."""
        refusals, _ = self.check(*args)
        return [hit for rule, found in refusals if rule.id in ("app-size", "app-type") for hit in found]

    def type_warnings(self, *args):
        """app-type's warnings: files whose braces its scan could not follow (fail open)."""
        _, warnings = self.check(*args)
        return [text for kind, text in warnings if kind in ("app-type", "guardrails")]

    def assertRefused(self, *needles, args=()):
        found = self.hits(*args)
        self.assertTrue(found, "expected an app-size refusal")
        text = "\n".join(f"{h.path}:{h.number}: {h.text}" for h in found)
        for needle in needles:
            self.assertIn(needle, text)
        return found

    def test_a_dated_reviewed_exception_turns_a_new_app_file_into_a_warning(self):
        path = f"{APP}/Cloud/CloudNew.swift"
        self.write(path, swift_body(40, "cloudNew"))
        self.commit("a new App file")
        self.assertRefused("new App file")
        entry = {"date": "2026-10-31", "rule": "app-size", "path": path, "why": "moves to Rust", "author": "lane-a",
                 "owner": "the Rust move", "receipt": "Review (codex): SHIP at " + "a" * 40, "expiry": "2999-12-31"}
        self.write(guardrails.EXCEPTIONS, json.dumps({"exceptions": [entry]}))
        self.commit("its exception")
        self.assertEqual(self.hits(), [])
        self.assertTrue(any("excepted by" in text for _, text in self.check()[1]))
        # A self-reviewed, an expired or another file's entry allows nothing.
        for broken in ({"receipt": "Review (lane-a): SHIP at " + "a" * 40}, {"expiry": "2026-10-30"},
                       {"path": f"{APP}/Cloud/Other.swift"}, {"rule": "god-file"}, {"date": "2026-02-31"},
                       {"expiry": "2999-00-00"}):
            self.write(guardrails.EXCEPTIONS, json.dumps({"exceptions": [{**entry, **broken}]}))
            self.commit("a broken exception")
            self.assertRefused("new App file")

    def growth(self, *args):
        """The push's app-size growth warnings (`path:line: text`): never refusals for now."""
        _, warnings = self.check(*args)
        return [text for kind, text in warnings if kind == "app-size"]

    def assertWarned(self, *needles, args=()):
        """An app-size growth warning with every NEEDLE, and no app-size refusal; returns the warnings."""
        self.assertEqual([h.text for h in self.hits(*args)], [], "growth warns, it does not refuse")
        found = self.growth(*args)
        self.assertTrue(found, "expected an app-size growth warning")
        text = "\n".join(found)
        for needle in needles:
            self.assertIn(needle, text)
        return found

    def assertPasses(self, message=""):
        self.assertEqual([h.text for h in self.hits()], [], message)
        self.assertEqual(self.growth(), [], message)
        self.assertEqual(self.type_warnings(), [], message)

    def reset(self):
        self.git("reset", "--quiet", "--hard", self.base)

    def test_growth_of_a_feature_file_warns_at_its_first_added_line_with_its_bytes(self):
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(5, "added"))
        self.commit("grow")
        added = sum(len(line) + 1 for line in swift_body(5, "added").splitlines() if line.strip())
        found = self.assertWarned(f"outside the root grows +5 source lines (+{added} bytes); move the code to its "
                                  "domain package (the `TextBox` folder's row in",
                                  f"CmuxNextApp grows +5 source lines (+{added} bytes")
        self.assertTrue(found[0].startswith(f"{APP}/TextBox/TextBoxView.swift:121: "), found[0])
        text, refused = guardrails.format_report(*self.check())
        self.assertFalse(refused, text)
        self.assertIn("warnings (never refuse):\n  [app-size] ", text)

    def test_root_wiring_is_capped_at_thirty_lines_and_warns_unless_an_app_shrink_pays(self):
        wire = code(swift_body(20, "wire"))
        self.append(f"{APP}/AppServices+Glass.swift", swift_body(20, "wire"))
        self.commit("wiring with no shrink")
        found = self.assertWarned(f"CmuxNextApp grows +{wire} source lines")
        self.assertEqual(len(found), 1, "the root's own budget is not over and no feature file grew")
        self.reset()
        self.append(f"{APP}/AppServices+Glass.swift", swift_body(20, "wire"))
        self.shrink_quit()
        self.commit("wiring paid by moving Quit code to its package")
        self.assertPasses()
        self.reset()
        for relative, tag in (("AppDelegate.swift", "a"), ("CmuxNextApp.swift", "b"), ("AppServices.swift", "c")):
            self.append(f"{APP}/{relative}", swift_body(11, tag))
        self.assertEqual(3 * code(swift_body(11, "a")), 30)
        self.shrink_quit()
        self.commit("30 lines across the root files, paid")
        self.assertPasses()
        self.reset()
        self.append(f"{APP}/AppDelegate.swift", swift_body(35, "wire"))
        self.assertEqual(code(swift_body(35, "wire")), 31)
        self.shrink_quit(0)
        self.commit("31 lines, paid many times over")
        found = self.assertRefused("the composition root grows +31 source lines", "budget of +30")
        self.assertEqual([h.bucket for h in found], ["root"])

    def test_an_app_services_extension_in_a_feature_folder_is_not_root(self):
        self.append(f"{APP}/Cloud/AppServices+Cloud.swift", swift_body(20, "wire"))
        self.commit("feature code in an AppServices extension")
        self.assertWarned(f"outside the root grows +{code(swift_body(20, 'wire'))} source lines",
                          "the `Cloud` folder's row in")

    def test_a_moved_file_passes_and_a_split_s_new_imports_are_growth_as_ci_counts_them(self):
        (self.repo / APP / "Shutdown").mkdir()  # git before 2.54 does not create the folder for a git mv
        self.git("mv", f"{APP}/Quit/QuitCoordinator.swift", f"{APP}/Shutdown/QuitCoordinator.swift")
        self.commit("move")
        self.assertPasses("a git mv")
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:150]))
        self.write(f"{APP}/Quit/QuitSteps.swift", "import AppKit\nimport CmuxNextDesign\n\n" + "".join(self.quit[150:]))
        self.commit("split")
        found = self.assertWarned("outside the root grows +2 source lines", "CmuxNextApp grows +2 source lines")
        self.assertEqual(len(found), 2, "the split file itself is a move: no new-file refusal")
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:150]))
        self.write(f"{APP}/Quit/QuitSteps.swift", "import AppKit\nimport CmuxNextDesign\n\n" + "".join(self.quit[150:]))
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(swift_body(120, "textBox").splitlines(keepends=True)[:112]))
        self.commit("split, its imports paid by a deleted function")
        self.assertPasses("a split whose imports the push pays for")

    def test_code_moved_between_the_root_and_feature_files_is_not_growth(self):
        lines = swift_body(200, "delegate").splitlines(keepends=True)
        self.write(f"{APP}/AppDelegate.swift", "".join(lines[:37] + lines[137:]))
        self.append(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[37:137]))
        self.commit("100 lines out of AppDelegate")
        self.assertPasses("out of the root")
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:201]))
        self.append(f"{APP}/AppDelegate.swift", "".join(self.quit[201:]))
        self.commit("99 lines into AppDelegate")
        found = self.assertRefused(f"the composition root grows +{code(self.quit[201:])} source lines",
                                   "budget of +30")
        self.assertEqual([h.bucket for h in found], ["root"], "a move into the root is not App growth")
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:270]))
        self.append(f"{APP}/AppDelegate.swift", "".join(self.quit[270:]))
        self.assertLessEqual(code(self.quit[270:]), 30)
        self.commit("30 lines into AppDelegate")
        self.assertPasses("a move into the root within its budget")

    def test_a_block_that_stays_in_its_file_is_no_move_into_a_new_file(self):
        # Re-indenting a block (wrapping it in `Task { @MainActor in ... }`) removes and re-adds every line with the
        # same stripped text: the block is still in its file, so a copy of it in a new file is new code.
        lines = swift_body(120, "textBox").splitlines(keepends=True)
        self.write(f"{APP}/TextBox/TextBoxView.swift",
                   "".join(["    " + line if line.strip() else line for line in lines[:40]] + lines[40:]))
        self.write(f"{APP}/TextBox/TextBoxReload.swift", "".join(lines[:40]))
        self.commit("a re-indented block, and a copy of it in a new file")
        found = self.assertRefused(f"new App file, {code(lines[:40])} source lines ({code(lines[:40])} not moved)",
                                   "only a move or the push's one Host conformance file may be added")
        self.assertEqual([h.bucket for h in found], [f"new:{APP}/TextBox/TextBoxReload.swift"])
        self.reset()
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[40:]))
        self.write(f"{APP}/TextBox/TextBoxReload.swift", "".join(lines[:40]))
        self.commit("control: the block really leaves its file")
        self.assertPasses("a split")

    def test_moved_imports_do_not_count_toward_a_new_file_s_moved_share(self):
        imports = "import Foundation\nimport SwiftUI\nimport AppKit\nimport CmuxNextCore\n\n"
        old = swift_body(16, "old").splitlines(keepends=True)
        self.rebase_on({f"{APP}/Quit/QuitOld.swift": imports + "".join(old)}, "an old Quit file")
        self.git("rm", "--quiet", f"{APP}/Quit/QuitOld.swift")
        fresh = "".join(f"    let quitFresh{i} = {i}\n" for i in range(4))
        self.write(f"{APP}/Quit/QuitNew.swift", imports + "".join(old[:8]) + fresh)
        self.commit("one moved function and four new lines in a new file; the old file's imports come along")
        moved, total = code(old[:8]), code(old[:8]) + 4
        self.assertLess(moved, guardrails.MOVE_SHARE * total, "the file's code is not mostly moved")
        self.assertGreaterEqual(moved + 4, guardrails.MOVE_SHARE * total, "the imports would push it over")
        found = self.assertRefused(f"new App file, {total + 4} source lines")
        self.assertEqual([h.bucket for h in found], [f"new:{APP}/Quit/QuitNew.swift"])

    def test_a_move_out_of_the_root_stays_neutral_when_feature_files_drop_stub_lines(self):
        # The feature side's removed `}` and `return 0` lines match the moved block's: they must not cut the block
        # into runs too short to count as moved out of the root (each line not counted is free root budget).
        lines = swift_body(200, "delegate").splitlines(keepends=True)
        wire = swift_body(35, "wire")
        self.assertEqual(code(wire), guardrails.ROOT_BUDGET + 1)
        self.write(f"{APP}/AppDelegate.swift", "".join(lines[:40] + lines[136:]) + wire)
        self.append(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[40:136]))
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:200]))
        self.commit("84 lines out of AppDelegate, dead Quit code deleted, 31 new wiring lines")
        found = self.assertRefused(f"the composition root grows +{code(wire)} source lines", "budget of +30")
        self.assertEqual([(h.bucket, h.excess) for h in found], [("root", 1)])
        self.reset()
        self.write(f"{APP}/AppDelegate.swift", "".join(lines[:40] + lines[136:]))
        self.append(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[40:136]))
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:200]))
        self.commit("control: the same move with no new wiring")
        self.assertPasses("a move out of the root and a deletion")

    def test_a_small_file_renamed_whole_is_a_move(self):
        flag = "import Foundation\n\nlet quitFlag = true\n"
        self.rebase_on({f"{APP}/Quit/QuitFlag.swift": flag}, "a small Quit file")
        (self.repo / APP / "Shutdown").mkdir()  # git before 2.54 does not create the folder for a git mv
        self.git("mv", f"{APP}/Quit/QuitFlag.swift", f"{APP}/Shutdown/QuitFlag.swift")
        self.commit("rename a two-line file")
        self.assertPasses("a git mv of a file shorter than MOVE_RUN")
        self.reset()
        (self.repo / APP / "Shutdown").mkdir(exist_ok=True)
        self.git("mv", f"{APP}/Quit/QuitFlag.swift", f"{APP}/Shutdown/QuitFlag.swift")
        self.write(f"{APP}/Shutdown/QuitFlagCopy.swift", flag)
        self.commit("rename it and copy it")
        found = self.assertRefused("new App file, 2 source lines")
        self.assertEqual([h.bucket for h in found], [f"new:{APP}/Shutdown/QuitFlagCopy.swift"])
        self.reset()
        self.git("mv", f"{APP}/Quit/QuitFlag.swift", f"{APP}/AppServices+QuitFlag.swift")
        self.commit("a feature file renamed into the root")
        self.assertRefused("a new root file is split from the root files")
        self.reset()
        self.rebase_on({f"{APP}/AppServices+Flag.swift": "import Foundation\n\nlet appFlag = true\n"}, "a small root file")
        self.git("mv", f"{APP}/AppServices+Flag.swift", f"{APP}/Quit/Flag.swift")
        self.commit("a root file renamed into a feature folder")
        self.assertPasses("a rename out of the root is neutral, however short: no root shrink, no feature growth")

    def test_feature_logic_pasted_into_an_existing_app_services_file_is_refused(self):
        lines = swift_body(120, "textBox").splitlines(keepends=True)
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[:20]))
        self.append(f"{APP}/AppServices.swift", "".join(lines[20:]))
        self.commit("100 lines of TextBox logic into AppServices.swift")
        found = self.assertRefused(f"the composition root grows +{code(lines[20:])} source lines", "budget of +30",
                                   "AppServices.swift +")
        self.assertEqual([h.bucket for h in found], ["root"])
        self.assertEqual(found[0].path, f"{APP}/AppServices.swift")

    def test_new_app_files_are_refused_however_small(self):
        model = code(swift_body(300, "model"))
        self.write(f"{APP}/TextBox/TextBoxModel.swift", swift_body(300, "model"))
        self.commit("a new 300-line file")
        self.assertRefused(f"new App file, {model} source lines ({model} not moved), goes to its domain package "
                           "(the `TextBox` folder's row in")
        self.assertIn(f"outside the root grows +{model} source lines", "\n".join(self.growth()))
        self.reset()
        self.write(f"{APP}/AppDelegate+Menus.swift",
                   "import AppKit\n\n" + "".join(f"func menu{i}() {{ build({i}) }}\n" for i in range(8)))
        self.commit("a new 10-line root file of new code")
        self.assertRefused("new App file, 9 source lines", "a new root file is split from the root files")
        self.reset()
        self.assertEqual(self.shrink_quit(291), 8)
        self.write(f"{APP}/Quit/NewThing.swift", "".join(f"let newThing{i} = {i}\n" for i in range(8)))
        self.commit("an 8-line new file paid for by an 8-line deletion")
        found = self.assertRefused("new App file, 8 source lines (8 not moved)")
        self.assertEqual([h.bucket for h in found], [f"new:{APP}/Quit/NewThing.swift"])

    def test_a_new_file_that_copies_lines_its_old_file_keeps_is_not_a_move(self):
        # Re-indenting a block shows it as removed and re-added (-U0); its lines still exist in the old file.
        lines = swift_body(120, "textBox").splitlines(keepends=True)
        block = lines[16:56]
        wrapped = ["    func reload() {\n"] + [("    " + line) if line.strip() else line for line in block] + ["    }\n"]
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[:16] + wrapped + lines[56:]))
        self.write(f"{APP}/TextBox/TextBoxReload.swift", "".join(block))
        self.commit("a block wrapped in place and copied into a new file")
        found = self.assertRefused("new App file", "only a move or the push's one Host conformance file")
        self.assertIn(f"new:{APP}/TextBox/TextBoxReload.swift", [h.bucket for h in found])
        self.reset()
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(lines[:16] + lines[56:]))
        self.write(f"{APP}/TextBox/TextBoxReload.swift", "".join(block))
        self.commit("the same block moved out")
        self.assertEqual([h.bucket for h in self.hits()], [], "control: a real move into a new file passes")

    def test_a_file_deleted_whole_and_pasted_into_an_existing_file_is_no_rename_of_a_new_copy(self):
        # The deleted file's lines are back in TextBoxView: they did not leave the App, so a new file with the same
        # text is a copy, not a rename, however exactly it matches the deleted file.
        old = swift_body(40, "old")
        self.rebase_on({f"{APP}/Quit/QuitOld.swift": old}, "an old Quit file")
        self.git("rm", "--quiet", f"{APP}/Quit/QuitOld.swift")
        self.append(f"{APP}/TextBox/TextBoxView.swift", old)
        self.write(f"{APP}/Quit/QuitCopy.swift", old)
        self.commit("delete a file, paste it into an existing file and re-add it under a new name")
        found = self.assertRefused(f"new App file, {code(old)} source lines ({code(old)} not moved)",
                                   "only a move or the push's one Host conformance file may be added")
        self.assertEqual([h.bucket for h in found], [f"new:{APP}/Quit/QuitCopy.swift"])
        self.reset()
        self.git("rm", "--quiet", f"{APP}/Quit/QuitOld.swift")
        self.write(f"{APP}/Quit/QuitCopy.swift", old)
        self.commit("control: the same file renamed, not pasted anywhere else")
        self.assertEqual([h.bucket for h in self.hits()], [], "a rename passes")

    def test_one_deleted_file_is_renamed_once_whatever_the_names_of_its_copies(self):
        # An exact copy and a near copy of one deleted file: one block moved once, so one of them is refused, and
        # it is the near copy (the exact copy is the rename) in either name order.
        old = swift_body(40, "old")
        near = old + "    let quitFresh = 1\n"
        self.rebase_on({f"{APP}/Quit/QuitOld.swift": old}, "an old Quit file")
        for exact, copy in (("B", "A"), ("A", "B")):
            with self.subTest(exact=exact):
                self.reset()
                self.git("rm", "--quiet", f"{APP}/Quit/QuitOld.swift")
                self.write(f"{APP}/Quit/Quit{exact}.swift", old)
                self.write(f"{APP}/Quit/Quit{copy}.swift", near)
                self.commit(f"Quit{exact} renames QuitOld, Quit{copy} copies it with one new line")
                found = self.assertRefused(f"new App file, {code(near)} source lines ({code(near)} not moved)")
                self.assertEqual([h.bucket for h in found], [f"new:{APP}/Quit/Quit{copy}.swift"])

    def test_the_growth_summary_names_a_feature_file_s_new_lines_beside_a_move_into_it(self):
        # TextBoxView takes 84 lines out of AppDelegate, deletes one of its own functions (its `return 0` and two
        # `}` match the moved block's) and adds 3 new lines: those 3 are its growth, and the summary names them.
        lines = swift_body(200, "delegate").splitlines(keepends=True)
        box = swift_body(120, "textBox").splitlines(keepends=True)
        fresh = "".join(f"    let textBoxFresh{i} = {i}\n" for i in range(3))
        self.rebase_on({f"{APP}/Zoom/ZoomModel.swift": swift_body(40, "zoom")}, "a Zoom file")
        self.write(f"{APP}/AppDelegate.swift", "".join(lines[:40] + lines[136:]))
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(box[8:] + lines[40:136]) + fresh)
        self.append(f"{APP}/Zoom/ZoomModel.swift", swift_body(10, "zoomMore"))
        self.commit("84 lines out of AppDelegate into TextBoxView, which drops a function and adds 3 lines")
        grows = code(box[8:] + lines[40:136]) + 3 + code(swift_body(10, "zoomMore")) - code(box) - code(lines[40:136])
        self.assertGreater(grows, 0)
        self.assertWarned(f"App outside the root grows +{grows} source lines", "TextBox/TextBoxView.swift +3 new")

    def test_a_file_s_own_re_indented_braces_beside_a_move_out_of_the_root_are_not_moved(self):
        # AppDelegate moves 10 lines into TextBoxView, re-indents 20 of its own statements and adds 25 wiring lines;
        # TextBoxView wraps its own 20 statements and the moved lines in `Task { @MainActor in ... }`. Each file's
        # re-added `}` lines are its own: none moved out of the root (the wiring is +25, not +45), and none is new.
        def statements(tag, indent):
            pad = " " * indent
            return "".join(f"{pad}if {tag}Ready{i} {{\n{pad}    {tag}Start{i}()\n{pad}}}\n" for i in range(20))
        moved = "".join(f"        let delegateMoved{i} = delegateMove({i})\n" for i in range(10))
        wire = "".join(f"        let delegateWire{i} = DelegateWire({i})\n" for i in range(25))
        self.rebase_on({
            f"{APP}/AppDelegate.swift": "final class AppDelegate {\n    func launch() {\n" + moved
                                        + statements("delegate", 8) + "    }\n}\n",
            f"{APP}/TextBox/TextBoxView.swift": "final class TextBoxView {\n    func reload() {\n"
                                                + statements("textBox", 8) + "    }\n}\n",
        }, "a launch and a reload")
        self.write(f"{APP}/AppDelegate.swift", "final class AppDelegate {\n    func launch() {\n"
                   + statements("delegate", 12) + wire + "    }\n}\n")
        self.write(f"{APP}/TextBox/TextBoxView.swift", "final class TextBoxView {\n    func reload() {\n"
                   "        Task { @MainActor in\n" + "".join("    " + line for line in moved.splitlines(keepends=True))
                   + statements("textBox", 12) + "        }\n    }\n}\n")
        self.commit("10 lines out of AppDelegate, both files re-indent their own statements, 25 wiring lines")
        self.assertWarned("App outside the root grows +2 source lines", "CmuxNextApp grows +27 source lines",
                          "AppDelegate.swift +25 added, TextBox/TextBoxView.swift +2 new")

    def test_a_new_wrapper_around_a_block_moved_out_of_the_root_is_not_moved(self):
        # The block moved out of AppDelegate goes into a new `extension TextBoxView { ... }`. The wrapper's `}`
        # closes no opener of the block, so it is new feature code, not a line moved out of the root, even when the
        # root re-adds braces (a re-indented function of its own) that could pay for it: the wiring count is exact.
        lines = swift_body(200, "delegate").splitlines(keepends=True)
        own = ["  " + line if line.strip() else line for line in lines[:8]]
        block = "extension TextBoxView {\n" + "".join(lines[40:136]) + "}\n"
        for wire, verdict in ((swift_body(34, "wire"), None), (swift_body(35, "wire"), ("root", 1))):
            with self.subTest(wiring=code(wire)):
                self.reset()
                self.write(f"{APP}/AppDelegate.swift", "".join(own + lines[8:40] + lines[136:]) + wire)
                self.append(f"{APP}/TextBox/TextBoxView.swift", block)
                self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:200]))
                self.commit(f"84 lines out of AppDelegate into a new extension, {code(wire)} new wiring lines")
                if verdict is None:
                    self.assertEqual(code(wire), guardrails.ROOT_BUDGET)
                    self.assertPasses("wiring exactly at the budget")
                else:
                    found = self.assertRefused(f"the composition root grows +{code(wire)} source lines")
                    self.assertEqual([(h.bucket, h.excess) for h in found], [verdict])

    def test_the_growth_summary_counts_a_file_s_own_re_added_lines_whatever_the_root_removed(self):
        # TextBoxView's `}` and `return 0` lines that its own removed lines explain are not new, whether or not the
        # root also removes such lines in the push (AppDelegate deletes a function: its braces join the lines the
        # root lost). Once in a re-indented function, once after new code that ends a run too short to credit.
        box = swift_body(120, "textBox").splitlines(keepends=True)
        delegate = swift_body(200, "delegate").splitlines(keepends=True)
        reindented = "".join(["  " + line if line.strip() else line for line in box[:8]] + box[8:])
        fresh = "".join(f"    let textBoxFresh{i} = {i}\n" for i in range(3))
        after_new = ("    func textBoxFresh() -> Int {\n        textBoxRun()\n        return 0\n    }\n"
                     + "".join(f"    let textBoxFresh{i} = {i}\n" for i in range(6)))
        for name, text, new in (("re-indented", reindented + fresh, 3),
                                ("own function replaced", "".join(box[8:]) + after_new, 8)):
            for root_edit in (False, True):
                with self.subTest(name, root_edit=root_edit):
                    self.reset()
                    self.write(f"{APP}/TextBox/TextBoxView.swift", text)
                    if root_edit:
                        self.write(f"{APP}/AppDelegate.swift", "".join(delegate[8:]))
                    self.commit(f"TextBoxView: {name}; AppDelegate deletes a function: {root_edit}")
                    self.assertWarned("App outside the root grows +3 source lines",
                                      f"TextBox/TextBoxView.swift +{new} new")

    def test_a_new_type_in_an_existing_app_file_is_refused_like_a_new_file(self):
        # Lead decision (b): appending a new type to an existing file must not pass where its own new file would not.
        view = f"{APP}/TextBox/TextBoxView.swift"
        thing = swift_type("NewThingView", 40, head="@MainActor\n")
        self.append(view, "\n" + thing)
        self.commit("a new 40-line type appended to an existing App file")
        found = self.assertRefused("new type NewThingView in an existing App file",
                                   "a new App file for new code is refused too",
                                   "keep it a private helper of <= 15 source lines", "// app-type-allow:")
        self.assertEqual([h.bucket for h in found], [f"new:{view}:NewThingView"])
        self.assertEqual(found[0].number, 122, "points at the declaration line")
        # Review 2 of app-size-b: "its own file" sent new code into the new-file refusal (ClassicMigrationRunState).
        self.assertNotIn("its own file", found[0].text)
        for name, text in (("an actor", swift_type("Loader", 20, kind="actor")),
                           ("a public final class", swift_type("Store", 20, kind="class", head="public final ")),
                           ("an enum", swift_type("Mode", 20, kind="enum")),
                           ("a protocol", "protocol Saving {\n    func save()\n}\n"),
                           ("a private type over 15 lines", swift_type("Helper", 20, head="private "))):
            with self.subTest(refused=name):
                self.reset()
                self.append(view, text)
                self.commit(name)
                self.assertTrue([h for h in self.hits() if h.bucket.startswith(f"new:{view}:")], name)

    def test_a_new_type_in_an_existing_file_passes_when_it_is_moved_small_private_an_extension_or_escaped(self):
        view = f"{APP}/TextBox/TextBoxView.swift"
        quit_type = swift_type("QuitSteps", 40)
        self.rebase_on({f"{APP}/Quit/QuitSteps.swift": quit_type,
                        f"{APP}/TextBox/TextBoxStyle.swift": "struct TextBoxStyle {\n    let size = 1\n}\n"},
                       "types to move")
        cases = {
            "a type moved in from another App file": ({f"{APP}/Quit/QuitSteps.swift": None}, quit_type),
            "a private helper of 15 source lines": ({}, swift_type("Row", 16, head="private ")),
            "a fileprivate helper of 15 source lines": ({}, swift_type("Cell", 16, head="fileprivate ")),
            "an extension": ({}, "extension TextBoxStyle {\n" + swift_body(30, "ext") + "}\n"),
            "an escaped type": ({}, "// app-type-allow: the view's preview needs the private type\n"
                                + swift_type("Preview", 30, head="@MainActor\n")),
            "a type declared in a multi-line string": ({}, 'let template = """\n}\nstruct Fake {\n"""\n'),
        }
        self.assertEqual(code(swift_type("Row", 16)), 15)
        for name, (deleted, text) in cases.items():
            with self.subTest(passes=name):
                self.reset()
                for path in deleted:
                    (self.repo / path).unlink()
                self.append(view, text)
                self.commit(name)
                self.assertEqual([h.text for h in self.hits() if h.bucket.startswith(f"new:{view}")], [], name)
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit) + quit_type)
        self.commit("setup: QuitSteps also in an existing file")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit))
        self.append(view, quit_type)
        self.commit("a type moved between two existing App files")
        self.assertEqual([h.text for h in self.hits()], [], "a move between existing files is a move")
        self.reset()
        nested = "struct TextBoxLayout {\n" + "".join("    " + line if line.strip() else line
                                                     for line in swift_type("Metrics", 30).splitlines(True)) + "}\n"
        self.rebase_on({f"{APP}/TextBox/TextBoxLayout.swift": nested}, "a nested type")
        self.write(f"{APP}/TextBox/TextBoxLayout.swift", "struct TextBoxLayout {\n}\n" + swift_type("Metrics", 30))
        self.commit("a nested type lifted to the top level of its file")
        self.assertEqual([h.text for h in self.hits()], [], "a lifted nested type is a move")
        self.reset()
        self.write(f"{APP}/TextBox/TextBoxStyle.swift", "struct TextBoxStyle: Equatable {\n    let size = 1\n}\n")
        self.commit("an old type's declaration line gains a conformance")
        self.assertPasses("an edited declaration of a type the file already had is not a new type")
        self.reset()
        self.write(f"{APP}/TextBox/TextBoxStyle.swift", "struct TextBoxLook {\n    let size = 1\n}\n")
        self.commit("an old type renamed in place")
        self.assertEqual([h.text for h in self.hits()], [], "a rename in place adds no new code")

    def indent(self, text, by=4):
        return "".join(" " * by + line if line.strip() else line for line in text.splitlines(keepends=True))

    def type_hits(self, path):
        return [h for h in self.hits() if h.bucket.startswith(f"new:{path}:")]

    def test_a_new_type_nested_in_an_extension_a_type_or_a_function_is_held_to_the_move_rule(self):
        # Review 1 of app-size-b: the rule looked only at brace depth 0, so a type wrapped in `extension X { }` or
        # added inside an existing class passed with a growth warning (CLAUDE.md: nested types still count).
        view = f"{APP}/TextBox/TextBoxView.swift"
        zoom = f"{APP}/Zoom/ZoomModel.swift"
        self.rebase_on({zoom: "final class ZoomModel {\n" + swift_body(40, "zoom") + "}\n"}, "a Zoom class")
        zoom_lines = (self.repo / zoom).read_text().splitlines(keepends=True)

        def inside_zoom(text):
            return "".join(zoom_lines[:-1]) + self.indent(text) + zoom_lines[-1]
        refused = {
            "a type in an extension appended to a file":
                (view, None, "extension TextBoxView {\n" + self.indent(swift_type("Big", 40)) + "}\n",
                 "TextBoxView.Big"),
            "a 40-line struct inside an existing class": (zoom, inside_zoom(swift_type("Big", 40)), None, "ZoomModel.Big"),
            "a 40-line private struct inside an existing class":
                (zoom, inside_zoom(swift_type("Big", 40, head="private ")), None, "ZoomModel.Big"),
            "a small public type in an extension":
                (view, None, "extension TextBoxView {\n" + self.indent(swift_type("Tiny", 6, head="public ")) + "}\n",
                 "TextBoxView.Tiny"),
            "a 40-line local struct in a function body":
                (zoom, inside_zoom("func zoomLayout() {\n" + self.indent(swift_type("Local", 40)) + "}\n"),
                 None, "ZoomModel.zoomLayout().Local"),
        }
        for name, (path, text, appended, qual) in refused.items():
            with self.subTest(refused=name):
                self.reset()
                if text is not None:
                    self.write(path, text)
                else:
                    self.append(path, appended)
                self.commit(name)
                found = self.type_hits(path)
                self.assertEqual([h.bucket for h in found], [f"new:{path}:{qual}"], name)
                self.assertEqual(self.type_warnings(), [])
        passes = {
            "a small nested type in a class": inside_zoom(swift_type("Key", 10, kind="enum")),
            "a small private type in an extension": None,
        }
        for name, text in passes.items():
            with self.subTest(passes=name):
                self.reset()
                if text is not None:
                    self.write(zoom, text)
                else:
                    self.append(view, "extension TextBoxView {\n" + self.indent(swift_type("Row", 10, head="private "))
                                + "}\n")
                self.commit(name)
                self.assertEqual([h.text for h in self.hits() if h.bucket.startswith("new:")], [], name)
        # A nested type moved unchanged out of its outer type into an extension of an existing file is a move.
        self.reset()
        metrics = self.indent(swift_type("Metrics", 30))
        self.rebase_on({f"{APP}/TextBox/TextBoxLayout.swift": "struct TextBoxLayout {\n" + metrics + "}\n"},
                       "a nested type")
        self.write(f"{APP}/TextBox/TextBoxLayout.swift", "struct TextBoxLayout {\n}\n")
        self.write(zoom, "".join(zoom_lines) + "extension ZoomModel {\n" + metrics + "}\n")
        self.commit("a nested type moved into an extension of an existing file")
        self.assertEqual([h.text for h in self.hits() if h.bucket.startswith("new:")], [])

    def test_a_small_helper_that_stops_being_one_is_judged_whole(self):
        # Review 1 of app-size-b: push 1 adds a 15-line private helper (it passes); push 2 drops `private` and grows
        # it. The type was in the base, so the rule never looked at it again.
        view = f"{APP}/TextBox/TextBoxView.swift"
        lines = (self.repo / view).read_text()
        helper = swift_type("Foo", 16, head="private ")
        self.assertEqual(code(helper), guardrails.PRIVATE_TYPE_MAX)
        self.append(view, helper)
        self.commit("push 1: a private helper of 15 source lines")
        self.assertEqual([h.text for h in self.hits()], [], "push 1 passes")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        for name, text in (("push 2: no longer private and 300 lines", swift_type("Foo", 300)),
                           ("push 2: no longer private", swift_type("Foo", 16)),
                           ("push 2: still private, 40 lines", swift_type("Foo", 40, head="private "))):
            with self.subTest(name):
                self.reset()
                self.write(view, lines + text)
                self.commit(name)
                found = self.type_hits(view)
                self.assertEqual([h.bucket for h in found], [f"new:{view}:Foo"], name)
                self.assertIn("is no longer a small private or nested helper", found[0].text)
                # Its lines from the base are a move into its own file, so that advice stays for a whole type.
                self.assertIn("its own file" + (" (make it internal)" if "still private" in name else ""),
                              found[0].text)
        self.reset()
        self.write(view, lines + helper.replace("fooScaled0 = value * 2", "fooScaled0 = value * 3"))
        self.commit("control: an edit inside the helper that keeps it small and private")
        self.assertEqual([h.text for h in self.hits()], [])

    def test_one_removed_type_is_credited_to_one_placement_only(self):
        # Review 1 of app-size-b: each candidate type built its own pools, so one deleted type pasted into two
        # existing files (or into a new file and an existing one) was two moves.
        steps = swift_type("QuitSteps", 40)
        zoom = f"{APP}/Zoom/ZoomModel.swift"
        self.rebase_on({f"{APP}/Quit/QuitSteps.swift": steps, zoom: swift_body(40, "zoom")}, "a type to move")
        (self.repo / APP / "Quit/QuitSteps.swift").unlink()
        self.append(f"{APP}/TextBox/TextBoxView.swift", steps)
        self.append(zoom, steps)
        self.commit("one deleted type pasted into two existing files")
        self.assertEqual([h.bucket for h in self.hits() if h.bucket.startswith("new:")],
                         [f"new:{zoom}:QuitSteps"], "the first file in path order is the move, the second is new")
        self.reset()
        (self.repo / APP / "Quit/QuitSteps.swift").unlink()
        self.write(f"{APP}/Shutdown/QuitSteps.swift", steps)
        self.append(zoom, steps)
        self.commit("the deleted file re-added under a new name, and its type also pasted into an existing file")
        # One move and one refusal. The lines are back in an existing file, so the new file is no rename (as in
        # test_a_file_deleted_whole_and_pasted_into_an_existing_file_is_no_rename_of_a_new_copy): it is refused,
        # and the type is the move.
        self.assertEqual([h.bucket for h in self.hits() if h.bucket.startswith("new:")],
                         [f"new:{APP}/Shutdown/QuitSteps.swift"])

    def test_a_type_moved_into_the_root_is_the_root_budget_s_and_a_private_type_is_told_to_become_internal(self):
        steps = swift_type("QuitSteps", 40)
        self.rebase_on({f"{APP}/Quit/QuitSteps.swift": steps}, "a feature type")
        (self.repo / APP / "Quit/QuitSteps.swift").unlink()
        self.append(f"{APP}/AppServices+Glass.swift", steps)
        self.commit("a feature type moved into a root file")
        self.assertEqual([h.bucket for h in self.hits()], ["root"], "a move, which the root budget judges")
        self.reset()
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_type("Cache", 30, head="fileprivate "))
        self.commit("a new fileprivate type over 15 lines")
        found = self.type_hits(f"{APP}/TextBox/TextBoxView.swift")
        self.assertEqual(len(found), 1)
        self.assertIn("keep it a private helper of <= 15 source lines", found[0].text)
        self.assertNotIn("its own file", found[0].text, "new code in a new App file is refused too")

    def test_the_type_scan_reads_interpolations_raw_strings_and_regex_literals(self):
        # Review 1 of app-size-b: a brace in a raw string or a regex literal moved the old scan's depth, so every
        # type after it was invisible, with no warning.
        view = f"{APP}/TextBox/TextBoxView.swift"
        late = swift_type("Late", 40)
        tricky = {
            "an interpolation with a closure and a string": 'let lateTitle = "\\(items.map { "\\($0)}" }.joined()) {"\n',
            "a raw string": 'let lateRaw = #"a"b{"#\n',
            "a raw string with an escaped quote": 'let lateRawQuote = #"a\\#"b{"#\n',
            "a raw multi-line string": 'let lateRawMulti = #"""\n    "} {\n    """#\n',
            "a multi-line string with an interpolation": 'let lateMulti = """\n    {\\(a ? "}" : "{")\n    """\n',
            "a bare regex literal": "let lateRegex = /[{]/\n",
            "a bare regex after a keyword": "func lateMatch() -> Regex<Substring> {\n    return /a{2}}/\n}\n",
            "an extended regex literal": "let lateExtended = #/[{]\\//#\n",
            "a division": "let lateDivide = total / count / 2\n",
            "a nested block comment": "/* { /* nested } */ { */\n",
        }
        for name, text in tricky.items():
            with self.subTest(construct=name):
                self.reset()
                self.append(view, text + late)
                self.commit(name)
                self.assertEqual([h.bucket for h in self.type_hits(view)], [f"new:{view}:Late"], name)
                self.assertEqual(self.type_warnings(), [], name)

    def test_a_file_whose_braces_the_type_scan_cannot_follow_is_warned_and_left_out(self):
        view = f"{APP}/TextBox/TextBoxView.swift"
        self.append(view, "let stray = 1 }\n" + swift_type("Late", 40))
        self.commit("a stray closing brace before a new type")
        warned = self.type_warnings()
        self.assertEqual(len(warned), 1, warned)
        self.assertIn(f"{view}:1: could not follow this file's braces (head: a `}}` with no opener on line 121)",
                      warned[0])
        self.assertEqual(self.type_hits(view), [], "fail open for that file only")
        self.assertTrue(self.growth(), "app-size still runs")

    def test_a_fault_in_the_type_scan_turns_off_only_app_type(self):
        # Review 1 of app-size-b: the type check ran inside app-size, so an exception in the brace scan turned off
        # the root budget and the new-file refusals too.
        self.append(f"{APP}/AppDelegate.swift", swift_body(35, "wire"))
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_type("Late", 40))
        self.write(f"{APP}/Quit/QuitNew.swift", swift_body(20, "fresh"))
        self.commit("root +31, a new file and a new type")
        with mock.patch.object(guardrails, "type_scan", side_effect=RuntimeError("boom")):
            refusals, warnings = self.check()
        self.assertEqual(sorted(h.bucket for rule, hits in refusals if rule.id == "app-size" for h in hits),
                         [f"new:{APP}/Quit/QuitNew.swift", "root"])
        self.assertNotIn("app-type", [rule.id for rule, _ in refusals])
        failed = [text for kind, text in warnings if kind == "guardrails"]
        self.assertEqual(len(failed), 1, warnings)
        self.assertIn("rule app-type failed (RuntimeError: boom", failed[0])

    def test_the_type_scan_reads_only_files_that_can_add_a_type(self):
        # Review 1 of app-size-b: the scan read the base and head of every changed App file, so a wide rename paid a
        # Python scan per file. A file that adds no type declaration line and has no small helper type is skipped.
        files = {f"{APP}/Wide/Wide{i}.swift": swift_body(40, f"wide{i}") for i in range(30)}
        self.rebase_on(files, "thirty App files")
        for path, text in files.items():
            self.write(path, text.replace("Value0(", "Renamed0("))
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_type("Late", 40))
        self.commit("a one-line rename in thirty files and one new type")
        scanned = []
        real = guardrails.type_scan

        def counted(lines):
            scanned.append(len(lines))
            return real(lines)
        with mock.patch.object(guardrails, "type_scan", counted):
            found = self.hits()
        self.assertEqual(len(scanned), 2, "the base and head of the one file that adds a type")
        self.assertEqual([h.bucket for h in found if h.bucket.startswith("new:")],
                         [f"new:{APP}/TextBox/TextBoxView.swift:Late"])

    def test_a_type_moved_between_existing_files_is_a_move_while_another_file_adds_code(self):
        # Review 2 of app-size-b: app_type's pool subtracted every re-added line, braces too, so the `}` and
        # `return 0` another file's new functions add took the moved type's generic lines out of the pool; only
        # its specific lines were credited (about 45 % < MOVE_SHARE) and a pure move was refused.
        view, zoom = f"{APP}/TextBox/TextBoxView.swift", f"{APP}/Zoom/ZoomModel.swift"
        steps = swift_type("QuitSteps", 40)
        self.rebase_on({f"{APP}/Quit/QuitCoordinator.swift": "".join(self.quit) + steps,
                        zoom: swift_body(40, "zoom")}, "a type in an existing file")
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit))
        self.append(view, steps)
        self.append(zoom, swift_body(40, "zoomMore"))  # 5 new functions: 10 `}` and 5 `return 0`
        self.commit("a type moved between two existing files; a third file grows")
        self.assertEqual([h.text for h in self.hits() if h.bucket.startswith("new:")], [])
        self.assertEqual(self.type_warnings(), [], "the type was scanned and judged")
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit))
        self.append(view, steps.replace("quitSteps", "quitStepsNew"))
        self.append(zoom, swift_body(40, "zoomMore"))
        self.commit("control: a new type (not the removed one) appended in the same push")
        self.assertEqual([h.bucket for h in self.type_hits(view)], [f"new:{view}:QuitSteps"])

    def test_a_new_type_in_a_file_the_push_moves_is_judged(self):
        # Review 2 of app-size-b: a new file that passes as a move (a git mv that `--no-renames` shows as a delete
        # and an add, or a split) had no type check, so up to 20 % of a large moved file could be new types.
        old, new = f"{APP}/Quit/QuitCoordinator.swift", f"{APP}/Shutdown/QuitCoordinator.swift"
        quit = "".join(self.quit[:296])  # 37 whole functions: braces that balance, as the type scan needs
        self.rebase_on({old: quit}, "a QuitCoordinator whose braces balance")
        (self.repo / old).unlink()
        self.write(new, quit + swift_type("ShutdownPlan", 40))
        self.commit("git mv QuitCoordinator.swift to Shutdown/ with a new 40-line type appended")
        found = [h for h in self.hits() if h.bucket.startswith("new:")]
        self.assertEqual([h.bucket for h in found], [f"new:{new}:ShutdownPlan"], "the file is a move, its new type is not")
        self.assertIn("new type ShutdownPlan in a new App file that is a move", found[0].text)
        self.reset()
        steps = swift_type("QuitSteps", 40)
        self.rebase_on({old: quit + steps}, "a type to split out")
        self.write(old, quit)
        self.write(f"{APP}/Quit/QuitSteps.swift", steps)
        self.commit("control: a type split out of its file into a new file")
        self.assertEqual([h.text for h in self.hits()], [], "a split that moves a type whole passes")
        self.assertEqual(self.type_warnings(), [])

    def test_a_new_type_inside_a_type_moved_into_an_existing_file_is_judged(self):
        # A judged (moved) outer type covered every type inside it, so a new nested type rode on its move credit.
        view = f"{APP}/TextBox/TextBoxView.swift"
        steps = swift_type("QuitSteps", 200)
        self.rebase_on({f"{APP}/Quit/QuitCoordinator.swift": "".join(self.quit) + steps}, "a large type")
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit))
        lines = steps.splitlines(keepends=True)
        self.append(view, "".join(lines[:-1]) + self.indent(swift_type("Extra", 40)) + lines[-1])
        self.commit("a type moved into an existing file with a new 40-line type inside it")
        self.assertEqual([h.bucket for h in self.type_hits(view)], [f"new:{view}:QuitSteps.Extra"])
        self.reset()
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit))
        self.append(view, steps)
        self.commit("control: the type moved alone")
        self.assertEqual([h.text for h in self.hits() if h.bucket.startswith("new:")], [])
        self.assertEqual(self.type_warnings(), [])

    def test_a_small_private_type_with_a_large_extension_in_its_file_is_judged_on_both(self):
        # Review 2 of app-size-b: a 3-line private view is a small helper, and its body in `extension NewThingView`
        # did not count, so a 300-line view went into a god file with only a growth warning.
        view = f"{APP}/TextBox/TextBoxView.swift"
        self.append(view, "private struct NewThingView: View {\n    var body: some View { content }\n}\n"
                    "extension NewThingView {\n" + swift_body(296, "content") + "}\n")
        self.commit("a 3-line private view with a 296-line extension")
        found = self.type_hits(view)
        self.assertEqual([h.bucket for h in found], [f"new:{view}:NewThingView"])
        self.assertIn("with its `extension` blocks in this file", found[0].text)
        self.assertEqual(self.type_warnings(), [])
        self.reset()
        tiny = "private struct Tiny {\n    let a = 1\n}\nextension Tiny {\n" + swift_body(8, "tiny") + "}\n"
        self.assertLessEqual(code(tiny), guardrails.PRIVATE_TYPE_MAX)
        self.append(view, tiny)
        self.commit("control: a private helper and its extension, 15 source lines or fewer together")
        self.assertEqual([h.text for h in self.hits() if h.bucket.startswith("new:")], [])
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.append(view, "extension Tiny {\n" + swift_body(40, "tinyMore") + "}\n")
        self.commit("push 2: the helper grows through a new extension")
        found = self.type_hits(view)
        self.assertEqual([h.bucket for h in found], [f"new:{view}:Tiny"])
        self.assertIn("is no longer a small private or nested helper", found[0].text)

    def test_a_type_declared_after_a_comment_a_statement_or_a_nested_attribute_is_seen(self):
        # Review 2 of app-size-b: TYPE_DECL matched only at the start of the stripped line, with no nested
        # parentheses in an attribute, so these forms passed with no refusal and no warning.
        view = f"{APP}/TextBox/TextBoxView.swift"
        late = swift_type("Late", 40)
        for name, prefix in (("a block comment", "/* x */ "), ("an earlier statement", "let lateLead = 1; "),
                             ("an attribute with parentheses in a string",
                              '@available(*, deprecated, message: "use X (new)") '),
                             ("an attribute with nested parentheses", "@LateMacro(.init(x)) ")):
            with self.subTest(form=name):
                self.reset()
                self.append(view, prefix + late)
                self.commit(name)
                self.assertEqual([h.bucket for h in self.type_hits(view)], [f"new:{view}:Late"], name)
                self.assertEqual(self.type_warnings(), [], name)

    def test_one_root_block_pasted_into_a_feature_file_and_as_a_type_is_one_placement(self):
        # Review 2 of app-size-b: app_type's pool did not subtract what the other side adds back, so a root block
        # moved into feature file A (neutral for the root) also made a new type in feature file B a move.
        services = swift_body(200, "services").splitlines(keepends=True)
        block = "".join(services[40:80])
        zoom = f"{APP}/Zoom/ZoomModel.swift"
        self.rebase_on({zoom: swift_body(40, "zoom")}, "a Zoom file")
        self.write(f"{APP}/AppServices.swift", "".join(services[:40] + services[80:]))
        self.append(f"{APP}/TextBox/TextBoxView.swift", block)
        self.append(zoom, "struct Stolen {\n" + block + "}\n")
        self.commit("a root block pasted as plain lines into one feature file and as a type into another")
        self.assertEqual([h.bucket for h in self.type_hits(zoom)], [f"new:{zoom}:Stolen"])
        self.reset()
        self.write(f"{APP}/AppServices.swift", "".join(services[:40] + services[80:]))
        self.append(zoom, "struct Stolen {\n" + block + "}\n")
        self.commit("control: the root block moved only into the type")
        self.assertEqual([h.text for h in self.hits() if h.bucket.startswith("new:")], [])
        self.assertEqual(self.type_warnings(), [])

    def test_an_escape_on_an_outer_type_does_not_cover_the_types_inside_it(self):
        # Review 2 of app-size-b: one `// app-type-allow:` on `enum Namespace { }` let any number of nested types
        # of any size into a god file.
        view = f"{APP}/TextBox/TextBoxView.swift"
        self.append(view, "// app-type-allow: the view's names stay with the view\nenum TextBoxNames {\n"
                    + self.indent(swift_type("Big", 40)) + "}\n")
        self.commit("an escaped namespace with a 40-line type inside")
        self.assertEqual([h.bucket for h in self.type_hits(view)], [f"new:{view}:TextBoxNames.Big"])

    def test_code_moved_from_a_package_into_the_app_is_new_app_code(self):
        # The App-size rule moves code out of the App; a package's code moved into the App is the wrong direction,
        # so it is not a move: a new App file or a new type built from package lines is refused like new code.
        model = swift_type("KitModel", 40)
        self.rebase_on({f"{KIT}/KitModel.swift": model}, "a package type")
        (self.repo / KIT / "KitModel.swift").unlink()
        self.write(f"{APP}/TextBox/KitModel.swift", model)
        self.commit("a 40-line package file deleted and added as a new App file")
        found = self.assertRefused(f"new App file, {code(model)} source lines ({code(model)} not moved)")
        self.assertEqual([h.bucket for h in found], [f"new:{APP}/TextBox/KitModel.swift"])
        self.reset()
        (self.repo / KIT / "KitModel.swift").unlink()
        self.append(f"{APP}/TextBox/TextBoxView.swift", model)
        self.commit("the same package type appended to an existing App file")
        refused = [h for rule, found in self.check()[0] for h in found if h.bucket.startswith(f"new:{APP}/TextBox/")]
        self.assertEqual([h.bucket for h in refused], [f"new:{APP}/TextBox/TextBoxView.swift:KitModel"])

    def test_root_lines_moved_into_other_app_files_give_no_root_shrink_and_no_root_growth(self):
        # A pure move of root code into another App file is neutral for the root (the lead's ruling: pure moves
        # stay exempt; CLAUDE.md "File organization" asks to split god files): no shrink that makes room for new
        # wiring, and no growth. Only the new wiring counts. 62ee1308604 counted each moved line twice (+2 per
        # line), so a pure split of AppDelegate was refused.
        services = swift_body(200, "services").splitlines(keepends=True)
        moved = services[40:64]  # 21 source lines of existing root code
        self.assertEqual(code(moved), 21)
        # New wiring with no generic line (`}`, `return 0`): the root's own removed generic lines then all stay
        # available to the moved block, so this test checks the rule, not the cross-root run count.
        wire = "".join(f"    let wire{i} = makeWire({i})\n" for i in range(11))
        kept = "".join(services[:40] + services[64:])
        self.write(f"{APP}/AppServices.swift", kept + wire)
        self.write(f"{APP}/Workspace/WorkspaceWiring.swift", "extension AppServices {\n" + "".join(moved) + "}\n")
        self.commit("21 root lines moved into a feature file, 11 new root lines")
        self.assertEqual([h.bucket for h in self.hits() if h.bucket == "root"], [], "root +11: within the budget")
        self.reset()
        self.write(f"{APP}/AppServices.swift", kept + wire)
        self.append(f"{APP}/TextBox/TextBoxView.swift", "".join(moved))
        self.commit("the same lines appended to an existing feature file")
        self.assertEqual([h.bucket for h in self.hits() if h.bucket == "root"], [], "root +11: within the budget")
        self.reset()
        self.write(f"{APP}/AppServices.swift", kept + wire)
        self.write(f"{KIT}/Workspace/WorkspaceWiring.swift", "".join(moved))
        self.commit("control: the same lines moved into a package")
        self.assertEqual([h.text for h in self.hits()], [], "a move from the root into a package is a root shrink")

    def test_a_pure_move_out_of_app_delegate_into_a_new_app_file_passes(self):
        # The lead's case 1: 100 lines split out of AppDelegate into a new App file, nothing else.
        lines = swift_body(200, "delegate").splitlines(keepends=True)
        self.write(f"{APP}/AppDelegate.swift", "".join(lines[:37] + lines[137:]))
        self.write(f"{APP}/Launch/LaunchSteps.swift", "".join(lines[37:137]))
        self.commit("100 lines out of AppDelegate into a new App file")
        self.assertPasses("a pure move out of the root: no refusal, no growth warning")

    def test_new_root_lines_beside_a_move_out_of_the_root_count_whole(self):
        # The lead's case 2: a push moves 49 root lines into an App file and adds 50 new root lines. The move is
        # no root shrink, so the root grows +50 (not +1) and is refused.
        services = swift_body(200, "services").splitlines(keepends=True)
        moved = services[40:96]
        self.assertEqual(code(moved), 49)
        wire = "".join(f"    let wire{i} = makeWire({i})\n" for i in range(50))
        self.write(f"{APP}/AppServices.swift", "".join(services[:40] + services[96:]) + wire)
        self.write(f"{APP}/Workspace/WorkspaceWiring.swift", "extension AppServices {\n" + "".join(moved) + "}\n")
        self.commit("49 root lines moved into a feature file, 50 new root lines")
        found = self.assertRefused("the composition root grows +50 source lines", "budget of +30",
                                   "49 lines moved from the root into other App files give no root shrink")
        self.assertEqual([(h.bucket, h.excess) for h in found], [("root", 50 - guardrails.ROOT_BUDGET)])

    def test_new_wiring_split_between_the_root_and_a_feature_file_is_not_a_move_out_of_the_root(self):
        # Case 2 of the review: 41 new wiring lines, 29 in the root and 12 in a feature file. None of them was in
        # the root, so nothing moved out of it: the feature file's +12 is App growth (a warning, as agreed), and
        # the root is within its budget. Lead (2026-10-23): no lines out of the root is not an evasion; it passes.
        wire = swift_body(33, "wire")
        self.assertEqual(code(wire), 29)
        self.append(f"{APP}/AppServices.swift", wire)
        self.write(f"{APP}/Workspace/WorkspaceWiring.swift", "extension AppServices {\n" + swift_body(11, "split") + "}\n")
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:250]))  # an unrelated deletion
        self.commit("29 new root lines and 12 new lines in an AppServices extension in a feature folder")
        found = self.hits()
        self.assertEqual([h.bucket for h in found if h.bucket == "root"], [], "no root refusal")
        self.reset()
        self.append(f"{APP}/AppServices.swift", wire)
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(13, "split"))
        self.commit("the same 12 lines in an existing feature file")
        self.assertWarned("outside the root grows +12 source lines")

    def test_one_host_conformance_file_of_forwards_per_push(self):
        self.write(f"{APP}/AppServices+FooHost.swift", host_file(25))
        self.commit("a 25-line Host conformance, unpaid")
        self.assertWarned(f"CmuxNextApp grows +{code(host_file(25))} source lines")
        self.reset()
        self.assertEqual(code(host_file(31)), guardrails.HOST_FILE_MAX)
        self.write(f"{APP}/AppServices+FooHost.swift", host_file(31))
        self.shrink_quit()
        self.commit("a 30-source-line Host conformance for Quit code moved to its package")
        self.assertPasses()
        logic = "import CmuxNextFoo\n\n@MainActor\nextension AppServices: FooHost {}\n" + swift_body(24, "logic")
        nested = "import CmuxNextFoo\n\nextension AppServices: FooHost {\n" + swift_body(20, "logic") + "}\n"
        lines = host_file(25).splitlines(keepends=True)

        def member(text):
            """host_file(25) with TEXT as its first member: the Host file a dodge would write."""
            return "".join(lines[:4] + [f"    {text}\n"] + lines[4:])
        for text, needle in ((host_file(25, declare=False), "is outside `extension AppServices: <Domain>Host"),
                             (host_file(32), "at most 30 source lines"),
                             (logic, "holds only one-line forwards: line 5"),
                             (nested, "is not a one-line forward"),
                             (member("static var cache: [String: Int] = [:]"), "line 5 (`static var cache"),
                             (member("private static let table = makeTable()"), "stores state"),
                             (member("class var counter = 0"), "stores state"),
                             (member("var pending: [Int]"), "stores state"),
                             (member("init(foo: Foo) { self.init() }"), "is not a one-line forward")):
            with self.subTest(needle=needle):
                self.reset()
                self.write(f"{APP}/AppServices+FooHost.swift", text)
                self.shrink_quit(0)
                self.commit("a host file")
                found = self.assertRefused(needle)
                self.assertEqual([h.bucket for h in found if h.bucket.startswith("new:")],
                                 [f"new:{APP}/AppServices+FooHost.swift"])
        self.reset()
        self.write(f"{APP}/AppServices+FooHost.swift", member("var fooState: FooState { foo.state }"))
        self.shrink_quit()
        self.commit("a computed var forward")
        self.assertPasses("a computed var whose body is one brace pair is a forward")
        self.reset()
        domains = [f"Domain{chr(65 + i)}" for i in range(10)]
        for domain in domains:
            self.write(f"{APP}/AppServices+{domain}Host.swift", host_file(30, domain))
        self.commit("ten 30-line host files")
        found = self.assertRefused("one new Host conformance file per push")
        self.assertEqual(len([h for h in found if h.bucket.startswith("new:")]), 9)
        self.assertIn(f"the composition root grows +{9 * code(host_file(30))} source lines",
                      "\n".join(h.text for h in found))

    def test_a_host_file_that_takes_feature_lines_gives_no_shrink_credit(self):
        forwards = "".join(f"    func quitForward{i}() {{ quit.forward{i}() }}\n" for i in range(20))
        self.rebase_on({f"{APP}/Quit/QuitForwards.swift": "extension QuitCoordinator {\n" + forwards + "}\n"},
                       "Quit forwards")
        self.write(f"{APP}/Quit/QuitForwards.swift", "extension QuitCoordinator {\n}\n")
        self.write(f"{APP}/AppServices+QuitHost.swift",
                   "import CmuxNextQuit\n\n@MainActor\nextension AppServices: QuitHost {\n" + forwards + "}\n")
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(22, "fresh"))
        self.assertEqual(code(swift_body(22, "fresh")), 20)
        self.commit("20 feature lines into the Host file, 20 new feature lines")
        found = self.assertWarned("outside the root grows +20 source lines")
        self.assertEqual(len(found), 2, "the Host file itself is valid; the App grows by it")

    def test_a_feature_file_renamed_into_the_root_is_refused(self):
        self.git("mv", f"{APP}/Cloud/AppServices+Cloud.swift", f"{APP}/AppServices+Cloud.swift")
        self.commit("feature code becomes a root file")
        self.assertRefused("a new root file is split from the root files")

    def test_generic_lines_do_not_count_as_moves(self):
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(self.quit[:100]))
        self.append(f"{APP}/AppDelegate.swift", swift_body(60, "fresh"))
        self.commit("200 dead lines deleted, 60 new root lines (a third braces and return 0)")
        self.assertRefused(f"the composition root grows +{code(swift_body(60, 'fresh'))} source lines")
        self.reset()
        lines = swift_body(200, "delegate").splitlines(keepends=True)
        self.write(f"{APP}/AppDelegate.swift", "".join(lines[:100]))
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(100, "fresh"))
        self.commit("the root shrinks by 100, a feature file gets 100 new lines")
        self.assertWarned(f"outside the root grows +{code(swift_body(100, 'fresh'))} source lines")

    def test_a_long_numeric_line_in_a_move_is_judged_in_linear_time(self):
        line = "    [" + "1" * 40 + ", quitX],"
        started = time.monotonic()
        self.assertFalse(guardrails.is_generic(line.strip()))
        self.assertTrue(guardrails.is_generic("[" + "1" * 40 + "]"))
        self.assertLess(time.monotonic() - started, 1.0, "a nested-repeat regex takes 2^40 steps here")
        self.rebase_on({f"{APP}/Quit/QuitTable.swift": "let quitTable = [\n" + line + "\n" + swift_body(20, "table")
                        + "]\n"}, "a table")
        (self.repo / APP / "Shutdown").mkdir()
        self.git("mv", f"{APP}/Quit/QuitTable.swift", f"{APP}/Shutdown/QuitTable.swift")
        self.commit("move the table")
        self.assertPasses()

    def test_feature_growth_paid_by_a_feature_deletion_passes_and_warns_when_a_root_shrink_pays(self):
        self.shrink_quit(290)
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(5, "added"))
        self.commit("trade")
        self.assertPasses()
        self.reset()
        self.write(f"{APP}/AppDelegate.swift", swift_body(100, "delegate"))
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(5, "added"))
        self.commit("the root pays")
        found = self.assertWarned("outside the root grows +5 source lines")
        self.assertEqual(len(found), 1, "the App as a whole shrank")

    def test_source_lines_count_as_ci_counts_them_and_only_app_swift_files(self):
        self.append(f"{APP}/TextBox/TextBoxView.swift", "// a comment\n\n/*\nlet commented = 1\n*/\nlet last = 1")
        self.commit("one source line among comments and a blank")
        self.assertWarned("outside the root grows +1 source lines (+13 bytes)")
        self.reset()
        self.write(f"{APP}/Resources/Strings.xcstrings", "{\n" * 400)
        self.write(f"{KIT}/New.swift", swift_body(300, "kit"))
        self.commit("strings and a package file")
        self.assertPasses()

    def test_comment_and_blank_lines_are_neither_growth_nor_credit(self):
        lines = swift_body(120, "textBox").splitlines(keepends=True)
        lines.insert(1, "        // main-proof: an AppKit callback on the main thread\n\n")
        self.write(f"{APP}/TextBox/TextBoxView.swift", "".join(lines))
        self.append(f"{APP}/AppServices.swift", "/// The services every window shares.\n///\n/// More.\n")
        self.commit("comments and blank lines only")
        self.assertPasses("a `// main-proof:` reason is not growth")
        self.reset()
        blanks = len(self.quit) - code(self.quit)
        self.write(f"{APP}/Quit/QuitCoordinator.swift", "".join(line for line in self.quit if line.strip()))
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(42, "fresh"))
        self.assertEqual(code(swift_body(42, "fresh")), blanks)
        self.commit("blank lines deleted pay for nothing")
        self.assertWarned(f"outside the root grows +{blanks} source lines")

    def test_a_merge_counts_only_the_branch_s_own_growth(self):
        self.git("checkout", "--quiet", "-b", "topic")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.append(f"{APP}/TextBox/TextBoxView.swift", swift_body(50, "landed"))
        self.commit("App growth that landed past the guardrails")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.assertWarned(f"grows +{code(swift_body(50, 'landed'))} source lines",
                          args=(guardrails.check, pushed, "HEAD"))
        self.assertEqual(self.growth(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"), [], "merged")
        self.append(f"{APP}/Quit/QuitCoordinator.swift", swift_body(5, "own"))
        self.commit("the branch's own growth")
        found = self.assertWarned("outside the root grows +5 source lines", "CmuxNextApp grows +5 source lines",
                                  args=(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"))
        self.assertEqual(len(found), 2, found)
        # A root refusal in a merge counts only the branch's own excess, as before.
        self.append(f"{APP}/AppDelegate.swift", swift_body(40, "ownWire"))
        self.commit("the branch's own root wiring")
        found = self.assertRefused(f"the composition root grows +{code(swift_body(40, 'ownWire'))} source lines",
                                   args=(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"))
        self.assertEqual([(h.bucket, h.excess) for h in found],
                         [("root", code(swift_body(40, "ownWire")) - guardrails.ROOT_BUDGET)])

    def test_a_merge_counts_the_root_growth_the_branch_already_pushed_once(self):
        # The branch pushed +20 root lines before; it merges feat-cmux-next and adds +20 more: its own +20 is
        # within the budget, though over the merged upstream the root grows +40.
        self.git("checkout", "--quiet", "-b", "topic")
        self.append(f"{APP}/AppDelegate.swift", swift_body(23, "earlierWire"))
        self.commit("root wiring pushed before")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{KIT}/Landed.swift", "struct Landed {}\n")
        self.commit("landed on feat-cmux-next")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.append(f"{APP}/AppServices.swift", swift_body(23, "ownWire"))
        self.commit("the branch's own root wiring")
        earlier, own = code(swift_body(23, "earlierWire")), code(swift_body(23, "ownWire"))
        self.assertGreater(earlier + own, guardrails.ROOT_BUDGET, "control: over the merged upstream it is over")
        self.assertLessEqual(own, guardrails.ROOT_BUDGET)
        self.assertEqual(self.hits(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"), [])
        self.append(f"{APP}/AppServices.swift", swift_body(16, "moreWire"))
        self.commit("more of the branch's own root wiring")
        mine = own + code(swift_body(16, "moreWire"))
        found = self.assertRefused(f"this push's own: +{mine}", args=(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"))
        self.assertEqual([(h.bucket, h.excess) for h in found], [("root", mine - guardrails.ROOT_BUDGET)])

    def test_the_guardrails_skip_reason_names_the_rule(self):
        self.append(f"{APP}/AppDelegate.swift", swift_body(35, "wire"))
        self.shrink_quit(0)
        self.commit("31 root lines")
        refusals, _ = self.check()
        text, refused = self.report("app-size: generated wiring, reviewed", refusals)
        self.assertFalse(refused, text)
        self.assertIn("SKIPPED", text)
        text, refused = self.report("app-sise: typo", refusals)
        self.assertTrue(refused, text)
        self.assertIn("names no rule app-sise", text)


class GhosttyPinTests(Fixture):
    """The ghostty-next gitlink and the GhosttyNextKit pin name one commit after a push that changes either."""

    OLD, NEW = "7d5fa1573a7202ed7ae508f0aa70d2295712527e", "723c4ab93e70c6be896bd9b6d0ad42f2a5fbfedc"

    def manifest(self, commit):
        return ('.binaryTarget(\n    name: "GhosttyNextKit",\n    url: "https://github.com/manaflow-ai/ghostty-next/'
                f'releases/download/xcframework-{commit}-apple-v6/GhosttyNextKit.xcframework.zip",\n'
                '    checksum: "00"\n)\n')

    def gitlink(self, commit, message):
        self.git("update-index", "--add", "--cacheinfo", f"160000,{commit},{guardrails.GHOSTTY_NEXT}")
        self.git("commit", "--quiet", "--no-verify", "-m", message)

    def problem(self):
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            return guardrails.ghostty_pin_problem(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)

    def setUp(self):
        super().setUp()
        self.write(guardrails.GHOSTTY_KIT, self.manifest(self.OLD))
        self.git("add", guardrails.GHOSTTY_KIT)
        self.gitlink(self.OLD, "pinned and linked at one commit")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def test_a_gitlink_only_bump_is_refused_and_names_both_commits_and_the_fix(self):
        self.gitlink(self.NEW, "bump the gitlink only (769ae064b16)")
        problem = self.problem()
        self.assertIsNotNone(problem)
        self.assertIn("[ghostty-pin]", problem)
        self.assertIn(self.NEW[:12], problem)
        self.assertIn(self.OLD[:12], problem)
        self.assertIn("do:", problem)

    def test_a_bump_of_both_passes_and_a_push_that_changes_neither_passes(self):
        self.write(guardrails.GHOSTTY_KIT, self.manifest(self.NEW))
        self.git("add", guardrails.GHOSTTY_KIT)
        self.gitlink(self.NEW, "bump both")
        self.assertIsNone(self.problem())
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.gitlink(self.OLD, "mismatch landed by someone else")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        self.write(f"{KIT}/Unrelated.swift", "struct Unrelated {}\n")
        self.commit("an unrelated push on a mismatched base")
        self.assertIsNone(self.problem())

    def test_it_runs_under_a_fifth_of_a_second(self):
        self.gitlink(self.NEW, "bump the gitlink only")
        started = time.monotonic()
        self.problem()
        self.assertLess(time.monotonic() - started, 0.2)


class WarningTests(Fixture):
    def test_changing_a_perf_hot_function_names_its_bench(self):
        self.write(f"{KIT}/Router.swift", HOT.replace("count += key", "count += key * 2"))
        self.commit("changes the hot path")
        refusals, warnings = self.check()
        self.assertEqual(refusals, [])
        hot = [w for kind, w in warnings if kind == "perf-hot"]
        self.assertEqual(len(hot), 1, warnings)
        self.assertIn("bench-typing.py", hot[0])
        self.assertIn("2ms", hot[0])

    def test_changing_a_cold_function_does_not_warn(self):
        self.write(f"{KIT}/Router.swift", HOT.replace("count = 0\n    }\n}", "count = -1\n    }\n}"))
        self.commit("changes the cold path")
        _, warnings = self.check()
        self.assertEqual([w for kind, w in warnings if kind == "perf-hot"], [])

    def test_removing_a_perf_hot_marker_warns(self):
        self.write(f"{KIT}/Router.swift", HOT.replace(" // perf-hot: 2ms key-dispatch", ""))
        self.commit("drops the marker")
        _, warnings = self.check()
        self.assertTrue(any("removes a perf-hot marker" in w for _, w in warnings), warnings)

    def test_editing_a_marked_declaration_line_keeps_its_marker_without_a_warning(self):
        self.write(f"{KIT}/Router.swift", HOT.replace("func dispatch(_ key: Int) {", "func dispatch(_ key: Int, again: Bool = false) {"))
        self.commit("adds a parameter to the hot function")
        _, warnings = self.check()
        self.assertFalse(any("removes a perf-hot marker" in w for _, w in warnings), warnings)
        self.assertTrue(any(kind == "perf-hot" for kind, _ in warnings), warnings)

    # ChordTracker.step and KeyBindingTable.step (feat-cmux-next): the signature runs over two lines and the marker
    # trails the line with the body's `{`.
    WRAPPED = ("import Foundation\nstruct Chords {\n    var armed = 0\n"
               "    mutating func step(_ key: Int, window: Int, focus: Int? = nil,\n"
               "                       first: (Int) -> Int?, canArm: () -> Bool) -> Int { // perf-hot: 0.5ms key-dispatch\n"
               "        armed += key\n        return armed\n    }\n}\n")

    def test_a_marker_after_a_wrapped_signature_marks_its_function(self):
        self.rebase_on({f"{KIT}/Chords.swift": self.WRAPPED}, "a wrapped hot signature")
        self.write(f"{KIT}/Chords.swift", self.WRAPPED.replace("armed += key", "armed += key * 2"))
        self.commit("changes the hot body")
        hot = [w for kind, w in self.check()[1] if kind == "perf-hot"]
        self.assertEqual(len(hot), 1, hot)
        self.assertIn("Chords.swift:4:", hot[0])
        self.assertIn("mutating func step", hot[0])
        self.assertIn("bench-typing.py", hot[0])

    def test_a_marker_that_marks_no_declaration_warns(self):
        self.write(f"{KIT}/Router.swift", HOT.replace("        count = 0\n", "        count = 0 // perf-hot: 2ms key-dispatch\n"))
        self.commit("a marker on a statement")
        hot = [w for kind, w in self.check()[1] if kind == "perf-hot"]
        self.assertTrue(any("Router.swift:8:" in w and "marks no declaration" in w for w in hot), hot)

    def test_codebase_health_counts_the_markers_the_guardrails_resolve(self):
        spec = importlib.util.spec_from_file_location("cmux_next_codebase_health", SOURCE / "scripts/cmux-next/codebase-health.py")
        health = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(health)
        chords, router = f"{KIT}/Chords.swift", f"{KIT}/Router.swift"
        texts = {chords: self.WRAPPED,
                 router: HOT.replace("        count = 0\n", "        count = 0 // perf-hot: 2ms key-dispatch\n")}

        def resolved():
            """(path, declaration line) per marker, None for a marker that marks no declaration."""
            found = [(m.path, m.declaration) for m in health.perf_hot_markers(guardrails, texts) if m.pid == "key-dispatch"]
            return sorted(found, key=lambda entry: (entry[0], -1 if entry[1] is None else entry[1]))

        self.assertEqual(resolved(), [(chords, 4), (router, None), (router, 4)],
                         "Chords' wrapped step() and Router's dispatch() are marked; the statement marker marks nothing")
        texts[router] = HOT.replace(" // perf-hot: 2ms key-dispatch", "").replace(
            "        count = 0\n", "        count = 0 // perf-hot: 2ms key-dispatch\n")
        self.assertEqual(resolved(), [(chords, 4), (router, None)], "a marker on a statement marks nothing")

    def test_touching_an_owned_area_names_the_owner_and_doc(self):
        self.write(f"{KIT}/Sidebar/Row.swift", "struct R {}\n")
        self.commit("sidebar row")
        refusals, warnings = self.check()
        self.assertEqual(refusals, [])
        owners = [w for kind, w in warnings if kind == "owner"]
        self.assertEqual(len(owners), 1, warnings)
        self.assertIn("a590", owners[0])
        self.assertIn("plans/cmux-next/sidebar-owner.md", owners[0])

    def test_the_owned_areas_of_the_plan_warn_with_their_owner(self):
        # plans/cmux-next/OWNERS.md as it ships: each area perf-lead.md and the lead brief assign has a row whose
        # globs cover its code paths, so a push there names the owner.
        self.write("plans/cmux-next/OWNERS.md", (SOURCE / "plans/cmux-next/OWNERS.md").read_text())
        self.commit("the shipped owner map")
        self.base = self.git("rev-parse", "HEAD").stdout.strip()
        expected = {
            # The typing row names this file; the terminal row only its folder: the most specific row owns it.
            f"{PKG}/Sources/CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift": ["PL-typing"],
            f"{PKG}/Sources/CmuxNextTerminal/GhosttyRuntime.swift": ["PL-ghostty"],
            f"{PKG}/Sources/CmuxNextApp/GhosttyConfigLiveReload.swift": ["PL-ghostty"],
            "cmux-tui/crates/cmux-tui-core/src/service.rs": ["PL-daemon"],
            "cmux-tui/crates/cmux-server/src/lib.rs": ["PL-daemon"],
            "cmux-tui/crates/cmux-pty/src/lib.rs": ["PL-daemon"],
            "cmux-tui/crates/cmux-process/src/spawn_apple.rs": ["PL-holder"],
            "cmux-tui/crates/cmux-flow-trace/src/lib.rs": ["PL-trace"],
            # Not listed: a crate no row names has no owner (no catch-all row).
            "cmux-tui/crates/cmux-git/src/lib.rs": [],
            "cmux-tui/crates/cmux-tui-core/src/holder_runtime/sink.rs": ["PL-daemon holder"],
            "cmux-tui/crates/cmux-holder-v3/src/holder.rs": ["PL-daemon holder"],
            "cmux-tui/crates/acpmux/src/lib.rs": ["PL-acpmux"],
            "cmux-tui/crates/acpmux/src/main.rs": ["PL-acpmux"],
            "scripts/cmux-next/build-acpmux.sh": ["PL-acpmux"],
            f"{PKG}/Sources/CmuxNextHangReports/HangReportService.swift": ["PL-telemetry"],
            f"{PKG}/Sources/CmuxNextApp/HangReports/HangReportsController.swift": ["PL-telemetry"],
            f"{PKG}/Sources/CmuxNextApp/Windows/WindowState.swift": ["PL-switch"],
            f"{PKG}/Sources/CmuxNextApp/Windows/WindowRegistry+Selection.swift": ["PL-switch"],
        }
        for path, owners in expected.items():
            with self.subTest(path=path):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(path, "// touched\n")
                self.commit(f"touches {path}")
                warned = [w for kind, w in self.check()[1] if kind == "owner"]
                for owner in owners:
                    self.assertTrue(any(f"owner {owner}" in w for w in warned), (owner, warned))
                # One file, one owner per area: no second row (a catch-all folder, a duplicate area) names another.
                self.assertEqual(len(warned), len(owners), warned)

    def test_a_typical_push_runs_git_a_fixed_number_of_times(self):
        # The cost that grows with a push is git process starts, so count them instead of timing a busy runner:
        # one diff, one name list and one batched blob read, however many files the push changes.
        for n in range(5):
            self.write(f"{KIT}/F{n}.swift", "import Foundation\n" + "func f() { print(1) }\n" * 300)
        self.commit("five files")
        calls = []

        def run(args, *rest, **kwargs):
            calls.append(args)
            return subprocess.run(args, *rest, **kwargs)

        def popen(args, *rest, **kwargs):
            calls.append(args)
            return subprocess.Popen(args, *rest, **kwargs)

        # A stand-in for the module guardrails.py and its git helper imported, so subprocess's own internals are
        # not counted.
        stand_in = types.SimpleNamespace(run=run, Popen=popen, PIPE=subprocess.PIPE, DEVNULL=subprocess.DEVNULL)
        guardrails.subprocess = guardrails.git_batch.subprocess = stand_in
        try:
            refusals, _ = self.check()
        finally:
            guardrails.subprocess = guardrails.git_batch.subprocess = subprocess
        self.assertEqual(refusals, [])
        self.assertEqual(len(calls), 3, calls)



class LexCacheTests(Fixture):
    """app-size's lexing (lead 2026-10-24: the guardrails took 2.4-2.8 s on the slowest real pushes): a plain file is
    classified per line, a file with a block comment, a multi-line string or a regex literal is lexed by CI's lexer
    once per blob and cached under the git common dir."""

    def test_the_per_line_path_matches_cis_lexer_on_plain_files(self):
        lexer = guardrails.swift_lexer()
        for text in ("import Foundation\n\n// note\n   // indented note\nlet x = 1 // trailing\n}\n",
                     'let url = "http://example.com"\n/// doc\n#if DEBUG\nfunc f() {}\n#endif\n', "", "\n\n"):
            self.assertEqual(guardrails.source_flags(text), lexer(text), text)

    def test_a_lexed_blob_is_cached_and_reused(self):
        text = 'let a = 1\n/* a\n block */\nlet s = """\n  x\n  """\n'
        blob = "ab" * 20
        cache = self.root / "lex"
        guardrails.LEX_CACHE["dir"] = cache
        self.addCleanup(guardrails.LEX_CACHE.__setitem__, "dir", None)
        want = guardrails.swift_lexer()(text)
        self.assertEqual(guardrails.source_flags(text, blob), want)
        self.assertEqual((cache / blob).read_text(), "".join("1" if f else "0" for f in want))
        with mock.patch.object(guardrails, "swift_lexer", return_value=lambda t: self.fail("lexed again")):
            self.assertEqual(guardrails.source_flags(text, blob), want, "the cache answers")
        (cache / blob).write_text("1")  # a damaged entry (wrong length) is lexed again
        self.assertEqual(guardrails.source_flags(text, blob), want)

    def test_check_finds_the_cache_under_the_git_common_dir_and_fails_open(self):
        found = guardrails.lex_cache_dir(self.repo)
        self.assertIsNotNone(found)
        self.assertEqual(found.parent.parent, (self.repo / ".git").resolve())
        tree = self.root / "worktree"
        self.git("worktree", "add", "--quiet", "--detach", str(tree))
        self.assertEqual(guardrails.lex_cache_dir(tree), found, "a linked worktree shares its repository's cache")
        self.assertIsNone(guardrails.lex_cache_dir(self.root / "no-such-dir"))


class SharedRuleTests(Fixture):
    """A rule another check owns is judged by that check's own definition, never by a second copy here."""

    def load_ratchet(self):
        spec = importlib.util.spec_from_file_location("crash_ratchet_for_test", SOURCE / "scripts/cmux-next/crash_ratchet.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_unchecked_sendable_is_refused_exactly_when_the_crash_ratchet_counts_it(self):
        # CI's crash ratchet (crash_ratchet.py, class `unchecked`) takes `// crash-allow:` on the line or the line
        # directly above; a push this rule passes must not turn that ratchet red after it lands.
        ratchet = self.load_ratchet()
        body = "final class Box: @unchecked Sendable {\n    let x = 0\n}\n"
        for text in ("// crash-allow: x is written once in init, then only read\n" + body,
                     body.replace("Sendable {", "Sendable { // crash-allow: x is written once in init"),
                     "// crash-allow: x is written once in init, then only read\n// and never after\n" + body,
                     "// crash-allow: x is written once in init, then only read\n@available(macOS 14, *)\n" + body):
            with self.subTest(text=text):
                lines = text.split("\n")
                counted = any("unchecked" in ratchet.swift_line_hits(lines, i) and not ratchet.allowed(lines, i)
                              for i in range(len(lines)) if not lines[i].lstrip().startswith("//"))
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", text)
                self.commit("an unchecked box")
                self.assertEqual("unchecked-sendable" in [rule for rule, _ in self.refused()], counted)


class SleepRuleTests(unittest.TestCase):
    """check-concurrency.sh's wakeup rule is the one sleep rule (the guardrails no longer copy it): every sleep
    primitive counts, the injected sleeper CLAUDE.md prescribes too (`try await sleep(delay)`)."""

    MANIFEST = ("// swift-tools-version: 6.2\nimport PackageDescription\n"
                "let package = Package(name: \"Fixture\", targets: [\n"
                "    .target(name: \"FixtureUI\", swiftSettings: uiSwiftSettings),\n])\n")

    def scan(self, text):
        with tempfile.TemporaryDirectory(prefix="cmux-sleep-rule-") as temporary:
            root = Path(temporary) / "Package"
            (root / "Sources/FixtureUI").mkdir(parents=True)
            (root / "Package.swift").write_text(self.MANIFEST)
            (root / "Sources/FixtureUI/Wait.swift").write_text(text)
            return subprocess.run(["bash", str(SOURCE / "scripts/cmux-next/check-concurrency.sh"), str(root)],
                                  text=True, capture_output=True, timeout=60)

    def test_an_injected_sleeper_is_a_sleep(self):
        for call in ("try await sleep(.milliseconds(50))", "try await self.sleep(delay)", "try? await clockSleep.sleep(delay)",
                     "do { try await sleep(delay) } catch { return }"):
            with self.subTest(call=call):
                result = self.scan(f"func wait(sleep: Sleep) async throws {{\n    while !ready() {{\n        {call}\n    }}\n}}\n")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("Wait.swift:3: sleep", result.stdout)

    def test_a_reviewed_wakeup_allow_passes_and_a_thread_sleep_stays_refused(self):
        allowed = self.scan("func hold(sleep: Sleep) async {\n    // wakeup-allow: one 450 ms press-and-hold delay, cancelled on release\n"
                            "    do { try await sleep(.milliseconds(450)) } catch { return }\n}\n")
        self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
        blocking = self.scan("func spin() {\n    while !done() {\n        Thread.sleep(forTimeInterval: 0.01)\n    }\n}\n")
        self.assertEqual(blocking.returncode, 1, blocking.stdout + blocking.stderr)
        self.assertIn("Wait.swift:3: Thread.sleep", blocking.stdout)

    def test_an_injected_sleeper_in_a_task_group_is_a_raced_deadline(self):
        result = self.scan("func first(sleep: Sleep) async throws {\n    try await withThrowingTaskGroup(of: Void.self) { group in\n"
                           "        // wakeup-allow: the deadline under test\n"
                           "        group.addTask { try await sleep(.seconds(1)) }\n        try await group.next()\n    }\n}\n")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Wait.swift:2: deadline raced in a task group", result.stdout)


class BlobReadTests(Fixture):
    """The file texts come from one `git cat-file --batch`; a failed read must stop the check, not judge lines alone."""

    # An escaped main hop (passes): its escape is on the line above, so judging it needs the file's text.
    TEXT = ("func f() {\n    // main-async-allow: AppKit's sheet callback API forces a GCD hop\n"
            "    DispatchQueue.main.async { print(1) }\n}\n")

    def fake_git(self, body):
        """Put a `git` first on PATH whose `cat-file` runs BODY (sh) and whose other commands are the real git."""
        real = shutil.which("git")
        folder = self.root / "fake-bin"
        folder.mkdir(exist_ok=True)
        script = folder / "git"
        script.write_text("#!/bin/sh\nfor arg in \"$@\"; do\n  if [ \"$arg\" = cat-file ]; then\n"
                          f"{body}\n  fi\ndone\nexec {real} \"$@\"\n")
        script.chmod(0o755)
        saved = os.environ["PATH"]
        os.environ["PATH"] = f"{folder}{os.pathsep}{saved}"
        self.addCleanup(os.environ.__setitem__, "PATH", saved)

    def test_the_blob_request_never_goes_through_a_pipe(self):
        # cmux-lawrence hangs on a subprocess with more than about 10 KB of piped stdin (e8b8e40e4e9); a hang
        # there is a push that never returns. This git refuses a piped request instead of hanging the test.
        self.fake_git("    if [ -p /dev/stdin ]; then echo 'fake git: piped stdin hangs here' >&2; exit 1; fi")
        self.write(f"{KIT}/Added.swift", self.TEXT)
        self.commit("an escaped main hop")
        self.assertEqual(self.refused(), [])

    def test_a_failed_blob_read_stops_the_check_and_the_hook_fails_open(self):
        self.fake_git("    echo 'fake git: cat-file failed' >&2; exit 1")
        self.write(f"{KIT}/Added.swift", self.TEXT)
        self.commit("an escaped main hop")
        with self.assertRaises(Exception):
            self.check()
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate", SOURCE / "scripts/cmux-next/prepush-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()) as stdout:
                ranges = [(self.base, "HEAD")]
                refused = gate.guardrails(self.repo, ranges, gate.start_guardrails(self.repo, ranges, SOURCE / "scripts/cmux-next"))
        finally:
            os.environ.update(saved)
            sys.modules[_spec.name] = guardrails
        self.assertFalse(refused, stdout.getvalue())
        self.assertIn("guardrails.py failed", stderr.getvalue())
        self.assertNotIn("[main-async]", stdout.getvalue())


class GateWrapperTests(Fixture):
    """guardrails.run_push(): a checker failure lets through only the range it could not judge."""

    def test_a_failure_on_one_pushed_range_keeps_the_refusal_of_another(self):
        rule = next(r for r in guardrails.RULES if r.id == "main-async")

        def check_own(repo, base, head, before=()):
            if head == "feat-b":
                raise SystemExit("guardrails: git diff failed")
            return [(rule, [guardrails.Added(f"{KIT}/A.swift", 1, "DispatchQueue.main.async { }")])], []

        class Finished:
            def finish(self):
                return "", False

        ranges = [types.SimpleNamespace(base=self.base, head=head, before=()) for head in ("feat-a", "feat-b")]
        stderr, stdout = io.StringIO(), io.StringIO()
        with mock.patch.object(guardrails, "check_own", check_own), \
                contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(stdout):
            refused = guardrails.run_push(self.repo, ranges, Finished())
        self.assertTrue(refused, stderr.getvalue())
        self.assertIn("[main-async]", stdout.getvalue())
        self.assertIn("feat-b", stderr.getvalue(), "the warning names the range it could not judge")


class RatchetWaitTests(unittest.TestCase):
    """guardrails.Ratchet.finish(): a slow arch ratchet still judges the push.

    On 2026-10-31 the push of 7c99189e2ce (app_lines +2, TIP RED 1014) passes the hook's gate on a busy CPU: the
    ratchet needs about 18 s warm, finish() waited 20 s, printed "ran past 20s; not applied" and let the push
    through. The gate's own watchdog (prepush-gate.py, CMUX_NEXT_GATE_LIMIT_SECONDS) already refuses a hung push,
    so the wait needs no limit of its own that passes the push."""

    def test_a_ratchet_slower_than_any_wait_limit_still_refuses(self):
        with tempfile.TemporaryDirectory(prefix="cmux-ratchet-wait-") as folder:
            Path(folder, guardrails.ARCH_RATCHET).write_text(
                "import time\n"
                "def run_push(repo, ranges, out=None):\n"
                "    time.sleep(1.0)\n"
                "    out.append('arch-ratchet: [app_lines] CmuxNextApp Swift lines: +2')\n"
                "    return True\n")
            # Any wait limit shorter than the ratchet's run: the old 20 s on a loaded Mac, 0.2 s here.
            with mock.patch.object(guardrails.Ratchet, "WAIT_LIMIT", 0.2, create=True):
                ratchet = guardrails.Ratchet(Path(folder), [], scripts_dir=Path(folder))
                text, refused = ratchet.finish()
        self.assertTrue(refused, text)
        self.assertIn("[app_lines]", text)
        self.assertNotIn("not applied", text)


class HookTests(Fixture):
    """The installed pre-push hook runs the guardrails; CI (GITHUB_ACTIONS, --commits) never does."""

    def setUp(self):
        super().setUp()
        tracked = subprocess.run(["git", "-C", str(SOURCE), "ls-files", "--cached", "--others", "--exclude-standard",
                                  "scripts/cmux-next"], text=True, capture_output=True, check=True).stdout.split()
        checks = [p for p in tracked if "/" not in p[len("scripts/cmux-next/"):]
                  or p.startswith(("scripts/cmux-next/lint/", "scripts/cmux-next/arch_rules/"))]
        for relative in ("scripts/git-hooks", "scripts/install-git-hooks.sh", "scripts/web_lint_prepush.py",
                         "scripts/ci/base_merge_warning.py", "scripts/web-lint.sh", "scripts/merge-xcstrings.py",
                         "scripts/merge-pbxproj.py", "scripts/merge-baseline.py", "scripts/merge-daemon-capabilities.py",
                         "scripts/ci/merge_main_resolver.py", "scripts/ci/validate_test_execution_registry.py",
                         "scripts/ci/test_execution_registry.py", "scripts/ci/workload_entrypoints.py",
                         "scripts/normalize-pbxproj.py", *checks):
            source, target = SOURCE / relative, self.repo / relative
            if not source.exists() or target.exists():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_dir():
                shutil.copytree(source, target)
            else:
                shutil.copyfile(source, target)
                shutil.copymode(source, target)
        self.commit("scripts")
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.install()
        self.write(f"{KIT}/Added.swift", "func added() {\n    DispatchQueue.main.async { print(1) }\n}\n")
        self.commit("adds a main hop")

    def install(self):
        installed = subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, env=self.env, text=True,
                                   capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)

    def push(self, *args, **env):
        return subprocess.run(["git", "-C", str(self.repo), "push", "origin", *(args or ("feat-cmux-next",))],
                              env={**self.env, **env}, text=True, capture_output=True)

    def test_debt_landed_on_feat_cmux_next_does_not_block_a_branch_merged_with_or_rebased_onto_it(self):
        other = {"CMUX_NEXT_CHECKS_SKIP_REASON": "fixture: other checks"}
        self.git("checkout", "--quiet", "-b", "topic", "HEAD~1")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        first = self.push("topic", **other)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        before = self.git("rev-parse", "HEAD").stdout.strip()
        # The main-hop commit lands on feat-cmux-next past the guardrails (a skip reason, a clone without hooks).
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("merge", "--quiet", "--no-edit", "--no-verify", "origin/feat-cmux-next")
        merged = self.push("topic", **other)
        output = merged.stdout + merged.stderr
        self.assertEqual(merged.returncode, 0, output)
        self.assertNotIn("[main-async]", output)
        self.git("reset", "--quiet", "--hard", before)
        self.git("rebase", "--quiet", "origin/feat-cmux-next")
        rebased = self.push("--force", "topic", **other)
        output = rebased.stdout + rebased.stderr
        self.assertEqual(rebased.returncode, 0, output)
        self.assertNotIn("[main-async]", output)
        self.write(f"{KIT}/Own.swift", "func own() {\n    DispatchQueue.main.async { print(2) }\n}\n")
        self.commit("the branch's own main hop")
        own = self.push("topic", **other)
        output = own.stdout + own.stderr
        self.assertNotEqual(own.returncode, 0, output)
        self.assertIn("Own.swift", output)
        self.assertNotIn("Added.swift", output)

    def test_hook_refuses_a_new_main_hop_even_with_the_checks_skip_reason(self):
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("[main-async]", output)
        self.assertIn("Added.swift", output)
        self.assertNotIn("Old.swift", output, "base debt must not be reported")

    def test_hook_lets_the_push_through_with_the_guardrails_skip_reason(self):
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks",
                           CMUX_GUARDRAILS_SKIP_REASON="main-async: fixture")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("SKIPPED by CMUX_GUARDRAILS_SKIP_REASON", output)

    def test_hook_refuses_app_growth_and_no_skip_reason_lets_the_app_total_rise(self):
        self.git("reset", "--quiet", "--hard", "HEAD~1")  # without setUp's main hop
        self.write(f"{APP}/Feature/Thing.swift", swift_body(12, "thing"))
        self.commit("a new App file")
        other = {"CMUX_NEXT_CHECKS_SKIP_REASON": "fixture: other checks"}
        refused = self.push(**other)
        output = refused.stdout + refused.stderr
        self.assertNotEqual(refused.returncode, 0, output)
        self.assertIn("[app-size]", output)
        self.assertIn("Feature/Thing.swift", output)
        skipped = self.push(**other, CMUX_GUARDRAILS_SKIP_REASON="app-size: fixture")
        output = skipped.stdout + skipped.stderr
        self.assertIn("SKIPPED by CMUX_GUARDRAILS_SKIP_REASON", output)
        # The skip reason skips guardrails' app-size rule only: the arch ratchet's app_lines row still refuses
        # the App total's rise (reward-hacking audit 2026-10-30; the ratchet has no skip).
        self.assertNotEqual(skipped.returncode, 0, output)
        self.assertIn("[app_lines]", output)

    def test_hook_refuses_a_new_stateful_singleton_through_the_arch_ratchet_and_no_skip_reason_skips_it(self):
        self.write(f"{KIT}/Cache.swift", "final class Cache {\n    var hits = 0\n    static let shared = Cache()\n}\n")
        self.commit("adds a stateful singleton")
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks",
                           CMUX_GUARDRAILS_SKIP_REASON="main-async: fixture")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("[stateful_singletons]", output)
        self.assertIn("Cache.swift:3", output)
        self.assertIn('"row": "stateful_singletons"', output, "the refusal names its one escape, a dated exception")

    def test_an_installed_arch_rule_module_refuses_the_push(self):
        # The installer copies arch_rules/ next to the trusted arch-ratchet.py; a module it left out would never run.
        self.write("scripts/cmux-next/arch_rules/fixture_refuse.py",
                   "def check(base, head, changes):\n"
                   "    return [('fixture_refuse', 'arch rule fixture_refuse: refused this push')], []\n")
        self.commit("adds an arch rule module")
        self.install()
        installed = self.repo / ".git" / "cmux-git-hooks" / "cmux-next-checks" / "arch_rules"
        self.assertTrue((installed / "fixture_refuse.py").is_file(), sorted(p.name for p in installed.glob("*")))
        self.assertTrue((installed / "__init__.py").is_file())
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks",
                           CMUX_GUARDRAILS_SKIP_REASON="main-async: fixture")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("arch rule fixture_refuse: refused this push", output)
        self.assertNotIn("arch rules directory", output)

    def test_a_broken_guardrails_script_warns_and_lets_the_push_through(self):
        installed = self.repo / ".git" / "cmux-git-hooks" / "cmux-next-checks"
        self.assertTrue(installed.is_symlink(), "the installer swaps a link, so the checks are never missing")
        (installed / "guardrails.py").write_text("def run_push(repo, ranges, ratchet=None):\n    raise ValueError('boom')\n")
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("guardrails.py failed (ValueError: boom)", output)

    def test_a_second_install_keeps_the_checks_in_place(self):
        before = (self.repo / ".git" / "cmux-git-hooks" / "cmux-next-checks").resolve()
        again = subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, env=self.env, text=True,
                               capture_output=True)
        self.assertEqual(again.returncode, 0, again.stderr)
        link = self.repo / ".git" / "cmux-git-hooks" / "cmux-next-checks"
        self.assertTrue(link.is_symlink())
        self.assertNotEqual(link.resolve(), before, "each install writes a new copy")
        self.assertTrue((link / "guardrails.py").is_file())
        # Retention is by use, not by age or position: a push holds its copy (the test below); with none running
        # the replaced copy goes, so copies never pile up.
        self.assertFalse(before.exists(), "no push holds the replaced copy")

    def install(self):
        result = subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, env=self.env, text=True,
                                capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_push_running_on_an_old_checks_copy_keeps_it_through_later_installs(self):
        # The gate resolves the checks link once. A push that started on a days-old copy and is still in swiftlint
        # when two other worktrees reinstall (the stale-copy warning asks every agent to) must keep that copy.
        hooks = self.repo / ".git" / "cmux-git-hooks"
        link = hooks / "cmux-next-checks"
        old = link.resolve()
        days = time.time() - 3 * 86400
        os.utime(old, (days, days))
        spec = importlib.util.spec_from_file_location("cmux_next_installed_gate", hooks / "cmux_next_prepush_gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        reached, release = threading.Event(), threading.Event()

        class PushedRefs:  # the hook's stdin: the gate blocks here after it resolved its checks copy
            def read(self):
                reached.set()
                release.wait(120)
                return ""

        result, stderr = {}, io.StringIO()

        def push():
            with mock.patch.object(sys, "stdin", PushedRefs()), contextlib.redirect_stdout(io.StringIO()):
                result["code"] = gate.main(["--pre-push", "--repo", str(self.repo), "--trusted-scripts-dir", str(link)])

        with mock.patch.dict(os.environ, self.env, clear=True), contextlib.redirect_stderr(stderr):
            running = threading.Thread(target=push)
            running.start()
            try:
                self.assertTrue(reached.wait(60), "the gate never read the pushed refs")
                self.install()
                self.install()
                self.assertTrue((old / "guardrails.py").is_file(), "a push is still reading this copy")
            finally:
                release.set()
                running.join(120)
        self.assertEqual(result.get("code"), 0, stderr.getvalue())
        self.assertNotIn("not installed", stderr.getvalue())
        self.install()
        self.assertFalse(old.exists(), "once no push reads it, the next install removes the old copy")
        self.assertTrue((link / "guardrails.py").is_file())

    def leftover(self, name, files, in_use, age_seconds=0):
        """A checks copy (or a half-removed one) in the hook folder: FILES files, `.in-use` when IN_USE."""
        path = self.repo / ".git" / "cmux-git-hooks" / name
        path.mkdir()
        for n in range(files):
            (path / f"check{n}.py").write_text("x = 1\n")
        if in_use:
            (path / ".in-use").touch()
        if age_seconds:
            then = time.time() - age_seconds
            os.utime(path, (then, then))
        return path

    def test_an_install_waits_for_one_that_is_removing_a_leftover_and_both_finish(self):
        # post-merge runs the installer in every worktree that pulls a hook change, so two can run together. Install
        # A is stopped inside its cleanup, at the start of its removal of a killed install's half-removed tree, while
        # install B starts. B waits for A (and names A's pid) instead of removing that tree too; then both finish
        # and the leftovers are gone. Without the install lock B removes the tree and A's removal fails.
        hooks = self.repo / ".git" / "cmux-git-hooks"
        killed = self.leftover("cmux-next-checks.deleting.1.cmux-next-checks.v1.1", 3, in_use=True)
        legacy = self.leftover("cmux-next-checks.v2.2", 3, in_use=False, age_seconds=3600)
        (hooks / "python3-path").unlink()
        reached, release = self.root / "reached.fifo", self.root / "release.fifo"
        os.mkfifo(reached)
        os.mkfifo(release)
        real = os.path.realpath(shutil.which("python3", path=self.env.get("PATH")))
        prelude = (
            "import shutil\n"
            "_rmtree, _stopped = shutil.rmtree, []\n"
            "def _stop_once(path, *args, **kwargs):\n"
            "    if not _stopped:\n"
            "        _stopped.append(path)\n"
            f"        with open({str(reached)!r}, 'w') as signal:\n"
            "            signal.write(path)\n"
            f"        with open({str(release)!r}) as go:\n"
            "            go.read()\n"
            "    return _rmtree(path, *args, **kwargs)\n"
            "shutil.rmtree = _stop_once\n")
        stub = self.root / "python-stub"
        stub.mkdir()
        (stub / "python3").write_text(
            f"#!{real} -I\n"
            "# Stops install A's cleanup (the -c program that removes `.deleting.` trees) at its first tree removal.\n"
            "import os, sys\n"
            "args = sys.argv[1:]\n"
            "if args[:2] == ['-I', '-c'] and 'cmux-next-checks.deleting.' in args[2]:\n"
            f"    args = ['-I', '-c', {prelude!r} + args[2], *args[3:]]\n"
            f"os.execv({real!r}, [{real!r}, *args])\n")
        (stub / "python3").chmod(0o755)
        first = subprocess.Popen(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, text=True,
                                 env={**self.env, "PATH": f"{stub}:{self.env['PATH']}"},
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        signal = {}
        waiter = threading.Thread(target=lambda: signal.setdefault("text", reached.read_text()))
        waiter.start()
        waiter.join(120)
        if waiter.is_alive():
            first.kill()
            with open(reached, "w"):
                pass  # unblocks the waiter
            self.fail(f"install A never removed a tree: {first.communicate()}")
        self.assertEqual(os.path.realpath(signal["text"]), os.path.realpath(killed))
        second = subprocess.Popen(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, env=self.env, text=True,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        said, heard = [], threading.Event()

        def listen():
            for line in second.stderr:
                said.append(line)
                if "waiting for it to finish" in line:
                    heard.set()
            heard.set()  # B is done (the end of its output) without saying it waits

        reader = threading.Thread(target=listen)
        reader.start()
        try:
            # A bound only for a failure: an install that waits without a word would leave this test hanging.
            self.assertTrue(heard.wait(120), "install B neither said it waits nor finished")
            self.assertTrue(killed.exists(), f"install B removed the tree install A is removing: {''.join(said)}")
            self.assertIn(f"(pid {first.pid}); waiting for it to finish", "".join(said))
            self.assertIsNone(second.poll(), "install B finished while install A held the lock")
        finally:
            with open(release, "w") as go:
                go.write("go\n")
            _, err = first.communicate(timeout=300)
            second.wait(timeout=300)
            reader.join(300)
            second.stderr.close()
        self.assertEqual(first.returncode, 0, err)
        self.assertEqual(second.returncode, 0, "".join(said))
        self.assertTrue((hooks / "python3-path").is_file())
        self.assertFalse(killed.exists())
        self.assertFalse(legacy.exists())
        current = (hooks / "cmux-next-checks").resolve()
        self.assertTrue((current / "guardrails.py").is_file())
        self.assertTrue((current / ".in-use").is_file())

    def test_a_process_an_install_leaves_running_does_not_hold_the_install_lock(self):
        # With core.fsmonitor=true, an index read (`git ls-files`) starts `git fsmonitor--daemon run --detach`,
        # which keeps every fd it inherits and outlives the install. A lock fd it inherits would make every later
        # install (post-merge runs one on each pull of feat-cmux-next) wait forever. A stub git that detaches a
        # process the same way stands in for the daemon (the builtin one runs on macOS and Windows only).
        hooks = self.repo / ".git" / "cmux-git-hooks"
        pidfile = self.root / "detached.pid"
        real = os.path.realpath(shutil.which("git", path=self.env.get("PATH")))
        stub = self.root / "git-stub"
        stub.mkdir()
        (stub / "git").write_text(
            "#!/bin/bash\n"
            f'if [[ "$1" == ls-files && ! -e "{pidfile}" ]]; then\n'
            "    sleep 600 </dev/null >/dev/null 2>&1 &\n"
            f'    echo $! > "{pidfile}"\n'
            "fi\n"
            f'exec "{real}" "$@"\n')
        (stub / "git").chmod(0o755)
        first = subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, text=True, capture_output=True,
                               env={**self.env, "PATH": f"{stub}:{self.env['PATH']}"}, timeout=300)
        detached = int(pidfile.read_text())

        def stop():
            with contextlib.suppress(ProcessLookupError):
                os.kill(detached, 9)

        self.addCleanup(stop)
        self.assertEqual(first.returncode, 0, first.stderr)
        os.kill(detached, 0)  # the stand-in daemon outlived the install
        lock = os.open(hooks / "install.lock", os.O_RDONLY)
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                self.fail("a process the install left running holds the install lock")
        finally:
            os.close(lock)
        self.install()

    def test_an_install_that_overlaps_another_links_a_copy_with_its_lock_file(self):
        # Install A is stopped where it first takes a lock (a python3 start, 30-80 ms, in a real run) while install B
        # runs from start to end. B's cleanup must never remove a copy A is staging: A's linked copy keeps its
        # `.in-use`, so a push on it holds it.
        stub = self.root / "python-stub"
        stub.mkdir()
        reached, release = self.root / "reached.fifo", self.root / "release.fifo"
        os.mkfifo(reached)
        os.mkfifo(release)
        real = os.path.realpath(shutil.which("python3", path=self.env.get("PATH")))
        (stub / "python3").write_text(
            "#!/bin/bash\n"
            "# Stops install A where it first takes a lock (the install lock holder, its first python3) until the test\n"
            "# releases it; its cleanup, which takes the copies' locks later, runs through.\n"
            f'case "$*" in *CMUX_HOOKS_INSTALL_LOCK_HELD*) echo reached > "{reached}"; read -r _ < "{release}" ;; esac\n'
            f'exec "{real}" "$@"\n')
        (stub / "python3").chmod(0o755)
        first = subprocess.Popen(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, text=True,
                                 env={**self.env, "PATH": f"{stub}:{self.env['PATH']}"},
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        signal = {}
        waiter = threading.Thread(target=lambda: signal.setdefault("text", reached.read_text()))
        waiter.start()
        waiter.join(120)
        if waiter.is_alive():
            first.kill()
            with open(reached, "w"):
                pass  # unblocks the waiter
            self.fail(f"install A never took a lock: {first.communicate()}")
        self.install()  # install B, from start to end, while A waits at its lock
        with open(release, "w") as go:
            go.write("go\n")
        _, err = first.communicate(timeout=300)
        self.assertEqual(first.returncode, 0, err)
        current = (self.repo / ".git" / "cmux-git-hooks" / "cmux-next-checks").resolve()
        self.assertTrue((current / "guardrails.py").is_file())
        self.assertTrue((current / ".in-use").is_file(), "the linked copy lost its lock file to the other install's cleanup")

    def test_a_sleep_poll_and_an_assume_isolated_are_refused_once_by_the_check_that_owns_them(self):
        # check-concurrency.sh's wakeup rule owns sleeps (escape `// wakeup-allow:`), crash_ratchet.py owns
        # assumeIsolated (banned; escape `// main-proof:`). A second refusal here with other advice (`poll-allow:`)
        # sent agents to an escape the owning check does not honor.
        self.git("reset", "--quiet", "--hard", "HEAD~1")
        self.write(f"{PKG}/Package.swift", "// swift-tools-version: 6.2\nimport PackageDescription\n"
                   "let uiSwiftSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]\n"
                   "let package = Package(name: \"CmuxNext\", targets: [\n"
                   "    .target(name: \"CmuxNextApp\", swiftSettings: uiSwiftSettings),\n"
                   "    .target(name: \"CmuxNextKit\", swiftSettings: uiSwiftSettings),\n])\n")
        self.write(f"{APP}/CmuxNextApp.swift", "import Foundation\nfunc start() { ChildSignalDefaults.installAppSignalPolicy() }\n")
        self.commit("package")
        base = self.git("rev-parse", "HEAD").stdout.strip()
        self.write(f"{KIT}/Poll.swift", "func wait() async throws {\n    while !ready() {\n"
                   "        try await Task.sleep(for: .milliseconds(5))\n    }\n}\n"
                   "func hop() {\n    MainActor.assumeIsolated { print(1) }\n}\n")
        self.commit("a poll and an unproven hop")
        gate = self.repo / "scripts/cmux-next/prepush-gate.py"
        result = subprocess.run([sys.executable, "-I", str(gate), "--base", base, "--head", "HEAD"],
                                cwd=self.repo, env=self.env, text=True, capture_output=True)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("Main-thread concurrency", output)
        self.assertIn("Crash safety", output)
        self.assertNotIn("[sleep-poll]", output)
        self.assertNotIn("[assume-isolated]", output)
        self.assertNotIn("poll-allow", output)

    def test_ci_runs_never_apply_the_guardrails(self):
        gate = self.repo / "scripts/cmux-next/prepush-gate.py"
        local = subprocess.run([sys.executable, "-I", str(gate), "--base", self.base, "--head", "HEAD"],
                               cwd=self.repo, env=self.env, text=True, capture_output=True)
        self.assertIn("[main-async]", local.stdout + local.stderr, "a local run applies them (control)")
        for args, env in (([], {"GITHUB_ACTIONS": "true"}), (["--commits", f"{self.base}..HEAD"], {})):
            with self.subTest(args=args, env=env):
                result = subprocess.run([sys.executable, "-I", str(gate), "--base", self.base, "--head", "HEAD", *args]
                                        if not args else [sys.executable, "-I", str(gate), *args],
                                        cwd=self.repo, env={**self.env, **env}, text=True, capture_output=True)
                self.assertNotIn("guardrails", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
