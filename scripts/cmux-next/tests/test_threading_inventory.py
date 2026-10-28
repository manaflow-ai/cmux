#!/usr/bin/env python3
"""threading-inventory.py (p02-threads-001) on fixture trees, and its acceptance counts on 772cdfc45ac.

--task-graph (p02-threads-110) expands a fixture plan (files, folders, globs, `{a,b}`, a range over a queue
placeholder, prose) and orders each shared file's owners into one per wave; on 772cdfc45ac it lists
AcpmuxEnvironment+BuildHomeAdoption.swift under 036/038/047/060 and leaves 0 shared files per wave.

The fixture has hits of every rule (main-blocking, raw-blocking, raw-blocking-ext, maybe-main-blocking, task-priority,
thread-doc, once-blocking, cpu-intensive: raw JSON, property list, image and regex calls on the main thread, not off it in the
main-actor target nor in another target), an `await backoff.wait(` that no rule reports, a sync main-actor function
with 4 call sites (a comment, a string, a declaration and a call from another module do not count), and the isolation
forms the JSONL names (main, pool, nonisolated, actor). The CLI runs on a throwaway git repo with sockets switched off
and must leave every file as it
was (no __pycache__ either, nothing left in TMPDIR).

Smaller trees pin the context reader: escaping closures (`readabilityHandler = {`, a completion, `@Sendable`) are
`unknown` while inline ones (`forEach`, `Task {`, `{ ... }()`, control flow) keep their function's isolation; main
openers win over pool openers; an actor's static members are not actor-isolated; `@MainActor @Observable` on one
line states isolation. caller_count follows access (a public member of an unmarked extension is called from other
modules), argument labels and receivers (`registry.bind(` is not `Handlers.bind(into:context:)`, `items.remove(at:)`
is not `remove(_:)`), and two split call-graph components with one root name get distinct labels.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the inventory:
  python3 -m pytest scripts/cmux-next/tests/test_threading_inventory.py
  python3 -I scripts/cmux-next/tests/test_threading_inventory.py
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # loading the tool below must not write __pycache__ beside it

import importlib.util

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parents[1]
TOOL = SCRIPTS / "threading-inventory.py"
_spec = importlib.util.spec_from_file_location("cmux_next_threading_inventory", TOOL)
inventory = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = inventory
_spec.loader.exec_module(inventory)

SRC = "Packages/macOS/CmuxNext/Sources/"
MANIFEST = """// swift-tools-version: 6.2
import PackageDescription

let uiSwiftSettings: [SwiftSetting] = [.defaultIsolation(MainActor.self)]
let coreSwiftSettings: [SwiftSetting] = []

let package = Package(
    name: "CmuxNext",
    targets: [
        .target(name: "CmuxNextUI", swiftSettings: uiSwiftSettings),
        .target(name: "CmuxNextCore", swiftSettings: coreSwiftSettings),
    ]
)
"""
THREADING_DOC = """# Threading model

## Registered threads and queues

- `com.cmuxterm.next.listed`: the listed queue.
- `com.cmuxterm.next.fence`: the fence's queue.

## Reviewed blocking allowances
"""
FIXTURE = {
    # A sync main-actor function (the UI target is main actor by default) that reads a file: main-blocking, and
    # raw-blocking (the raw primitive still needs its seam). Four call sites in its module.
    SRC + "CmuxNextUI/Loader.swift": """import Foundation

final class Loader {
    func loadThing(url: URL) -> Data? {
        return try? Data(contentsOf: url)
    }
}
""",
    SRC + "CmuxNextUI/Callers.swift": """import Foundation

final class Screen {
    let loader = Loader()

    func show(_ url: URL) {
        _ = loader.loadThing(url: url)
        _ = loader.loadThing(url: url.appendingPathComponent("a"))
        // loadThing(url:) is not a call in a comment
        let label = "loadThing(url:)"
        _ = label
    }

    func refresh(_ url: URL) {
        if loader.loadThing(url: url) == nil { _ = loader.loadThing(url: url) }
    }
}
""",
    # cpu-intensive: raw JSON, plist, image and regex calls on main in a main-actor target (also in
    # an inline `map {}`). A keyed container's
    # decode, a `matches(in:)` with no `range:` (not NSRegularExpression's), the seam and an escaped line are not hits.
    SRC + "CmuxNextUI/Restorer.swift": """import AppKit

struct Saved: Decodable {
    var name: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
    }
}

final class Restorer {
    func restore(_ data: Data) -> Saved? {
        try? JSONDecoder().decode(Saved.self, from: data)
    }

    func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    func picture(_ data: Data) -> NSImage? {
        NSImage(data: data)
    }

    func links(_ text: String, _ detector: NSDataDetector) -> Int {
        detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).count
    }

    func ranked(_ ranker: Ranker, _ items: [String]) -> Int {
        ranker.matches(in: items, for: "a").count
    }

    func checked(_ data: Data) -> Saved? {
        try? JSONDecoder().blockingDecode(Saved.self, from: data)
    }

    func reviewed(_ data: Data) -> Any? {
        // blocking-allow: the fixture's reviewed small parse
        try? JSONSerialization.jsonObject(with: data)
    }

    func settings(_ data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    func bitmap(_ data: Data) -> NSBitmapImageRep? {
        NSBitmapImageRep(data: data)
    }

    func filtered(_ data: Data) -> CIImage? {
        CIImage(data: data)
    }

    func all(_ items: [Data]) -> [Saved?] {
        items.map { item in
            try? JSONDecoder().decode(Saved.self, from: item)
        }
    }
}
""",
    # The same raw decodes in the main-actor target but off the main thread: in a detached task (the pool, also on
    # one line), in an actor's method, in a nonisolated function and in a `@concurrent` one. None is a hit: the seam's
    # off-main call is the plain call.
    SRC + "CmuxNextUI/Decoders.swift": """import Foundation

final class Importer {
    func start(_ data: Data) {
        // qos-allow: the fixture's pool closure
        Task.detached(priority: .utility) {
            _ = try? JSONDecoder().decode([String].self, from: data)
        }
        // qos-allow: the fixture's one-line pool closure
        Task.detached(priority: .utility) { _ = try? JSONSerialization.jsonObject(with: data) }
    }

    nonisolated func plain(_ data: Data) -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }

    @concurrent func pooled(_ data: Data) async -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }
}

