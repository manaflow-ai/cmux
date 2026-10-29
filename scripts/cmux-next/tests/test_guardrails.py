#!/usr/bin/env python3
"""guardrails.py's blocking rules see every blocking primitive class (p02-threads-002) and refuse blocking on a
shared pool thread (p02-threads-010), and raw-blocking-ext (p02-threads-126) refuses the primitives raw-blocking
does not name.

Each new primitive (process launch, queue and thread waits, Security, AX, getaddrinfo, CGWindowList, LSCopy,
NSWorkspace queries, SMAppService, AuthorizationCopyRights, sync XPC proxies, AppleScript) is refused as
main-blocking in main-actor code and as raw-blocking in nonisolated code; the task 003 seams are refused on main
and pass off main; the async overloads (`try await service.unregister()`) and look-alikes (`self?.launch()`,
`icons.icon(for:)`) pass. pool-blocking refuses a raw or seam call in a Task.detached or child task body, an
`async let` initializer, a `Task {` in a nonisolated function, an @concurrent function and an actor method (also in
an extension in another file, and an `async` actor init), reads isolation from the declaration's prefix only, and
passes a `work.run` closure and an actor with a real custom executor (the HomeCache pattern; a comment is none).
raw-blocking-ext refuses, on any thread, a FileManager disk op through a name whose nearest declaration in scope binds
a FileManager (`let fm = FileManager.default`, `fileManager: FileManager? = .default`, `FileManager()`, also through
`fm?.` and `fm!.`), POSIX file and process calls (arguments read across lines), FileHandle
open/write/read/seek/synchronize, ImageIO URL I/O, sqlite3_*, sysctl, proc_pid*, `canEvaluatePolicy`, getpw* and
Host.current(). Its fixtures pin what it must not refuse: a method of the same name (`menu.removeItem(at:)`), the
`stat()` struct initializer, a call off its C arity, a `waitpid(..., WNOHANG)` poll, a POSIX name a declaration in
scope shadows (but never `open(..., O_*)`, and never from another function), `evaluatePolicy` (async or reply), a
`blockingCall`/`allowBlocking` closure, the seams and an escaped line; its acceptance count runs
threading-inventory.py on 772cdfc45ac.
The rules run on in-memory changes (as check() builds them); only the actor-index and check() push tests make a
throwaway git repository in a temporary folder.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the blocking rules:
  python3 -m pytest scripts/cmux-next/tests/test_guardrails.py
  python3 -I scripts/cmux-next/tests/test_guardrails.py
"""
from __future__ import annotations

import collections
import difflib
import importlib.util
import os
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
    "_ = blockingFtruncate(fd, 0)",
    "_ = blockingRename(from, to)",
    "_ = blockingUnlink(path)",
    "_ = blockingStat(path, &info)",
    "_ = blockingLstat(path, &info)",
    "free(blockingRealpath(path, nil))",
    "_ = blockingAccess(path, R_OK)",
    "_ = blockingChmod(path, 0o700)",
    "_ = blockingMkdir(path, 0o700)",
    "_ = blockingRmdir(path)",
    "_ = blockingWaitpid(pid, &status, 0)",
    "var result = blockingWaitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)",
    "let handle = try FileHandle.blockingForReading(from: url)",
    "let handle = try FileHandle.blockingForWriting(to: url)",
    "let handle = try FileHandle.blockingForUpdating(url)",
    "_ = try handle.blockingSeekToEnd()",
    "try handle.blockingSeek(toOffset: 0)",
    "try handle.blockingSynchronize()",
    "let source = blockingImageSource(url: url as CFURL)",
    "let count = blockingImageSourceCount(source)",
    "let properties = blockingImageSourceCopyProperties(source, at: 0)",
    "let image = blockingImageSourceCreateImage(source, at: 0, options: options)",
    "let thumbnail = blockingImageSourceCreateThumbnail(source, at: 0, options: options)",
    "let destination = blockingImageDestination(url: url as CFURL, type: type, count: 1)",
    "_ = blockingImageDestinationFinalize(destination)",
    "_ = blockingSQLiteOpen(path, &db, flags)",
    "_ = blockingSQLitePrepare(db, sql, -1, &statement, nil)",
    "_ = blockingSQLiteStep(statement)",
    "_ = blockingSQLiteExec(db, sql)",
    "blockingSQLiteClose(db)",
    "blockingSQLiteCloseV2(to)",
    "let step = blockingSQLiteBackupStep(backup, -1)",
    "_ = blockingSysctl(&mib, 2, &value, &size, nil, 0)",
    "_ = blockingSysctlByName(\"hw.memsize\", &value, &size, nil, 0)",
    "_ = blockingProcPidInfo(pid, PROC_PIDTBSDINFO, 0, &info, size)",
    "guard blockingProcPidPath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }",
    "_ = blockingProcPidFDInfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)",
    "let needed = blockingProcListPids(UInt32(PROC_UID_ONLY), uid, nil, 0)",
    "_ = blockingProcPidRusage(pid, RUSAGE_INFO_V4, pointer)",
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


