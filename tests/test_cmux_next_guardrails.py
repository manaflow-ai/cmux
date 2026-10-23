#!/usr/bin/env python3
"""cmux-next guardrails (scripts/cmux-next/guardrails.py): refuse new debt, warn on hot paths and owners.

Each test commits into a throwaway repository and checks what the commit adds. The rule tests call
`guardrails.check` directly; the hook tests install the real hooks and push through the real `git push`,
so the installed trusted copy of the gate is what runs. Not on CI (Lawrence 2026-10-23: "not to add
gates/tests in CI, but you have to run them yourself"): run it yourself after every change to guardrails.py,
prepush-gate.py's guardrails path or install-git-hooks.sh: python3 tests/test_cmux_next_guardrails.py
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import git_fixture_env  # disables git auto maintenance

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
    "assume-isolated": ("func f() {\n    MainActor.assumeIsolated { print(1) }\n}\n",
                        "func f() {\n    MainActor.assumeIsolated { print(1) } // main-proof: observer on queue: .main\n}\n"),
    "deinit-main-only": ("final class Feed {\n    var task: Task<Void, Never>?\n    nonisolated deinit {\n"
                         "        guard Thread.isMainThread else { return } // main-proof: returns off the main thread\n"
                         "        MainActor.assumeIsolated { task?.cancel() } // main-proof: guarded above\n    }\n}\n",
                         "final class Feed {\n    var task: Task<Void, Never>?\n    nonisolated deinit {\n"
                         "        task?.cancel()\n    }\n    func f() {\n"
                         "        guard Thread.isMainThread else { return }\n    }\n}\n"),
    "unchecked-sendable": ("final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
                           "// crash-allow: x is written once in init, then only read\n"
                           "final class Box: @unchecked Sendable {\n    let x = 0\n}\n"),
    "sleep-poll": ("func wait() async throws {\n    while !ready() {\n        try await Task.sleep(for: .milliseconds(5))\n    }\n}\n",
                   "func wait() async throws {\n    try await Task.sleep(for: .seconds(2)) // a minimum display time\n}\n"),
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

    def check(self, function=None, *args):
        saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
        try:
            return (function or guardrails.check)(self.repo, *(args or (self.base, "HEAD")))
        finally:
            os.environ.update(saved)

    def refused(self, *args):
        return [(r.id, [f"{h.path.rsplit('/', 1)[-1]}: {h.text.strip()}" for h in hits]) for r, hits in self.check(*args)[0]]

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

    def test_every_main_thread_test_in_a_deinit_is_refused(self):
        for check in ("if !Thread.isMainThread { return }",
                      "if Thread.isMainThread { MainActor.assumeIsolated { task?.cancel() } } // main-proof: guarded",
                      "guard Thread.current.isMainThread else { return }",
                      "guard pthread_main_np() != 0 else { return }"):
            with self.subTest(check=check):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", "final class Feed {\n    var task: Task<Void, Never>?\n"
                                                 f"    nonisolated deinit {{\n        {check}\n        task?.cancel()\n    }}\n}}\n")
                self.commit("main-thread test in a deinit")
                self.assertIn("deinit-main-only", [r.id for r, _ in self.check()[0]])

    def test_base_debt_and_moved_lines_never_count(self):
        self.git("mv", f"{KIT}/Old.swift", f"{KIT}/Moved.swift")
        self.write(f"{KIT}/Router.swift", HOT.replace("var count = 0", "var count = 1"))
        self.commit("moves the old singleton and edits elsewhere")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def rebase_on(self, files, message="more base debt"):
        for relative, text in files.items():
            self.write(relative, text)
        self.commit(message)
        self.base = self.git("rev-parse", "HEAD").stdout.strip()

    def test_editing_a_line_that_already_has_debt_adds_none(self):
        before = {
            f"{KIT}/Old.swift": "final class Old {\n    static let shared = Old()\n}\n",
            f"{KIT}/Box.swift": "final class Box: @unchecked Sendable {\n    var x = 0\n}\n",
            f"{KIT}/Hop.swift": "func f(_ x: Int) {\n    MainActor.assumeIsolated { self.handle(x) }\n}\n",
            f"{KIT}/Wait.swift": "func wait() async throws {\n    while !ready() {\n"
                                 "        try await Task.sleep(for: .milliseconds(5))\n    }\n}\n",
        }
        self.rebase_on(before)
        after = {
            f"{KIT}/Old.swift": "final class Old {\n    static let shared = Old(limit: 2)\n}\n",
            f"{KIT}/Box.swift": "final class Box: Equatable, @unchecked Sendable {\n    var x = 0\n}\n",
            f"{KIT}/Hop.swift": "func f(_ x: Int) {\n    MainActor.assumeIsolated { self.handle(x + 1) }\n}\n",
            f"{KIT}/Wait.swift": "func wait() async throws {\n    while !ready() {\n"
                                "        try await Task.sleep(for: .milliseconds(50))\n    }\n}\n",
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

    def test_a_one_line_poll_is_refused_and_wakeup_allow_is_its_escape(self):
        poll = "func wait() async throws {\n    while !ready() { try await Task.sleep(for: .milliseconds(5)) }\n}\n"
        self.write(f"{KIT}/Added.swift", poll)
        self.commit("one-line poll")
        self.assertIn("sleep-poll", [r.id for r, _ in self.check()[0]])
        self.git("reset", "--quiet", "--hard", self.base)
        self.write(f"{KIT}/Added.swift", poll.replace("    while", "    // wakeup-allow: the device has no change event\n    while"))
        self.commit("reviewed poll")
        self.assertEqual(self.check()[0], [])

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

    def test_short_notification_names_in_a_name_extension_are_refused(self):
        for decl in ('Self("pagesChanged")', '.init("pagesChanged")'):
            with self.subTest(decl=decl):
                self.git("reset", "--quiet", "--hard", self.base)
                self.write(f"{KIT}/Added.swift", f"extension Notification.Name {{\n    static let pagesChanged = {decl}\n}}\n")
                self.commit("short name")
                self.assertIn("broadcast-name", [r.id for r, _ in self.check()[0]])

    def test_a_removed_one_shot_delay_does_not_pay_for_a_new_poll(self):
        self.rebase_on({f"{KIT}/Wait.swift": "func wait() async throws {\n    try await Task.sleep(for: .seconds(2))\n}\n"})
        self.write(f"{KIT}/Wait.swift", "func wait() async throws {\n    while !ready() {\n"
                                        "        try await Task.sleep(for: .milliseconds(5))\n    }\n}\n")
        self.commit("delay -> poll")
        self.assertEqual(self.refused(), [("sleep-poll", ["Wait.swift: try await Task.sleep(for: .milliseconds(5))"])])

    def test_wrapping_an_old_sleep_in_a_new_loop_is_refused(self):
        delay = "func wait() async throws {\n    try await Task.sleep(for: .seconds(2))\n}\n"
        start = self.base
        for name, wrapped in (
            ("re-indented", "func wait() async throws {\n    while !ready() {\n        try await Task.sleep(for: .seconds(2))\n"
                            "    }\n}\n"),
            ("same indent", "func wait() async throws {\n    while !ready() {\n    try await Task.sleep(for: .seconds(2))\n"
                            "    }\n}\n"),
        ):
            with self.subTest(name):
                self.git("reset", "--quiet", "--hard", start)
                self.rebase_on({f"{KIT}/Wait.swift": delay})
                self.write(f"{KIT}/Wait.swift", wrapped)
                self.commit("wraps the delay in a loop")
                self.assertEqual([rule for rule, _ in self.refused()], ["sleep-poll"])

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
        poll = "func wait() async throws {\n    while !ready() {\n        try await Task.sleep(for: .milliseconds(5))\n    }\n}\n"
        self.rebase_on({f"{KIT}/Wait.swift": poll})
        self.write(f"{KIT}/Old.swift", "final class Old: Sendable {\n    static let shared = Old()\n}\n")
        self.write(f"{KIT}/Wait.swift", poll.replace("!ready()", "!isReady()"))
        self.commit("edits the class and loop lines around old debt")
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

    def test_big_new_app_file_is_refused_and_app_growth_warns(self):
        self.write(f"{APP}/Feature.swift", "import Foundation\n" + "let x = 1\n" * 450)
        self.commit("big new App file")
        refusals, warnings = self.check()
        self.assertIn("app-big-file", [r.id for r, _ in refusals])
        self.assertTrue(any(kind == "app-grow" for kind, _ in warnings))

    def test_app_file_limit_matches_wc_l_and_a_renamed_app_file_passes(self):
        def body(lines):
            return "".join(f"let value{n} = {n}\n" for n in range(lines))

        self.write(f"{APP}/Exact.swift", body(400))
        self.commit("a new App file of exactly 400 lines")
        self.assertEqual(self.check()[0], [], "check-no-godfiles.sh accepts 400 lines")
        self.write(f"{APP}/Exact.swift", body(401))
        self.commit("401 lines")
        self.assertIn("app-big-file", [r.id for r, _ in self.check()[0]])

        self.git("reset", "--quiet", "--hard", self.base)
        self.rebase_on({f"{APP}/Feature.swift": body(450)}, "an existing big App file")
        (self.repo / APP / "Features").mkdir()  # git before 2.54 does not create the folder for a git mv
        self.git("mv", f"{APP}/Feature.swift", f"{APP}/Features/Feature.swift")
        self.commit("moves it into a folder")
        self.assertEqual(self.check()[0], [], "a git mv adds no new App code")

    def test_app_growth_counts_only_swift(self):
        self.write(f"{APP}/Resources/Localizable.xcstrings", "{\n" + '  "k": "v",\n' * 50 + "}\n")
        self.commit("strings only")
        _, warnings = self.check()
        self.assertEqual([w for kind, w in warnings if kind == "app-grow"], [])

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

        # A stand-in for the module guardrails.py imported, so subprocess's own internals are not counted.
        guardrails.subprocess = types.SimpleNamespace(run=run, Popen=popen, PIPE=subprocess.PIPE,
                                                      DEVNULL=subprocess.DEVNULL)
        try:
            refusals, _ = self.check()
        finally:
            guardrails.subprocess = subprocess
        self.assertEqual(refusals, [])
        self.assertEqual(len(calls), 3, calls)


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
