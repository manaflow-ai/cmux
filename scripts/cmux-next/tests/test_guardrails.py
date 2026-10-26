#!/usr/bin/env python3
"""guardrails.py's blocking rules see every blocking primitive class (p02-threads-002) and refuse blocking on a
shared pool thread (p02-threads-010).

Each new primitive (process launch, queue and thread waits, Security, AX, getaddrinfo, CGWindowList, LSCopy,
NSWorkspace queries, SMAppService, AuthorizationCopyRights, sync XPC proxies, AppleScript) is refused as
main-blocking in main-actor code and as raw-blocking in nonisolated code; the task 003 seams are refused on main
and pass off main; the async overloads (`try await service.unregister()`) and look-alikes (`self?.launch()`,
`icons.icon(for:)`) pass. pool-blocking refuses a raw or seam call in a Task.detached or child task body, an
`async let` initializer, a `Task {` in a nonisolated function, an @concurrent function and an actor method (also in
an extension in another file, and an `async` actor init), reads isolation from the declaration's prefix only, and
passes a `work.run` closure and an actor with a real custom executor (the HomeCache pattern; a comment is none).
The rules run on in-memory changes (as check() builds them); only the actor-index test makes a throwaway git
repository in a temporary folder.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the blocking rules:
  python3 -m pytest scripts/cmux-next/tests/test_guardrails.py
  python3 -I scripts/cmux-next/tests/test_guardrails.py
"""
from __future__ import annotations

import collections
import importlib.util
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # loading the tool below must not write __pycache__ beside it

SCRIPTS = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_p02_002", SCRIPTS / "guardrails.py")
guardrails = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = guardrails
_spec.loader.exec_module(guardrails)

SRC = "Packages/macOS/CmuxNext/Sources/"
UI = SRC + "CmuxNextUIKit"        # uiSwiftSettings: main-actor by default
SERVICE = SRC + "CmuxNextService"  # daemonSwiftSettings: nonisolated by default
MANIFEST = """// swift-tools-version: 6.2
let package = Package(name: "CmuxNext", targets: [
    .target(name: "CmuxNextUIKit", swiftSettings: uiSwiftSettings),
    .target(name: "CmuxNextService", swiftSettings: daemonSwiftSettings),
])
"""
DOC = "# threading model\n\n## Registered threads and queues\n\n- `com.cmuxterm.next.known`\n"

# One statement per new primitive class, as the code base writes it.
NEW_PRIMITIVES = [
    "try process.run()",
    "try box.process.run()",  # a chained receiver (CmuxNextDaemon/Launch/ProcessRunner.swift:74)
    "do { try process.run() } catch { failed(error) }",
    "try? helper.process.run()",
    "process.launch()",
    "operations.waitUntilAllOperationsAreFinished()",
    "queue.asyncAndWait { work() }",
    "queue.asyncAndWait(execute: work)",
    "pthread_join(thread, nil)",
    "pthread_cond_wait(&condition, &mutex)",
    "let gate = NSConditionLock(condition: 0)",
    "gate.lock(whenCondition: 1)",
    "let status = SecItemCopyMatching(query as CFDictionary, &result)",
    "_ = SecItemAdd(attributes as CFDictionary, nil)",
    "_ = SecItemUpdate(query as CFDictionary, changes as CFDictionary)",
    "_ = SecItemDelete(query as CFDictionary)",
    "let trusted = SecTrustEvaluateWithError(trust, &error)",
    "_ = SecStaticCodeCheckValidity(code, [], requirement)",
    "_ = SecCodeCopySelf([], &code)",
    "_ = SecCodeCopySigningInformation(code, flags, &info)",
    "_ = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value)",
    "_ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)",
    "_ = AXUIElementSetAttributeValue(element, attribute, value)",
    "let status = getaddrinfo(host, nil, &hints, &result)",
    "let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)",
    "let image = CGWindowListCreateImage(bounds, .optionIncludingWindow, id, [])",
    "let handlers = LSCopyAllRoleHandlersForContentType(type, .all)",
    "let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)",
    "let app = workspace.urlForApplication(toOpen: url)",
    "let apps = workspace.urlsForApplications(toOpen: type)",
    "let icon = NSWorkspace.shared.icon(forFile: path)",
    "let icon = NSWorkspace.shared.icon(for: .folder)",
    "let icon = workspace.icon(forFile: app.path)",
    "let status = SMAppService.agent(plistName: plistName).status",
    "let status = SMAppService.daemon(plistName: Constants().plistName).status",
    "try SMAppService.agent(plistName: plistName).register()",
    "try SMAppService.mainApp.unregister()",
    "_ = AuthorizationCopyRights(auth, &rights, nil, flags, nil)",
    "let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in }",
    "let result = script.executeAndReturnError(&error)",
]