# raw-blocking-ext.
REPO = SCRIPTS.parents[1]
INVENTORY_REV = "772cdfc45ac"
EXT_RULE = next(rule for rule in guardrails.RULES if rule.id == "raw-blocking-ext")
THREADING_SEAMS = SRC + "CmuxNextCompat/Threading"

REFUSED = {
    "fm variable": "func f() {\n    let fm = FileManager.default\n    try? fm.removeItem(at: url)\n}\n",
    "typed property": ("struct S {\n    let fileManager: FileManager = .default\n"
                       "    func f() -> Bool { self.fileManager.fileExists(atPath: p) }\n}\n"),
    "injected parameter": "init(files: FileManager) {\n    _ = files.contentsOfDirectory(atPath: p)\n}\n",
    "FileManager()": "func f() {\n    _ = FileManager().fileExists(atPath: p)\n}\n",
    "stat(path, &st)": "func f() -> Bool {\n    var st = stat()\n    return stat(path, &st) == 0\n}\n",
    "lstat": "func f() {\n    guard lstat(url.path, &info) == 0 else { return }\n}\n",
    "open O_": "func f() {\n    let fd = open(path, O_RDONLY | O_CLOEXEC)\n}\n",
    "Darwin.open": "func f() {\n    let fd = Darwin.open(path, flags)\n}\n",
    "Darwin.read": "func f() {\n    _ = Darwin.read(fd, &buffer, 1)\n}\n",
    "rename": "func f() {\n    guard rename(temporary.path, url.path) == 0 else { return }\n}\n",
    "unlink": "func f() {\n    unlink(path)\n}\n",
    "fsync flock": "func f() {\n    _ = fsync(fd)\n    _ = flock(fd, LOCK_EX)\n}\n",
    "realpath": "func f() {\n    let resolved = realpath(path, nil)\n}\n",
    "waitpid blocking": "func f() {\n    while waitpid(pid, &status, 0) < 0, errno == EINTR {}\n}\n",
    "FileHandle open": "func f() throws {\n    let h = try FileHandle(forWritingTo: url)\n}\n",
    "FileHandle write": "func f() throws {\n    try handle.write(contentsOf: data)\n    try handle.synchronize()\n}\n",
    "FileHandle read": "func f() throws {\n    _ = try handle.read(upToCount: 16)\n    _ = try handle.seekToEnd()\n}\n",
    "ImageIO": "func f() {\n    let s = CGImageSourceCreateWithURL(url as CFURL, nil)\n}\n",
    "ImageIO finalize": "func f() {\n    _ = CGImageDestinationFinalize(destination)\n}\n",
    "sqlite3": "func f() {\n    _ = sqlite3_open_v2(path, &db, flags, nil)\n    _ = sqlite3_step(statement)\n}\n",
    "sysctl": "func f() {\n    _ = sysctl(&mib, 4, &info, &size, nil, 0)\n    _ = sysctlbyname(name, &v, &n, nil, 0)\n}\n",
    "proc_pid": "func f() {\n    _ = proc_pidpath(pid, &buffer, 4096)\n}\n",
    "LAContext": "func f() {\n    _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)\n}\n",
    "getpwuid": "func f() {\n    let entry = getpwuid(getuid())\n}\n",
    "Host.current": "func f() {\n    _ = Host.current().localizedName\n}\n",
    # A declaration hides a POSIX name only in its own scope, and never hides `open(..., O_*)`.
    "open beside a guard let open in another function": ("func a() {\n    guard let open = onOpen, open(file) else { return }\n"
                                                          "}\nfunc b() {\n    let fd = open(path, O_RDONLY)\n}\n"),
    "open beside a Bool member": "struct S {\n    var open: Bool\n    func f() { _ = open(path, O_RDONLY) }\n}\n",
    "rename beside a local in another function": ("func a() {\n    guard let rename = onRename else { return }\n"
                                                  "    rename(x, y)\n}\nfunc b() {\n    _ = rename(old, new)\n}\n"),
    "access beside a non-callable parameter": "init(access: AccessLevel) {\n    _ = access(path, R_OK)\n}\n",
    "an optional FileManager": ("struct S {\n    var fm: FileManager?\n"
                                "    func f() -> Bool { fm?.fileExists(atPath: p) ?? false }\n}\n"),
    "a force-unwrapped FileManager": "func f(fm: FileManager?) throws {\n    try fm!.removeItem(at: url)\n}\n",
    "a FileManager parameter passed on": ("func f(fileManager: FileManager = .default) {\n"
                                          "    _ = list(fileManager: fileManager)\n"
                                          "    _ = fileManager.fileExists(atPath: p)\n}\n"),
    "a wrapped open": "func f() {\n    let fd = open(\n        path,\n        O_RDONLY | O_CLOEXEC)\n}\n",
    "WNOHANG outside the call": "func f() {\n    _ = waitpid(pid, &status, 0); let flag = WNOHANG\n}\n",
}
PASSED = {
    "a method with no binding": "func f() {\n    menu.removeItem(at: 0)\n}\n",
    "fileExists on a non-FileManager": "func f(store: Store) {\n    _ = store.fileExists(atPath: p)\n}\n",
    "stat() initializer": "func f() {\n    var st = stat()\n}\n",
    "WNOHANG poll": "func f() {\n    _ = waitpid(pid, &status, WNOHANG)\n}\n",
    "a labeled call": "func f() {\n    rename(id, to: name)\n    _ = access(keyPath: \\.sections)\n}\n",
    "a declaration": "func rename(_ url: URL, to name: String) {}\nenum E { case stat(Int) }\n",
    "an injected closure": ("struct S {\n    var stat: (String) -> Int?\n"
                            "    func f() { _ = stat(path) }\n}\n"),
    "a closure parameter": "init(rename: @escaping (String, String) -> Void) {\n    rename(a, b)\n}\n",
    "the seam": "func f() throws {\n    _ = FileManager.checked.fileExists(atPath: p)\n    _ = try handle.blockingRead(upToCount: 4)\n}\n",
    "a chained default": "func f() {\n    let home = FileManager.default\n        .homeDirectoryForCurrentUser\n    _ = home.url(\n}\n",
    "an awaited policy": "func f() async {\n    _ = try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: r)\n}\n",
    "a reply-closure policy": ("func f() {\n    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) "
                               "{ @Sendable success, _ in\n        done(success)\n    }\n}\n"),
    "a comment and a string": "func f() {\n    // unlink(path)\n    print(\"stat(path, &st)\")\n}\n",
    "the escape": "func f() {\n    // blocking-allow: test fixture for the escape\n    unlink(path)\n}\n",
    "Darwin.close": "func f() {\n    Darwin.close(fd)\n    _ = open\n}\n",
    "a guard let rename in its own scope": "func a() {\n    guard let rename = onRename else { return }\n    rename(x, y)\n}\n",
    "a member closure called from an extension": ("struct S {\n    var stat: (String, Int) -> Int\n}\n"
                                                  "extension S {\n    func f() { _ = stat(p, 1) }\n}\n"),
    "a call off its C arity": "func f() {\n    _ = stat(resolved)\n    rename(id)\n}\n",
    "an open with no O_ flag": "func f() {\n    open(file)\n    _ = open(\n        url, mode\n    )\n}\n",
    "a wrapped WNOHANG poll": "func f() {\n    _ = waitpid(\n        pid, &status,\n        WNOHANG)\n}\n",
    "in a blockingCall closure": ("func f() {\n    blockingCall(.fileIO) { _ = unlink(path) }\n"
                                  "    let ok = blockingCall(.systemCall) {\n        stat(path, &st) == 0\n    }\n}\n"),
    "in an allowBlocking closure": ("func f() throws {\n    let fm = FileManager.default\n"
                                    "    try allowBlocking(.fixture) {\n        try fm.removeItem(at: url)\n    }\n}\n"),
}


