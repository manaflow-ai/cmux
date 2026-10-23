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
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
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
ROW = """import SwiftUI
struct WorkspaceRow: View {
    let title: String
    var body: some View { Text(title) }
}
"""

# rule id -> (file text that adds it, the same with its reviewed escape or the right pattern)
CASES = {
    "singleton": ("final class Cache {\n    static let shared = Cache()\n}\n",
                  "final class Cache {\n    // singleton-allow: the process has exactly one memory-pressure source\n"
                  "    static let shared = Cache()\n}\n"),
    "unchecked-sendable": ("final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
                           "// crash-allow: x is written once in init, then only read\n"
                           "final class Box: @unchecked Sendable {\n    let x = 0\n}\n"),
    "main-async": ("func f() {\n    DispatchQueue.main.async { print(1) }\n}\n",
                   "@MainActor func f() {\n    print(1)\n}\n"),
    "broadcast-name": ("extension Notification.Name {\n    static let pagesChanged = Notification.Name(\"pagesChanged\")\n}\n",
                       "protocol PagesObserver: AnyObject {\n    func pageChanged(_ id: Int)\n}\n"),
    "combine-state": ("import Combine\nfinal class Model: ObservableObject {\n    @Published var x = 0\n}\n",
                      "import Observation\n@Observable final class Model {\n    var x = 0\n}\n"),
    "generic-class-deinit": ("@MainActor final class Once<T> {\n    var value: T?\n}\n",
                             "@MainActor final class Once<T> {\n    var value: T?\n    nonisolated deinit {}\n}\n"),
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
        self.write(f"{KIT}/Old.swift", "final class Old {\n    static let shared = Old()\n}\n")  # base debt
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
        self.commit("moves the old singleton and edits elsewhere")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def test_editing_a_line_that_already_has_debt_adds_none(self):
        before = {
            f"{KIT}/Old.swift": "final class Old {\n    static let shared = Old()\n}\n",
            f"{KIT}/Box.swift": "final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
        }
        self.rebase_on(before)
        after = {
            f"{KIT}/Old.swift": "final class Old {\n    static let shared = Old(limit: 2)\n}\n",
            f"{KIT}/Box.swift": "final class Box: Equatable, @unchecked Sendable {\n    var x = 0\n}\n",
        }
        for relative, text in after.items():
            self.write(relative, text)
        self.commit("edits lines that already had debt")
        refusals, _ = self.check()
        self.assertEqual([(r.id, [h.text.strip() for h in hits]) for r, hits in refusals], [])

    def test_an_edit_does_not_hide_a_second_new_hit_in_the_same_file(self):
        self.write(f"{KIT}/Old.swift", "final class Old {\n    static let shared = Old(limit: 2)\n}\n"
                                       "final class Other {\n    static let shared = Other()\n}\n")
        self.commit("edits one singleton and adds another")
        refusals, _ = self.check()
        self.assertEqual([(r.id, len(hits)) for r, hits in refusals], [("singleton", 1)])

    def test_stateful_named_singletons_are_refused_and_value_constants_pass(self):
        cases = {
            "final class Prefs {\n    static let standard = Prefs()\n}\n": True,
            "actor Clock {\n    static let live = Clock()\n}\n": True,
            "struct Style {\n    static let standard = Style()\n}\n": False,
            "enum Spacing {\n    static let `default` = 8.0\n}\n": False,
        }
        for text, refused in cases.items():
            with self.subTest(text=text):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", text)
                self.commit("named static")
                self.assertEqual("singleton" in [r.id for r, _ in self.check()[0]], refused)

    def test_a_named_static_holding_a_reference_instance_is_refused_in_any_container(self):
        # The pushed tree's declarations decide: an extension takes its type's kind, and a value container (a
        # namespace enum, a struct) that stores an instance of a class or actor holds runtime state too.
        self.rebase_on({f"{KIT}/AppModel.swift": "final class AppModel {}\n",
                        f"{KIT}/NotificationService.swift": "final class NotificationService {}\n",
                        f"{KIT}/DaemonClient.swift": "public actor DaemonClient {}\n",
                        f"{KIT}/Style.swift": "struct Style {\n    var size = 1\n}\n",
                        f"{KIT}/Config.swift": "struct Config {}\n"}, "declarations")
        cases = {
            "extension AppModel {\n    static let current = AppModel()\n}\n": True,
            "enum Env {\n    static let live = NotificationService()\n}\n": True,
            "struct Deps {\n    static let live: DaemonClient = .init()\n}\n": True,
            "extension Style {\n    static let compact = Style(size: 2)\n}\n": False,
            "enum Env {\n    static let current = Config()\n}\n": False,
            "extension Style {\n    static let standard = Self()\n}\n": False,
        }
        start = self.base
        for text, refused in cases.items():
            with self.subTest(text=text):
                self.git("reset", "--quiet", "--hard", start)
                self.write(f"{KIT}/Added.swift", text)
                self.commit("named static")
                self.assertEqual("singleton" in [r for r, _ in self.refused()], refused)

    def test_short_notification_names_in_a_name_extension_are_refused(self):
        for decl in ('Self("pagesChanged")', '.init("pagesChanged")'):
            with self.subTest(decl=decl):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", f"extension Notification.Name {{\n    static let pagesChanged = {decl}\n}}\n")
                self.commit("short name")
                self.assertIn("broadcast-name", [r.id for r, _ in self.check()[0]])

    # rule id -> (file with justified debt, the escape line) for every rule whose escape sits above the line.
    ESCAPED = {
        "singleton": ("final class Hub {\n    // singleton-allow: the process has one memory-pressure source\n"
                      "    static let shared = Hub()\n}\n", "    // singleton-allow: the process has one memory-pressure source\n"),
        "unchecked-sendable": ("// crash-allow: x is written once in init, then only read\n"
                               "final class Box: @unchecked Sendable {\n    let x = 0\n}\n",
                               "// crash-allow: x is written once in init, then only read\n"),
        "main-async": ("func f() {\n    // main-async-allow: AppKit's sheet callback API forces a GCD hop\n"
                       "    DispatchQueue.main.async { print(1) }\n}\n",
                       "    // main-async-allow: AppKit's sheet callback API forces a GCD hop\n"),
        "broadcast-name": ("extension Notification.Name {\n    // broadcast-allow: every window must hear a theme change\n"
                           "    static let themeChanged = Notification.Name(\"themeChanged\")\n}\n",
                           "    // broadcast-allow: every window must hear a theme change\n"),
        "row-store": ("import SwiftUI\nstruct WorkspaceRow: View {\n    // row-snapshot-allow: one row, never in a list\n"
                      "    @Environment(SidebarStore.self) private var store\n    var body: some View { Text(\"x\") }\n}\n",
                      "    // row-snapshot-allow: one row, never in a list\n"),
        "generic-class-deinit": ("// generic-class-allow: its target is nonisolated by default\nfinal class Once<T> {\n    var value: T?\n}\n",
                                 "// generic-class-allow: its target is nonisolated by default\n"),
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

    def test_a_struct_that_becomes_a_class_around_a_named_static_is_refused(self):
        start = self.base
        for name, after in (
            ("static unchanged", "final class Prefs {\n    static let standard = Prefs()\n}\n"),
            ("static edited", "final class Prefs {\n    static let standard = Prefs(suite: 2)\n}\n"),
        ):
            with self.subTest(name):
                self.git("reset", "--quiet", "--hard", start)
                self.rebase_on({f"{KIT}/Prefs.swift": "struct Prefs {\n    static let standard = Prefs()\n}\n"})
                self.write(f"{KIT}/Prefs.swift", after)
                self.commit("struct -> class")
                self.assertEqual([rule for rule, _ in self.refused()], ["singleton"])

    def test_an_edit_of_the_opener_around_old_debt_adds_none(self):
        row = ("import SwiftUI\nstruct EntryRow: View {\n    @Environment(SidebarStore.self) private var store\n"
               "    var body: some View { Text(\"x\") }\n}\n")
        self.rebase_on({f"{KIT}/Entry.swift": row})
        self.write(f"{KIT}/Old.swift", "final class Old: Sendable {\n    static let shared = Old()\n}\n")
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
        self.rebase_on({f"{KIT}/Cache.swift": "final class Cache {\n    static let shared = Cache()\n}\n"})
        self.write(f"{KIT}/Cache.swift", "final class Cache {\n    static let shared = Cache(limit: 2)\n}\n")
        self.write(f"{KIT}/Store.swift", "final class Store {\n    static let shared = Cache()\n}\n")
        self.commit("edits one singleton and copies its old line into another class")
        self.assertEqual(self.refused(), [("singleton", ["Cache.swift: static let shared = Cache(limit: 2)"])])

    def test_only_declared_notification_names_are_refused(self):
        cases = {
            "func observe() {\n    NotificationCenter.default.addObserver(forName: "
            "Notification.Name(\"com.apple.screenIsLocked\"), object: nil, queue: nil) { _ in }\n}\n": False,
            "func post(name: Notification.Name = .pagesChanged) {}\n": False,
            "enum Names {\n    static let pagesChanged = Notification.Name(\"pagesChanged\")\n}\n": True,
            "let pagesChanged = Notification.Name(\"pagesChanged\")\n": True,
        }
        for text, refused in cases.items():
            with self.subTest(text=text):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", text)
                self.commit("notification name")
                self.assertEqual("broadcast-name" in [rule for rule, _ in self.refused()], refused)

    def test_a_no_prefix_diff_config_still_applies_the_rules(self):
        self.git("config", "diff.noprefix", "true")
        self.git("config", "diff.mnemonicPrefix", "true")
        self.write(f"{KIT}/Added.swift", CASES["singleton"][0])
        self.write(f"{KIT}/Conflict.swift", "<<<<<<< HEAD\nlet a = 1\n=======\nlet a = 2\n>>>>>>> topic\n")
        self.commit("a singleton and a conflict")
        self.assertEqual([rule for rule, _ in self.refused()], ["singleton"])
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate", SOURCE / "scripts/cmux-next/prepush-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            markers = gate.conflict_markers(self.repo, self.base, "HEAD")
        finally:
            os.environ.update(saved)
        self.assertEqual(len(markers), 2, markers)

    def test_lines_brought_in_from_feat_cmux_next_never_count(self):
        self.git("checkout", "--quiet", "-b", "topic")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{KIT}/Landed.swift", CASES["singleton"][0])
        self.commit("debt that landed past the guardrails (a skip reason, a clone without hooks)")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.assertEqual(self.refused(guardrails.check, pushed, "HEAD"),
                         [("singleton", ["Landed.swift: static let shared = Cache()"])], "control: the plain range has it")
        self.assertEqual(self.refused(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"), [], "merged")
        self.write(f"{KIT}/Own.swift", "final class Own {\n    static let shared = Own()\n}\n")
        self.commit("the branch's own singleton")
        self.assertEqual(self.refused(guardrails.check_push, pushed, "HEAD", "feat-cmux-next"),
                         [("singleton", ["Own.swift: static let shared = Own()"])])
        self.git("reset", "--quiet", "--hard", pushed)
        self.git("rebase", "--quiet", "feat-cmux-next")
        # The hook's base for a force push is the merge base of the new and the old head: the old fork point.
        fork = self.git("merge-base", "HEAD", pushed).stdout.strip()
        self.assertEqual(self.refused(guardrails.check, fork, "HEAD"),
                         [("singleton", ["Landed.swift: static let shared = Cache()"])], "control: the plain range has it")
        self.assertEqual(self.refused(guardrails.check_push, fork, "HEAD", "feat-cmux-next"), [], "rebased")

    def test_owner_globs_do_not_cross_folders_with_a_single_star(self):
        self.assertTrue(guardrails.glob_match("A/Motion/Spring.swift", "A/Motion/"))
        self.assertTrue(guardrails.glob_match("A/MotionGate.swift", "A/Motion*.swift"))
        self.assertFalse(guardrails.glob_match("A/Motion/Spring.swift", "A/Motion*.swift"))
        self.assertTrue(guardrails.glob_match("A/B/C/D.swift", "A/**/D.swift"))

    def test_a_moved_line_that_only_gains_an_access_modifier_is_no_new_debt(self):
        (self.repo / "Packages/macOS/CmuxNext/Sources/CmuxNextOther").mkdir(parents=True)
        self.git("mv", f"{KIT}/Old.swift", "Packages/macOS/CmuxNext/Sources/CmuxNextOther/Old.swift")
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextOther/Old.swift",
                   "package final class Old {\n    package static let shared = Old()\n}\n")
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

    def test_other_rules_do_not_read_test_targets(self):
        self.write("Packages/macOS/CmuxNext/Tests/CmuxNextFooTests/Fake.swift",
                   "final class Fake {\n    static let shared = Fake()\n}\n")
        self.commit("a test fake singleton")
        self.assertEqual(self.refused(), [])

    def test_skip_reason_lets_the_push_through_and_is_printed(self):
        self.write(f"{KIT}/Added.swift", CASES["singleton"][0])
        self.commit("adds a singleton")
        refusals, warnings = self.check()
        os.environ[guardrails.SKIP_ENV] = "singleton: test"
        try:
            text, refused = guardrails.format_report(refusals, warnings)
        finally:
            del os.environ[guardrails.SKIP_ENV]
        self.assertFalse(refused)
        self.assertIn("SKIPPED", text)

    def test_a_rule_that_raises_is_off_for_that_push_and_the_others_still_refuse(self):
        self.write(f"{KIT}/Added.swift", CASES["singleton"][0])
        self.commit("adds a singleton")

        def broken(changes, moved):
            raise RuntimeError("boom")

        for failing in ("app-size", "singleton"):
            with self.subTest(failing=failing):
                rules = tuple(dataclasses.replace(r, find=broken) if r.id == failing else r for r in guardrails.RULES)
                with mock.patch.object(guardrails, "RULES", rules):
                    refusals, warnings = self.check()
                self.assertEqual([r.id for r, _ in refusals], [] if failing == "singleton" else ["singleton"])
                failed = [text for kind, text in warnings if kind == "guardrails"]
                self.assertEqual(len(failed), 1, warnings)
                self.assertIn(f"rule {failing} failed (RuntimeError: boom at test_cmux_next_guardrails.py:", failed[0])
        with mock.patch.object(guardrails, "perf_hot_warnings", broken):
            refusals, warnings = self.check()
        self.assertEqual([r.id for r, _ in refusals], ["singleton"])
        self.assertIn("perf-hot failed (RuntimeError: boom", " ".join(text for _, text in warnings))

    def test_a_rule_that_raises_only_on_the_pushed_range_of_a_merge_is_warned_once(self):
        # A branch that merged feat-cmux-next in: check_push checks the pushed range and the branch's own range.
        self.git("checkout", "--quiet", "-b", "topic")
        self.write(f"{KIT}/Topic.swift", "struct Topic {}\n")
        self.commit("topic work")
        pushed = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{APP}/Landed.swift", "struct Landed {}\n")
        self.commit("landed on feat-cmux-next")
        self.git("checkout", "--quiet", "topic")
        self.git("merge", "--quiet", "--no-edit", "feat-cmux-next")
        self.write(f"{KIT}/Own.swift", "final class Own {\n    static let shared = Own()\n}\n")
        self.commit("the branch's own singleton")
        original = next(r for r in guardrails.RULES if r.id == "app-size")

        def only_pushed(changes, moved):  # Landed.swift is only in the pushed range, never in the branch's own
            if any(c.path.endswith("/Landed.swift") for c in changes):
                raise RuntimeError("boom")
            return original.find(changes, moved)

        def always(changes, moved):
            raise RuntimeError("boom")

        for name, find in (("pushed range only", only_pushed), ("both ranges", always)):
            with self.subTest(failing=name):
                rules = tuple(dataclasses.replace(r, find=find) if r.id == "app-size" else r for r in guardrails.RULES)
                with mock.patch.object(guardrails, "RULES", rules):
                    _, branch_warnings = self.check(guardrails.check, "feat-cmux-next", "HEAD")
                    refusals, warnings = self.check(guardrails.check_push, pushed, "HEAD", "feat-cmux-next")
                if find is only_pushed:
                    self.assertEqual([t for k, t in branch_warnings if k == "guardrails"], [],
                                     "control: the rule runs on the branch's own range")
                self.assertEqual([(r.id, [h.path.rsplit("/", 1)[-1] for h in hits]) for r, hits in refusals],
                                 [("singleton", ["Own.swift"])])
                failed = [text for kind, text in warnings if kind == "guardrails"]
                self.assertEqual(len(failed), 1, warnings)
                self.assertIn("rule app-size failed (RuntimeError: boom at test_cmux_next_guardrails.py:", failed[0])

    def test_skip_reason_skips_only_the_named_rules(self):
        self.write(f"{KIT}/Added.swift", CASES["singleton"][0] + CASES["main-async"][0])
        self.commit("adds a singleton and a main hop")
        refusals, _ = self.check()
        self.assertEqual(sorted(r.id for r, _ in refusals), ["main-async", "singleton"])
        text, refused = self.report("singleton: a fixture", refusals)
        self.assertTrue(refused, text)
        self.assertIn("[main-async]", text)
        self.assertIn("SKIPPED", text)
        text, refused = self.report("singleton, main-async: a fixture", refusals)
        self.assertFalse(refused, text)
        for bad, error in (("singletons: typo", "names no rule singletons"), ("singleton", "must be"),
                           ("singleton:   ", "must be")):
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
        refusals, _ = self.check(*args)
        return [hit for rule, found in refusals if rule.id == "app-size" for hit in found]

    def assertRefused(self, *needles, args=()):
        found = self.hits(*args)
        self.assertTrue(found, "expected an app-size refusal")
        text = "\n".join(f"{h.path}:{h.number}: {h.text}" for h in found)
        for needle in needles:
            self.assertIn(needle, text)
        return found

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
        texts = {f"{KIT}/Chords.swift": self.WRAPPED.split("\n"),
                 f"{KIT}/Router.swift": HOT.replace("        count = 0\n", "        count = 0 // perf-hot: 2ms key-dispatch\n").split("\n")}
        coverage = {pid: files for pid, _, files in health.perf_hot_coverage(self.repo, texts)}
        self.assertEqual(coverage["key-dispatch"], ["CmuxNextKit/Chords.swift", "CmuxNextKit/Router.swift"],
                         "Router.swift's marked dispatch() counts; its statement marker does not add a second entry")
        texts[f"{KIT}/Router.swift"] = HOT.replace(" // perf-hot: 2ms key-dispatch", "").replace(
            "        count = 0\n", "        count = 0 // perf-hot: 2ms key-dispatch\n").split("\n")
        coverage = {pid: files for pid, _, files in health.perf_hot_coverage(self.repo, texts)}
        self.assertEqual(coverage["key-dispatch"], ["CmuxNextKit/Chords.swift"], "a marker on a statement marks nothing")

    def test_touching_an_owned_area_names_the_owner_and_doc(self):
        self.write(f"{KIT}/Sidebar/Row.swift", "struct R {}\n")
        self.commit("sidebar row")
        refusals, warnings = self.check()
        self.assertEqual(refusals, [])
        owners = [w for kind, w in warnings if kind == "owner"]
        self.assertEqual(len(owners), 1, warnings)
        self.assertIn("a590", owners[0])
        self.assertIn("plans/cmux-next/sidebar-owner.md", owners[0])

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

    # A value constant (passes) and an escaped singleton (passes): both need the file's text to be judged.
    TEXT = ("struct Style {\n    static let standard = Style()\n}\n"
            "final class Hub {\n    // singleton-allow: the process has one memory-pressure source\n"
            "    static let shared = Hub()\n}\n")

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
        self.commit("a value constant and an escaped singleton")
        self.assertEqual(self.refused(), [])

    def test_a_failed_blob_read_stops_the_check_and_the_hook_fails_open(self):
        self.fake_git("    echo 'fake git: cat-file failed' >&2; exit 1")
        self.write(f"{KIT}/Added.swift", self.TEXT)
        self.commit("a value constant and an escaped singleton")
        with self.assertRaises(Exception):
            self.check()
        spec = importlib.util.spec_from_file_location("cmux_next_prepush_gate", SOURCE / "scripts/cmux-next/prepush-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(io.StringIO()) as stdout:
                refused = gate.guardrails(self.repo, [(self.base, "HEAD")], SOURCE / "scripts/cmux-next")
        finally:
            os.environ.update(saved)
            sys.modules[_spec.name] = guardrails
        self.assertFalse(refused, stdout.getvalue())
        self.assertIn("guardrails.py failed", stderr.getvalue())
        self.assertNotIn("[singleton]", stdout.getvalue())


class HookTests(Fixture):
    """The installed pre-push hook runs the guardrails; CI (GITHUB_ACTIONS, --commits) never does."""

    def setUp(self):
        super().setUp()
        tracked = subprocess.run(["git", "-C", str(SOURCE), "ls-files", "--cached", "--others", "--exclude-standard",
                                  "scripts/cmux-next"], text=True, capture_output=True, check=True).stdout.split()
        checks = [p for p in tracked if "/" not in p[len("scripts/cmux-next/"):] or p.startswith("scripts/cmux-next/lint/")]
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
        installed = subprocess.run(["bash", "scripts/install-git-hooks.sh"], cwd=self.repo, env=self.env, text=True,
                                   capture_output=True)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.write(f"{KIT}/Added.swift", "final class Cache {\n    static let shared = Cache()\n}\n")
        self.commit("adds a singleton")

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
        # The singleton commit lands on feat-cmux-next past the guardrails (a skip reason, a clone without hooks).
        self.git("push", "--quiet", "--no-verify", "origin", "feat-cmux-next")
        self.git("fetch", "--quiet", "origin")
        self.git("merge", "--quiet", "--no-edit", "--no-verify", "origin/feat-cmux-next")
        merged = self.push("topic", **other)
        output = merged.stdout + merged.stderr
        self.assertEqual(merged.returncode, 0, output)
        self.assertNotIn("[singleton]", output)
        self.git("reset", "--quiet", "--hard", before)
        self.git("rebase", "--quiet", "origin/feat-cmux-next")
        rebased = self.push("--force", "topic", **other)
        output = rebased.stdout + rebased.stderr
        self.assertEqual(rebased.returncode, 0, output)
        self.assertNotIn("[singleton]", output)
        self.write(f"{KIT}/Own.swift", "final class Own {\n    static let shared = Own()\n}\n")
        self.commit("the branch's own singleton")
        own = self.push("topic", **other)
        output = own.stdout + own.stderr
        self.assertNotEqual(own.returncode, 0, output)
        self.assertIn("Own.swift", output)
        self.assertNotIn("Added.swift", output)

    def test_hook_refuses_a_new_singleton_even_with_the_checks_skip_reason(self):
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks")
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("[singleton]", output)
        self.assertIn("Added.swift", output)
        self.assertNotIn("Old.swift", output, "base debt must not be reported")

    def test_hook_lets_the_push_through_with_the_guardrails_skip_reason(self):
        result = self.push(CMUX_NEXT_CHECKS_SKIP_REASON="fixture: other checks",
                           CMUX_GUARDRAILS_SKIP_REASON="singleton: fixture")
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("SKIPPED by CMUX_GUARDRAILS_SKIP_REASON", output)

    def test_hook_refuses_app_growth_and_its_skip_reason_lets_it_through(self):
        self.git("reset", "--quiet", "--hard", "HEAD~1")  # without setUp's singleton
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
        self.assertEqual(skipped.returncode, 0, output)
        self.assertIn("SKIPPED by CMUX_GUARDRAILS_SKIP_REASON", output)

    def test_a_broken_guardrails_script_warns_and_lets_the_push_through(self):
        installed = self.repo / ".git" / "cmux-git-hooks" / "cmux-next-checks"
        self.assertTrue(installed.is_symlink(), "the installer swaps a link, so the checks are never missing")
        (installed / "guardrails.py").write_text("def check(repo, base, head):\n    raise ValueError('boom')\n")
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
        self.assertTrue((before / "guardrails.py").is_file(), "the replaced copy stays for a push already running")

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
        self.assertIn("[singleton]", local.stdout + local.stderr, "a local run applies them (control)")
        for args, env in (([], {"GITHUB_ACTIONS": "true"}), (["--commits", f"{self.base}..HEAD"], {})):
            with self.subTest(args=args, env=env):
                result = subprocess.run([sys.executable, "-I", str(gate), "--base", self.base, "--head", "HEAD", *args]
                                        if not args else [sys.executable, "-I", str(gate), *args],
                                        cwd=self.repo, env={**self.env, **env}, text=True, capture_output=True)
                self.assertNotIn("guardrails", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
