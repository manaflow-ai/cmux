#!/usr/bin/env python3
"""The pre-push arch ratchet (scripts/cmux-next/arch-ratchet.py, arch_counts.py) on throwaway git repos.

Each test commits a base and a head into a temporary repository and asks the ratchet about base..head:
a new stateful singleton under any name or spelling (a file-scope global, `static weak var`, a closure or
factory initializer, a struct that holds a stateful object, a protocol annotation, a class two links away),
a static Mutex or var, a new Notification.Name, an assumeIsolated in a deinit or under another call's proof,
a KVO or CFNotificationCenter observer and a new hard layer edge are refused; a value `static let standard`,
a singleton moved to another package and an adapter type with `main-proof:` pass, while a proved call in an
extension or a free function does not; a name that looks like an association key does not hide a static;
one-line declarations count; a swap (one singleton or broadcast removed, another added) is refused, also of
two typeless static vars in one package, and a refusal names the static the push added. A push
that raises the json's own totals, deletes it or changes an applied exception is refused, and an edited
pending exception gives no allowance; --update refuses a rise no dated exception covers and names the
commit; the audit names the commits over the record. The delta method must give the same numbers as two
full counts, and the hook must stay under 1 s on a 30-file push and on a warm 80-file cross-package move
(which reads no file twice: the facts cache). The installed-hook path (install-git-hooks.sh
copying arch_rules/, guardrails running the ratchet) is in tests/test_cmux_next_guardrails.py.

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
guardrails = load("cmux_next_guardrails_under_test", SCRIPTS / "guardrails.py")

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
                                                     "GITHUB_ACTIONS")}
        os.environ.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=str(root))
        os.environ.pop("GITHUB_ACTIONS", None)
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

    def update(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = ratchet.update(self.repo)
        return code, out.getvalue()

    def recorded(self):
        return json.loads((self.repo / counts.RATCHET_JSON).read_text())

    def refused_rows(self, files, message="head"):
        """Write FILES on top of the base, commit, and return the refused rows (delta == full checked too)."""
        for relative, text in files.items():
            self.write(relative, text)
        head = self.commit(message)
        refusals, _ = self.check(head=head)
        self.assert_matches_full(self.base, head)
        return self.rows(refusals), refusals

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
        self.assertIn('"row": "stateful_singletons", "allow": 1', text, "the one escape: a dated json exception")
        self.assertNotIn("SKIP_REASON", text)

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
                   "    private static var blurKey: UInt8 = 0\n    static var computed: Int { 3 }\n"
                   "    func blur(_ o: AnyObject) {\n"
                   "        objc_setAssociatedObject(o, &Self.blurKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)\n"
                   "    }\n}\n")
        self.commit("values")
        refusals, _ = self.check()
        self.assertEqual(refusals, [])

    def test_an_association_key_name_does_not_hide_a_static(self):
        rows, refusals = self.refused_rows({f"{SRC}/CmuxNextDomain/Keys.swift":
                                            "final class Holder {\n    var items: [Int] = []\n}\n"
                                            "enum Keys {\n    nonisolated(unsafe) static var cacheAssocKey: [String: Int] = [:]\n"
                                            "    static let associatedKeyStore = Holder()\n"
                                            "    private static var unusedKey: UInt8 = 0\n}\n"})
        self.assertEqual(rows, ["global_mutable_statics", "stateful_singletons"])
        self.assertIn("+2", dict(refusals)["global_mutable_statics"], "a key no association call uses is a var")

    def test_a_key_used_as_an_association_key_of_another_type_counts(self):
        rows, _ = self.refused_rows({f"{SRC}/CmuxNextDomain/Cache.swift":
                                     "enum Cache {\n    nonisolated(unsafe) static var table: [String: Int] = [:]\n"
                                     "    static func tag(_ o: AnyObject) {\n"
                                     "        objc_setAssociatedObject(o, &table, nil, .OBJC_ASSOCIATION_RETAIN)\n"
                                     "    }\n}\n"})
        self.assertEqual(rows, ["global_mutable_statics"], "only a key-typed static is an association key")

    def test_one_line_type_bodies_are_read(self):
        rows, refusals = self.refused_rows({
            f"{SRC}/CmuxNextDomain/OneLine.swift":
                "enum ZZA { static let shared = URLSession(configuration: .default) }\n"
                "enum ZZB { static var counter = 0 }\n"
                "struct ZZC { static var counter = 0; let a = 1 }\n"
                "let first = Store(); let second = Store()\n"
                "enum ZZD { static var computed: Int { 3 } }\n"})
        self.assertEqual(rows, ["global_mutable_statics", "stateful_singletons"])
        self.assertIn("+3", dict(refusals)["stateful_singletons"])
        self.assertIn("+2", dict(refusals)["global_mutable_statics"])

    def test_queues_tasks_and_streams_are_global_state(self):
        rows, refusals = self.refused_rows({f"{SRC}/CmuxNextDomain/Pipes.swift":
                                            "enum Pipes {\n    static let queue = DispatchQueue(label: \"x\")\n"
                                            "    static let warmup = Task { await work() }\n"
                                            "    static let events = AsyncStream<Int> { _ in }\n"
                                            "    static let main = DispatchQueue.main\n}\n"})
        self.assertEqual(rows, ["global_mutable_statics"])
        self.assertIn("+3", refusals[0][1], "DispatchQueue.main is the system queue, not new state")

    def test_a_swapped_singleton_is_refused_and_a_renamed_or_retyped_one_passes(self):
        self.write(f"{SRC}/CmuxNextDomain/Cache.swift", "final class Cache {\n    var hits = 0\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        base = self.commit("one singleton")
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let app = Store()\n}\n")
        renamed = self.commit("renamed")
        self.assertEqual(self.check(base=base, head=renamed)[0], [])
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let app = Cache()\n}\n")
        retyped = self.commit("retyped")
        self.assertEqual(self.check(base=renamed, head=retyped)[0], [])
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.write(f"{SRC}/CmuxNextOther/Cache+Shared.swift", "enum Hub {\n    static let cache = Cache()\n}\n")
        swapped = self.commit("swap: the Store singleton goes, a Cache one elsewhere comes")
        refusals, _ = self.check(base=renamed, head=swapped)
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        self.assertIn("swap", refusals[0][1])
        self.assertIn("Cache+Shared.swift:2", refusals[0][1])
        self.assertIn('"allow": 1', refusals[0][1])
        self.assertEqual(counts.delta_count(self.repo, renamed, swapped).total("stateful_singletons"), 0)
        self.assert_matches_full(renamed, swapped)

    def test_a_swap_of_two_shared_singletons_of_different_owners_is_refused(self):
        # Both globals are called `shared`: a bare-name key made them partners and the swap passed.
        self.write(f"{SRC}/CmuxNextDomain/Cache.swift", "final class Cache {\n    var hits = 0\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        base = self.commit("Store.shared")
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.write(f"{SRC}/CmuxNextOther/Hub.swift", "enum Hub {\n    static let shared = Cache()\n}\n")
        swapped = self.commit("swap: Store.shared goes, Hub.shared comes")
        self.assertEqual(counts.delta_count(self.repo, base, swapped).total("stateful_singletons"), 0)
        refusals, _ = self.check(base=base, head=swapped)
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        self.assertIn("Hub.swift:2", refusals[0][1])
        # The same owner and name, retyped and moved to another package, keeps its partner.
        self.git("reset", "--quiet", "--hard", base)
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.write(f"{SRC}/CmuxNextOther/Store+Shared.swift", "extension Store {\n    static let shared = Cache()\n}\n")
        retyped = self.commit("Store.shared moves and is retyped")
        self.assertEqual(self.check(base=base, head=retyped)[0], [])
        self.assert_matches_full(base, swapped)

    def test_a_swap_of_typeless_static_vars_in_one_package_is_refused(self):
        # Replay of ec7ed9d691b's shape: a `((String) -> Void)?` hook leaves one type and a hook of the same shape
        # comes to another type of the same package. Neither has a type key, so only the owner-qualified names
        # tell them apart; the delta cancel must not drop both sites before the swap rule sees them.
        self.write(f"{SRC}/CmuxNextDomain/KeyEquivalent.swift",
                   "enum KeyEquivalent {\n    nonisolated(unsafe) static var trace: ((String) -> Void)?\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/KeyClaims.swift", "enum KeyClaims {\n    static func claim() {}\n}\n")
        base = self.commit("one typeless hook")
        self.write(f"{SRC}/CmuxNextDomain/KeyEquivalent.swift", "enum KeyEquivalent {\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/KeyClaims.swift",
                   "enum KeyClaims {\n    static func claim() {}\n"
                   "    nonisolated(unsafe) static var hook: ((String) -> Void)?\n}\n")
        swapped = self.commit("swap: KeyEquivalent.trace goes, KeyClaims.hook comes")
        delta = counts.delta_count(self.repo, base, swapped)
        self.assertEqual(delta.total("global_mutable_statics"), 0)
        self.assertEqual([s.text for s in delta.unpartnered("global_mutable_statics")],
                         ["nonisolated(unsafe) static var hook: ((String) -> Void)?"])
        refusals, _ = self.check(base=base, head=swapped)
        self.assertEqual(self.rows(refusals), ["global_mutable_statics"])
        self.assertIn("swap", refusals[0][1])
        self.assertIn("KeyClaims.swift:3: nonisolated(unsafe) static var hook", refusals[0][1])
        self.assert_matches_full(base, swapped)
        # The same static moved to another file of its package keeps its identity and passes.
        self.git("reset", "--quiet", "--hard", base)
        self.remove(f"{SRC}/CmuxNextDomain/KeyEquivalent.swift")
        self.write(f"{SRC}/CmuxNextDomain/KeyEquivalent+Trace.swift",
                   "enum KeyEquivalent {\n    nonisolated(unsafe) static var trace: ((String) -> Void)?\n}\n")
        moved = self.commit("KeyEquivalent.trace moves to another file")
        self.assertEqual(self.check(base=base, head=moved)[0], [])
        self.assert_matches_full(base, moved)

    def test_a_static_moved_to_another_type_counts_as_new_debt_and_a_typed_one_keeps_its_partner(self):
        # Decision (arch_counts "Site identity"): the owner is part of a static's identity. A type rename (or an
        # extraction into a new Coordinator) moves a typeless static to another type: new debt there, which the
        # move fixes or a dated exception carries. A typed singleton still finds its partner by its type.
        self.write(f"{SRC}/CmuxNextDomain/TerminalKeyEquivalent.swift",
                   "enum TerminalKeyEquivalent {\n    nonisolated(unsafe) static var trace: ((String) -> Void)?\n"
                   "    static let shared = Store()\n}\n")
        base = self.commit("a typeless hook and a typed singleton")
        self.git("mv", f"{SRC}/CmuxNextDomain/TerminalKeyEquivalent.swift", f"{SRC}/CmuxNextDomain/KeyEquivalentRouter.swift")
        self.write(f"{SRC}/CmuxNextDomain/KeyEquivalentRouter.swift",
                   "enum KeyEquivalentRouter {\n    nonisolated(unsafe) static var trace: ((String) -> Void)?\n"
                   "    static let shared = Store()\n}\n")
        renamed = self.commit("the owner type is renamed")
        delta = counts.delta_count(self.repo, base, renamed)
        self.assertEqual((delta.total("global_mutable_statics"), delta.total("stateful_singletons")), (0, 0))
        self.assertEqual(delta.unpartnered("stateful_singletons"), [])
        refusals, _ = self.check(base=base, head=renamed)
        self.assertEqual(self.rows(refusals), ["global_mutable_statics"])
        self.assertIn("moved to another type counts as new debt", refusals[0][1])
        self.assertIn("KeyEquivalentRouter.swift:2: nonisolated(unsafe) static var trace", refusals[0][1])
        self.assert_matches_full(base, renamed)

    def test_a_file_scope_global_keeps_its_identity_across_the_files_of_its_package(self):
        # One identity for a file-scope global (arch_counts.static_name: package and name), in the delta cancel
        # and in the swap rule's key: a move to another file of the package is the same global.
        hook = "nonisolated(unsafe) var routeHook: ((String) -> Void)?\n"
        self.write(f"{SRC}/CmuxNextDomain/Route.swift", hook)
        base = self.commit("a typeless file-scope hook")
        self.remove(f"{SRC}/CmuxNextDomain/Route.swift")
        self.write(f"{SRC}/CmuxNextDomain/Routing.swift", "enum Routing {\n}\n" + hook)
        moved = self.commit("the hook moves to another file of its package")
        self.assertEqual(self.check(base=base, head=moved)[0], [])
        _, after, _ = counts.full_count(self.repo, moved)
        self.assertIn("name:CmuxNextDomain:routeHook",
                      [k for site in after.sites["global_mutable_statics"] for k in site.keys])
        self.assert_matches_full(base, moved)

    def test_a_refusal_names_the_static_the_push_added_not_an_unchanged_one(self):
        # Replay of 16332dd2ced's shape: a file with one typeless `static var` gains a second of the same shape
        # below it. The refusal names the new line, not the unchanged one above it.
        self.write(f"{SRC}/CmuxNextDomain/KeyEquivalent.swift",
                   "enum KeyEquivalent {\n    nonisolated(unsafe) public static var menuMayClaim: ((String) -> Bool)?\n"
                   "    static func route() {}\n}\n")
        base = self.commit("one typeless hook")
        self.write(f"{SRC}/CmuxNextDomain/KeyEquivalent.swift",
                   "enum KeyEquivalent {\n    nonisolated(unsafe) public static var menuMayClaim: ((String) -> Bool)?\n"
                   "    static func route() {}\n"
                   "    nonisolated(unsafe) public static var sendToProgram: ((String) -> Bool)?\n}\n")
        head = self.commit("a second hook")
        refusals, _ = self.check(base=base, head=head)
        self.assertEqual(self.rows(refusals), ["global_mutable_statics"])
        self.assertIn("+1", refusals[0][1])
        self.assertIn("KeyEquivalent.swift:4: nonisolated(unsafe) public static var sendToProgram", refusals[0][1])
        self.assertNotIn("menuMayClaim", refusals[0][1])
        self.assert_matches_full(base, head)

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

    def test_composition_root_file_names_are_not_exempt(self):
        # The composition root holds instances, not statics: a static moved into AppServices+Foo.swift is still
        # reachable from the whole App target.
        self.write(f"{SRC}/CmuxNextApp/AppServices+Store.swift", "extension AppServices {\n    static let store = Store()\n}\n")
        self.write(f"{SRC}/CmuxNextApp/AppDelegate+Cache.swift", "extension AppDelegate {\n    static var cache: [Int] = []\n}\n")
        self.commit("root")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["global_mutable_statics", "stateful_singletons"])

    def test_a_file_scope_global_counts_like_a_static(self):
        rows, refusals = self.refused_rows({f"{SRC}/CmuxNextDomain/Globals.swift":
                                            "let sharedStore = Store()\nnonisolated(unsafe) var cache: [String: Int] = [:]\n"
                                            "@MainActor private let closeFrame = Store()\nlet limit = 3\n"})
        self.assertEqual(rows, ["global_mutable_statics", "stateful_singletons"])
        self.assertIn("+2", dict(refusals)["stateful_singletons"])
        self.assertIn("Globals.swift:2: nonisolated(unsafe) var cache", dict(refusals)["global_mutable_statics"])

    def test_a_top_level_global_of_a_main_swift_counts_and_its_condition_bindings_do_not(self):
        # The review's case: a top-level `let`/`var` of main.swift is a module global every file of the target
        # sees (main-actor isolated since SE-0343), so a stateful or a mutable one counts. The bindings of a
        # top-level `guard`/`if` condition list continued over lines (`guard let a = x,\n      let b = y else`)
        # are the entry point's locals, not globals: they counted as stateful singletons.
        self.write(f"{SRC}/CmuxNextTool/main.swift",
                   "guard let name = CommandLine.arguments.first,\n      let other = Store() as Store? else { exit(1) }\n"
                   "if let a = Store() as Store?,\n   let b = Store() as Store? { print(a, b) }\n"
                   "let service = Store()\nnonisolated(unsafe) var cache = [String: Int]()\nservice.run()\n")
        self.commit("an executable's main")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["global_mutable_statics", "stateful_singletons"])
        texts = dict(refusals)
        self.assertIn("main.swift:5: let service = Store()", texts["stateful_singletons"])
        self.assertIn(": +1", texts["stateful_singletons"])
        self.assertIn("main.swift:6: nonisolated(unsafe) var cache", texts["global_mutable_statics"])
        self.assert_matches_full(self.base, "HEAD")

    def test_moving_a_static_singleton_to_a_file_scope_global_is_not_a_drop(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        base = self.commit("a singleton")
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "let sharedStore = Store()\n")
        self.commit("the same singleton by another spelling")
        delta = counts.delta_count(self.repo, base, "HEAD")
        self.assertEqual(delta.total("stateful_singletons"), 0)
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        self.assertNotIn(ratchet.UPDATE_HINT, out)
        self.assert_matches_full(base, "HEAD")

    def test_weak_and_unowned_statics_are_counted(self):
        rows, refusals = self.refused_rows({f"{SRC}/CmuxNextDomain/Store+App.swift":
                                            "extension Store {\n    static weak var app: Store?\n"
                                            "    static unowned(unsafe) var owner: Store = Store()\n}\n"})
        self.assertEqual(rows, ["stateful_singletons"])
        self.assertIn("+2", refusals[0][1])

    def test_closure_initializers_are_resolved(self):
        rows, refusals = self.refused_rows({f"{SRC}/CmuxNextDomain/Store+Made.swift":
                                            "extension Store {\n    static let viaLocal = {\n        let s = Store()\n"
                                            "        return s\n    }()\n    static let direct = { Store() }()\n"
                                            "    static let typed = { () -> Store in\n        make()\n    }()\n"
                                            "    static let handler = { (x: Int) in print(x) }\n}\n"})
        self.assertEqual(rows, ["stateful_singletons"])
        self.assertIn("+3", refusals[0][1])

    def test_a_lowercase_factory_resolves_through_its_return_type(self):
        self.write(f"{SRC}/CmuxNextOther/Factory.swift", "func makeStore() -> Store {\n    Store()\n}\n"
                   "func makeStyle() -> Style {\n    Style()\n}\n")
        self.base = self.commit("factories in another file")
        rows, refusals = self.refused_rows({f"{SRC}/CmuxNextDomain/Made.swift":
                                            "enum Made {\n    static let store = makeStore()\n    static let style = makeStyle()\n"
                                            "    static let local = build()\n    static func build() -> Store { Store() }\n}\n"})
        self.assertEqual(rows, ["stateful_singletons"])
        self.assertIn("+2", refusals[0][1])

    def test_a_struct_that_holds_a_stateful_object_is_stateful(self):
        rows, _ = self.refused_rows({f"{SRC}/CmuxNextDomain/Env.swift":
                                     "struct Env {\n    let store = Store()\n    static let live = Env()\n}\n"
                                     "struct Box {\n    let size = 1\n    static let standard = Box()\n}\n"})
        self.assertEqual(rows, ["stateful_singletons"])

    def test_appkit_responders_and_running_foundation_objects_are_stateful(self):
        # deep-guardrails review (a08985b7dac): a named static that holds a reference instance with runtime state is a
        # singleton. A view, view controller or window controller subclass, a menu, a status item, a timer, a
        # process, a thread or a file handle holds that state in its system superclass, so it counts like NSWindow.
        for decl, use in (("final class Picker: NSViewController {}\n", "static let shared = Picker()"),
                          ("final class Badge: NSView {}\n", "static let shared = Badge()"),
                          ("final class Prefs: NSWindowController {}\n", "static let shared = Prefs()"),
                          ("", "static let menu = NSMenu()"),
                          ("", "static let item: NSStatusItem = NSStatusBar.system.statusItem(withLength: 20)"),
                          ("", "static let tick: Timer = Timer(timeInterval: 1, repeats: true) { _ in }"),
                          ("", "static let helper = Process()"),
                          ("", "static let worker = Thread()"),
                          ("", "static let log: FileHandle = .standardError")):
            with self.subTest(use=use):
                self.git("reset", "--quiet", "--hard", self.base)
                rows, _ = self.refused_rows({f"{SRC}/CmuxNextDomain/Ui.swift": decl + f"enum Ui {{\n    {use}\n}}\n"})
                self.assertEqual(rows, ["stateful_singletons"], use)

    def test_a_protocol_annotation_does_not_hide_a_stateful_initializer(self):
        rows, _ = self.refused_rows({f"{SRC}/CmuxNextDomain/Live.swift":
                                     "protocol Storing: AnyObject {}\nextension Store: Storing {}\n"
                                     "enum Live {\n    static let store: any Storing = Store()\n"
                                     "    static let wrapped = Wrapper(store: Store())\n}\n"})
        self.assertEqual(rows, ["stateful_singletons"])

    def test_a_class_two_links_away_is_stateful(self):
        self.write(f"{SRC}/CmuxNextDomain/Chain.swift", "final class Inner {\n    var n = 0\n}\n"
                   "final class Middle {\n    let inner = Inner()\n}\nfinal class Outer {\n    let middle = Middle()\n}\n")
        self.base = self.commit("a chain")
        rows, _ = self.refused_rows({f"{SRC}/CmuxNextOther/Outer+Shared.swift":
                                     "extension Outer {\n    static let shared = Outer()\n}\n"})
        self.assertEqual(rows, ["stateful_singletons"])

    def test_a_flip_two_links_away_recounts_an_unchanged_static(self):
        self.write(f"{SRC}/CmuxNextDomain/Inner.swift", "final class Inner {\n    let n = 0\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/Middle.swift", "final class Middle {\n    let inner = Inner()\n}\n")
        self.write(f"{SRC}/CmuxNextOther/Outer.swift",
                   "final class Outer {\n    let middle = Middle()\n    static let shared = Outer()\n}\n")
        base = self.commit("a stateless chain and a shared instance at its top")
        self.write(f"{SRC}/CmuxNextDomain/Inner.swift", "final class Inner {\n    var n = 0\n}\n")
        self.commit("the bottom gains state")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        self.assertIn("CmuxNextOther", refusals[0][1])
        self.assert_matches_full(base, "HEAD")

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

    def test_a_swapped_notification_name_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Names.swift",
                   "extension Notification.Name {\n    static let a = Notification.Name(\"pagesChanged\")\n}\n")
        base = self.commit("one name")
        self.write(f"{SRC}/CmuxNextDomain/Names.swift",
                   "extension Notification.Name {\n    static let b = Notification.Name(\"pagesChanged\")\n}\n")
        renamed = self.commit("the same broadcast under another constant")
        self.assertEqual(self.check(base=base, head=renamed)[0], [])
        self.write(f"{SRC}/CmuxNextDomain/Names.swift",
                   "extension Notification.Name {\n    static let b = Notification.Name(\"tabsChanged\")\n}\n")
        self.commit("another broadcast in its place")
        refusals, _ = self.check(base=renamed)
        self.assertEqual(self.rows(refusals), ["app_broadcast_names"])

    def test_typed_messages_and_message_observers_are_counted(self):
        self.write(f"{SRC}/CmuxNextDomain/Typed.swift",
                   "struct PagesChanged: NotificationCenter.MainActorMessage {\n    typealias Subject = Store\n}\n"
                   "final class Listen {\n    func start() {\n"
                   "        _ = NotificationCenter.default.messages(of: Store.self, for: PagesChanged.self)\n    }\n}\n")
        self.commit("typed")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["app_broadcast_names", "observer_sites"])

    def test_a_new_observer_site_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Watch.swift",
                   "final class Watch {\n    func start() {\n        _ = NotificationCenter.default.addObserver(\n"
                   "            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { _ in }\n    }\n}\n")
        self.commit("observer")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["observer_sites"])

    OBSERVATION = ("public final class Observation {\n    private let token: any NSObjectProtocol\n"
                   "    public init(_ name: Notification.Name, object: AnyObject? = nil,\n"
                   "                center: NotificationCenter = .default, _ handler: @escaping () -> Void) {\n"
                   "        token = center.addObserver(forName: name, object: object, queue: .main) { _ in handler() }\n"
                   "    }\n}\n")
    # CmuxNextCompat's wrapper shape: an observer by what its init does, never by its name.
    MAO = (f"{SRC}/CmuxNextCompat/MainActorObservation.swift",
           "public final class MainActorObservation {\n    private let token: any NSObjectProtocol\n"
           "    public init(_ name: Notification.Name, object: AnyObject? = nil,\n"
           "                center: NotificationCenter = .default, _ handler: @escaping @MainActor () -> Void) {\n"
           "        token = center.addObserver(forName: name, object: object, queue: .main) { _ in\n"
           "            MainActor.assumeIsolated { handler() }\n        }\n    }\n}\n")
    AO = "NotificationCenter.default.addObserver(forName: {}, object: nil, queue: nil) {{ _ in }}"
    OBS = (f"{SRC}/CmuxNextCompat/Obs.swift",
           "public final class Obs {\n    private let token: any NSObjectProtocol\n"
           "    public init(_ name: Notification.Name) {\n"
           "        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in }\n"
           "    }\n}\n")
    WATCH = f"{SRC}/CmuxNextDomain/Watch.swift"

    def observers(self, rev="HEAD"):
        return counts.full_count(self.repo, rev)[1].totals()["observer_sites"]

    def raw_base(self, names=("n0", "n1", "n2")):
        """A base with one raw registration per name in Watch.swift (and no Obs wrapper); returns its sha."""
        if (self.repo / self.OBS[0]).exists():
            self.remove(self.OBS[0])
        self.write(self.WATCH, "final class Watch {\n    func start() {\n"
                   + "".join(f"        {self.AO.format('.' + n)}\n" for n in names) + "    }\n}\n")
        return self.commit("raw observers")

    def assert_same_count(self, base, head_text, expected, files=()):
        """HEAD_TEXT replaces Watch.swift (and FILES, (path, text) pairs, are added): it registers EXPECTED
        observers (a full count), the delta over BASE is 0, and the push is neither refused nor told to lower
        the record."""
        for path, text in files:
            self.write(path, text)
        self.write(self.WATCH, head_text)
        self.commit("the same observers in another shape")
        self.assertEqual(self.observers(), expected, head_text)
        self.assertEqual(counts.delta_count(self.repo, base, "HEAD").total("observer_sites"), 0, head_text)
        self.assert_matches_full(base, "HEAD")
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        self.assertNotIn(ratchet.UPDATE_HINT, out)

    def test_observers_behind_a_helper_count_once_per_registration(self):
        # The review's case (FeedService.swift's shape): a helper that forwards its name parameter to an observer
        # counts each call, not its own one site, and a wrapper type counts each construction, not its addObserver.
        self.write(f"{SRC}/CmuxNextCompat/Observation.swift", self.OBSERVATION)
        self.write(f"{SRC}/CmuxNextDomain/Presence.swift",
                   "final class Presence {\n    var observers: [Observation] = []\n    func start() {\n"
                   "        func on(_ center: NotificationCenter, _ name: Notification.Name) -> Observation {\n"
                   "            Observation(name, center: center) { print(1) }\n        }\n"
                   "        observers = [\n            on(.default, NSApplication.didBecomeActiveNotification),\n"
                   "            on(.default, NSApplication.didResignActiveNotification),\n"
                   "            on(.default, NSWorkspace.didWakeNotification),\n        ]\n    }\n}\n")
        base = self.commit("three observers behind a local helper and a wrapper type")
        _, full, _ = counts.full_count(self.repo, base)
        self.assertEqual(full.rows["observer_sites"], {"CmuxNextDomain": 3})
        # Six NotificationCenter observers replaced by one module helper and six calls in another file: same count.
        self.write(self.WATCH, "final class Watch {\n    func start() {\n"
                   + "".join(f"        {self.AO.format(f'.n{i}')}\n" for i in range(6)) + "    }\n}\n")
        before = self.commit("six raw observers")
        self.write(self.WATCH, "final class Watch {\n    func start() {\n"
                   + "".join(f"        watch(.n{i})\n" for i in range(6)) + "    }\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/Watching.swift",
                   "func watch(_ name: Notification.Name, center: NotificationCenter = .default) {\n"
                   "    _ = center.addObserver(forName: name, object: nil, queue: nil) { _ in }\n}\n")
        self.commit("behind a helper")
        self.assertEqual(counts.delta_count(self.repo, before, "HEAD").total("observer_sites"), 0)
        self.assert_matches_full(before, "HEAD")
        # A seventh call through the helper, in a file that does not name the helper's file, is a new observer.
        self.write(f"{SRC}/CmuxNextDomain/More.swift", "final class More {\n    func go() {\n        watch(.n7)\n    }\n}\n")
        head = self.commit("one more")
        refusals, _ = self.check(base=self.git("rev-parse", "HEAD~1"), head=head)
        self.assertEqual(self.rows(refusals), ["observer_sites"])
        self.assertIn("More.swift:3: watch(.n7)", refusals[0][1])

    def test_a_named_closure_or_a_captured_parameter_is_a_helper_too(self):
        # A closure bound to a name is the same helper as a func (its own `in` list or `$0`), and a registration
        # that reads a parameter of an outer function makes that function the wrapper.
        self.write(f"{SRC}/CmuxNextCompat/Observation.swift", self.OBSERVATION)
        self.write(f"{SRC}/CmuxNextDomain/Closures.swift",
                   "final class Closures {\n    var keep: [Observation] = []\n    func start() {\n"
                   "        let on = { (name: Notification.Name) in Observation(name) { print(1) } }\n"
                   "        let short: (Notification.Name) -> Observation = { Observation($0) { print(2) } }\n"
                   "        keep = [on(.a), on(.b), short(.c), short(.d), short(.e)]\n    }\n"
                   "    func watch(_ name: Notification.Name) {\n"
                   "        let later = {\n            NotificationCenter.default.addObserver(forName: name, object: nil,"
                   " queue: nil) { _ in }\n        }\n        _ = later\n    }\n"
                   "    func use() {\n        watch(.f)\n        watch(.g)\n    }\n}\n")
        base = self.commit("closure helpers and a captured parameter")
        _, full, _ = counts.full_count(self.repo, base)
        self.assertEqual(full.rows["observer_sites"], {"CmuxNextDomain": 7})

    def test_a_wrapper_used_as_a_value_counts_its_registrations(self):
        # A wrapper used by reference (`forEach(on)`, `map(T.init)`, `let f = on`) or built with `let a: T =
        # .init(...)` counts the registrations each use makes, as the raw calls it replaced did.
        base = self.raw_base()
        self.assert_same_count(base, "final class Watch {\n    func start() {\n"
                               "        [Notification.Name.n0, .n1, .n2].forEach(on)\n    }\n"
                               "    private func on(_ name: Notification.Name) {\n"
                               f"        {self.AO.format('name')}\n    }}\n}}\n", 3)
        helper = "    private func on(_ name: Notification.Name) -> Obs {\n        Obs(name)\n    }\n"
        cases = {"map(T.init)": ("let all = [Notification.Name.n0, .n1, .n2].map(Obs.init)\n        _ = all", ""),
                 ": T = .init(": ("let a: Obs = .init(.n0)\n        let b: Obs = .init(.n1)\n"
                                  "        let c: Obs = .init(.n2)\n        _ = (a, b, c)", ""),
                 "let f = on": ("let f = on\n        _ = f(.n0)\n        _ = on(.n1)\n        _ = on(.n2)", helper)}
        for name, (body, extra) in cases.items():
            with self.subTest(name):
                before = self.raw_base()
                self.assert_same_count(before, "final class Watch {\n    func start() {\n        " + body
                                       + "\n    }\n" + extra + "}\n", 3, [self.OBS])

    def test_a_helper_the_caller_configures_counts_once_per_call(self):
        # A function is a wrapper by what a call of it decides, not by the literal form of the name argument: a
        # caller's handler, a name built from the parameter, `k.name`, a loop over a parameter list.
        heads = {
            "caller's handler": "        onWake {}\n        onWake {}\n        onWake {}\n    }\n"
                                "    private func onWake(_ h: @escaping () -> Void) {\n"
                                "        NotificationCenter.default.addObserver(forName: .n0, object: nil, queue: nil)"
                                " { _ in h() }\n",
            "(name)": "        on(.n0); on(.n1); on(.n2)\n    }\n    private func on(_ name: Notification.Name) {\n"
                      f"        {self.AO.format('(name)')}\n",
            "built from it": "        on(\"a\"); on(\"b\"); on(\"c\")\n    }\n    private func on(_ key: String) {\n"
                             "        let name = names[key] ?? .n0\n"
                             f"        {self.AO.format('name')}\n",
            "k.name": "        on(K()); on(K()); on(K())\n    }\n    private func on(_ k: K) {\n"
                      f"        {self.AO.format('k.name')}\n",
            "loop": "        on([.n0, .n1, .n2])\n    }\n    private func on(_ names: [Notification.Name]) {\n"
                    f"        for n in names {{\n            {self.AO.format('n')}\n        }}\n",
            "forEach $0": "        on([.n0, .n1, .n2])\n    }\n    private func on(_ names: [Notification.Name]) {\n"
                          f"        names.forEach {{ {self.AO.format('$0')} }}\n",
        }
        for name, body in heads.items():
            with self.subTest(name):
                base = self.raw_base()
                self.assert_same_count(base, "final class Watch {\n    func start() {\n" + body + "    }\n}\n", 3)

    def test_a_configured_wrapper_counts_through_any_depth(self):
        # a(n) -> b(n) -> c(n) -> addObserver(forName: n): each call of a registers once, however deep the chain.
        base = self.raw_base()
        self.assert_same_count(base, "final class Watch {\n    func start() {\n        a(.n0); a(.n1); a(.n2)\n    }\n"
                               "    private func a(_ n: Notification.Name) { b(n) }\n"
                               "    private func b(_ n: Notification.Name) { c(n) }\n"
                               "    private func c(_ n: Notification.Name) {\n"
                               f"        {self.AO.format('n')}\n    }}\n}}\n", 3)

    def test_a_fixed_registration_counts_once_at_its_statement_in_every_shape(self):
        # The review's cases: a fixed-name helper with three callers counted 3 as a raw unbranched addObserver, but
        # 1 through MainActorObservation, through `Task { for await _ in notifications(named:) }` or inside an `if`,
        # and 3 again after a `guard`. Nothing a caller supplies decides a fixed registration, so it counts once at
        # its statement in each shape, and a fourth caller adds nothing in any of them.
        shapes = {
            "raw": f"        {self.AO.format('.n0')}\n",
            "MainActorObservation": "        token = MainActorObservation(NSWindow.didChangeOcclusionStateNotification,"
                                    " object: window) {}\n",
            "Task + notifications": "        Task {\n            for await _ in NotificationCenter.default.notifications("
                                    "named: .n0) {}\n        }\n",
            "inside if": f"        if on {{\n            {self.AO.format('.n0')}\n        }}\n",
            "after guard": f"        guard on else {{ return }}\n        {self.AO.format('.n0')}\n",
        }
        # Another file uses the wrapper, as the tree does: a wrapper nothing references counts its own body once.
        self.write(*self.MAO)
        self.write(f"{SRC}/CmuxNextDomain/Other.swift",
                   "final class Other {\n    var token: AnyObject?\n    func go() {\n"
                   "        token = MainActorObservation(.n9) {}\n    }\n}\n")
        for name, body in shapes.items():
            with self.subTest(name):
                for callers in (3, 4):
                    self.write(self.WATCH, "final class Watch {\n    var on = true\n    var token: AnyObject?\n"
                               "    let window = NSWindow()\n    func start() {\n"
                               + "        observe()\n" * callers + "    }\n    func observe() {\n" + body + "    }\n}\n")
                    self.commit(f"{name} with {callers} callers")
                    self.assertEqual(self.observers(), 2, (name, callers))  # Other.swift's and observe()'s
                self.assert_matches_full(self.git("rev-parse", "HEAD~1"), "HEAD")

    def test_extract_inline_and_branch_keep_a_fixed_count(self):
        # The review's cases: moving a fixed registration one level down (a() calls b(), b registers) read 3 -> 1
        # and inlining it back 1 -> 3, wrapping it in a trivial `if` read 3 -> 1. Each is a refactor: delta 0.
        def watch(body: str, extra: str = "") -> str:
            return ("final class W {\n    var on = true\n    func go() {\n        a()\n        a()\n        a()\n    }\n"
                    "    func a() {\n" + body + "    }\n" + extra + "}\n")
        raw = f"        {self.AO.format('.n0')}\n"
        self.write(self.WATCH, watch(raw))
        base = self.commit("a fixed registration in a()")
        self.assertEqual(self.observers(), 1)
        for name, text in {"extract": watch("        b()\n", "    func b() {\n" + raw + "    }\n"),
                           "if": watch(f"        if on {{\n    {raw}        }}\n"),
                           "guard": watch("        guard on else { return }\n" + raw),
                           "inline": watch(raw)}.items():
            with self.subTest(name):
                self.write(self.WATCH, text)
                self.commit(name)
                self.assertEqual(counts.delta_count(self.repo, base, "HEAD").total("observer_sites"), 0, name)
                self.assert_matches_full(base, "HEAD")
                refused, out = self.run_push(base=base)
                self.assertFalse(refused, out)
                self.assertNotIn(ratchet.UPDATE_HINT, out)

    def test_raw_observers_moved_behind_main_actor_observation_keep_their_count(self):
        # e2b6fc74a78's shape: raw addObserver calls replaced by MainActorObservation, no registration removed. A
        # helper whose caller names the notification (`on(.n0)`) counts per call, a fixed one (`occlusion()`, or
        # FrameScheduler.forWindow(window): the caller gives only the `object:`) once: the same before and after.
        # Another file already uses the wrapper (as the tree does), so the wrapper's own body counts at neither end.
        self.write(*self.MAO)
        self.write(f"{SRC}/CmuxNextDomain/Other.swift",
                   "final class Other {\n    var token: AnyObject?\n    func go() {\n"
                   "        token = MainActorObservation(.n9) {}\n    }\n}\n")

        def watch(on: str, occlusion: str, window: str) -> str:
            return ("final class Watch {\n    var tokens: [Any] = []\n    func start(_ a: NSWindow, _ b: NSWindow) {\n"
                    "        on(.n0)\n        on(.n1)\n        occlusion()\n        occlusion()\n"
                    "        forWindow(a)\n        forWindow(b)\n    }\n"
                    f"    func on(_ name: Notification.Name) {{\n        tokens.append({on})\n    }}\n"
                    f"    func occlusion() {{\n        tokens.append({occlusion})\n    }}\n"
                    f"    func forWindow(_ w: NSWindow) {{\n        tokens.append({window})\n    }}\n}}\n")
        raw = "NotificationCenter.default.addObserver(forName: {}, object: {}, queue: .main) {{ _ in }}"
        self.write(self.WATCH, watch(raw.format("name", "nil"), raw.format(".n5", "nil"),
                                     raw.format("NSWindow.didMoveNotification", "w")))
        base = self.commit("raw")
        self.assertEqual(self.observers(), 5)  # on() per call (2), occlusion() once, forWindow() once, Other.swift
        self.write(self.WATCH, watch("MainActorObservation(name) {}", "MainActorObservation(.n5) {}",
                                     "MainActorObservation(NSWindow.didMoveNotification, object: w) {}"))
        self.commit("behind MainActorObservation")
        self.assertEqual(counts.delta_count(self.repo, base, "HEAD").total("observer_sites"), 0)
        self.assert_matches_full(base, "HEAD")
        self.write(self.WATCH, (self.repo / self.WATCH).read_text().replace("on(.n1)\n", "on(.n1)\n        on(.n2)\n"))
        head = self.commit("a third named call")
        refusals, _ = self.check(base=self.git("rev-parse", "HEAD~1"), head=head)
        self.assertEqual(self.rows(refusals), ["observer_sites"])

    def test_a_wrapper_type_that_stores_the_name_from_its_init_counts_per_construction(self):
        # The review's case: _origins followed only parameters, so a type that stores the observed name from its init
        # and registers in a method counted once however many times it is built.
        base = self.raw_base()
        self.assert_same_count(base, "final class Watch {\n    func start() {\n"
                               "        _ = Watcher(name: .n0)\n        _ = Watcher(name: .n1)\n        _ = Watcher(name: .n2)\n"
                               "    }\n}\n", 3,
                               [(f"{SRC}/CmuxNextDomain/Watcher.swift",
                                 "final class Watcher {\n    let name: Notification.Name\n"
                                 "    init(name: Notification.Name) {\n        self.name = name\n    }\n"
                                 "    func start() {\n"
                                 f"        {self.AO.format('name')}\n    }}\n}}\n")])

    def test_a_method_call_resolves_to_its_own_types_method(self):
        # The review's case: matching by bare name counted B's own `observe(Int)` calls as A's wrapper.
        self.write(f"{SRC}/CmuxNextDomain/A.swift",
                   "final class A {\n    func observe(_ name: Notification.Name) {\n"
                   f"        {self.AO.format('name')}\n    }}\n}}\n")
        self.write(f"{SRC}/CmuxNextDomain/B.swift",
                   "final class B {\n    func observe(_ x: Int) {}\n    func go() {\n"
                   "        observe(1); observe(2); observe(3); self.observe(4)\n    }\n}\n")
        base = self.commit("two observe methods")
        _, full, _ = counts.full_count(self.repo, base)
        self.assertEqual(full.rows["observer_sites"], {"CmuxNextDomain": 1})  # A's own, never called
        self.write(f"{SRC}/CmuxNextDomain/B.swift",
                   "final class B {\n    func observe(_ x: Int) {}\n    func go() {\n"
                   "        observe(1); observe(2); observe(3); self.observe(4); observe(5)\n    }\n}\n")
        head = self.commit("one more B.observe call")
        refusals, _ = self.check(base=base, head=head)
        self.assertEqual(refusals, [])
        self.write(f"{SRC}/CmuxNextDomain/C.swift",
                   "final class C {\n    let a = A()\n    func go() {\n        a.observe(.n0)\n        a.observe(.n1)\n"
                   "    }\n}\n")
        self.commit("two calls of A.observe through a typed property")
        delta = counts.delta_count(self.repo, head, "HEAD")
        self.assertEqual(delta.total("observer_sites"), 1)  # 2 calls replace A's uncalled body (1)
        self.assert_matches_full(head, "HEAD")

    def test_a_helper_that_becomes_an_observer_wrapper_counts_its_unchanged_callers(self):
        # The push changes only the helper's file: its callers elsewhere start registering observers.
        self.write(f"{SRC}/CmuxNextDomain/Watching.swift", "func watch(_ name: Notification.Name) {\n    print(name)\n}\n")
        self.write(f"{SRC}/CmuxNextOther/Users.swift",
                   "func users() {\n    watch(.a)\n    watch(.b)\n    self.watch(\n        .c\n    )\n}\n")
        base = self.commit("a plain helper and its callers")
        self.write(f"{SRC}/CmuxNextDomain/Watching.swift",
                   "func watch(_ name: Notification.Name) {\n"
                   "    _ = NotificationCenter.default.notifications(named: name)\n}\n")
        self.commit("the helper now observes")
        delta = counts.delta_count(self.repo, base, "HEAD")
        # Another module cannot see an internal `watch`: no call resolves, so its own registration counts (it
        # never disappears because its callers cannot be resolved).
        self.assertEqual(delta.by_package("observer_sites"), {"CmuxNextDomain": 1})
        self.assert_matches_full(base, "HEAD")
        self.write(f"{SRC}/CmuxNextDomain/Watching.swift",
                   "public func watch(_ name: Notification.Name) {\n"
                   "    _ = NotificationCenter.default.notifications(named: name)\n}\n")
        self.commit("public")
        delta = counts.delta_count(self.repo, base, "HEAD")
        self.assertEqual(delta.by_package("observer_sites"), {"CmuxNextOther": 3})
        self.assert_matches_full(base, "HEAD")

    def test_a_new_blocking_allowance_is_refused(self):
        text = ("enum Blocking {\n    static func allowBlocking(_ why: String) {}\n}\n"
                "final class Reader {\n    func read() {\n        let s = \"// blocking-allow: in a string\"\n"
                "        // blocking-allow: the file is a byte\n        _ = s\n"
                "        Blocking.allowBlocking(\"sync read\")\n    }\n}\n")
        sites = counts.analyze(f"{SRC}/CmuxNextDomain/Blocking.swift", text).sites
        self.assertEqual([s.line for s in sites if s.row == "blocking_allow_escapes"], [7, 9])
        self.write(f"{SRC}/CmuxNextDomain/Blocking.swift", text)
        self.commit("a comment and a call allow blocking; a declaration and a string do not")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["blocking_allow_escapes"])

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

    def test_an_unproved_call_removed_in_one_type_and_added_in_another_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/A.swift",
                   "final class A {\n    func fire() {\n        MainActor.assumeIsolated { print(1) }\n    }\n}\n")
        base = self.commit("an unproved call in A")
        self.write(f"{SRC}/CmuxNextDomain/A.swift",
                   "final class A {\n    func fire() {\n        // a comment line above\n"
                   "        MainActor.assumeIsolated { print(10) }\n    }\n}\n")
        edited = self.commit("the same call edited")
        self.assertEqual(self.check(base=base, head=edited)[0], [], "an edit of the call keeps its identity")
        self.remove(f"{SRC}/CmuxNextDomain/A.swift")
        self.write(f"{SRC}/CmuxNextOther/A.swift",
                   "final class A {\n    func fire() {\n        MainActor.assumeIsolated { print(1) }\n    }\n}\n")
        moved = self.commit("A moves to another package")
        self.assertEqual(self.check(base=edited, head=moved)[0], [], "a move keeps its identity")
        self.git("reset", "--quiet", "--hard", base)
        self.remove(f"{SRC}/CmuxNextDomain/A.swift")
        self.write(f"{SRC}/CmuxNextDomain/B.swift",
                   "final class B {\n    func fire() {\n        MainActor.assumeIsolated { print(2) }\n    }\n}\n")
        swapped = self.commit("remove one in A, add one in B")
        self.assertEqual(counts.delta_count(self.repo, base, swapped).total("assume_isolated_outside_adapters"), 0)
        refusals, _ = self.check(base=base, head=swapped)
        self.assertEqual(self.rows(refusals), ["assume_isolated_outside_adapters"])
        self.assertIn("B.swift:3", refusals[0][1])

    def test_one_proof_covers_one_call(self):
        self.write(f"{SRC}/CmuxNextDomain/TwoCalls.swift",
                   "final class TwoCalls {\n    func fire() {\n"
                   "        // main-proof: the observer is added to the main run loop\n"
                   "        MainActor.assumeIsolated { print(1) }\n        MainActor.assumeIsolated { print(2) }\n"
                   "    }\n    func again() {\n        // main-proof: the same run loop\n        let x = 1\n"
                   "        MainActor.assumeIsolated { print(x) }\n    }\n    func third() {\n"
                   "        CATransaction.setCompletionBlock { // main-proof: CATransaction.h, on the main thread\n"
                   "            MainActor.assumeIsolated { print(3) }\n        }\n    }\n}\n")
        self.commit("two calls under one proof; a code line between a proof and its call; a proved opener")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["assume_isolated_outside_adapters"])
        self.assertIn("+2", refusals[0][1])
        self.assertIn("TwoCalls.swift:5", refusals[0][1])
        self.assertIn("TwoCalls.swift:10", refusals[0][1])

    def test_kvo_and_cf_notification_observers_are_counted(self):
        self.write(f"{SRC}/CmuxNextDomain/Kvo.swift",
                   "final class Kvo {\n    func start(_ v: NSView) {\n"
                   "        _ = v.observe(\\.isHidden, options: [.new]) { _, _ in }\n"
                   "        CFNotificationCenterAddObserver(center, nil, callback, name, nil, .deliverImmediately)\n"
                   "    }\n}\n")
        self.commit("observers")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["observer_sites"])
        self.assertIn("+2", refusals[0][1])

    def test_a_proved_call_in_an_extension_or_a_free_function_is_not_an_adapter(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Callback.swift",
                   "extension Store {\n    func fire() {\n        // main-proof: the main run loop\n"
                   "        MainActor.assumeIsolated { print(1) }\n    }\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/AfterCommit.swift",
                   "func afterCommit() {\n    // main-proof: CATransaction completion runs on main\n"
                   "    MainActor.assumeIsolated { print(2) }\n}\n")
        body = "".join(f"    func f{i}() {{ print({i}) }}\n" for i in range(150))
        self.write(f"{SRC}/CmuxNextDomain/BigObserver.swift",
                   "final class BigObserver {\n" + body + "    func fire() {\n        // main-proof: main run loop\n"
                   "        MainActor.assumeIsolated { print(3) }\n    }\n}\n")
        self.write(f"{SRC}/CmuxNextDomain/Store+Seam.swift",
                   "extension Store {\n    final class Seam {\n        func fire() {\n"
                   "            // main-proof: the main run loop\n            MainActor.assumeIsolated { print(4) }\n"
                   "        }\n    }\n}\n")
        self.commit("an extension, a free function, a large type and a small nested seam type")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["assume_isolated_outside_adapters"])
        text = refusals[0][1]
        self.assertIn("+3", text)
        for place in ("Store+Callback.swift:4", "AfterCommit.swift:3", "BigObserver.swift:154"):
            self.assertIn(place, text)
        self.assertNotIn("Store+Seam.swift", text, "a small type of its own is a seam adapter, even nested")

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
        manifest = counts.parse_manifest(MANIFEST % ', "CmuxNextUI"')
        graph = {name: sorted(t.deps) for name, t in manifest.targets.items() if t.kind != "testTarget"}
        self.assertEqual(graph, {"CmuxNextCore": [], "CmuxNextDomain": ["CFFI", "CmuxNextCore", "CmuxNextUI"],
                                 "CmuxNextUI": ["CmuxNextDomain"], "CFFI": []})
        self.assertEqual(manifest.unreadable, {})

    def test_an_upward_edge_from_core_is_counted_and_refused(self):
        # Core -> domain is neither hard nor soft, but edges only point down (DESIGN section 2).
        self.write("Packages/macOS/CmuxNext/Package.swift",
                   (MANIFEST % "").replace('.target(name: "CmuxNextCore"),',
                                           '.target(name: "CmuxNextCore", dependencies: ["CmuxNextDomain"]),'))
        self.commit("upward")
        refusals, _ = self.check()
        self.assertEqual(self.rows(refusals), ["layer_upward"])
        self.assertIn("CmuxNextCore (core) -> CmuxNextDomain (domain)", dict(refusals)["layer_upward"])
        self.assert_matches_full(self.base, "HEAD")

    def test_a_layer_map_that_does_not_parse_counts_every_target_unplaced(self):
        # It used to raise KeyError in layers(), and the ratchet then failed open for the whole push.
        for broken in ('{"order": ["core"], "targets": {"CmuxNextCore": {"layr": "core"}}}',
                       '{"order": ["core"], "targets": {"CmuxNextCore": "core"}}', "{not json"):
            lay = counts.layers(MANIFEST % "", broken)
            self.assertIn("CmuxNextCore", lay.unplaced, broken)
        self.assertIsNotNone(counts.layers(MANIFEST % "", "{not json").error)
        self.write("plans/cmux-next/architecture-layers.json", "{not json")
        self.commit("broken map")
        refused, out = self.run_push()
        self.assertTrue(refused, out)
        self.assertNotIn("the ratchet failed", out)
        self.assertIn("[layer_unplaced]", out)

    def test_a_push_that_repairs_a_broken_base_map_is_not_refused_for_standing_edges(self):
        # The review's case: a broken map landed upstream (past the hook: a GitHub merge, --no-verify). It places
        # nothing, so its edges read 0, and the push that fixes the JSON was refused for the hard edge that stood
        # all along. The broken end is judged by the last map that parsed: every row is judged, none rises.
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST % ', "CmuxNextUI"')
        self.commit("a standing hard edge")
        self.write("plans/cmux-next/architecture-layers.json", "{not json")
        base = self.commit("a broken map lands")
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(LAYERS))
        self.commit("repairs the map")
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        self.assertNotIn("[layer_hard]", out)
        self.assertIn("layer_unplaced -4", out)
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertFalse(any("not judged" in n for n in notes), notes)
        self.assert_matches_full(base, "HEAD")

    def test_a_broken_map_with_no_earlier_map_leaves_the_edge_rows_unjudged(self):
        # No earlier map parses (the map was deleted, then added broken): its edges are unknown, not 0, so the
        # repair is not refused for the standing edge and a note says the edge rows were not judged.
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST % ', "CmuxNextUI"')
        self.remove("plans/cmux-next/architecture-layers.json")
        self.commit("a standing hard edge, no map")
        self.write("plans/cmux-next/architecture-layers.json", "{not json")
        base = self.commit("a broken map lands")
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(LAYERS))
        self.commit("repairs the map")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [], notes)
        self.assertTrue(any("layer_hard, layer_soft, layer_upward not judged" in n for n in notes), notes)

    def test_a_repair_of_a_broken_base_map_is_judged_against_the_last_map_that_parsed(self):
        # The review's case: a broken base map placed nothing, so the gate judged no relabel and no unplaced
        # target, and the push that repaired the map could relabel a standing hard edge away unrefused.
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST % ', "CmuxNextUI"')
        self.commit("a standing hard edge")
        self.write("plans/cmux-next/architecture-layers.json", "{not json")
        base = self.commit("a broken map lands")
        relabelled = json.loads(json.dumps(LAYERS))
        relabelled["targets"]["CmuxNextDomain"]["layer"] = "ui"
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(relabelled))
        self.commit("repairs the map and relabels the edge away")
        refused, out = self.run_push(base=base)
        self.assertTrue(refused, out)
        self.assertIn("moves from domain to ui", out)
        dropped = json.loads(json.dumps(LAYERS))
        del dropped["targets"]["CmuxNextUI"]
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(dropped))
        self.commit("repairs the map without CmuxNextUI")
        refusals, _ = ratchet.check_range(self.repo, base, "HEAD")
        self.assertIn("layer-gate", self.rows(refusals))
        self.assertIn("target CmuxNextUI (target) has no layer", dict(refusals)["layer-gate"])

    def test_a_new_edge_with_a_broken_base_map_is_still_refused_by_the_gate(self):
        self.write("plans/cmux-next/architecture-layers.json", "{not json")
        base = self.commit("a broken map lands")
        self.write("Packages/macOS/CmuxNext/Package.swift", MANIFEST % ', "CmuxNextUI"')
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(LAYERS))
        self.commit("repairs the map and adds a hard edge")
        refusals, _ = ratchet.check_range(self.repo, base, "HEAD")
        # The count judges the broken base by the map before it (no hard edge): the gate's refusal answers it.
        self.assertEqual(self.rows(refusals), ["layer-gate"])
        self.assertIn("new edge CmuxNextDomain (domain) -> CmuxNextUI (ui)", dict(refusals)["layer-gate"])

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

    def test_no_environment_variable_skips_a_row(self):
        self.add_singleton()
        os.environ["ARCH_RATCHET_SKIP_REASON"] = "stateful_singletons: fixture"
        try:
            refused, out = self.run_push()
        finally:
            del os.environ["ARCH_RATCHET_SKIP_REASON"]
        self.assertTrue(refused, out)
        self.assertIn("[stateful_singletons]", out)

    def test_an_edited_pending_exception_gives_no_allowance_and_a_duplicate_does(self):
        entry = {"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "reviewed A"}
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [entry]}))
        base = self.commit("a pending exception")
        self.add_singleton()
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [dict(entry, why="reviewed A.")]}))
        self.commit("edits its why")
        refusals, notes = self.check(base=base)
        self.assertEqual(self.rows(refusals), ["stateful_singletons"], notes)
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [entry, dict(entry)]}))
        self.commit("a second identical exception")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [], notes)

    def test_a_push_that_changes_an_applied_exception_is_refused(self):
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [
            {"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "fixture"}]}))
        self.commit("a reviewed singleton")
        self.assertEqual(self.update()[0], 0)
        base = self.commit("applied")
        data = self.recorded()
        data["exceptions"][0]["allow"] = 2
        self.write(counts.RATCHET_JSON, json.dumps(data))
        self.commit("edits the applied entry")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW])
        self.assertIn("applied exception", refusals[0][1])

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

    def test_a_hand_edit_of_method_version_is_refused_and_a_method_change_passes(self):
        self.assertEqual(self.update()[0], 0)
        base = self.commit("record")
        data = self.recorded()
        data["method_version"] = counts.METHOD_VERSION + 1
        data["totals"]["stateful_singletons"] += 5
        self.write(counts.RATCHET_JSON, json.dumps(data))
        self.commit("bumps method_version by hand to raise a total")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW])
        self.assertIn("method_version", refusals[0][1])
        self.write(counts.METHOD_FILE, f"METHOD_VERSION = {counts.METHOD_VERSION + 1}\n")
        self.commit("the row definitions change to that version")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [], notes)
        self.assertTrue(any("not compared" in n for n in notes), notes)
        self.write(counts.METHOD_FILE, f"METHOD_VERSION = {counts.METHOD_VERSION + 2}\n")
        self.commit("arch_counts.py names another version than the json")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW])

    def test_a_merge_push_gets_no_allowance_from_an_exception_upstream_landed(self):
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": []}))
        self.commit("record")
        self.git("checkout", "--quiet", "-b", "upstream")
        self.write(f"{SRC}/CmuxNextDomain/S.swift", "extension Store {\n    static let s = Store()\n}\n")
        self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [
            {"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "upstream's reviewed S"}]}))
        self.commit("upstream: singleton S and its exception")
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write("README", "pushed once\n")
        base = self.commit("already pushed")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "upstream")
        self.write(f"{SRC}/CmuxNextDomain/T.swift", "extension Store {\n    static let t = Store()\n}\n")
        head = self.commit("the branch's own singleton T")
        self.assertNotEqual(self.git("merge-base", base, "upstream"), base)
        refusals, notes = ratchet.check_range(self.repo, base, head, [], upstream_ref="upstream")
        self.assertEqual(self.rows(refusals), ["stateful_singletons"], notes)
        self.assertIn("T.swift:2", refusals[0][1])
        # An exception of the push's own (new over both ranges) still lets it through.
        data = json.loads((self.repo / counts.RATCHET_JSON).read_text())
        data["exceptions"].append({"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "own T"})
        self.write(counts.RATCHET_JSON, json.dumps(data))
        own = self.commit("the push's own exception")
        refusals, notes = ratchet.check_range(self.repo, base, own, [], upstream_ref="upstream")
        self.assertEqual(refusals, [], notes)

    def merge_push(self, upstream_files, own_files, upstream_json=None):
        """(base, head) of a merge push: the pushed branch is on the remote at BASE (a commit of its own after
        the fork point), upstream lands UPSTREAM_FILES ({path: text or None to remove}) and UPSTREAM_JSON,
        and the push adds OWN_FILES and merges upstream in."""
        fork = self.git("rev-parse", "HEAD")
        self.write("README", "the pushed branch, already on the remote\n")
        base = self.commit("pushed earlier")
        self.git("checkout", "--quiet", "-b", "upstream", fork)
        for path, text in upstream_files.items():
            self.remove(path) if text is None else self.write(path, text)
        if upstream_json is not None:
            self.write(counts.RATCHET_JSON, json.dumps(upstream_json))
        self.commit("landed upstream")
        self.git("checkout", "--quiet", "feat-cmux-next")
        for path, text in own_files.items():
            self.write(path, text)
        self.commit("the push's own change")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "upstream")
        head = self.git("rev-parse", "HEAD")
        self.assertNotIn(self.git("merge-base", base, "upstream"), (base, self.git("rev-parse", "upstream")))
        return base, head

    def test_a_merge_push_refuses_its_own_rise_next_to_an_upstream_drop(self):
        # The review's case: upstream drops three statics of a row, the push adds one in another package and
        # merges upstream in. Over base..head the row reads -2 (the minimum of two ranges took it), but the push
        # itself added +1: one range from where HEAD meets upstream counts it.
        cache = f"{SRC}/CmuxNextSidebar/Cache.swift"
        self.write(cache, "enum Cache {\n    static var a = 0\n    static var b = 0\n    static var c = 0\n}\n")
        self.commit("standing debt")
        base, head = self.merge_push({cache: None}, {f"{SRC}/CmuxNextBrowser/Other.swift":
                                                     "enum Other {\n    static var d = 0\n}\n"})
        refusals, notes = ratchet.check_range(self.repo, base, head, [], upstream_ref="upstream")
        self.assertEqual(self.rows(refusals), ["global_mutable_statics"], notes)
        self.assertIn("+1 (CmuxNextBrowser +1)", refusals[0][1])
        self.assertIn("Other.swift:2: static var d = 0", refusals[0][1])
        self.assertFalse(any(ratchet.UPDATE_HINT in n for n in notes), notes)

    def test_a_merge_push_cannot_raise_the_record_upstream_lowered(self):
        # The record rule refused only a rise every range showed: upstream removed a singleton and lowered the
        # record (1 -> 0); the push merged that in and wrote 1 back by hand. Over base..head the json reads 1 -> 1,
        # so the two-range rule let it through. Over the one range from where HEAD meets upstream it is 0 -> 1.
        self.record_singletons(1)
        self.add_singleton()
        base, head = self.merge_push({f"{SRC}/CmuxNextDomain/Store+Shared.swift": None}, {},
                                     upstream_json={"method_version": counts.METHOD_VERSION, "measured_sha": "0" * 40,
                                                    "totals": {"stateful_singletons": 0}, "exceptions": []})
        self.record_singletons(1)
        head = self.commit("writes the merged record back up by hand")
        refusals, notes = ratchet.check_range(self.repo, base, head, [], upstream_ref="upstream")
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW], notes)
        self.assertIn("raises stateful_singletons from 0 to 1", refusals[0][1])

    def test_a_merge_cannot_use_an_upstream_removal_to_pay_for_the_branch_s_own_observer(self):
        # Upstream removes an observer site; the branch adds another and merges upstream in. Over the old remote
        # head the totals cancel (observer_sites holds the total only): upstream's removal must not pay for it.
        observer = ("final class {name} {{\n    func start() {{\n        _ = NotificationCenter.default.addObserver(\n"
                    "            forName: NSWindow.{event}Notification, object: nil, queue: nil) {{ _ in }}\n    }}\n}}\n")
        self.write(f"{SRC}/CmuxNextDomain/Watch.swift", observer.format(name="Watch", event="didBecomeKey"))
        self.commit("an observer on the base")
        self.write("README", "pushed once\n")
        pushed = self.commit("already pushed")
        self.git("checkout", "--quiet", "-b", "upstream", "HEAD~1")
        self.remove(f"{SRC}/CmuxNextDomain/Watch.swift")
        self.commit("upstream removes the observer")
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write(f"{SRC}/CmuxNextDomain/Other.swift", observer.format(name="Other", event="didResignKey"))
        self.commit("the branch's own observer")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "upstream")
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(ratchet.check_own(self.repo, pushed, head, [])[0], [],
                         "control: over the old remote head the totals cancel")
        refusals, notes = ratchet.check_range(self.repo, pushed, head, [], upstream_ref="upstream")
        self.assertEqual(self.rows(refusals), ["observer_sites"], notes)
        self.assertIn("Other.swift", refusals[0][1])

    def test_a_push_that_raises_or_deletes_the_recorded_totals_is_refused(self):
        code, out = self.update()
        self.assertEqual(code, 0, out)
        base = self.commit("record")
        data = self.recorded()
        data["totals"]["stateful_singletons"] += 2
        self.write(counts.RATCHET_JSON, json.dumps(data))
        self.commit("raises the record by hand")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW])
        self.assertIn("raises stateful_singletons", refusals[0][1])
        self.remove(counts.RATCHET_JSON)
        self.commit("deletes the record")
        refusals, _ = self.check(base=base)
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW])
        self.assertIn("deletes", refusals[0][1])

    def test_update_refuses_a_rise_no_exception_covers_and_names_the_commit(self):
        self.assertEqual(self.update()[0], 0)
        self.commit("record")
        recorded = self.recorded()["totals"]["stateful_singletons"]
        landed = self.add_singleton()  # landed past the hook (a GitHub merge, --no-verify)
        code, out = self.update()
        self.assertEqual(code, 1, out)
        self.assertIn("stateful_singletons", out)
        self.assertIn(f"raised by {landed[:11]}", out)
        self.assertEqual(self.recorded()["totals"]["stateful_singletons"], recorded, "a refused update writes nothing")
        data = self.recorded()
        data["exceptions"].append({"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "fixture"})
        self.write(counts.RATCHET_JSON, json.dumps(data))
        code, out = self.update()
        self.assertEqual(code, 0, out)
        data = self.recorded()
        self.assertEqual(data["totals"]["stateful_singletons"], recorded + 1)
        self.assertEqual(data["exceptions"][0]["applied_sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(self.update()[0], 0, "an applied exception is folded in, not spent twice")

    def test_update_records_a_rise_already_on_upstream_with_a_generated_entry(self):
        self.assertEqual(self.update()[0], 0)
        self.commit("record")
        recorded = self.recorded()["totals"]["stateful_singletons"]
        landed = self.add_singleton()  # landed on origin/feat-cmux-next past the hook
        self.git("branch", "upstream", landed)
        self.write(f"{SRC}/CmuxNextDomain/Store+Mine.swift", "final class Mine {\n    var n = 0\n}\n")
        mine = self.commit("the runner's own commit lowers nothing")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = ratchet.update(self.repo, upstream_ref="upstream")
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("WARNING", out.getvalue())
        self.assertIn(landed[:11], out.getvalue())
        data = self.recorded()
        self.assertEqual(data["totals"]["stateful_singletons"], recorded + 1)
        entry = data["exceptions"][-1]
        self.assertEqual((entry["row"], entry["allow"], entry["raised_by"], entry["applied_sha"]),
                         ("stateful_singletons", 1, [landed], mine))
        update = self.commit("--update")
        # The record rule takes the generated entry; it allows no rise in a push's code.
        refusals, notes = ratchet.check_range(self.repo, landed, update, [], upstream_ref="upstream")
        self.assertEqual(refusals, [], notes)
        self.write(f"{SRC}/CmuxNextDomain/Store+More.swift", "extension Store {\n    static let more = Store()\n}\n")
        more = self.commit("a new singleton")
        refusals, _ = ratchet.check_range(self.repo, update, more, [], upstream_ref="upstream")
        self.assertEqual(self.rows(refusals), ["stateful_singletons"])
        # A generated entry that names a commit not on upstream does not cover the rise.
        self.git("reset", "--quiet", "--hard", mine)
        data["exceptions"][-1] = dict(entry, raised_by=[mine])
        self.write(counts.RATCHET_JSON, json.dumps(data))
        forged = self.commit("names a local commit")
        refusals, _ = ratchet.check_range(self.repo, landed, forged, [], upstream_ref="upstream")
        self.assertEqual(self.rows(refusals), [ratchet.RECORD_ROW])

    def test_a_copied_generated_entry_and_one_that_names_a_commit_before_the_record_are_refused(self):
        early = self.add_singleton()  # on upstream before the record: the record counted it already
        self.assertEqual(self.update()[0], 0)
        self.commit("record")
        recorded = self.recorded()["totals"]["stateful_singletons"]
        self.write(f"{SRC}/CmuxNextDomain/Store+Second.swift", "extension Store {\n    static let second = Store()\n}\n")
        landed = self.commit("a second singleton lands past the hook")
        self.git("branch", "upstream", landed)
        self.write("README", "the runner's own commit\n")
        mine = self.commit("the runner's own commit")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(ratchet.update(self.repo, upstream_ref="upstream"), 0, out.getvalue())
        update = self.commit("--update")
        data = self.recorded()
        entry = data["exceptions"][-1]
        self.assertEqual((entry["raised_by"], entry["applied_sha"], data["totals"]["stateful_singletons"]),
                         ([landed], mine, recorded + 1))
        self.assertEqual(ratchet.check_range(self.repo, landed, update, [], upstream_ref="upstream")[0], [])

        def push(change):
            """Commit the json at HEAD as CHANGE edits it; the record rule's refusals over UPDATE..it."""
            edited = self.recorded()
            change(edited)
            self.write(counts.RATCHET_JSON, json.dumps(edited))
            head = self.commit("a hand edit of the json")
            refusals, notes = ratchet.check_range(self.repo, update, head, [], upstream_ref="upstream")
            return self.rows(refusals), notes

        def raise_with(*entries):
            def change(edited):
                edited["exceptions"] += [dict(e) for e in entries]
                edited["totals"]["stateful_singletons"] += 1
            return change

        # A verbatim copy of the applied generated entry gives no second allowance.
        rows, notes = push(raise_with(entry))
        self.assertEqual(rows, [ratchet.RECORD_ROW], notes)
        # Upstream raises the row once more. An entry that names the old upstream commit (before the record's
        # measured_sha) does not cover that rise; one that names the commit that made it does.
        self.git("reset", "--quiet", "--hard", update)
        self.write(f"{SRC}/CmuxNextDomain/Store+Third.swift", "extension Store {\n    static let third = Store()\n}\n")
        later = self.commit("a third singleton lands past the hook")
        self.git("branch", "--force", "upstream", later)
        generated = dict(entry, applied_sha=later)
        for named, refused in ((early, [ratchet.RECORD_ROW]), (later, [])):
            self.git("reset", "--quiet", "--hard", later)
            rows, notes = push(lambda edited, named=named: (edited.update(measured_sha=later),
                                                            raise_with(dict(generated, raised_by=[named]))(edited)))
            self.assertEqual(rows, refused, (named[:11], notes))
        # A rise a later upstream commit undid is no rise: an entry for it gives nothing.
        self.git("reset", "--quiet", "--hard", later)
        self.remove(f"{SRC}/CmuxNextDomain/Store+Third.swift")
        undo = self.commit("upstream removes the third singleton")
        self.git("branch", "--force", "upstream", undo)
        rows, notes = push(lambda edited: (edited.update(measured_sha=undo),
                                           raise_with(dict(generated, raised_by=[later], applied_sha=undo))(edited)))
        self.assertEqual(rows, [ratchet.RECORD_ROW], notes)

    def test_update_still_refuses_a_rise_in_commits_not_on_upstream(self):
        self.assertEqual(self.update()[0], 0)
        record = self.commit("record")
        self.git("branch", "upstream", record)
        self.add_singleton()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = ratchet.update(self.repo, upstream_ref="upstream")
        self.assertEqual(code, 1, out.getvalue())
        self.assertIn("not on upstream", out.getvalue())

    def test_an_exception_added_and_applied_in_one_push_passes_both_rules(self):
        self.assertEqual(self.update()[0], 0)
        base = self.commit("record")
        self.write(f"{SRC}/CmuxNextDomain/Store+Shared.swift", "extension Store {\n    static let shared = Store()\n}\n")
        data = self.recorded()
        data["exceptions"].append({"date": "2026-10-23", "row": "stateful_singletons", "allow": 1, "why": "fixture"})
        self.write(counts.RATCHET_JSON, json.dumps(data))
        self.commit("a reviewed singleton and its exception")
        self.assertEqual(self.update()[0], 0)
        self.commit("update")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [], notes)

    def test_the_audit_names_the_commits_over_the_record(self):
        self.assertEqual(self.update()[0], 0)
        self.commit("record")
        landed = self.add_singleton()
        result = ratchet.audit(self.repo)
        self.assertEqual(sorted(result["over"]), ["stateful_singletons"])
        self.assertEqual([c["sha"] for c in result["over"]["stateful_singletons"]["raised_by"]], [landed[:11]])
        self.assertIn(landed[:11], "\n".join(ratchet.audit_lines(result)))

    def test_a_drop_prints_the_update_hint_and_passes(self):
        base = self.add_singleton()
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.commit("removes it")
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        self.assertIn(ratchet.UPDATE_HINT, out)

    def record_singletons(self, total, sha="0" * 40):
        self.write(counts.RATCHET_JSON, json.dumps({"method_version": counts.METHOD_VERSION, "measured_sha": sha,
                                                    "totals": {"stateful_singletons": total}, "exceptions": []}))

    def test_a_drop_the_pushed_json_already_records_prints_no_hint(self):
        self.record_singletons(1)
        base = self.add_singleton()
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.record_singletons(0)
        self.commit("removes it and lowers the record")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertTrue(any(n.startswith("arch-ratchet: stateful_singletons -1 ") for n in notes), notes)
        self.assertFalse(any(ratchet.UPDATE_HINT in n for n in notes), notes)

    def test_a_drop_the_pushed_json_does_not_lower_still_prints_the_hint(self):
        self.record_singletons(1)
        base = self.add_singleton()
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.record_singletons(1, sha="1" * 40)
        self.commit("removes it and touches only measured_sha")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertIn(f"arch-ratchet: {ratchet.UPDATE_HINT} (stateful_singletons)", notes)

    def test_a_drop_with_the_first_json_measured_after_it_prints_no_hint(self):
        base = self.add_singleton()  # the base has no arch-ratchet.json
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        measured = self.commit("removes it")
        self.record_singletons(0, sha=measured)  # what --update writes at that commit
        self.commit("adds the first record")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertTrue(any(n.startswith("arch-ratchet: stateful_singletons -1 ") for n in notes), notes)
        self.assertFalse(any(ratchet.UPDATE_HINT in n for n in notes), notes)

    def test_a_drop_after_the_first_json_the_push_adds_prints_the_hint(self):
        base = self.add_singleton()  # the base has no arch-ratchet.json
        self.write("README", "in the push\n")
        measured = self.commit("a commit of the push, before the drop")
        self.record_singletons(1, sha=measured)  # what --update writes at that commit: true there
        self.commit("adds the first record")
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.commit("removes it after the record")  # the pushed json still says 1; the truth is 0
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertIn(f"arch-ratchet: {ratchet.UPDATE_HINT} (stateful_singletons)", notes)

    def test_a_change_to_the_count_method_after_the_measured_sha_keeps_the_hint(self):
        self.record_singletons(0)  # low: a skip landed the singleton without an --update
        base = self.add_singleton()
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        measured = self.commit("removes it")
        self.record_singletons(0, sha=measured)
        self.commit("--update at its parent")
        self.write(counts.METHOD_FILE, "# a changed row definition\n")
        self.commit("changes the count method after the record")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertIn(f"arch-ratchet: {ratchet.UPDATE_HINT} (stateful_singletons)", notes)

    def test_an_update_measured_in_the_push_over_a_low_base_record_prints_no_hint(self):
        self.record_singletons(0)  # low: a skip landed the singleton without an --update
        base = self.add_singleton()
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        measured = self.commit("removes it")
        self.record_singletons(0, sha=measured)  # what --update writes at that commit
        self.commit("--update at its parent")
        refusals, notes = self.check(base=base)
        self.assertEqual(refusals, [])
        self.assertFalse(any(ratchet.UPDATE_HINT in n for n in notes), notes)

    def test_a_merge_push_compares_the_json_over_the_range_the_drop_came_from(self):
        self.record_singletons(1)
        self.add_singleton()
        self.git("checkout", "--quiet", "-b", "upstream")
        self.write(f"{SRC}/CmuxNextDomain/Store+Other.swift", "extension Store {\n    static let other = Store()\n}\n")
        self.record_singletons(2)
        self.commit("upstream adds a singleton and its --update")
        self.git("checkout", "--quiet", "feat-cmux-next")
        self.write("README", "pushed branch\n")
        base = self.commit("already on the pushed branch")
        self.remove(f"{SRC}/CmuxNextDomain/Store+Shared.swift")
        self.commit("removes the first singleton")
        self.git("merge", "--quiet", "--no-edit", "--no-ff", "upstream")
        self.record_singletons(1, sha="2" * 40)  # true at HEAD: upstream's singleton is left
        head = self.commit("lowers the record")
        self.assertNotEqual(self.git("merge-base", base, "upstream"), base)  # one range: upstream..head
        refusals, notes = ratchet.check_range(self.repo, base, head, [], upstream_ref="upstream")
        self.assertEqual(refusals, [])
        self.assertTrue(any(n.startswith("arch-ratchet: stateful_singletons -1 ") for n in notes), notes)
        self.assertFalse(any(ratchet.UPDATE_HINT in n for n in notes), notes)

    def test_app_lines_are_report_only(self):
        self.write(f"{SRC}/CmuxNextApp/Big.swift", "let a = 1\n" * 50)
        self.commit("app lines")
        refusals, notes = self.check()
        self.assertEqual(refusals, [])
        self.assertTrue(any("app_lines +50" in n for n in notes), notes)

    def test_rule_modules_load_from_a_directory_and_zero_modules_work(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(ratchet.load_rules(Path(empty)), ([], []))
            rules, warnings = ratchet.load_rules(Path(empty) / "arch_rules")
            self.assertEqual(rules, [])
            self.assertIn("is missing", warnings[0], "a broken install that skipped arch_rules/ warns")
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

    def test_a_dated_exception_for_a_module_id_lets_that_many_of_its_refusals_through(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "two_refusals.py").write_text(
                "ID = 'two-refusals'\n"
                "def check(base, head, changes):\n"
                "    return [(ID, 'first'), (ID, 'second', None)], []\n")
            rules, warnings = ratchet.load_rules(Path(folder))
            self.assertEqual(warnings, [])
            entry = {"date": "2026-10-23", "row": "two-refusals", "allow": 1, "why": "reviewed"}
            self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [entry]}))
            one = self.commit("allows one of two")
            refusals, _ = self.check(head=one, rules=rules)
            self.assertEqual([row for row, _ in refusals], ["two-refusals", "two-refusals"])
            self.assertIn("allow 1 [two-refusals] refusal(s); it has 2", refusals[-1][1])
            self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [entry, dict(entry, why="reviewed too")]}))
            two = self.commit("allows both")
            refusals, notes = self.check(head=two, rules=rules)
            self.assertEqual(refusals, [])
            self.assertTrue(any("[two-refusals] 2 refusal(s) let through" in n for n in notes), notes)
            # An exception for the file stem, not the module's ID, covers nothing.
            self.write(counts.RATCHET_JSON, json.dumps({"exceptions": [dict(entry, row="two_refusals", allow=2)]}))
            stem = self.commit("names the file stem")
            refusals, _ = self.check(head=stem, rules=rules)
            self.assertEqual(len(refusals), 2)

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

    def test_guardrails_run_it_and_a_broken_ratchet_fails_open(self):
        target = self.repo / "scripts/cmux-next"
        target.mkdir(parents=True)
        for name in ("arch-ratchet.py", "arch_counts.py", "guardrails.py"):
            shutil.copyfile(SCRIPTS / name, target / name)
        self.commit("scripts")
        self.add_singleton()
        ranges = [(self.git("rev-parse", "HEAD~1"), self.git("rev-parse", "HEAD"))]
        text, refused = guardrails.Ratchet(self.repo, ranges, target).finish()
        self.assertTrue(refused, text)
        self.assertIn("[stateful_singletons]", text)
        (target / "arch-ratchet.py").write_text("raise ValueError('boom')\n")
        text, refused = guardrails.Ratchet(self.repo, ranges, target).finish()
        self.assertFalse(refused, "a broken ratchet lets the push through")
        self.assertIn("arch-ratchet.py failed (ValueError: boom)", text)

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

    def test_a_warm_eighty_file_cross_package_move_reads_no_file_twice_and_takes_under_a_second(self):
        # The shape that cost 9-10 s (review 2): moved types with static factories and shared nested names, and
        # hundreds of unrelated files with instance methods of the same names (`func make`, `x.open(`).
        for i in range(300):
            self.write(f"{SRC}/CmuxNextDomain/Other{i}.swift",
                       f"final class Other{i} {{\n    let style = Style()\n    func make() -> Int {{ {i} }}\n"
                       f"    func open() {{ _ = make(); _ = style }}\n}}\n")
        for i in range(80):
            self.write(f"{SRC}/CmuxNextApp/Handlers/Moved{i}.swift",
                       f"final class Moved{i} {{\n    var count = 0\n    static let shared = make()\n"
                       f"    static func make() -> Moved{i} {{ Moved{i}() }}\n    struct Owner {{ let id = {i} }}\n"
                       f"    func open() {{ count += 1 }}\n}}\n")
        base = self.commit("three hundred files and eighty to move")
        # `git mv` into a directory that does not exist fails (git 2.54: "renaming ... failed").
        (self.repo / SRC / "CmuxNextMoved").mkdir(parents=True)
        for i in range(80):
            self.git("mv", f"{SRC}/CmuxNextApp/Handlers/Moved{i}.swift", f"{SRC}/CmuxNextMoved/Moved{i}.swift")
        self.commit("move eighty files to another package")
        cold = counts.delta_count(self.repo, base, "HEAD")
        self.assertEqual(cold.by_package("stateful_singletons"), {"CmuxNextApp": -80, "CmuxNextMoved": 80})
        self.assertLessEqual(cold.analyzed, 2 * 80 + 10,
                             "only the moved files at both ends are analyzed, not the files that only mention a name")
        warm = counts.delta_count(self.repo, base, "HEAD")
        self.assertEqual(warm.analyzed, 0, "every file's facts come from the cache on the second run")
        self.assertEqual(warm.by_package("stateful_singletons"), cold.by_package("stateful_singletons"))
        self.assert_matches_full(base, "HEAD")
        best = min(self.timed(base) for _ in range(3))
        self.assertLess(best, 1.0, f"{best:.2f}s")

    def timed(self, base):
        started = time.monotonic()
        refused, out = self.run_push(base=base)
        self.assertFalse(refused, out)
        return time.monotonic() - started


