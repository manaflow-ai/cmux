#!/usr/bin/env python3
"""The pre-push arch ratchet (scripts/cmux-next/arch-ratchet.py, arch_counts.py) on throwaway git repos.

Each test commits a base and a head into a temporary repository and asks the ratchet about base..head:
a new stateful singleton under any name, a static Mutex or var, a new Notification.Name, an
assumeIsolated in a deinit and a new hard layer edge are refused; a value `static let standard`, a
singleton moved to another package and an adapter with `main-proof:` pass. The delta method must give
the same numbers as two full counts, and the hook must stay under 1 s on a 30-file push.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_arch_ratchet.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SRC = "Packages/macOS/CmuxNext/Sources"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


counts = load("cmux_next_arch_counts", SCRIPTS / "arch_counts.py")
ratchet = load("cmux_next_arch_ratchet_under_test", SCRIPTS / "arch-ratchet.py")

STATEFUL = "public final class Store {\n    private var items: [String] = []\n    public init() {}\n}\n"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription
// CmuxNextDomain -> CmuxNextUI would be a hard edge (a comment never counts).
let shared: [Target.Dependency] = ["CmuxNextCore"]
let ffi: Target = .binaryTarget(name: "CFFI", path: "x.xcframework")
let package = Package(
    name: "CmuxNext",
    targets: [
        .target(name: "CmuxNextCore"),
        .target(
            name: "CmuxNextDomain",
            dependencies: shared + [.target(name: "CFFI"), .product(name: "Other", package: "Other")%s]
        ),
        .target(name: "CmuxNextUI", dependencies: ["CmuxNextDomain"]),
        .testTarget(name: "CmuxNextDomainTests", dependencies: ["CmuxNextUI"]),
    ] + [ffi]
)
"""
LAYERS = {"order": ["core", "service", "domain", "ui", "app"],
          "targets": {"CmuxNextCore": {"layer": "core"}, "CmuxNextDomain": {"layer": "domain"},
                      "CmuxNextUI": {"layer": "ui"}, "CFFI": {"layer": "core"}}}


class Repo(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cmux-arch-ratchet-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.repo = root / "repo"
        self.repo.mkdir()
        config = root / "gitconfig"
        config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                          "[gc]\n\tauto = 0\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        self.saved = {k: os.environ.get(k) for k in ("GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL", "HOME",
                                                     ratchet.SKIP_ENV, "GITHUB_ACTIONS")}
        os.environ.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        for key in (ratchet.SKIP_ENV, "GITHUB_ACTIONS"):
            os.environ.pop(key, None)
        self.addCleanup(self.restore_env)
        self.git("init", "--quiet", "--initial-branch=feat-cmux-next")
        self.write("README", "fixture\n")
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", STATEFUL)
        self.write(f"{SRC}/CmuxNextDomain/Style.swift", "public struct Style {\n    public let size = 12\n}\n")
        self.base = self.commit("base")

    def restore_env(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, text=True, capture_output=True,
                              check=True).stdout.strip()

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def remove(self, relative):
        (self.repo / relative).unlink()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "--quiet", "--allow-empty", "--no-verify", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, base=None, head="HEAD", rules=()):
        return ratchet.check_range(self.repo, base or self.base, head, list(rules))

    def rows(self, refusals):
        return sorted(row for row, _ in refusals)

    def run_push(self, base=None, head="HEAD"):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            refused = ratchet.run_push(self.repo, [(base or self.base, self.git("rev-parse", head))])
        return refused, out.getvalue()

    def assert_matches_full(self, base, head):
        """The delta method equals two full counts subtracted, per row and per package."""
        delta = counts.delta_count(self.repo, base, head)
        _, before, _ = counts.full_count(self.repo, base)
        _, after, _ = counts.full_count(self.repo, head)
        for row in counts.ROW_IDS:
            full = {k: after.rows[row][k] - before.rows[row][k] for k in set(after.rows[row]) | set(before.rows[row])}
            self.assertEqual({k: v for k, v in full.items() if v}, delta.by_package(row), row)