# The task 003 seams: refused on main, fine off it.
SEAMS = [
    "_ = blockingSecItemCopyMatching(query as CFDictionary, &result)",
    "_ = blockingSecItemAdd(attributes as CFDictionary, nil)",
    "_ = blockingSecItemUpdate(query as CFDictionary, changes as CFDictionary)",
    "_ = blockingSecItemDelete(query as CFDictionary)",
    "_ = blockingSecTrustEvaluate(trust, &error)",
    "_ = blockingSecStaticCodeCheckValidity(code, [], requirement)",
    "_ = blockingSecCodeCopySelf([], &code)",
    "_ = blockingSecCodeCopySigningInformation(code, flags, &info)",
    "_ = blockingAXCopyAttributeValue(element, attribute, &value)",
    "_ = blockingAXSetAttributeValue(element, attribute, value)",
    "_ = blockingAXPerformAction(element, action)",
    "_ = blockingGetaddrinfo(host, nil, &hints, &result)",
    "_ = blockingWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)",
    "_ = blockingWindowListCreateImage(bounds, .optionIncludingWindow, id, [])",
    "_ = blockingWindowListCreateImageFromArray(bounds, ids, [])",
    "_ = workspace.blockingURLForApplication(withBundleIdentifier: id)",
    "_ = workspace.blockingURLsForApplications(toOpen: url)",
    "_ = workspace.blockingIcon(forFile: path)",
    "_ = blockingSMAppServiceStatus(service)",
    "try blockingSMAppServiceRegister(service)",
    "try blockingSMAppServiceUnregister(service)",
    "_ = blockingAuthorizationCopyRights(auth, &rights, nil, flags, nil)",
    "try process.blockingRun()",
    # the task 127 seams: POSIX files, waitpid, FileHandle, ImageIO, SQLite, kernel and directory queries, LAContext
    "let fd = blockingOpen(path, O_RDONLY)",
    "_ = blockingPread(fd, buffer, count, 0)",
    "_ = blockingPwrite(fd, buffer, count, 0)",
    "_ = blockingFsync(fd)",
    "_ = blockingFlock(fd, LOCK_EX)",
    "_ = blockingRename(from, to)",
    "_ = blockingUnlink(path)",
    "_ = blockingStat(path, &info)",
    "_ = blockingLstat(path, &info)",
    "free(blockingRealpath(path, nil))",
    "_ = blockingAccess(path, R_OK)",
    "_ = blockingMkdir(path, 0o700)",
    "_ = blockingRmdir(path)",
    "_ = blockingWaitpid(pid, &status, 0)",
    "let handle = try FileHandle.blockingForReading(from: url)",
    "let handle = try FileHandle.blockingForWriting(to: url)",
    "let handle = try FileHandle.blockingForUpdating(url)",
    "_ = try handle.blockingSeekToEnd()",
    "try handle.blockingSeek(toOffset: 0)",
    "try handle.blockingSynchronize()",
    "let source = blockingImageSource(url: url as CFURL)",
    "let destination = blockingImageDestination(url: url as CFURL, type: type, count: 1)",
    "_ = blockingImageDestinationFinalize(destination)",
    "_ = blockingSQLiteOpen(path, &db, flags)",
    "_ = blockingSQLitePrepare(db, sql, -1, &statement, nil)",
    "_ = blockingSQLiteStep(statement)",
    "_ = blockingSQLiteExec(db, sql)",
    "blockingSQLiteClose(db)",
    "_ = blockingSysctl(&mib, 2, &value, &size, nil, 0)",
    "_ = blockingSysctlByName(\"hw.memsize\", &value, &size, nil, 0)",
    "_ = blockingProcPidInfo(pid, PROC_PIDTBSDINFO, 0, &info, size)",
    "let entry = blockingGetpwuid(getuid())",
    "let entry = blockingGetpwnam(name)",
    "let available = context.blockingCanEvaluatePolicy(.deviceOwnerAuthentication, error: &error)",
]

