#!/usr/bin/env python3
"""The pre-push arch ratchet (scripts/cmux-next/arch-ratchet.py, arch_counts.py) on throwaway git repos.

Each test commits a base and a head into a temporary repository and asks the ratchet about base..head:
a new stateful singleton under any name or spelling (a file-scope global, `static weak var`, a closure or
factory initializer, a struct that holds a stateful object, a protocol annotation, a class two links away),
a static Mutex or var, a new Notification.Name, an assumeIsolated in a deinit or under another call's proof,
a KVO or CFNotificationCenter observer and a new hard layer edge are refused; a value `static let standard`,
a singleton moved to another package and an adapter type with `main-proof:` pass, while a proved call in an
extension or a free function does not; a name that looks like an association key does not hide a static;
one-line declarations count; a swap (one singleton or broadcast removed, another added) is refused. A push
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
        self.assertNotEqual(self.git("merge-base", base, "upstream"), base)  # two ranges: base..head, upstream..head
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
                "    return [(ID, 'first', ('a',)), (ID, 'second', ('b',))], []\n")
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