class SingletonTests(Repo):
    def test_a_new_shared_instance_of_a_stateful_class_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift",
                   "extension Store {\n    public static let shared = Store()\n}\n")
        self.commit("adds a singleton")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        text = refusals[0][1]
        self.assertIn(f"{SRC}/CmuxNextDomain/Store+Shared.swift:2", text)
        self.assertIn("composition root", text)
        self.assertIn(f'{ratchet.SKIP_ENV}="stateful_singletons: <why>"', text)

    def test_a_renamed_singleton_is_refused_too(self):
        for name, init in (("app", "Store()"), ("current", "Self()"), ("live", "Store.init()")):
            with self.subTest(name=name):
                self.write(f"{SRC}/CmuxNextDomain/Store+App.swift",
                           f"extension Store {{\n    static let {name} = {init}\n}}\n")
                head = self.commit(f"adds Store.{name}")
                refusals, _ = self.check(head=head)
                self.assertEqual(self.rows(refusals), ["stateful_singletons"], name)

    def test_an_annotated_os_singleton_and_an_actor_are_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Prefs.swift",
                   "enum Prefs {\n    static let defaults: UserDefaults = .standard\n"
                   "    static let files = FileManager.default\n}\n"
                   "actor Ledger {\n    static let main = Ledger()\n}\n")
        self.commit("OS singletons and an actor")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        self.assertIn("+3", refusals[0][1])

    def test_a_static_mutex_and_a_static_var_are_refused_as_global_state(self):
        self.write(f"{SRC}/CmuxNextDomain/Counters.swift",
                   "enum Counters {\n    static let lock = Mutex<[String: Int]>([:])\n"
                   "    nonisolated(unsafe) static var hits = 0\n    static var last: String?\n}\n")
        self.commit("global state")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["global_mutable_statics"])
        self.assertIn("+3", refusals[0][1])
        self.assertIn("Counters.swift:3: nonisolated(unsafe) static var hits = 0", refusals[0][1])

    def test_an_attribute_on_the_line_above_names_the_static_line(self):
        self.write(f"{SRC}/CmuxNextDomain/Late.swift", "enum Late {\n    @MainActor\n    static var pending: [Int] = []\n}\n")
        self.commit("attribute above")
        refusals, _ = self.check()
        self.assertIn("Late.swift:3: static var pending: [Int] = []", refusals[0][1])

    def test_a_value_standard_constant_task_local_and_association_key_pass(self):
        self.write(f"{SRC}/CmuxNextDomain/Style+Standard.swift",
                   "extension Style {\n    public static let standard = Style()\n    static let shared = Style()\n"
                   "    static let empty: [String] = []\n    @TaskLocal static var trace: String?\n"
                   "    private static var blurKey: UInt8 = 0\n    static var computed: Int { 3 }\n}\n")
        self.commit("values")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def test_a_singleton_moved_to_another_package_passes(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        base = self.commit("existing debt")
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.write(f"{SRC}/CmuxNextOther/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        self.commit("moved")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        delta = counts.delta_count(self.repo, base, "HEAD")
        self.assertEqual(delta.by_package("stateful_singletons"), {"CmuxNextDomain": -1, "CmuxNextOther": 1})
        self.assert_matches_full(base, "HEAD")

    def test_a_class_that_gains_a_stored_var_makes_an_unchanged_static_count(self):
        self.write(f"{SRC}/CmuxNextDomain/Plain.swift", "final class Plain {\n    let id = 1\n}\n")
        self.write(f"{SRC}/CmuxNextOther/Plain+Shared.swift", "extension Plain {\n    static let shared = Plain()\n}\n")
        base = self.commit("a stateless class and its shared instance")
        self.write(f"{SRC}/CmuxNextDomain/Plain.swift", "final class Plain {\n    var id = 1\n}\n")
        self.commit("it gains state")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        self.assertIn("CmuxNextOther", refusals[0][1])
        self.assert_matches_full(base, "HEAD")

    def test_composition_root_files_are_not_counted(self):
        self.write(f"{SRC}/CmuxNextApp/AppServices+Store.swift", "extension AppServices {\n    static let store = Store()\n}\n")
        self.commit("root")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def test_uncommitted_edits_in_the_worktree_do_not_change_the_answer(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let app = Store()\n}\n")
        self.commit("adds a singleton")
        self.write(f"{SRC}/CmuxNextDomain/Store.swift", "public final class Store {\n}\n")  # dirty, not pushed
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])