ROOT_PKG = "Packages/macOS/CmuxNext"
SHARED = "Packages/Shared/SharedKit"
DEEP = "Packages/Shared/Deep"
UNLINKED = "Packages/Shared/Unlinked"
# The root links one local package (SharedKit, which links Deep: a transitive one) and one remote package.
CLOSURE_ROOT = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "CmuxNext",
    dependencies: [
        .package(path: "../../Shared/SharedKit"),
        .package(url: "https://example.com/remote.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "CmuxNextCore", dependencies: [.product(name: "SharedKit", package: "SharedKit")]),
        .target(name: "CmuxNextDomain", dependencies: ["CmuxNextCore", .product(name: "Remote", package: "remote")]),
    ]
)
"""
CLOSURE_SHARED = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "SharedKit",
    products: [.library(name: "SharedKit", targets: ["SharedKit"])],
    dependencies: [.package(path: "../Deep")%s],
    targets: [
        .target(name: "SharedKit", dependencies: [.product(name: "DeepKit", package: "Deep")%s]),
        .testTarget(name: "SharedKitTests", dependencies: ["SharedKit"]),
    ]
)
"""
# The product DeepKit exposes the target DeepCore: an edge to the product is an edge to that target.
CLOSURE_DEEP = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Deep",
    products: [.library(name: "DeepKit", targets: ["DeepCore"])],
    targets: [.target(name: "DeepCore")]
)
"""
CLOSURE_UNLINKED = """// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Unlinked", products: [.library(name: "Unlinked", targets: ["Unlinked"])],
                      targets: [.target(name: "Unlinked")])