# Lines no blocking rule refuses anywhere: async overloads, look-alikes, non-blocking calls of the same APIs.
NEVER = [
    "try await SMAppService.agent(plistName: plistName).unregister()",
    "try await service.run()",
    "self?.launch()",
    "launch()",
    "let image = icons.icon(for: entry)",
    "let image = Self.icon(for: item)",
    "SMAppService.openSystemSettingsLoginItems()",
    "let element = AXUIElementCreateApplication(pid)",
    "queue.async { work() }",
    "NSWorkspace.shared.openInBackground(url)",
]


def change(path: str, text: str) -> guardrails.FileChange:
    lines = text.split("\n")
    return guardrails.FileChange(path, lines, [guardrails.Added(path, n + 1, t) for n, t in enumerate(lines)],
                                 is_new=True)


def refused(directory: str, text: str) -> set[str]:
    """The blocking rules that refuse TEXT added as a new file in DIRECTORY (warnings left out)."""
    return refused_files([change(f"{directory}/Added.swift", text)])


def refused_files(changes: list, tree: tuple[Path, str] | None = None) -> set[str]:
    """The blocking rules that refuse CHANGES (warnings left out). TREE is the (repo, rev) whose unchanged files
    pool-blocking's actor index reads, as check() names HEAD's; without it no other file is read."""
    guardrails.load_blocking_context({}, "head", *(tree[:1] if tree else ()))
    if tree:
        guardrails.BLOCKING_CONTEXT["actor_tree"] = tree
    guardrails.BLOCKING_CONTEXT.update(threading_doc=DOC, manifest=MANIFEST)
    for scan in (guardrails.RAW_SCAN, guardrails.MAIN_SCAN, guardrails.ALWAYS_SCAN):
        scan.answers.clear()
    return {rule.id for rule in guardrails.BLOCKING_RULES
            if [h for h in rule.find(changes, collections.Counter()) if not getattr(h, "warn", False)]}


def in_function(statement: str, header: str = "func f() throws {") -> str:
    return f"{header}\n    {statement}\n}}\n"


class NewPrimitiveTests(unittest.TestCase):
    def test_each_new_primitive_is_main_blocking_in_main_actor_code(self):
        for statement in NEW_PRIMITIVES:
            with self.subTest(statement=statement):
                self.assertEqual(refused(UI, in_function(statement)), {"main-blocking"})

    def test_each_new_primitive_is_main_blocking_in_an_explicit_main_actor_function(self):
        for statement in NEW_PRIMITIVES:
            with self.subTest(statement=statement):
                self.assertEqual(refused(SERVICE, in_function(statement, "@MainActor func f() throws {")),
                                 {"main-blocking"})

    def test_each_new_primitive_is_raw_blocking_in_nonisolated_code(self):
        for statement in NEW_PRIMITIVES:
            with self.subTest(statement=statement):
                self.assertEqual(refused(SERVICE, in_function(statement)), {"raw-blocking"})
                self.assertEqual(refused(UI, in_function(statement, "nonisolated func f() throws {")),
                                 {"raw-blocking"})

    def test_a_primitive_in_a_closure_on_main_is_raw_blocking(self):
        text = "func f() {\n    queue.async {\n        _ = SecItemDelete(query as CFDictionary)\n    }\n}\n"
        self.assertEqual(refused(UI, text), {"raw-blocking"})

    def test_the_escape_comment_still_passes_a_new_primitive(self):
        text = "func f() {\n    // blocking-allow: fixture for the escape\n    _ = getaddrinfo(host, nil, &hints, &result)\n}\n"
        self.assertEqual(refused(UI, text), set())