class SignalTests(Repo):
    def test_a_new_notification_name_is_refused_and_a_system_one_passes(self):
        self.write(f"{SRC}/CmuxNextDomain/Names.swift",
                   "extension Notification.Name {\n    static let pagesChanged = Notification.Name(\"pagesChanged\")\n"
                   "    static let trust = Notification.Name(\"com.apple.accessibility.api\")\n"
                   "    static let viaInit = Self.init(rawValue: \"x\")\n}\n")
        self.commit("names")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["app_broadcast_names"])
        self.assertIn("+2", refusals[0][1])
        self.assertIn("tell the subscriber directly", refusals[0][1])

    def test_a_new_observer_site_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Watch.swift",
                   "final class Watch {\n    func start() {\n        _ = NotificationCenter.default.addObserver(\n"
                   "            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { _ in }\n    }\n}\n")
        self.commit("observer")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["observer_sites"])

    def test_assume_isolated_in_a_deinit_is_refused_even_with_main_proof(self):
        self.write(f"{SRC}/CmuxNextDomain/Holder.swift",
                   "final class Holder {\n    deinit {\n        // main-proof: released on main\n"
                   "        MainActor.assumeIsolated { print(1) }\n    }\n}\n")
        self.commit("deinit")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["assume_isolated_outside_adapters"])
        self.assertIn("Holder.swift:4", refusals[0][1])

    def test_assume_isolated_in_a_queue_main_block_or_without_proof_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Observe.swift",
                   "final class Observe {\n    func start() {\n"
                   "        NotificationCenter.default.addObserver(forName: .x, object: nil, queue: .main) { _ in\n"
                   "            MainActor.assumeIsolated { print(1) } // main-proof: queue main\n        }\n"
                   "    }\n\n    func later() {\n        MainActor.assumeIsolated { print(2) }\n    }\n}\n")
        self.commit("observer block")
        refusals, _ = self.check()
        self.assertIn("assume_isolated_outside_adapters", self.rows(refusals))
        self.assertIn("+2", dict(refusals)["assume_isolated_outside_adapters"])

    def test_a_small_adapter_with_main_proof_passes(self):
        self.write(f"{SRC}/CmuxNextDomain/RunLoopAdapter.swift",
                   "final class RunLoopAdapter {\n    func fire() {\n"
                   "        // main-proof: the observer is added to the main run loop\n"
                   "        MainActor.assumeIsolated { print(1) }\n    }\n}\n")
        self.commit("adapter")
        refusals, notes = self.check()
        self.assertEqual(refusals, [])
        self.assertTrue(any("assume_isolated_total +1" in n for n in notes), notes)


class LayerTests(Repo):
    def setUp(self):
        super().setUp()
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST % "")
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(LAYERS))
        self.base = self.commit("manifest")

    def test_the_static_manifest_parse_reads_targets_variables_and_dependencies(self):
        graph = counts.parse_manifest(MANIFEST % ', "CmuxNextUI"')
        self.assertEqual(graph, {"CmuxNextCore": [], "CmuxNextDomain": ["CmuxNextCore", "CFFI", "CmuxNextUI"],
                                 "CmuxNextUI": ["CmuxNextDomain"], "CFFI": []})

    def test_a_new_hard_edge_and_an_unplaced_target_are_refused(self):
        self.write("Packages/macOS/CmuxNext/Package.swift",
                   (MANIFEST % ', "CmuxNextUI"').replace('.target(name: "CmuxNextCore"),',
                                                         '.target(name: "CmuxNextCore"),\n        .target(name: "CmuxNextNew"),'))
        self.commit("edge")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["layer_hard", "layer_unplaced"])
        self.assertIn("CmuxNextDomain (domain) -> CmuxNextUI (ui)", dict(refusals)["layer_hard"])
        self.assert_matches_full(self.base, "HEAD")