def ext_hits(text: str, directory: str = SERVICE) -> list:
    return EXT_RULE.find([change(directory + "/Added.swift", text)], collections.Counter())


class RawBlockingExtTests(unittest.TestCase):
    def test_each_primitive_is_refused(self):
        for name, text in REFUSED.items():
            with self.subTest(name):
                self.assertTrue(ext_hits(text), f"{name} not refused:\n{text}")

    def test_lookalikes_seams_and_escapes_pass(self):
        for name, text in PASSED.items():
            with self.subTest(name):
                self.assertEqual([h.text for h in ext_hits(text)], [], f"{name} refused")

    def test_the_named_lines_are_the_hits(self):
        found = ext_hits(REFUSED["stat(path, &st)"])
        self.assertEqual([h.number for h in found], [3])  # the call, not `var st = stat()`
        found = ext_hits(REFUSED["fm variable"])
        self.assertEqual([h.number for h in found], [3])  # the op, not the binding
        found = ext_hits(REFUSED["open beside a guard let open in another function"])
        self.assertEqual([h.number for h in found], [5])
        found = ext_hits(REFUSED["rename beside a local in another function"])
        self.assertEqual([h.number for h in found], [6])  # b's rename, not a's closure
        found = ext_hits(REFUSED["a FileManager parameter passed on"])
        self.assertEqual([h.number for h in found], [3])  # the argument label declares nothing

    def test_a_name_is_read_from_its_nearest_declaration(self):
        """A FileManager name refuses only where its nearest declaration in scope binds a FileManager: the same
        name bound to the checked seam or a parameter of another type in another function is not one."""
        text = ("func a() {\n    let manager = FileManager.default\n    _ = manager.fileExists(atPath: p)\n}\n"
                "func b() {\n    let manager = FileManager.checked\n    try? manager.removeItem(at: url)\n}\n"
                "func c(manager: Store) {\n    _ = manager.contents(atPath: p)\n}\n"
                "func d() {\n    let manager = FileManager.default\n    do {\n        let manager = Store()\n"
                "        _ = manager.contents(atPath: p)\n    }\n    _ = manager.contents(atPath: p)\n}\n")
        self.assertEqual([h.number for h in ext_hits(text)], [3, 18])

    def test_blocking_call_on_main_is_main_blocking(self):
        """The seam scope passes raw-blocking-ext; on the main thread the `blockingCall` seam is main-blocking."""
        text = "func f() {\n    blockingCall(.fileIO) { _ = unlink(path) }\n}\n"
        self.assertEqual(refused(SERVICE, text), set())
        self.assertEqual(refused(UI, text), {"main-blocking"})

    def test_main_actor_code_and_the_seam_folder(self):
        self.assertTrue(ext_hits("func f() {\n    unlink(path)\n}\n", UI), "main-actor code is refused too")
        self.assertEqual(ext_hits("func blockingUnlink() {\n    unlink(path)\n}\n", THREADING_SEAMS), [])

    def test_no_other_blocking_rule_reports_these(self):
        """raw-blocking-ext names primitives the other blocking rules do not, so a line is refused once, in
        nonisolated and in main-actor code."""
        for name, text in REFUSED.items():
            with self.subTest(name):
                self.assertEqual(refused(SERVICE, text), {"raw-blocking-ext"})
                self.assertEqual(refused(UI, text), {"raw-blocking-ext"})

    def test_a_push_is_judged_through_check(self):
        """The rule runs in the hook's check() on what a commit adds, and base debt does not count."""
        with tempfile.TemporaryDirectory(prefix="cmux-guardrails-ext-") as root:
            repo = Path(root) / "repository"
            env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
            config = Path(root) / "gitconfig"
            config.write_text("[user]\n\tname = Fixture\n\temail = fixture@example.com\n[maintenance]\n\tauto = false\n"
                              "[gc]\n\tauto = 0\n")
            env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(config), HOME=root)

            def git(*args):
                return subprocess.run(["git", "-C", str(repo), *args], env=env, text=True, capture_output=True,
                                      check=True).stdout

            repo.mkdir()
            git("init", "--quiet", "--initial-branch=feat-cmux-next")
            old = repo / SERVICE / "Old.swift"
            old.parent.mkdir(parents=True)
            old.write_text("func old() {\n    unlink(path)\n}\n")
            git("add", "-A")
            git("commit", "--quiet", "--no-verify", "-m", "base")
            base = git("rev-parse", "HEAD").strip()
            old.write_text("func old() {\n    unlink(path)\n}\nfunc other() {}\n")
            (repo / SERVICE / "Added.swift").write_text(REFUSED["fm variable"])
            git("add", "-A")
            git("commit", "--quiet", "--no-verify", "-m", "adds")
            saved = {k: os.environ.pop(k) for k in list(os.environ) if k.startswith("GIT_")}
            try:
                refusals, warnings = guardrails.check(repo, base, "HEAD")
            finally:
                os.environ.update(saved)
            self.assertEqual([w for w in warnings if w[0] == "guardrails"], [])
            found = {rule.id: [(h.path.rsplit("/", 1)[-1], h.number) for h in rule_hits] for rule, rule_hits in refusals}
            self.assertEqual(found.get("raw-blocking-ext"), [("Added.swift", 3)])

    def test_the_rule_stays_fast_on_a_large_keyword_heavy_push(self):
        """60,000 added lines, a third of them refused primitives and a third FileManager variable ops: the
        rule's CPU time stays under 1 s."""
        body = "".join(f"func f{i}() {{\n    let fm = FileManager.default\n    _ = fm.fileExists(atPath: p{i})\n"
                       f"    guard stat(path{i}, &info) == 0 else {{ return }}\n    menu.removeItem(at: {i})\n}}\n"
                       for i in range(500))
        changes = [change(f"{SERVICE}/Big{index}.swift", body) for index in range(20)]
        started = time.process_time()
        found = EXT_RULE.find(changes, collections.Counter())
        elapsed = time.process_time() - started
        self.assertEqual(len(found), 20 * 500 * 2)
        self.assertLess(elapsed, 1.0)

    def test_inventory_counts_at_least_600_at_the_reference_rev(self):
        probe = subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{INVENTORY_REV}^{{commit}}"],
                               capture_output=True)
        if probe.returncode != 0:
            self.skipTest(f"{INVENTORY_REV} is not in this clone")
        out = subprocess.run([sys.executable, "-I", str(SCRIPTS / "threading-inventory.py"), "--repo", str(REPO),
                              "--rev", INVENTORY_REV, "--rule", "raw-blocking-ext", "--count"],
                             capture_output=True, text=True, check=True).stdout
        counts = dict(line.rsplit(" ", 1) for line in out.strip().splitlines())
        self.assertGreaterEqual(int(counts["raw-blocking-ext"]), 600, out)