class SeamTests(unittest.TestCase):
    def test_each_seam_is_refused_on_main(self):
        for statement in SEAMS:
            with self.subTest(statement=statement):
                self.assertEqual(refused(UI, in_function(statement)), {"main-blocking"})

    def test_each_seam_passes_off_main(self):
        for statement in SEAMS:
            with self.subTest(statement=statement):
                self.assertEqual(refused(SERVICE, in_function(statement)), set())
                self.assertEqual(refused(UI, in_function(statement, "nonisolated func f() throws {")), set())

    def test_the_seam_files_themselves_are_not_judged(self):
        text = in_function("return SecItemDelete(query)", "public func blockingSecItemDelete(_ query: CFDictionary) -> OSStatus {")
        self.assertEqual(refused(SRC + "CmuxNextCompat/Threading", text), set())


class NonBlockingTests(unittest.TestCase):
    def test_async_overloads_and_look_alikes_pass_on_main(self):
        for statement in NEVER:
            with self.subTest(statement=statement):
                self.assertEqual(refused(UI, in_function(statement, "func f() async throws {")), set())
                self.assertEqual(refused(SERVICE, in_function(statement, "func f() async throws {")), set())

    def test_an_await_later_in_the_statement_does_not_excuse_a_sync_unregister(self):
        text = in_function("try SMAppService.mainApp.unregister(); await done()", "func f() async throws {")
        self.assertEqual(refused(SERVICE, text), {"raw-blocking"})


# A seam call: only pool-blocking (never raw-blocking) can refuse it off main.
SEAM = "_ = try FileManager.checked.contentsOfDirectory(atPath: path)"
RAW = "_ = try Data(contentsOf: url)"
# Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Store/HomeCache.swift:21-35, then a method that blocks.
HOME_CACHE_EXECUTOR = """public actor HomeCache {
    /// Messages kept per opened conversation.
    public static let windowLimit = 200

    /// Writes one file (data, then its URL): the default replaces it atomically (a temporary file renamed over
    /// it, so a process end mid-write never leaves a torn file) and makes it owner-only.
    public typealias FileWriter = @Sendable (Data, URL) throws -> Void

    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.home.cache`): its file calls block a
    /// thread of its own, never a cooperative pool thread, so a full pool (a stuck quit) cannot hold the
    /// forced quit's last draft write.
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.home.cache", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func save(_ path: String) throws {
        %s
    }
}
"""


# A custom executor declared in an extension file of its own.
EXECUTOR_EXTENSION = ("extension Store {\n    nonisolated var unownedExecutor: UnownedSerialExecutor {\n"
                      "        Self.queue.asUnownedSerialExecutor()\n    }\n}\n")


def committed_tree(repo: Path, files: dict[str, str]) -> str:
    """FILES ({name: text} under SERVICE) committed as the one commit of a new repository at REPO; its sha."""
    for name, text in files.items():
        path = repo / SERVICE / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    env = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
           "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.invalid", "GIT_COMMITTER_NAME": "test",
           "GIT_COMMITTER_EMAIL": "test@example.invalid"}
    for args in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "tree"], ["rev-parse", "HEAD"]):
        result = subprocess.run(["git", "-C", str(repo), *args], check=True, env=env, capture_output=True, text=True)
    return result.stdout.strip()


def seam_context(directory: str, text: str) -> str | None:
    """pool_context of the first SEAM line of TEXT, added as a new file in DIRECTORY."""
    added = change(f"{directory}/Added.swift", text)
    refused_files([added])  # pool-blocking sets the head Version's ActorIndex
    head = guardrails.blocking_sides(added)[0][0]
    return guardrails.pool_context(head, next(i for i, line in enumerate(head.lines) if SEAM in line))


def pool(directory: str, text: str) -> bool:
    return "pool-blocking" in refused(directory, text)