"""
CLOSURE_LAYERS = {"order": ["core", "service", "domain", "ui", "app"],
                  "targets": {"CmuxNextCore": {"layer": "core"}, "CmuxNextDomain": {"layer": "domain"},
                              "SharedKit": {"layer": "service"}, "DeepCore": {"layer": "domain"},
                              "Unlinked": {"layer": "core"}}}
HUB = "public final class Hub {\n    var n = 0\n}\npublic enum Hubs {\n    static let shared = Hub()\n}\n"
OBSERVE = ("final class Watch {\n    func start() {\n        _ = NotificationCenter.default.addObserver(\n"
           "            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { _ in }\n    }\n}\n")


class ClosureTests(Repo):
    """The count's scope is CmuxNext plus the transitive closure of its local `.package(path:)` dependencies
    (method v5): moving code into a linked local package is not a drop."""

    def setUp(self):
        super().setUp()
        self.write(f"{ROOT_PKG}/Package.swift", CLOSURE_ROOT)
        self.write(f"{SHARED}/Package.swift", CLOSURE_SHARED % ("", ""))
        self.write(f"{SHARED}/Sources/SharedKit/Hub.swift", HUB)
        self.write(f"{SHARED}/Tests/SharedKitTests/HubTests.swift", "var testState = 0\n")
        self.write(f"{DEEP}/Package.swift", CLOSURE_DEEP)
        self.write(f"{DEEP}/Sources/DeepCore/Cache.swift", "var cache: [String: Int] = [:]\n")
        self.write(f"{UNLINKED}/Package.swift", CLOSURE_UNLINKED)
        self.write(f"{UNLINKED}/Sources/Unlinked/U.swift", "var unlinked = 0\n" + OBSERVE)
        self.write("plans/cmux-next/architecture-layers.json", json.dumps(CLOSURE_LAYERS))
        self.base = self.commit("a closure of local packages")

    def test_a_shared_package_s_swift_is_counted_under_its_module(self):
        _, found, _ = counts.full_count(self.repo, self.base)
        self.assertEqual(found.rows["stateful_singletons"]["SharedKit"], 1)
        self.assertEqual(found.rows["global_mutable_statics"]["DeepCore"], 1, "a transitive package is counted")
        self.assertNotIn("SharedKitTests", found.rows["global_mutable_statics"], "Tests/ is not Sources/")
        self.assertEqual(counts.package_of(f"{SHARED}/Sources/SharedKit/Hub.swift"), "SharedKit")
        self.assertEqual(counts.package_of(f"{ROOT_PKG}/Sources/CmuxNextImport/Sources/Grants.swift"),
                         "CmuxNextImport", "a Sources folder inside a module stays in that module")

    def test_a_transitive_local_package_is_in_scope_and_a_remote_or_unlinked_one_is_not(self):
        scope = counts.read_paths(self.repo, self.base)
        self.assertEqual(sorted(scope.packages), sorted([ROOT_PKG, SHARED, DEEP]))
        self.assertIn(f"{DEEP}/Package.swift", scope.manifests)
        self.assertIn(f"{DEEP}/Sources", scope.sources)
        for path in (counts.LAYERS_JSON, counts.RATCHET_JSON, counts.METHOD_FILE):
            self.assertIn(path, scope.files)
        self.assertTrue(scope.is_counted(f"{SHARED}/Package.swift"))
        self.assertTrue(scope.is_counted(f"{DEEP}/Sources/DeepCore/Cache.swift"))
        self.assertFalse(scope.is_counted(f"{UNLINKED}/Package.swift"))
        self.assertFalse(scope.is_counted(f"{UNLINKED}/Sources/Unlinked/U.swift"))
        _, found, _ = counts.full_count(self.repo, self.base)
        self.assertFalse(any("Unlinked" in found.rows[row] for row in counts.ROW_IDS), "an unlinked package")
        self.assertEqual(found.totals()["observer_sites"], 0)

    def test_a_product_edge_to_a_local_package_is_a_classified_layer_edge(self):
        self.assertEqual(counts.parse_manifest(CLOSURE_DEEP).products, {"DeepKit": ["DeepCore"]})
        _, found, lay = counts.full_count(self.repo, self.base)
        self.assertEqual(lay.upward, [("CmuxNextCore", "core", "SharedKit", "service")])
        self.assertEqual(lay.soft, [("SharedKit", "service", "DeepCore", "domain")], "the product's target")
        self.assertEqual(lay.hard, [])
        self.assertEqual(lay.unplaced, [], "a remote product is no target and no edge")
        self.assertEqual(found.totals()["layer_upward"], 1)
        self.assertEqual({s.path for s in found.sites["layer_soft"]}, {f"{SHARED}/Package.swift"})

    def test_delta_equals_full_on_a_range_that_changes_only_a_shared_package(self):
        self.write(f"{SHARED}/Sources/SharedKit/Hub.swift", HUB + "public enum Other {\n    static let hub = Hub()\n}\n")
        self.write(f"{SHARED}/Sources/SharedKit/Watch.swift", OBSERVE)
        head = self.commit("a singleton and an observer in a shared package")
        delta = counts.delta_count(self.repo, self.base, head)
        self.assertEqual(delta.by_package("stateful_singletons"), {"SharedKit": 1})
        self.assertEqual(delta.by_package("observer_sites"), {"SharedKit": 1})
        self.assert_matches_full(self.base, head)

    def test_delta_equals_full_on_a_range_that_changes_only_a_shared_manifest_to_link_a_package(self):
        # Linking the unlinked package brings its sources, its target and its edge into the count.
        self.write(f"{SHARED}/Package.swift", CLOSURE_SHARED % (', .package(path: "../Unlinked")',
                                                                ', .product(name: "Unlinked", package: "Unlinked")'))
        linked = self.commit("SharedKit links Unlinked")
        delta = counts.delta_count(self.repo, self.base, linked)
        self.assertEqual(delta.by_package("global_mutable_statics"), {"Unlinked": 1})
        self.assertEqual(delta.by_package("observer_sites"), {"Unlinked": 1})
        self.assertEqual(delta.by_package("layer_soft"), {}, "service -> core points down")
        self.assert_matches_full(self.base, linked)

    def test_delta_equals_full_on_a_range_that_changes_only_a_shared_manifest_to_drop_a_package(self):
        # Dropping Deep takes its sources, its target and the soft edge out.
        self.write(f"{SHARED}/Package.swift", CLOSURE_SHARED.replace('.package(path: "../Deep")', "")
                   .replace('.product(name: "DeepKit", package: "Deep")', "") % ("", ""))
        dropped = self.commit("SharedKit drops Deep")
        delta = counts.delta_count(self.repo, self.base, dropped)
        self.assertEqual(delta.by_package("global_mutable_statics"), {"DeepCore": -1})
        self.assertEqual(delta.by_package("layer_soft"), {"SharedKit": -1})
        self.assert_matches_full(self.base, dropped)

    def test_a_module_name_two_packages_use_is_reported_not_merged(self):
        self.write(f"{DEEP}/Sources/CmuxNextDomain/Dup.swift", "var dup = 0\n")
        head = self.commit("a second CmuxNextDomain")
        with self.assertRaises(counts.AmbiguousModule) as raised:
            counts.full_count(self.repo, head)
        self.assertIn(ROOT_PKG, str(raised.exception))
        self.assertIn(DEEP, str(raised.exception))
        with self.assertRaises(counts.AmbiguousModule):
            counts.delta_count(self.repo, self.base, head)


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