# awaited-low-priority: a low-priority task whose value main-actor code awaits.
AWAITED_RULE = next(rule for rule in guardrails.RULES if rule.id == "awaited-low-priority")
AWAITED_REV = "d842bcdc673"  # origin/perf/chrome-parity when the rule landed
AWAITED_COUNT = 21  # threading-inventory.py --rev d842bcdc673 --rule awaited-low-priority --count
STORED_HANDLE = """final class Store {
    private var lastWrite: Task<Void, Never>?

    func save() {
        lastWrite = Task.detached(priority: .utility) {
            write()
        }
    }

    func flush() async {
%s
    }
}
"""


def awaited(changes: list) -> list[tuple[str, int]]:
    """(file name, line) of each awaited-low-priority hit in CHANGES."""
    guardrails.load_blocking_context({}, "head")
    guardrails.BLOCKING_CONTEXT.update(threading_doc=DOC, manifest=MANIFEST)
    return [(h.path.rsplit("/", 1)[-1], h.number) for h in AWAITED_RULE.find(changes, collections.Counter())]


def awaited_in(directory: str, text: str) -> list[int]:
    return [line for _, line in awaited([change(f"{directory}/Added.swift", text)])]


class AwaitedLowPriorityTests(unittest.TestCase):
    def test_a_stored_handle_awaited_in_main_actor_code_is_refused(self):
        for await_line in ("        await lastWrite?.value", "        _ = await self.lastWrite?.result",
                           "        if let task = lastWrite { await task.value }; await lastWrite?.value"):
            with self.subTest(await_line=await_line):
                self.assertEqual(awaited_in(UI, STORED_HANDLE % await_line), [5])

    def test_a_stored_handle_awaited_in_an_extension_of_the_type_is_refused(self):
        text = (STORED_HANDLE % "") + "\nextension Store {\n    func drain() async {\n        await lastWrite?.value\n    }\n}\n"
        self.assertEqual(awaited_in(UI, text), [5])

    def test_a_property_initializer_awaited_by_a_method_is_refused(self):
        text = ("final class Loader {\n    private let names = Task(priority: .background) { list() }\n\n"
                "    func show() async {\n        render(await names.value)\n    }\n}\n")
        self.assertEqual(awaited_in(UI, text), [2])

    def test_an_awaited_at_once_low_task_is_refused(self):
        for statement in ("let data = await Task.detached(priority: .utility) { read() }.value",
                          "return try await Task.detached(priority: .low) {\n        try read()\n    }.value",
                          "guard await Task.detached(priority: .utility, operation: { check() }).value else { return }",
                          "let names = await work.task(.bestEffort) { await list() }.value",
                          "let names = await\n        Task<[String], Never>(priority: TaskPriority.background) { list() }.value"):
            with self.subTest(statement=statement):
                text = in_function(statement, "func f() async throws {")
                self.assertEqual(len(awaited_in(UI, text)), 1, text)

    def test_a_local_handle_awaited_later_in_its_function_is_refused(self):
        text = ("func f() async {\n    let page = work.task(.idle) { await fetch() }\n    prepare()\n"
                "    let result = await page.result\n    use(result)\n}\n")
        self.assertEqual(awaited_in(UI, text), [2])

    def test_an_await_in_a_main_actor_task_or_main_actor_run_is_refused(self):
        inherited = ("@MainActor func f() {\n    let task = Task.detached(priority: .utility) { read() }\n"
                     "    Task {\n        if let value = await task.value { show(value) }\n    }\n}\n")
        self.assertEqual(awaited_in(SERVICE, inherited), [2])
        hopped = ("func f() async {\n    let task = Task.detached(priority: .utility) { read() }\n"
                  "    await MainActor.run {\n        Task { await show(task.value) }\n    }\n}\n")
        self.assertEqual(awaited_in(SERVICE, hopped), [2])

    def test_fire_and_forget_low_tasks_are_not_refused(self):
        for text in ("func f() {\n    Task.detached(priority: .utility) { write() }\n}\n",
                     "func f() {\n    _ = work.task(.bestEffort) { await upload() }\n}\n",
                     STORED_HANDLE % "        lastWrite?.cancel()",
                     "func f() -> Task<Void, Never> {\n    return Task.detached(priority: .utility) { write() }\n}\n",
                     "func f() {\n    let task = Task(priority: .background) { write() }\n    keep(task)\n}\n"):
            with self.subTest(text=text):
                self.assertEqual(awaited_in(UI, text), [])

    def test_awaited_work_at_the_waiters_priority_is_not_refused(self):
        for statement in ("let data = await Task.detached(priority: .userInitiated) { read() }.value",
                          "let data = await Task(priority: .high) { read() }.value",
                          "let data = try await work.task(.userBlocking) { try await read() }.value",
                          "let data = await work.task(.userVisible) { await read() }.value"):
            with self.subTest(statement=statement):
                self.assertEqual(awaited_in(UI, in_function(statement, "func f() async throws {")), [])
        self.assertEqual(awaited_in(UI, (STORED_HANDLE % "        await lastWrite?.value").replace(
            "priority: .utility", "priority: .userInitiated")), [])

    def test_an_await_off_the_main_actor_is_not_refused(self):
        statement = "let data = await Task.detached(priority: .utility) { read() }.value"
        self.assertEqual(awaited_in(SERVICE, in_function(statement, "func f() async {")), [])
        self.assertEqual(awaited_in(UI, in_function(statement, "nonisolated func f() async {")), [])
        self.assertEqual(awaited_in(UI, in_function(statement, "@concurrent func f() async {")), [])
        self.assertEqual(awaited_in(UI, "actor Cache {\n" + in_function(statement, "func f() async {") + "}\n"), [])
        detached = "func f() {\n    Task.detached(priority: .userInitiated) {\n        " + statement + "\n    }\n}\n"
        self.assertEqual(awaited_in(UI, detached), [])
        escaping = "func f() {\n    handler = { [weak self] in\n        " + statement + "\n    }\n}\n"
        self.assertEqual(awaited_in(UI, escaping), [])

    def test_a_same_named_local_of_another_function_is_not_its_handle(self):
        text = ("func a() {\n    let task = Task.detached(priority: .utility) { write() }\n    keep(task)\n}\n\n"
                "func b(task: Task<Int, Never>) async {\n    _ = await task.value\n}\n")
        self.assertEqual(awaited_in(UI, text), [])

    def test_the_escape_passes(self):
        text = in_function("// priority-allow: fixture, nothing waits on a frame for it\n"
                           "    let data = await Task.detached(priority: .utility) { read() }.value",
                           "func f() async {")
        self.assertEqual(awaited_in(UI, text), [])

    def test_a_push_that_only_adds_the_await_refuses_the_old_creation_line(self):
        base = (STORED_HANDLE % "        lastWrite?.cancel()").split("\n")
        head = (STORED_HANDLE % "        lastWrite?.cancel()\n        await lastWrite?.value").split("\n")
        path = f"{UI}/Store.swift"
        pushed = guardrails.FileChange(path, head, [guardrails.Added(path, 12, head[11])], base_lines=base)
        self.assertEqual(awaited([pushed]), [("Store.swift", 5)])
        unrelated = (STORED_HANDLE % "        lastWrite?.cancel()\n        log()").split("\n")
        other = guardrails.FileChange(path, unrelated, [guardrails.Added(path, 12, unrelated[11])], base_lines=base)
        self.assertEqual(awaited([other]), [])

    def pushed(self, directory: str, base_text: str, head_text: str) -> list[tuple[str, int]]:
        """awaited() of the push from BASE_TEXT to HEAD_TEXT at DIRECTORY/Store.swift, read from its -U0 diff."""
        path = f"{directory}/Store.swift"
        base, head = base_text.split("\n"), head_text.split("\n")
        diff = "\n".join(difflib.unified_diff(base, head, f"a/{path}", f"b/{path}", n=0, lineterm=""))
        pushed = guardrails.parse_diff(f"diff --{'g' + 'it'} a/{path} b/{path}\n{diff}\n")[path]
        pushed.head_lines, pushed.base_lines = head, base
        return awaited([pushed])

    def test_a_push_that_moves_an_old_await_of_a_stored_handle_onto_main_refuses_the_old_creation_line(self):
        head = STORED_HANDLE % "        await lastWrite?.value"
        base = head.replace("    func flush() async {", "    nonisolated func flush() async {")
        self.assertEqual(awaited_in(UI, base), [])
        self.assertEqual(self.pushed(UI, base, head), [("Store.swift", 5)])

    def test_a_push_that_moves_an_old_await_at_once_onto_main_refuses_it(self):
        head = ("final class Reader {\n    func load() async {\n        prepare()\n        log()\n"
                "        let data = await Task.detached(priority: .utility) { read() }.value\n"
                "        use(data)\n    }\n}\n")
        for attribute in ("nonisolated ", "@concurrent "):
            with self.subTest(attribute=attribute):
                base = head.replace("    func load()", f"    {attribute}func load()")
                self.assertEqual(awaited_in(UI, base), [])
                self.assertEqual(self.pushed(UI, base, head), [("Store.swift", 5)])
        on_its_own_line = head.replace("    func load()", "    @concurrent\n    func load()").replace(
            "        prepare()\n", "")
        self.assertEqual(awaited_in(UI, on_its_own_line), [])
        for edit, creation in (("", 4), ("    // was @concurrent\n", 5)):
            with self.subTest(edit=edit):
                head_text = on_its_own_line.replace("    @concurrent\n", edit)
                self.assertEqual(self.pushed(UI, on_its_own_line, head_text), [("Store.swift", creation)])
        wrapped = head.replace("        log()\n", "        Task.detached {\n").replace(
            "        use(data)\n", "        use(data) }\n")
        self.assertEqual(awaited_in(UI, wrapped), [])
        self.assertEqual(self.pushed(UI, wrapped, head), [("Store.swift", 5)])

    def test_a_push_that_turns_an_actor_into_a_main_actor_class_refuses_the_old_creation_line(self):
        base = (STORED_HANDLE % "        await lastWrite?.value").replace("final class Store {", "actor Store {")
        head = base.replace("actor Store {", "@MainActor final class Store {")
        self.assertEqual(awaited_in(SERVICE, base), [])
        self.assertEqual(self.pushed(SERVICE, base, head), [("Store.swift", 5)])
        nonisolated = base.replace("actor Store {", "nonisolated final class Store {")
        self.assertEqual(awaited_in(UI, nonisolated), [])
        self.assertEqual(self.pushed(UI, nonisolated, nonisolated.replace("nonisolated final", "final")),
                         [("Store.swift", 5)])

    def test_inventory_records_the_count_at_the_reference_rev(self):
        probe = subprocess.run(["git", "-C", str(REPO), "cat-file", "-e", f"{AWAITED_REV}^{{commit}}"],
                               capture_output=True)
        if probe.returncode != 0:
            self.skipTest(f"{AWAITED_REV} is not in this clone")
        out = subprocess.run([sys.executable, "-I", str(SCRIPTS / "threading-inventory.py"), "--repo", str(REPO),
                              "--rev", AWAITED_REV, "--rule", "awaited-low-priority", "--count"],
                             capture_output=True, text=True, check=True).stdout
        counts = dict(line.rsplit(" ", 1) for line in out.strip().splitlines())
        self.assertEqual(int(counts["awaited-low-priority"]), AWAITED_COUNT, out)