actor DecodeCache {
    func load(_ data: Data) -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }
}
""",
    # The same raw decode in a target that is not main-actor by default: not a cpu-intensive hit.
    SRC + "CmuxNextCore/Wire.swift": """import Foundation

struct Wire {
    func read(_ data: Data) -> [String]? {
        try? JSONDecoder().decode([String].self, from: data)
    }
}
""",
    # Same name in another module: internal functions are called only from their own module.
    SRC + "CmuxNextCore/Other.swift": """import Foundation

struct OtherLoader {
    func loadThing(url: URL) -> Int { 0 }
    func use(_ url: URL) -> Int { loadThing(url: url) }
}
""",
    SRC + "CmuxNextCore/Reader.swift": """import Foundation

public struct Reader {
    public func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    public func caller(_ url: URL) async -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @concurrent public func offMain(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    func waits(_ backoff: Backoff) async throws {
        try await backoff.wait(owner: "reader")
    }
}

actor Store {
    func save(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }
}
""",
    SRC + "CmuxNextCore/Work.swift": """import Foundation

enum Work {
    static func start() {
        Task.detached {
            print("unstated")
        }
        Task(priority: .utility) {
            print("stated")
        }
    }

    static let unlisted = DispatchQueue(label: "com.cmuxterm.next.unlisted", qos: .utility)
    static let listed = DispatchQueue(label: "com.cmuxterm.next.listed", qos: .utility)
}
""",
    # sync-inversion: a public nonisolated function waits for a utility queue, and a main-actor
    # function of the UI target calls it.
    SRC + "CmuxNextCore/Fence.swift": """import Foundation

public final class Fence {
    let queue = DispatchQueue(label: "com.cmuxterm.next.fence", qos: .utility)

    public init() {}

    public func close() {
        queue.blockingSync {}
    }
}
""",
    SRC + "CmuxNextUI/FenceOwner.swift": """import Foundation

final class FenceOwner {
    let fence = Fence()

    func shut() {
        fence.close()
    }
}
""",
    # awaited-low-priority: a stored background task that a main-actor method awaits, and a
    # fire-and-forget one (a plain `Task(priority:)` states its priority: no task-priority hit).
    SRC + "CmuxNextUI/Saver.swift": """import Foundation

final class Saver {
    private var lastWrite: Task<Void, Never>?

    func save() {
        lastWrite = Task(priority: .background) { print("written") }
        Task(priority: .background) { print("forgotten") }
    }

    func flush() async {
        await lastWrite?.value
    }
}
""",
    # Two functions with hits where one calls the other (one call-graph root), and one unrelated function.
    SRC + "CmuxNextCore/Graph.swift": """import Foundation

struct Graph {
    func top(_ url: URL) {
        _ = FileManager.default.fileExists(atPath: url.path)
        helper(url)
    }

    func helper(_ url: URL) {
        _ = try? Data(contentsOf: url)
    }
}

struct Lone {
    func alone(_ url: URL) {
        _ = FileManager.default.fileExists(atPath: url.path)
    }
}
""",
    # raw-blocking-ext: a FileManager through a variable and a POSIX call; the `stat()` initializer is not one.
    SRC + "CmuxNextCore/Posix.swift": """import Foundation

struct Posix {
    let files: FileManager = .default