class PoolBlockingTests(unittest.TestCase):
    def test_a_detached_body_is_refused_in_every_target(self):
        for header in ("Task.detached {", "Task.detached(priority: .utility) {", "Task.detached { [weak self] in",
                       "let data = await Task.detached(operation: {"):
            for directory in (UI, SERVICE):
                with self.subTest(header=header, directory=directory):
                    text = f"func f() {{\n    {header}\n        {SEAM}\n    }}\n}}\n"
                    self.assertEqual(refused(directory, text), {"pool-blocking"})

    def test_a_raw_call_in_a_detached_body_is_raw_and_pool_blocking(self):
        text = f"func f() {{\n    Task.detached(priority: .utility) {{\n        {RAW}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, text), {"raw-blocking", "pool-blocking"})

    def test_a_detached_header_over_lines_is_refused(self):
        text = f"func f() {{\n    Task.detached(\n        priority: .utility\n    ) {{\n        {SEAM}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, text), {"pool-blocking"})

    def test_child_tasks_and_global_queues_are_refused(self):
        for opener in ("group.addTask {", "group.addTaskUnlessCancelled(priority: .high) {",
                       "group.addTask(priority: .low, operation: {",
                       "DispatchQueue.global(qos: .utility).async {",
                       "DispatchQueue.concurrentPerform(iterations: 4) { _ in"):
            with self.subTest(opener=opener):
                text = f"func f() async {{\n    {opener}\n        {SEAM}\n    }}\n}}\n"
                self.assertEqual(refused(SERVICE, text), {"pool-blocking"})

    def test_a_main_actor_closure_on_the_pool_opener_is_not_pool(self):
        text = f"func f() {{\n    Task.detached {{ @MainActor in\n        {SEAM}\n    }}\n}}\n"
        self.assertFalse(pool(SERVICE, text))

    def test_a_task_in_a_nonisolated_function_is_refused(self):
        text = f"func f() {{\n    Task {{\n        {SEAM}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, text), {"pool-blocking"})
        nonisolated = (f"nonisolated func f() {{\n    Task(priority: .utility) {{\n        if ready {{\n"
                       f"            {SEAM}\n        }}\n    }}\n}}\n")
        self.assertEqual(refused(UI, nonisolated), {"pool-blocking"})

    def test_a_task_in_main_actor_code_is_not_pool(self):
        self.assertFalse(pool(UI, f"func f() {{\n    Task {{\n        {SEAM}\n    }}\n}}\n"))
        self.assertFalse(pool(SERVICE, f"@MainActor func f() {{\n    Task {{\n        {SEAM}\n    }}\n}}\n"))
        self.assertFalse(pool(SERVICE, f"@MainActor\nfinal class Model {{\n    func f() {{\n        Task {{\n"
                                       f"            {SEAM}\n        }}\n    }}\n}}\n"))
        self.assertFalse(pool(SERVICE, f"func f() {{\n    Task {{ @MainActor in\n        {SEAM}\n    }}\n}}\n"))

    def test_a_plain_nonisolated_function_is_not_pool(self):
        self.assertFalse(pool(SERVICE, in_function(SEAM)))
        self.assertFalse(pool(SERVICE, in_function(SEAM, "func f() async throws {")))

    def test_an_at_concurrent_function_is_refused(self):
        for header in ("@concurrent func f() async throws {", "@concurrent\nfunc f() async throws {",
                       "@concurrent\n/// Reads it.\npublic func f(path: String) async throws {"):
            for directory in (UI, SERVICE):
                with self.subTest(header=header, directory=directory):
                    self.assertEqual(refused(directory, in_function(SEAM, header)), {"pool-blocking"})

    def test_an_at_concurrent_signature_over_lines_is_refused(self):
        header = "@concurrent\npublic func f(\n    path: String\n) async throws {"
        self.assertEqual(refused(SERVICE, in_function(SEAM, header)), {"pool-blocking"})

    def test_control_flow_after_plain_statements_keeps_the_context(self):
        """Swift statements end without `;`: `let x = 1` above `do {` must not hide the `do` (TerminalThemeStore,
        FileOperator.newFolder and SavedEnvironments on the tip)."""
        detached = (f"func f() {{\n    let previous = last\n    last = Task.detached(priority: .utility) {{\n"
                    f"        await previous?.value\n        do {{\n            if ready {{\n                {SEAM}\n"
                    f"            }}\n        }} catch {{\n        }}\n    }}\n}}\n")
        self.assertEqual(refused(SERVICE, detached), {"pool-blocking"})
        concurrent = (f"@concurrent\npublic func f(in folder: URL) async throws -> URL {{\n    let target = folder\n"
                      f"    do {{\n        {SEAM}\n    }} catch {{\n    }}\n    return target\n}}\n")
        self.assertEqual(refused(SERVICE, concurrent), {"pool-blocking"})
        actor = (f"actor Store {{\n    private func load() -> Data? {{\n        if let loaded {{ return loaded }}\n"
                 f"        let data: Data?\n        do {{\n            {SEAM}\n        }} catch {{\n        }}\n"
                 f"        return nil\n    }}\n}}\n")
        self.assertEqual(refused(SERVICE, actor), {"pool-blocking"})

    def test_an_attribute_line_then_a_signature_over_lines_is_refused(self):
        header = ("@concurrent static func launch(_ environment: Environment, deadline: Duration,\n"
                  "                               onSpawn: @Sendable (pid_t) -> Void) async throws -> Endpoint {")
        self.assertEqual(refused(SERVICE, in_function(SEAM, header)), {"pool-blocking"})

    def test_an_actor_method_is_refused(self):
        text = f"actor Store {{\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, text), {"pool-blocking"})
        self.assertEqual(refused(UI, text), {"pool-blocking"})
        locked = (f"actor Store {{\n    func save() throws {{\n        state.withLock {{ _ in\n            {SEAM}\n"
                  f"        }}\n    }}\n}}\n")
        self.assertEqual(refused(SERVICE, locked), {"pool-blocking"})
        in_task = f"actor Store {{\n    func save() {{\n        Task {{\n            {SEAM}\n        }}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, in_task), {"pool-blocking"})
        computed = (f"actor Store {{\n    var names: [String] {{\n        get throws {{\n            {SEAM}\n"
                    f"        }}\n    }}\n}}\n")
        self.assertEqual(refused(SERVICE, computed), {"pool-blocking"})

    def test_an_extension_of_an_actor_in_the_file_is_refused(self):
        text = f"actor Store {{}}\n\nextension Store {{\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, text), {"pool-blocking"})

    def test_actor_members_that_are_not_actor_isolated_pass(self):
        for header in ("nonisolated func save() throws {", "static func save() throws {",
                       "@MainActor func save() throws {", "init(path: String) throws {", "deinit {"):
            with self.subTest(header=header):
                self.assertFalse(pool(SERVICE, f"actor Store {{\n    {header}\n        {SEAM}\n    }}\n}}\n"))

    def test_a_nested_struct_in_an_actor_is_not_the_actor(self):
        text = (f"actor Store {{\n    struct Box {{\n        func save() throws {{\n            {SEAM}\n        }}\n"
                f"    }}\n}}\n")
        self.assertFalse(pool(SERVICE, text))

    def test_the_home_cache_executor_actor_passes(self):
        self.assertFalse(pool(SERVICE, HOME_CACHE_EXECUTOR % SEAM))
        self.assertFalse(pool(UI, HOME_CACHE_EXECUTOR % SEAM))

    def test_an_executor_comment_without_an_executor_is_refused(self):
        """A comment is no executor: the actor's methods still run on the cooperative pool."""
        for mark in ("// executor: com.cmuxterm.next.store", "/// executor: callers are off the main actor"):
            with self.subTest(mark=mark):
                text = f"{mark}\nactor Store {{\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n"
                self.assertEqual(refused(SERVICE, text), {"pool-blocking"})

    def test_an_executor_comment_with_an_executor_passes(self):
        text = (f"// executor: com.cmuxterm.next.store\nactor Store {{\n"
                f"    private nonisolated let queue = DispatchSerialQueue(label: \"com.cmuxterm.next.store\")\n"
                f"    nonisolated var unownedExecutor: UnownedSerialExecutor {{ queue.asUnownedSerialExecutor() }}\n"
                f"    func save() throws {{\n        {SEAM}\n    }}\n}}\n")
        self.assertFalse(pool(SERVICE, text))

    def assert_actor_method(self, text: str) -> None:
        """TEXT's SEAM line reads as an actor method, and a rule refuses it. main-blocking's lexical scope
        (check-main-actor-work.py main_actor_lines) reads a one-line `@MainActor var` above, or a `@MainActor`
        closure parameter on the signature line, as main: there main-blocking refuses the line and pool-blocking
        leaves it to that rule (one refusal per line)."""
        self.assertEqual(seam_context(SERVICE, text), "an actor method")
        self.assertTrue(refused(SERVICE, text) & {"pool-blocking", "main-blocking"})

    def test_a_one_line_member_above_keeps_its_attributes(self):
        """declaration_attributes stops at a one-line member: its `@concurrent`, `@MainActor` or `nonisolated` is
        its own, not the next function's."""
        concurrent_above = (f"struct R {{\n    @concurrent func a() async {{ }}\n    func b() {{\n        {SEAM}\n"
                            f"    }}\n}}\n")
        self.assertFalse(pool(SERVICE, concurrent_above))
        for above in ("@MainActor func a() { }", "@MainActor var label = \"\"", "@TaskLocal static var trace = 0",
                      "@discardableResult nonisolated func a() -> Int { 1 }"):
            with self.subTest(above=above):
                text = f"actor Store {{\n    {above}\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n"
                self.assert_actor_method(text)

    def test_a_parameter_type_is_not_the_declaration_isolation(self):
        """Only the attributes and modifiers before `func` state isolation: a `@MainActor`, `nonisolated(nonsending)`
        or `@concurrent` closure parameter, or a `.static` default, does not."""
        for signature in ("func save(then done: @escaping @MainActor () -> Void) throws {",
                          "func save(\n        done: @escaping @MainActor () -> Void\n    ) throws {",
                          "func save(_ body: nonisolated(nonsending) () async -> Void) async throws {",
                          "func save(_ kind: Kind = .static) throws {"):
            with self.subTest(signature=signature):
                text = f"actor Store {{\n    {signature}\n        {SEAM}\n    }}\n}}\n"
                self.assert_actor_method(text)
        task = f"func f(done: @escaping @MainActor () -> Void) {{\n    Task {{\n        {SEAM}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, task), {"pool-blocking"})
        concurrent_parameter = f"func f(op: @escaping @concurrent () async -> Void) {{\n    {SEAM}\n}}\n"
        self.assertFalse(pool(SERVICE, concurrent_parameter))

    def test_a_local_function_runs_in_its_enclosing_context(self):
        """A local function that states no isolation runs where its enclosing function does (HostedChiefCopy's
        `@concurrent static func exportLines` holds `func lines(_:)`)."""
        local = f"    func lines() throws {{\n        {SEAM}\n    }}\n"
        for header, expected in (("@concurrent static func f() async throws {", {"pool-blocking"}),
                                 ("func f() throws {", set())):
            with self.subTest(header=header):
                self.assertEqual(refused(SERVICE, f"{header}\n{local}    try lines()\n}}\n"), expected)
        actor = f"actor Store {{\n    func save() throws {{\n    {local}        try lines()\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, actor), {"pool-blocking"})

    def test_an_async_actor_initializer_is_refused(self):
        """SE-0327: an actor's `async` init runs on the actor's executor once `self` is initialized."""
        for header in ("init() async {", "init(path: String) async throws {"):
            with self.subTest(header=header):
                text = f"actor Store {{\n    var x = 0\n    {header}\n        x = 1\n        {SEAM}\n    }}\n}}\n"
                self.assertEqual(refused(SERVICE, text), {"pool-blocking"})
        closure = f"actor Store {{\n    init(load: () async -> Void) {{\n        {SEAM}\n    }}\n}}\n"
        self.assertFalse(pool(SERVICE, closure))

    def test_an_async_let_initializer_is_refused(self):
        call = SEAM.removeprefix("_ = ")
        for text in (f"func f() async throws {{\n    async let names = {call}\n    _ = try await names\n}}\n",
                     f"func f() async throws {{\n    async let names =\n        {call}\n    _ = try await names\n}}\n"):
            with self.subTest(text=text):
                self.assertEqual(refused(SERVICE, text), {"pool-blocking"})

    def test_an_extension_of_an_actor_in_another_file_is_refused(self):
        actor = change(f"{SERVICE}/Store.swift", "actor Store {\n    var count = 0\n}\n")
        extension = change(f"{SERVICE}/Store+Save.swift",
                           f"extension Store {{\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n")
        self.assertEqual(refused_files([actor, extension]), {"pool-blocking"})
        self.assertEqual(refused_files([extension]), set())  # no actor named Store in the push or a tree

    def test_an_executor_in_another_file_passes(self):
        actor = change(f"{SERVICE}/Store.swift", "actor Store {\n    var count = 0\n}\n")
        executor = change(f"{SERVICE}/Store+Executor.swift", EXECUTOR_EXTENSION)
        extension = change(f"{SERVICE}/Store+Save.swift",
                           f"extension Store {{\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n")
        self.assertEqual(refused_files([actor, executor, extension]), set())

    def test_an_actor_in_an_unchanged_file_of_the_tree_is_found(self):
        """check() resolves an extension against HEAD's tree (repo_actor_index): the push holds only the
        extension; the actor, and in the second case its executor, sit in files the push does not change."""
        save = f"extension Store {{\n    func save() throws {{\n        {SEAM}\n    }}\n}}\n"
        cases = (({"Store.swift": "public actor Store {\n}\n"}, {"pool-blocking"}),
                 ({"Store.swift": "public actor Store {\n}\n", "Store+Executor.swift": EXECUTOR_EXTENSION}, set()),
                 ({"Store.swift": "public final class Store {\n}\n"}, set()))
        for tree, expected in cases:
            with self.subTest(tree=sorted(tree)), tempfile.TemporaryDirectory() as root:
                rev = committed_tree(Path(root), {**tree, "Store+Save.swift": save})
                try:
                    found = refused_files([change(f"{SERVICE}/Store+Save.swift", save)], tree=(Path(root), rev))
                finally:
                    guardrails.load_blocking_context({}, rev)
                self.assertEqual(found, expected)

    def test_a_work_run_closure_passes(self):
        run = f"await work.run(.userVisible, mayBlock: .files) {{\n            {SEAM}\n        }}"
        for text in (f"actor Store {{\n    func save() async throws {{\n        {run}\n    }}\n}}\n",
                     f"@concurrent func f() async throws {{\n        {run}\n}}\n",
                     f"func f() {{\n    Task.detached(priority: .utility) {{\n        {run}\n    }}\n}}\n"):
            with self.subTest(text=text):
                self.assertEqual(refused(SERVICE, text), set())

    def test_a_serial_queue_closure_passes(self):
        text = f"actor Store {{\n    func save() {{\n        queue.async {{\n            {SEAM}\n        }}\n    }}\n}}\n"
        self.assertEqual(refused(SERVICE, text), set())

    def test_the_escape_comment_passes(self):
        text = (f"actor Store {{\n    func save() throws {{\n        // blocking-allow: fixture for the escape\n"
                f"        {SEAM}\n    }}\n}}\n")
        self.assertEqual(refused(SERVICE, text), set())

    def test_the_rule_is_listed(self):
        self.assertIn("pool-blocking", [rule.id for rule in guardrails.RULES])