class TaskIdTests(unittest.TestCase):
    """task-id-comment and task_ids.py: a plan task id goes in the commit message, never in a new code comment."""

    @property
    def ids(self):
        return guardrails.task_ids_module()

    def hits(self, path: str, base: str, head: str) -> list[tuple[str, int]]:
        base_lines, head_lines = base.split("\n"), head.split("\n")
        diff = difflib.SequenceMatcher(a=base_lines, b=head_lines, autojunk=False)
        added, removed = [], []
        for tag, i1, i2, j1, j2 in diff.get_opcodes():
            if tag in ("replace", "delete"):
                removed += [guardrails.Added(path, n + 1, base_lines[n]) for n in range(i1, i2)]
            if tag in ("replace", "insert"):
                added += [guardrails.Added(path, n + 1, head_lines[n]) for n in range(j1, j2)]
        change = guardrails.FileChange(path, head_lines, added, removed=removed, base_lines=base_lines)
        return [(h.path.rsplit("/", 1)[-1], h.number) for h in guardrails.task_id_comments([change], collections.Counter())]

    def test_a_new_comment_with_an_id_is_refused_in_every_comment_form(self):
        for path, line in ((UI + "/A.swift", "let a = 1 // the rows load later (p08-startup-064)"),
                           (UI + "/A.swift", "/// p07-memory-082: the engine loads on demand"),
                           (UI + "/A.swift", "/* see cp/p10-stability-083/084 */"),
                           ("cmux-tui/crates/x/src/a.rs", "// the frame (p03-rendering-100) goes first"),
                           ("webviews/src/a.ts", "// drafts flush on blur (p13-webui-082)")):
            with self.subTest(line=line):
                self.assertEqual(self.hits(path, "let x = 0\n", f"let x = 0\n{line}\n"), [(path.rsplit('/', 1)[-1], 2)])

    def test_ids_in_code_strings_paths_and_generated_blocks_pass(self):
        for line in ('let key = "p04-input-053"',
                     "// see plans/cmux-next/chrome-parity/p01-process.md",
                     "// the corpus file p04-input-053.json",
                     "let p04 = 1 // a plain comment",
                     "// BEGIN tool.py: generated from x.json; do not edit.\n// (p10-stability-039)\n// END tool.py"):
            with self.subTest(line=line):
                self.assertEqual(self.hits(UI + "/A.swift", "let x = 0\n", f"let x = 0\n{line}\n"), [])

    def test_an_edited_or_moved_comment_that_keeps_its_id_is_not_new(self):
        base = "let x = 0\n// the rows load later (p08-startup-064)\n"
        self.assertEqual(self.hits(UI + "/A.swift", base, "let x = 0\n// the rows load much later (p08-startup-064)\n"), [])
        self.assertEqual(self.hits(UI + "/A.swift", base, "let x = 0\n// the rows load later (cp/p08-startup-064)\n"), [],
                         "a branch prefix around a kept id made it new")
        self.assertEqual(self.hits(UI + "/A.swift", base, "let x = 0\n// rows (p08-startup-064, p08-startup-065)\n"),
                         [("A.swift", 2)])

    def test_the_rule_is_in_the_local_tier(self):
        rule = next(r for r in guardrails.RULES if r.id == "task-id-comment")
        self.assertTrue(rule.local_only)

    def strip(self, text: str, path: str = "a.swift") -> str:
        return self.ids.rewrite(path, text)[0]

    def test_strip_keeps_the_sentence(self):
        cases = {
            "/// Built once per change (p04-input-053):\n": "/// Built once per change:\n",
            "x = 1  // not AppKit (p08-startup-087)\n": "x = 1  // not AppKit\n",
            "/// `start` post, p08-startup-031). Needs it.\n": "/// `start` post). Needs it.\n",
            "/// p07-memory-082: the engine loads\n": "/// The engine loads\n",
            "/// A slide (`x`, chrome-parity p03-rendering-100): notes\n": "/// A slide (`x`): notes\n",
            "/// The calls (p02-threads-130, 146).\n": "/// The calls.\n",
            "/// drives `oneInput(_:)`\n/// (p10-stability-182). Once the input\n":
                "/// drives `oneInput(_:)`.\n/// Once the input\n",
            "// handlers (choosers.h, task\n// p01-process-228). Plain C++\n": "// handlers (choosers.h).\n// Plain C++\n",
            "let a = 1 // p04-input-005\n": "let a = 1\n",
            "// foo\n// p04-input-006\n// bar\n": "// foo\n// bar\n",
            "/* A block (p04-input-001)\n * p04-input-003\n */\n": "/* A block\n */\n",
            "/// ``skip()`` and `run()` (p04-input-001): it calls `foo()`.\n":
                "/// ``skip()`` and `run()`: it calls `foo()`.\n",
            "// The Mutex the caches live in (p10-stability-172, -055).\n": "// The Mutex the caches live in.\n",
            "/// p08-startup-087: cmux restores its windows.\n": "/// cmux restores its windows.\n",
            "//! The hang reporter\n//! (p10-stability-207). It runs\n": "//! The hang reporter.\n//! It runs\n",
            "//! p04-input-001: a reader\n": "//! A reader\n",
            "/*\n * - the interactions (cmux's INP,\n *   p04-input-097);\n */\n": "/*\n * - the interactions (cmux's INP);\n */\n",
            "/*\n *   field data (chrome-parity p09-observability-063 and 064;\n *   plans/x.md, \"Upload\");\n */\n":
                "/*\n *   field data\n *   (plans/x.md, \"Upload\");\n */\n",
        }
        for before, after in cases.items():
            with self.subTest(before=before):
                self.assertEqual(self.strip(before), after)

    def test_strip_changes_only_comments_and_lists_what_needs_a_person(self):
        text = ('let s = "p04-input-053 (p04-input-054)" // the flip is p02-threads-021\n'
                "// BEGIN tool.py: generated from x.json; do not edit.\n// (p10-stability-039)\n// END tool.py\n")
        out, left = self.ids.rewrite("a.swift", text)
        self.assertEqual(out, text)
        self.assertEqual(left, [1])
        py = 'x = "p04-input-053"  # the queue (p05-ipc-142)\n'
        self.assertEqual(self.strip(py, "a.py"), 'x = "p04-input-053"  # the queue\n')
        self.assertEqual(self.strip("// generated by gen.py; do not edit\n// (p01-process-001)\n"),
                         "// generated by gen.py; do not edit\n// (p01-process-001)\n")

    def test_strip_leaves_hash_inputs_whole(self):
        for path in self.ids.HASHED:
            with self.subTest(path=path):
                self.assertEqual(self.ids.tracked(guardrails.Path(__file__).resolve().parents[3], [path]), [])

    def test_strip_is_idempotent(self):
        text = "/// Built once (p04-input-053): the facts\n/// (p10-stability-182). Once the input\n"
        once = self.strip(text)
        self.assertEqual(self.strip(once), once)