    func tidy(_ path: String) -> Bool {
        var info = stat()
        try? files.removeItem(atPath: path)
        return info.st_size == 0
    }
}
""",
    # once-blocking: a seam in an immediately called static initializer closure (no other rule:
    # a seam off the main thread is fine, but here it blocks whichever thread reads `list` first).
    SRC + "CmuxNextCore/Words.swift": """import Foundation

enum Words {
    static let list: [String] = {
        (try? String(blockingContentsOf: url, encoding: .utf8))?.components(separatedBy: "\\n") ?? []
    }()
    static let limit = 2048
}
""",
}


def tree(sources: dict[str, str] | None = None) -> "inventory.Tree":
    return inventory.Tree(dict(FIXTURE if sources is None else sources), THREADING_DOC, MANIFEST)


def hit(hits, rule: str, text: str, file: str = ""):
    found = [h for h in hits if h.rule == rule and text in h.text and h.path.endswith("/" + file if file else "")]
    assert len(found) == 1, f"{rule} {text!r}: {[(h.rule, h.path, h.line, h.text) for h in hits]}"
    return found[0]


class RuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.hits = inventory.inventory(tree())

    def test_one_hit_per_rule(self):
        self.assertEqual(set(h.rule for h in self.hits), set(inventory.RULES))
        hit(self.hits, "main-blocking", "Data(contentsOf: url)")
        hit(self.hits, "maybe-main-blocking", "String(contentsOf: url")
        hit(self.hits, "task-priority", "Task.detached {")
        hit(self.hits, "thread-doc", "com.cmuxterm.next.unlisted")
        # Reader.offMain is @concurrent and Store.save an actor method with no custom executor.
        self.assertEqual({(h.enclosing_func, h.isolation) for h in self.hits if h.rule == "pool-blocking"},
                         {("Reader.offMain", "pool"), ("Store.save", "actor")})
        hit(self.hits, "raw-blocking-ext", "files.removeItem(atPath: path)")
        self.assertEqual(hit(self.hits, "awaited-low-priority", "lastWrite = Task(").enclosing_func, "Saver.save")

    def test_cpu_intensive_lists_raw_long_cpu_calls_that_run_on_the_main_thread(self):
        found = [h for h in self.hits if h.rule == "cpu-intensive"]
        self.assertEqual({(h.path.rsplit("/", 1)[1], h.text) for h in found}, {
            ("Restorer.swift", "try? JSONDecoder().decode(Saved.self, from: data)"),
            ("Restorer.swift", "try? JSONSerialization.jsonObject(with: data)"),
            ("Restorer.swift", "NSImage(data: data)"),
            ("Restorer.swift", "detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).count"),
            ("Restorer.swift", "try? PropertyListSerialization.propertyList(from: data, format: nil)"),
            ("Restorer.swift", "NSBitmapImageRep(data: data)"),
            ("Restorer.swift", "CIImage(data: data)"),
            ("Restorer.swift", "try? JSONDecoder().decode(Saved.self, from: item)"),
        })
        self.assertTrue(all(h.ui_target and h.isolation == "main" for h in found), found)
        self.assertEqual(hit(found, "cpu-intensive", "from: data)").enclosing_func, "Restorer.restore")
        self.assertEqual(hit(found, "cpu-intensive", "from: item").enclosing_func, "Restorer.all")
        # Off the main thread in the main-actor target (Decoders.swift): the pool, an actor, nonisolated, @concurrent.
        self.assertFalse([h for h in found if h.path.endswith("/Decoders.swift")], found)

    def test_raw_blocking_lists_the_raw_primitives_main_blocking_took(self):
        raw = {(h.path.rsplit("/", 1)[1], h.text) for h in self.hits if h.rule == "raw-blocking"}
        self.assertIn(("Loader.swift", "return try? Data(contentsOf: url)"), raw)
        self.assertIn(("Reader.swift", "try data.write(to: url)"), raw)

    def test_await_wait_and_stated_calls_are_not_hits(self):
        texts = [h.text for h in self.hits]
        self.assertFalse([t for t in texts if "backoff.wait" in t], texts)
        self.assertFalse([t for t in texts if "priority: .utility" in t or "next.listed" in t], texts)

    def test_rules_are_guardrails_own(self):
        guardrails = inventory.g
        self.assertEqual(Path(guardrails.__file__).resolve(), (SCRIPTS / "guardrails.py").resolve())
        for rule_id in ("main-blocking", "pool-blocking", "maybe-main-blocking", "task-priority", "thread-doc"):
            self.assertIs(inventory.RULES[rule_id], inventory.RULE_BY_ID[rule_id].find)

    def test_sync_main_function_with_four_callers(self):
        found = hit(self.hits, "main-blocking", "Data(contentsOf: url)")
        self.assertEqual(found.enclosing_func, "Loader.loadThing")
        self.assertEqual(found.isolation, "main")
        self.assertIs(found.is_async, False)
        self.assertTrue(found.ui_target)
        self.assertEqual(found.module, "CmuxNextUI")
        self.assertEqual(found.caller_count, 4)

    def test_isolation_and_async(self):
        reader = hit(self.hits, "raw-blocking", "try? Data(contentsOf: url)", "Reader.swift")
        self.assertEqual((reader.enclosing_func, reader.isolation, reader.is_async), ("Reader.read", "nonisolated", False))
        caller = hit(self.hits, "maybe-main-blocking", "String(contentsOf: url")
        self.assertEqual((caller.enclosing_func, caller.isolation, caller.is_async), ("Reader.caller", "nonisolated", True))
        off = hit(self.hits, "raw-blocking", "try Data(contentsOf: url)")
        self.assertEqual((off.enclosing_func, off.isolation, off.is_async), ("Reader.offMain", "pool", True))
        store = hit(self.hits, "raw-blocking", "data.write(to: url)")
        self.assertEqual((store.enclosing_func, store.isolation, store.enclosing_type), ("Store.save", "actor", "Store"))
        detached = hit(self.hits, "task-priority", "Task.detached {")
        self.assertEqual((detached.enclosing_func, detached.isolation), ("Work.start", "nonisolated"))
        queue = hit(self.hits, "thread-doc", "next.unlisted")
        self.assertEqual((queue.enclosing_func, queue.is_async, queue.caller_count, queue.enclosing_type),
                         (None, None, None, "Work"))

    def test_closures_name_their_thread(self):
        source = {SRC + "CmuxNextCore/Hops.swift": """import Foundation

struct Hops {
    func hop(_ url: URL, queue: DispatchQueue) {
        queue.async {
            _ = try? Data(contentsOf: url)
        }
        Task { @MainActor in
            _ = try? String(contentsOf: url, encoding: .utf8)
        }
    }
}
"""}
        hits = inventory.inventory(tree(source))
        self.assertEqual(hit(hits, "raw-blocking", "Data(contentsOf").isolation, "pool")
        self.assertEqual(hit(hits, "main-blocking", "String(contentsOf").isolation, "main")

    def test_attribute_on_its_own_line(self):
        # guardrails' block_header stops at an attribute line; the inventory reads the attribute into the declaration.
        source = {SRC + "CmuxNextCore/Off.swift": """import Foundation

struct Off {
    @concurrent
    func load(
        _ url: URL
    ) async throws -> Data {
        try Data(contentsOf: url)
    }