class SpeedTests(unittest.TestCase):
    def test_sixty_thousand_keyword_heavy_lines_stay_under_one_second(self):
        """60,000 added lines in main-actor code, a third of them blocking calls drawn from the new primitives and
        seams (each one goes through the main-actor scope and closure walk and is refused): the blocking rules'
        CPU time stays under 1 s."""
        calls = NEW_PRIMITIVES + SEAMS
        body = "".join(f"func f{i}() {{\n    if ready {{\n        {calls[i % len(calls)].replace('host', f'host{i}')}\n"
                       f"    }}\n}}\n" for i in range(600))
        changes = [change(f"{UI}/Big{index}.swift", body) for index in range(20)]
        for c in changes:
            c.is_new = False
        guardrails.BLOCKING_CONTEXT.update(threading_doc=DOC, manifest=MANIFEST)
        guardrails.BLOCKING_CONTEXT.pop("ui_targets", None)
        started = time.process_time()
        hits = {rule.id: rule.find(changes, collections.Counter()) for rule in guardrails.BLOCKING_RULES}
        elapsed = time.process_time() - started
        self.assertEqual(len(hits["main-blocking"]), 20 * 600)  # the scope and closure checks really ran
        self.assertLess(elapsed, 1.0)


if __name__ == "__main__":
    unittest.main()