class ExecutorHookTests(unittest.TestCase):
    """executor-hook (sequence-manager S6): the main-executor hook symbol in code outside MainJobRing.swift is refused,
    with no escape; a comment may name it."""

    RULE = next(rule for rule in guardrails.RULES if rule.id == "executor-hook")
    LOOKUP = 'let slot = dlsym(handle, "swift_task_enqueueMainExecutor_hook")'

    def hits(self, path: str, text: str) -> int:
        self.assertTrue(guardrails.in_rule_scope(path, self.RULE.scope), path)
        return len(self.RULE.find([change(path, text)], collections.Counter()))

    def test_a_lookup_outside_the_ring_is_refused_in_sources_and_tests(self):
        self.assertEqual(self.hits(SRC + "CmuxNextWakeups/Hook.swift", self.LOOKUP), 1)
        self.assertEqual(self.hits("Packages/macOS/CmuxNext/Tests/CmuxNextWakeupsTests/HookTests.swift", self.LOOKUP), 1)

    def test_the_ring_itself_and_comments_pass(self):
        self.assertEqual(self.hits(SRC + "CmuxNextCompat/MainJobRing.swift", self.LOOKUP), 0)
        self.assertEqual(self.hits(SRC + "CmuxNextWakeups/Hook.swift", "/// `swift_task_enqueueMainExecutor_hook` is one word"), 0)
        self.assertEqual(self.hits(SRC + "CmuxNextWakeups/Hook.swift", "install() // swift_task_enqueueMainExecutor_hook"), 0)

    def test_there_is_no_escape(self):
        self.assertIsNone(self.RULE.escape)
        self.assertEqual(self.hits(SRC + "CmuxNextWakeups/Hook.swift", "// executor-hook-allow: because\n" + self.LOOKUP), 1)


if __name__ == "__main__":
    unittest.main()
