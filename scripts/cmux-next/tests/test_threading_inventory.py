#!/usr/bin/env python3
"""threading-inventory.py (p02-threads-001) on fixture trees, and its acceptance counts on 772cdfc45ac.

The fixture has hits of every rule (main-blocking, raw-blocking, maybe-main-blocking, task-priority, thread-doc,
cpu-intensive: raw JSON, property list, image and regex calls on the main thread, not off it in the main-actor
target nor in another target), an
`await backoff.wait(` that no rule reports, a sync main-actor function with 4 call sites (a comment, a string, a
declaration and a call from another module do not count), and the isolation forms the JSONL names (main, pool,
nonisolated, actor). The CLI runs on a throwaway git repo with sockets switched off and must leave every file as it
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
    # cpu-intensive (p02-threads-121): raw JSON, plist, image and regex calls on main in a main-actor target (also in
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
                         {"main-blocking": 1, "raw-blocking": 8, "pool-blocking": 2, "maybe-main-blocking": 1,
                          "task-priority": 1, "thread-doc": 1, "cpu-intensive": 8})
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


ACCEPTANCE_REV = "772cdfc45ac"


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


if __name__ == "__main__":
    unittest.main()