    @MainActor
    func show(_ url: URL) {
        _ = try? Data(contentsOf: url)
    }
}
"""}
        hits = [h for h in inventory.inventory(tree(source)) if h.rule == "raw-blocking"]
        load = hit(hits, "raw-blocking", "try Data(contentsOf")
        self.assertEqual((load.enclosing_func, load.isolation, load.is_async), ("Off.load", "pool", True))
        show = hit(hits, "raw-blocking", "_ = try? Data(contentsOf")
        self.assertEqual((show.enclosing_func, show.isolation, show.is_async), ("Off.show", "main", False))

    def test_attributes_sharing_a_line(self):
        # guardrails' ATTRIBUTE_LINE takes one attribute per line; `@MainActor @Observable` still states isolation.
        source = {SRC + "CmuxNextCore/Phone.swift": """import Foundation

@MainActor @Observable
public final class Phone {
    public func shot(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

@Observable @MainActor
final class Recorder {
    func clip(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
"""}
        hits = [h for h in inventory.inventory(tree(source)) if h.rule == "raw-blocking"]
        self.assertEqual(hit(hits, "raw-blocking", "Data(contentsOf").isolation, "main")
        self.assertEqual(hit(hits, "raw-blocking", "fileExists").isolation, "main")

    def test_escaping_closures_are_unknown_and_inline_ones_inherit(self):
        # A handler the system calls later on its own queue is not main code, though its function is.
        source = {SRC + "CmuxNextUI/Shell.swift": """import Foundation

final class Shell {
    func run(_ reader: FileHandle, center: Center, request: Request, file: URL) {
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            _ = data
        }
        center.add(request) { error in
            try? FileManager.default.removeItem(at: file)
        }
        let work: @Sendable () -> Void = {
            _ = try? Data(contentsOf: file)
        }
        let later = { @Sendable in
            _ = try? String(contentsOf: file, encoding: .utf8)
        }
        [file].forEach { url in
            _ = FileManager.default.fileExists(atPath: url.path)
        }
        Task {
            _ = FileManager.default.contents(atPath: file.path)
        }
        let size: Int = {
            (try? FileManager.default.attributesOfItem(atPath: file.path))?.count ?? 0
        }()
        defer {
            _ = try? FileManager.default.contentsOfDirectory(atPath: file.path)
        }
        if size > 0 {
            _ = FileManager.default.isExecutableFile(atPath: file.path)
        }
        for url in [file].flatMap({ url in [url].map { $0 } }) {
            _ = try? url.resourceValues(forKeys: [.fileSizeKey])
        }
    }
}
"""}
        hits = [h for h in inventory.inventory(tree(source)) if h.rule == "raw-blocking"]
        isolation = {text: hit(hits, "raw-blocking", text).isolation for text in (
            "availableData", "removeItem", "Data(contentsOf", "String(contentsOf", "fileExists", "contents(atPath",
            "attributesOfItem", "contentsOfDirectory", "isExecutableFile", "resourceValues")}
        self.assertEqual(isolation, {
            "availableData": "unknown", "removeItem": "unknown", "Data(contentsOf": "unknown",
            "String(contentsOf": "unknown", "fileExists": "main", "contents(atPath": "main",
            "attributesOfItem": "main", "contentsOfDirectory": "main", "isExecutableFile": "main",
            "resourceValues": "main"})

    def test_main_openers_before_pool_openers(self):
        source = {SRC + "CmuxNextCore/Later.swift": """import Foundation

struct Later {
    func go(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            _ = try? Data(contentsOf: url)
        }
        Task.detached { @MainActor in
            _ = try? String(contentsOf: url, encoding: .utf8)
        }
        Task.detached {
            _ = FileManager.default.fileExists(atPath: url.path)
        }
    }

    func pick(_ kind: Int, _ url: URL) async -> Data? {
        switch kind {
        case 1: return await Task.detached { FileManager.default.contents(atPath: url.path) }.value
        default: return nil
        }
    }
}
"""}
        hits = [h for h in inventory.inventory(tree(source)) if h.rule == "raw-blocking"]
        self.assertEqual(hit(hits, "raw-blocking", "Data(contentsOf").isolation, "main")
        self.assertEqual(hit(hits, "raw-blocking", "String(contentsOf").isolation, "main")
        self.assertEqual(hit(hits, "raw-blocking", "fileExists").isolation, "pool")
        self.assertEqual(hit(hits, "raw-blocking", "contents(atPath").isolation, "pool")

    def test_static_members_of_an_actor_are_not_isolated_to_it(self):
        source = {SRC + "CmuxNextCore/Installer.swift": """import Foundation

actor Installer {
    static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?.count ?? 0
    }

    func save(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    static let probe = FileManager.default.fileExists(atPath: "/tmp")
}
"""}
        hits = [h for h in inventory.inventory(tree(source)) if h.rule == "raw-blocking"]
        size = hit(hits, "raw-blocking", "attributesOfItem")
        self.assertEqual((size.enclosing_func, size.isolation), ("Installer.size", "nonisolated"))
        self.assertEqual(hit(hits, "raw-blocking", "data.write").isolation, "actor")
        self.assertEqual(hit(hits, "raw-blocking", "fileExists").isolation, "nonisolated")

    def test_rule_and_path_filters(self):
        only = inventory.inventory(tree(), ["task-priority"], inventory.path_matcher([SRC + "CmuxNextCore/Work.swift"]))
        self.assertEqual([(h.rule, h.text) for h in only], [("task-priority", "Task.detached {")])
        globbed = inventory.inventory(tree(), ["raw-blocking"], inventory.path_matcher([SRC + "CmuxNextUI/*.swift"]))
        self.assertEqual({h.module for h in globbed}, {"CmuxNextUI"})
        self.assertEqual(inventory.inventory(tree(), ["raw-blocking"], inventory.path_matcher([SRC + "Nothing/"])), [])


class SyncInversionTests(unittest.TestCase):
    """sync-inversion: a sync wait onto a serial queue whose declared QoS is below the waiter's."""

    SOURCES = {
        SRC + "CmuxNextUI/Lane.swift": """import Foundation

final class Lane {
    private let low = DispatchQueue(label: "com.cmuxterm.next.low", qos: .utility)
    private let high: DispatchQueue
    private let lowest = DispatchQueue(label: "com.cmuxterm.next.lowest", qos: .background)
    private let plain = DispatchQueue(label: "com.cmuxterm.next.plain")
    private let follower = DispatchQueue(label: "com.cmuxterm.next.follower", target: .main)

    init() {
        self.high = DispatchQueue(label: "com.cmuxterm.next.high",
                                  qos: .userInteractive)
    }

    func close() {
        low.sync { print("inverted") }
        high.blockingSync { print("equal") }
        plain.blockingSync { print("plain") }
        follower.sync { print("targets another queue") }
        DispatchQueue.global(qos: .utility).sync { print("global") }
        // blocking-allow: a reviewed wait
        low.sync { print("escaped") }
        allowBlocking(.terminate) {
            low.blockingSync { print("terminate") }
        }
    }

    func offMain() {
        low.async {
            self.lowest.sync { print("below the low queue") }
            self.low.sync { print("never: the same queue") }
            self.high.sync { print("above") }
        }
    }
}
""",
        # The waits sit in an extension of a core type in another file; only a main-actor caller makes one a hit.
        SRC + "CmuxNextCore/Store.swift": """import Foundation

public final class Store {
    let queue = DispatchQueue(label: "com.cmuxterm.next.store", qos: .utility)
    public init() {}
}
""",
        SRC + "CmuxNextCore/Store+Wait.swift": """import Foundation

extension Store {
    public func save() {
        queue.blockingSync { print("saved") }
    }

    public func flush() {
        queue.blockingSync { print("flushed") }
    }

    public func load() async {
        queue.blockingSync { print("async: its callers are not judged") }
    }
}
""",
        SRC + "CmuxNextUI/StoreOwner.swift": """import Foundation

final class StoreOwner {
    let store = Store()

    func quit() {
        store.save()
    }

    func later() async {
        await store.load()
    }
}
""",
    }

    @classmethod
    def setUpClass(cls):
        cls.hits = inventory.inventory(tree(cls.SOURCES), ["sync-inversion"])
        cls.texts = {h.text for h in cls.hits}

    def test_a_main_thread_wait_onto_a_lower_queue(self):
        self.assertIn('low.sync { print("inverted") }', self.texts)
        self.assertIn('plain.blockingSync { print("plain") }', self.texts)  # no qos: default, below the main thread
        self.assertIn('DispatchQueue.global(qos: .utility).sync { print("global") }', self.texts)
        self.assertEqual(hit(self.hits, "sync-inversion", "inverted").isolation, "main")

    def test_equal_or_unknown_queues_and_reviewed_waits_are_not_hits(self):
        for text in ("equal", "targets another queue", "escaped", "terminate"):
            self.assertFalse([t for t in self.texts if text in t], self.texts)

    def test_a_queue_closure_waits_at_its_queues_qos(self):
        self.assertIn('self.lowest.sync { print("below the low queue") }', self.texts)
        for text in ("never: the same queue", "above"):
            self.assertFalse([t for t in self.texts if text in t], self.texts)

    def test_a_nonisolated_wait_is_judged_by_its_callers(self):
        save = hit(self.hits, "sync-inversion", "saved")
        self.assertEqual((save.enclosing_func, save.caller_count), ("Store.save", 1))
        for text in ("flushed", "async: its callers are not judged"):
            self.assertFalse([t for t in self.texts if text in t], self.texts)

    def test_nothing_else_is_a_hit(self):
        self.assertEqual(len(self.hits), 5, [(h.line, h.text) for h in self.hits])


class CallerCountTests(unittest.TestCase):
    def counts(self, sources: dict[str, str]) -> dict[str, int | None]:
        hits = inventory.inventory(tree(sources), ["raw-blocking"])
        return {h.enclosing_func: h.caller_count for h in hits}

    def test_public_member_of_an_unmarked_extension_is_called_from_other_modules(self):
        counts = self.counts({
            SRC + "CmuxNextCore/Box.swift": """import Foundation

public struct Box {
    public init() {}
}

extension Box {
    public func fetch(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}

internal extension Box {
    func peek(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

private extension Box {
    func hidden(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: url.path)
    }
}
""",
            SRC + "CmuxNextUI/UseBox.swift": """import Foundation
import CmuxNextCore

final class UseBox {
    func use(_ url: URL) {
        _ = Box().fetch(url)
        _ = Box().peek(url)
        _ = Box().hidden(url)
    }
}
"""})
        self.assertEqual((counts["Box.fetch"], counts["Box.peek"], counts["Box.hidden"]), (1, 0, 0))

    def test_labels_and_receiver_pick_the_call_sites(self):
        counts = self.counts({
            SRC + "CmuxNextCore/Handlers.swift": """import Foundation

enum Handlers {
    static func bind(into registry: Registry, context: Context) {
        _ = FileManager.default.fileExists(atPath: context.path)
    }
}

final class Backups {
    func remove(_ id: String) {
        try? FileManager.default.removeItem(atPath: id)
    }

    func load(_ id: String, completion: @escaping (Data?) -> Void) {
        completion(FileManager.default.contents(atPath: id))
    }

    func each(_ body: () -> Void) {
        _ = FileManager.default.isExecutableFile(atPath: "/each")
        body()
    }
}
""",
            SRC + "CmuxNextCore/Wiring.swift": """import Foundation

struct Wiring {
    func wire(_ registry: Registry, _ context: Context, backups: Backups, items: inout [Int]) {
        Handlers.bind(into: registry, context: context)
        registry.bind("a") { _ in }
        registry.bind("b", to: 1)
        backups.remove("x")
        items.remove(at: 0)
        items.remove(
            at: 1
        )
        backups.load("y") { _ in }
        backups.load(
            "z",
            completion: { _ in }
        )
        backups.load { _ in }
        backups.each {
            print("each")
        }
    }
}
"""})
        self.assertEqual({k: counts[k] for k in ("Handlers.bind", "Backups.remove", "Backups.load", "Backups.each")},
                         {"Handlers.bind": 1, "Backups.remove": 1, "Backups.load": 2, "Backups.each": 1})


class GroupTests(unittest.TestCase):
    def setUp(self):
        self.tree = tree()
        self.hits = inventory.inventory(self.tree, ["raw-blocking"])

    def test_root_joins_a_caller_and_its_callee(self):
        groups = dict(inventory.group_by_root(self.tree, self.hits, 25))
        by_func = {h.enclosing_func: label for label, chunk in groups.items() for h in chunk}
        self.assertEqual(by_func["Graph.top"], by_func["Graph.helper"])
        self.assertTrue(by_func["Graph.top"].startswith("root:CmuxNextCore/Graph.top"), by_func)
        self.assertNotEqual(by_func["Lone.alone"].split("/")[0], by_func["Loader.loadThing"].split("/")[0])

    def test_chunks_hold_at_most_max_hits(self):
        for grouping in (lambda n: inventory.group_by_root(self.tree, self.hits, n),
                         lambda n: inventory.group_by_module(self.hits, n)):
            groups = grouping(1)
            self.assertTrue(all(len(chunk) == 1 for _, chunk in groups))
            self.assertEqual(sum(len(chunk) for _, chunk in groups), len(self.hits))
            self.assertEqual(len({label for label, _ in groups}), len(groups))

    def test_split_components_with_one_root_name_keep_apart(self):
        # Two initializers of one type in two files: same root label, each split into chunks.
        body = """    init({label} url: URL) {{
        _ = FileManager.default.fileExists(atPath: url.path)
        _ = try? Data(contentsOf: url)
    }}
"""
        sources = {SRC + "CmuxNextCore/FooA.swift": "import Foundation\n\nstruct Foo {\n" + body.format(label="a") + "}\n",
                   SRC + "CmuxNextCore/FooB.swift": "import Foundation\n\nextension Foo {\n" + body.format(label="b")
                   + "}\n"}
        fixture = tree(sources)
        hits = inventory.inventory(fixture, ["raw-blocking"])
        groups = inventory.group_by_root(fixture, hits, 1)
        labels = [label for label, _ in groups]
        self.assertEqual(len(labels), 4)
        self.assertEqual(len(set(labels)), len(labels), labels)

    def test_module_groups(self):
        labels = [label for label, _ in inventory.group_by_module(self.hits, 25)]
        self.assertEqual(labels, ["module:CmuxNextCore", "module:CmuxNextUI"])


PLAN = [
    {"id": "t-001", "files": [SRC + "CmuxNextCore/Reader.swift", SRC + "CmuxNextCore/{Graph,Wire}.swift"]},
    {"id": "t-002", "files": [SRC + "CmuxNextCore/Reader.swift", SRC + "CmuxNextCore/New.swift (new)"],
     "depends_on": ["t-003"]},
    {"id": "t-003", "files": [SRC + "CmuxNextCore/Reader.swift"]},
    {"id": "t-004", "files": [SRC + "CmuxNextCore/"]},
    {"id": "t-005", "files": [SRC + "CmuxNextUI/*.swift"]},
    {"id": "t-010..011", "files": [SRC + "<module>/"], "machine_queue": "MQ-1", "depends_on": ["t-001"]},
    {"id": "t-020", "files": ["origin/some-branch (abc1234)", "the design's list"]},
    {"id": "t-030", "files": [SRC + "CmuxNextUI/ (MQ-99 hits)"], "machine_queue": "MQ-99", "depends_on": ["t-404"]},
]
LISTING = [*FIXTURE, "Packages/macOS/CmuxNext/Package.swift"]


class TaskGraphTests(unittest.TestCase):
    """--task-graph (p02-threads-110): one owner per file per wave."""

    @classmethod
    def setUpClass(cls):
        cls.graph = inventory.build_task_graph(tree(), LISTING, {"tasks": PLAN})
        cls.shared = {path: (order, added) for path, order, added in cls.graph.shared}

    def test_file_lists_expand(self):
        files = {unit_id: set(unit.files) for unit_id, unit in self.graph.units.items()}
        core = {p for p in FIXTURE if "/CmuxNextCore/" in p}
        self.assertEqual(files["t-001"], {SRC + "CmuxNextCore/" + n for n in ("Reader.swift", "Graph.swift",
                                                                            "Wire.swift")})
        self.assertIn(SRC + "CmuxNextCore/New.swift", files["t-002"])  # a file the task creates
        self.assertEqual(files["t-004"], core)
        self.assertTrue(all(self.graph.units["t-004"].files.values()))  # a folder is directory-wide
        self.assertEqual(files["t-005"], {p for p in FIXTURE if "/CmuxNextUI/" in p})
        self.assertFalse(any(self.graph.units["t-005"].files.values()))  # a glob names its files

    def test_range_placeholder_resolves_to_the_queue_hits_split_in_path_order(self):
        # raw-blocking hits: Graph 3, Reader 4, Loader 1. Two ids cut them into runs of about equal weight.
        self.assertEqual(set(self.graph.units["t-010"].files), {SRC + "CmuxNextCore/Graph.swift",
                                                                 SRC + "CmuxNextCore/Reader.swift"})
        self.assertEqual(set(self.graph.units["t-011"].files), {SRC + "CmuxNextUI/Loader.swift"})
        self.assertTrue(all(self.graph.units["t-010"].files.values()))  # a module sweep goes after named files
        self.assertEqual(self.graph.units["t-011"].entry, "t-010..011")
        self.assertIn("t-001", self.graph.units["t-011"].depends_on)

    def test_owners_ordered_by_id_dependencies_and_directory_wide_last(self):
        # Files in path order: Graph.swift first orders t-001, then the directory-wide t-004 and t-010.
        self.assertEqual(self.shared[SRC + "CmuxNextCore/Graph.swift"],
                         (["t-001", "t-004", "t-010"], [("t-004", "t-001"), ("t-010", "t-004")]))
        order, added = self.shared[SRC + "CmuxNextCore/Reader.swift"]
        # t-002 waits for t-003 already; directory-wide t-004 and t-010 come after the tasks that name the file,
        # and t-010 already waits for t-004.
        self.assertEqual(order, ["t-001", "t-003", "t-002", "t-004", "t-010"])
        self.assertEqual(added, [("t-003", "t-001"), ("t-004", "t-002")])
        order, added = self.shared[SRC + "CmuxNextCore/Wire.swift"]
        self.assertEqual((order, added), (["t-001", "t-004"], []))  # t-004 already waits for t-001 (Reader)

    def test_one_owner_per_file_per_wave_after_the_edges(self):
        self.assertGreater(inventory.shared_per_wave(self.graph.units, self.graph.waves_before), 0)
        self.assertEqual(inventory.shared_per_wave(self.graph.units, self.graph.waves_after), 0)
        owners: dict = {}
        for unit in self.graph.units.values():
            for path in unit.files:
                owners.setdefault((self.graph.waves_after[unit.id], path), []).append(unit.id)
        self.assertEqual([k for k, v in owners.items() if len(v) > 1], [])

    def test_unreadable_entries_and_unknown_dependencies_are_reported(self):
        self.assertEqual([(t, e) for t, e, _ in self.graph.unresolved if t == "t-020"],
                         [("t-020", "origin/some-branch (abc1234)"), ("t-020", "the design's list")])
        # A queue the inventory has no rule for takes its whole folder, said so.
        notes = {t: n for t, _, n in self.graph.unresolved}
        self.assertIn("whole folder", notes["t-030"])
        self.assertEqual(set(self.graph.units["t-030"].files), {p for p in FIXTURE if "/CmuxNextUI/" in p})
        self.assertEqual(self.graph.unknown_dependencies, [("t-030", "t-404")])

    def test_a_cycle_is_an_error(self):
        plan = [{"id": "a", "files": [], "depends_on": ["b"]}, {"id": "b", "files": [], "depends_on": ["a"]}]
        with self.assertRaisesRegex(ValueError, "cycle"):
            inventory.build_task_graph(tree(), LISTING, plan)

    def test_every_folder_an_entry_names_in_prose_counts(self):
        plan = [{"id": "two", "files": [f"{SRC}CmuxNextCore/ and {SRC}CmuxNextUI/ packages (one chunk each)"],
                 "machine_queue": "MQ-99"}]
        graph = inventory.build_task_graph(tree(), LISTING, plan)
        self.assertEqual(set(graph.units["two"].files), set(FIXTURE))
        [(_, _, note)] = graph.unresolved
        self.assertIn(f"{SRC}CmuxNextCore/, {SRC}CmuxNextUI/", note)  # both folders, said so
        # With a rule, each named folder resolves to its hits.
        plan[0]["machine_queue"] = "MQ-1"
        graph = inventory.build_task_graph(tree(), LISTING, plan)
        self.assertEqual(set(graph.units["two"].files), {SRC + "CmuxNextCore/Graph.swift",
                                                         SRC + "CmuxNextCore/Reader.swift",
                                                         SRC + "CmuxNextUI/Loader.swift"})
        self.assertEqual(graph.unresolved, [])

    def test_ranges_without_parts_and_files_no_part_takes_are_reported(self):
        notes = [(t, n) for t, e, n in self.graph.unresolved if e == "(range)"]
        self.assertEqual(notes, [("t-010..011", "no RANGE_PARTS row: its files split in path order")])
        files = {SRC + "CmuxNextCore/Reader.swift": 1, SRC + "CmuxNextUI/Loader.swift": 1, "tool/src/main.rs": 1}
        split, orphans = inventory.split_range(["r-1", "r-2"], files, [(1, "Core"), (1, "tool/src/*")])
        self.assertEqual(split, [[SRC + "CmuxNextCore/Reader.swift"], ["tool/src/main.rs"]])
        self.assertEqual(orphans, [SRC + "CmuxNextUI/Loader.swift"])
        self.assertIn("CmuxNextUI", inventory.orphan_note(orphans))

    def test_selector_tokens(self):
        match = inventory.token_matches
        self.assertTrue(match("Browser..Daemon", SRC + "CmuxNextControl/A.swift"))
        self.assertTrue(match("Browser..Daemon", SRC + "CmuxNextBrowser/A.swift"))
        self.assertTrue(match("Browser..Daemon", SRC + "CmuxNextDaemonService/A.swift"))  # Last takes its prefixes
        self.assertFalse(match("Browser..Daemon", SRC + "CmuxNextWakeups/LaneScheduler.swift"))
        self.assertFalse(match("Browser..Daemon", SRC + "CmuxNextAgentPane/A.swift"))
        core = inventory.TUI_CORE
        self.assertTrue(match(core + "server*", core + "server/listen.rs"))
        self.assertTrue(match(core + "server*", core + "server.rs"))
        self.assertFalse(match(core + "server*", core + "session_shutdown.rs"))
        self.assertFalse(match("Core", "tool/CmuxNextCore/A.swift"))  # a module only under Sources/

    def test_design_ranges_split_into_their_ids(self):
        for task_id, parts in inventory.RANGE_PARTS.items():
            self.assertEqual(sum(count for count, _ in parts), len(inventory.range_ids(task_id)), task_id)
        self.assertEqual(inventory.range_ids("p02-threads-060..101")[-1], "p02-threads-101")
        self.assertEqual(len(inventory.range_ids("p02-threads-060..101")), 42)


def git(repo: Path, *args: str) -> None:
    env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
           "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env=env)


def snapshot(root: Path) -> dict[str, tuple[int, int]]:
    return {str(p.relative_to(root)): (p.stat().st_size, p.stat().st_mtime_ns)
            for p in root.rglob("*") if p.is_file()}


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.repo = Path(cls.tmp.name)
        files = {**FIXTURE, "Packages/macOS/CmuxNext/Package.swift": MANIFEST,
                 "plans/cmux-next/threading-model.md": THREADING_DOC}
        for path, text in files.items():
            (cls.repo / path).parent.mkdir(parents=True, exist_ok=True)
            (cls.repo / path).write_text(text)
        git(cls.repo, "init", "-q")
        git(cls.repo, "add", "-A")
        git(cls.repo, "commit", "-qm", "fixture")
        git(cls.repo, "gc", "-q")  # no loose objects git might pack later

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_main(self, *args: str) -> str:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(inventory.main(["--repo", str(self.repo), *args]), 0)
        return out.getvalue()

    def test_count_and_jsonl(self):
        counts = dict(line.split() for line in self.run_main("--count").splitlines())
        self.assertEqual({k: int(v) for k, v in counts.items()},
                         {"main-blocking": 1, "raw-blocking": 8, "pool-blocking": 2, "raw-blocking-ext": 1,
                          "maybe-main-blocking": 1,
                          "task-priority": 1, "thread-doc": 1, "cpu-intensive": 8, "sync-inversion": 1,
                          "once-blocking": 1, "awaited-low-priority": 1})
        records = [json.loads(line) for line in self.run_main("--rule", "main-blocking", "--jsonl").splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(set(records[0]), {"rule", "path", "line", "module", "ui_target", "text", "enclosing_func",
                                           "is_async", "isolation", "caller_count", "enclosing_type"})
        self.assertEqual((records[0]["line"], records[0]["caller_count"]), (5, 4))

    def test_group_flags(self):
        records = [json.loads(line) for line in
                   self.run_main("--rule", "raw-blocking", "--group", "root", "--max-hits", "2", "--jsonl").splitlines()]
        sizes: dict[str, int] = {}
        for record in records:
            sizes[record["group"]] = sizes.get(record["group"], 0) + 1
        self.assertTrue(sizes and max(sizes.values()) <= 2, sizes)
        text = self.run_main("--rule", "raw-blocking,task-priority", "--group", "module", "--count")
        self.assertIn("module:CmuxNextUI 1", text)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            inventory.main(["--repo", str(self.repo), "--max-hits", "3"])  # --max-hits needs --group
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            inventory.main(["--repo", str(self.repo), "--rule", "no-such-rule"])

    def test_no_network(self):
        def refuse(*args, **kwargs):
            raise AssertionError("threading-inventory opened a socket")
        saved = socket.socket, socket.create_connection, socket.getaddrinfo
        socket.socket = socket.create_connection = socket.getaddrinfo = refuse
        try:
            self.assertIn("raw-blocking 8", self.run_main("--count"))
        finally:
            socket.socket, socket.create_connection, socket.getaddrinfo = saved

    def test_no_writes(self):
        # The repo, the scripts tree and TMPDIR (where git_batch's unnamed request file lives while git reads it)
        # are left as they were.
        before, scripts_before = snapshot(self.repo), snapshot(SCRIPTS)
        with tempfile.TemporaryDirectory() as watched:
            env = {k: v for k, v in os.environ.items() if k != "PYTHONDONTWRITEBYTECODE"}
            env["TMPDIR"] = watched
            result = subprocess.run([sys.executable, str(TOOL), "--group", "root", "--jsonl"], cwd=self.repo,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip())
            self.assertEqual(os.listdir(watched), [])
        self.assertEqual(snapshot(self.repo), before)
        self.assertEqual(snapshot(SCRIPTS), scripts_before)

    def test_task_graph(self):
        with tempfile.TemporaryDirectory() as outside:
            plan = Path(outside) / "tasks.json"
            programs = {"p": {"tasks": PLAN}, "q": {"tasks": [{"id": "x", "files": []}]}}
            plan.write_text(json.dumps({"programs": programs}))
            before = snapshot(self.repo)
            lines = [json.loads(line) for line in
                     self.run_main("--task-graph", str(plan), "--program", "p", "--jsonl").splitlines()]
            self.assertEqual(snapshot(self.repo), before)
            text = self.run_main("--task-graph", str(plan))
        records = {r["file"]: r for r in lines if "file" in r}
        reader = records[SRC + "CmuxNextCore/Reader.swift"]
        self.assertEqual(reader["tasks"], ["t-001", "t-003", "t-002", "t-004", "t-010"])
        self.assertEqual(reader["resolution"]["depends_on"], [["t-003", "t-001"], ["t-004", "t-002"]])
        summary = lines[-1]["summary"]
        self.assertEqual(summary["shared_per_wave"]["after"], 0)
        self.assertEqual(summary["tasks"], 9)  # --program p: t-010..011 is two tasks, q's x is left out
        self.assertIn("shared files per wave", text)
        self.assertIn("unresolved t-020: the design's list (no path)", text)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            inventory.main(["--repo", str(self.repo), "--task-graph", "plan.json", "--rule", "raw-blocking"])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            inventory.main(["--repo", str(self.repo), "--program", "p"])  # --program needs --task-graph

    def test_task_graph_unknown_program_is_an_error(self):
        with tempfile.TemporaryDirectory() as outside:
            plan = Path(outside) / "tasks.json"
            plan.write_text(json.dumps({"programs": {"p02-threads": {"tasks": PLAN}}}))
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = inventory.main(["--repo", str(self.repo), "--task-graph", str(plan), "--program", "p02-thread"])
            self.assertEqual((rc, out.getvalue()), (2, ""))
            self.assertIn("no program p02-thread in the plan", err.getvalue())
            plan.write_text(json.dumps({"tasks": PLAN}))
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = inventory.main(["--repo", str(self.repo), "--task-graph", str(plan), "--program", "p"])
            self.assertEqual((rc, out.getvalue()), (2, ""))
            self.assertIn("--program needs a plan with programs", err.getvalue())


ACCEPTANCE_REV = "772cdfc45ac"
DESIGN_PLAN = REPO / "plans/cmux-next/chrome-parity/design-result.json"


def has_rev(rev: str) -> bool:
    return subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{rev}^{{commit}}"],
                          capture_output=True).returncode == 0


@unittest.skipUnless(has_rev(ACCEPTANCE_REV), f"{ACCEPTANCE_REV} is not in this clone")
class AcceptanceTests(unittest.TestCase):
    def test_counts_on_the_design_revision(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            inventory.main(["--repo", str(REPO), "--rev", ACCEPTANCE_REV, "--count", "--jsonl"])
        counts = json.loads(out.getvalue())["rules"]
        # 974 counted the primitive classes before p02-threads-002, which only adds classes (1097 with them).
        self.assertGreaterEqual(counts["raw-blocking"], 0.95 * 974, counts)
        self.assertGreaterEqual(counts["task-priority"], 120, counts)

    @unittest.skipUnless(DESIGN_PLAN.is_file(), "the chrome-parity plan is not in this checkout")
    def test_task_graph_on_the_design_revision(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            inventory.main(["--repo", str(REPO), "--rev", ACCEPTANCE_REV, "--task-graph", str(DESIGN_PLAN),
                            "--program", "p02-threads", "--jsonl"])
        lines = [json.loads(line) for line in out.getvalue().splitlines()]
        tasks = {r["file"].rsplit("/", 1)[-1]: r["tasks"] for r in lines if "file" in r}
        adoption = set(tasks["AcpmuxEnvironment+BuildHomeAdoption.swift"])
        self.assertLessEqual({f"p02-threads-{n}" for n in ("036", "038", "047", "060")}, adoption, adoption)
        lanes = set(tasks["LaneScheduler.swift"])
        self.assertLessEqual({f"p02-threads-{n}" for n in ("005", "015", "017", "114", "115", "116", "117", "118",
                                                           "119", "123", "125")}, lanes, lanes)
        # Wakeups is not in 043's Browser..Daemon, nor in any other part of 041-045.
        self.assertEqual({t for t in lanes if t in inventory.range_ids("p02-threads-041..045")}, set(), lanes)
        records = {r["file"]: r["tasks"] for r in lines if "file" in r}
        core, tui = "cmux-tui/crates/cmux-tui-core/src/", "cmux-tui/crates/cmux-tui/src/"
        self.assertIn("p02-threads-213", records[core + "server/listen.rs"])  # section 9: 213 takes server/
        self.assertNotIn("p02-threads-216", records[core + "server/listen.rs"])
        self.assertIn("p02-threads-217", records[tui + "main.rs"])  # 217 the cmux-tui binary
        self.assertNotIn("p02-threads-218", records[tui + "main.rs"])
        # 146 (MQ-17, no inventory rule) takes both folders its prose names, Shared and iOS.
        tasks = json.loads(DESIGN_PLAN.read_text())["programs"]["p02-threads"]["tasks"]
        [task] = [t for t in tasks if t["id"] == "p02-threads-146"]
        listing = inventory.g.git(REPO, "ls-tree", "-r", "--name-only", ACCEPTANCE_REV).split("\n")
        expander = inventory.Expander(inventory.Tree({}, None, None), [p for p in listing if p])
        files, note = expander.entry(task["files"][0], inventory.task_finders(task))
        self.assertEqual({p.split("/", 2)[1] for p in files}, {"Shared", "iOS"})
        self.assertIn("Packages/Shared/, Packages/iOS/", note)
        summary = lines[-1]["summary"]
        self.assertGreater(summary["shared_per_wave"]["before"], 0)
        self.assertEqual(summary["shared_per_wave"]["after"], 0)
        self.assertEqual(summary["unknown_dependencies"], [])


if __name__ == "__main__":
    unittest.main()