class RatchetTests(Repo):
    def add_singleton(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        return self.commit("adds a singleton")

    def test_the_skip_reason_lets_only_the_named_row_through(self):
        self.add_singleton()
        os.environ[ratchet.SKIP_ENV] = "stateful_singletons: fixture"
        refused, out = self.run_push()
        self.assertFalse(refused, out)
        self.assertIn("SKIPPED by ARCH_RATCHET_SKIP_REASON", out)
        os.environ[ratchet.SKIP_ENV] = "observer_sites: fixture"
        refused, out = self.run_push()
        self.assertTrue(refused, out)

    def test_a_dated_exception_the_push_adds_lets_the_row_rise(self):
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": []}))
        base = self.commit("record")
        self.add_singleton()
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [
            {"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "fixture"}]}))
        self.commit("exception")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertTrue(any("exception 2026-10-23" in n for n in notes), notes)

    def test_a_drop_prints_the_update_hint_and_passes(self):
        base = self.add_singleton()
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.commit("removes it")
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        self.assertIn(ratchet.UPDATE_HINT, out)

    def test_app_lines_are_report_only(self):
        self.write(f"{SRC}/CmuxNextApp/Big.swift", "let a = 1\n" * 50)
        self.commit("app lines")
        refusals, notes = self.check()
        self.assertEqual(refusals, [])
        self.assertTrue(any("app_lines +50" in n for n in notes), notes)

    def test_rule_modules_load_from_a_directory_and_zero_modules_work(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(ratchet.load_rules(Path(empty)), ([], []))
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "__init__.py").write_text("")
            Path(folder, "app_size.py").write_text(
                "def check(base, head, changes):\n"
                "    return [('app_size', f'refused {len(changes.files)} file(s)')], ['note from rule']\n")
            Path(folder, "broken.py").write_text("raise ValueError('boom')\n")
            rules, warnings = ratchet.load_rules(Path(folder))
            self.assertEqual([r for r, _ in rules], ["app_size"])
            self.assertIn("broken.py did not load", warnings[0])
            self.write("x.txt", "x\n")
            self.commit("a change")
            refusals, notes = self.check(rules=rules)
            self.assertEqual(refusals, [("app_size", "refused 1 file(s)")])
            self.assertIn("note from rule", notes)

    def test_github_actions_never_runs_it_and_an_internal_error_fails_open(self):
        self.add_singleton()
        os.environ["GITHUB_ACTIONS"] = "true"
        refused, out = self.run_push()
        self.assertFalse(refused)
        self.assertEqual(out, "")
        del os.environ["GITHUB_ACTIONS"]
        refused, out = self.run_push(base="0" * 40)
        self.assertFalse(refused)
        self.assertIn("WARNING: the ratchet failed", out)

    def test_prepush_gate_calls_it_on_the_local_path(self):
        target = self.repo / "scripts/cmux-next"
        target.mkdir(parents=True)
        for name in ("arch-ratchet.py", "arch_counts.py"):
            shutil.copyfile(SCRIPTS / name, target / name)
        self.commit("scripts")
        self.add_singleton()
        gate = load("cmux_next_prepush_gate_under_test", SCRIPTS / "prepush-gate.py")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            refused = gate.ArchRatchet(self.repo, [(self.git("rev-parse", "HEAD~1"), self.git("rev-parse", "HEAD"))],
                                       None).finish()
        self.assertTrue(refused, out.getvalue())
        self.assertIn("[stateful_singletons]", out.getvalue())
        (target / "arch-ratchet.py").write_text("raise ValueError('boom')\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            refused = gate.ArchRatchet(self.repo, [(self.git("rev-parse", "HEAD~1"), self.git("rev-parse", "HEAD"))],
                                       None).finish()
        self.assertFalse(refused, "a broken ratchet lets the push through")
        self.assertIn("arch-ratchet.py failed (ValueError: boom)", out.getvalue())

    def test_a_thirty_file_push_takes_under_a_second(self):
        for i in range(40):
            self.write(f"{SRC}/CmuxNextDomain/Model{i}.swift",
                       f"final class Model{i} {{\n    var value = {i}\n    let style = Style()\n"
                       f"    func run() {{\n        print(value)\n    }}\n}}\n" * 3)
        base = self.commit("forty models")
        for i in range(30):
            self.write(f"{SRC}/CmuxNextDomain/Model{i}.swift",
                       f"final class Model{i} {{\n    var value = {i + 1}\n    let style = Style()\n"
                       f"    static let standard = Style()\n    func run() {{\n        print(value)\n    }}\n}}\n" * 3)
        self.commit("thirty edits")
        best = min(self.timed(base) for _ in range(3))
        self.assertLess(best, 1.0, f"{best:.2f}s")

    def timed(self, base):
        started = time.monotonic()
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        return time.monotonic() - started


class MethodTests(unittest.TestCase):
    def test_strip_blanks_comments_and_strings_and_keeps_offsets(self):
        raw = 'let a = "x \\(f("}")) y" // static let shared = Foo()\n/* { */ let b = #"\\("{"#\n'
        code = counts.strip(raw)
        self.assertEqual(len(code), len(raw))
        self.assertNotIn("shared", code)
        self.assertEqual(code.count("{"), 0)
        self.assertEqual(code.count("\n"), 2)

    def test_init_types(self):
        cases = {"Foo()": "Foo", "Foo<Int>(1)": "Foo", "Mutex<[(a: Int, b: String)]>([])": "Mutex",
                 "NSHashTable<NSView>.weakObjects()": "NSHashTable", "Foo.make()": "Foo", "Self()": "Owner",
                 ".init()": "Owner", "Foo { 1 }": "Foo", "FileManager.default": "FileManager",
                 "Foo.shared": None, "FileManager.default.temporaryDirectory.appending(path: x)": None, "1": None}
        for expr, want in cases.items():
            with self.subTest(expr=expr):
                self.assertEqual(counts._init_type(expr, "Owner"), want)


if __name__ == "__main__":
    unittest.main()
