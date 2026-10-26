#!/usr/bin/env python3
"""guardrails.py's blocking rules see every blocking primitive class (p02-threads-002).

Each new primitive (process launch, queue and thread waits, Security, AX, getaddrinfo, CGWindowList, LSCopy,
NSWorkspace queries, SMAppService, AuthorizationCopyRights, sync XPC proxies, AppleScript) is refused as
main-blocking in main-actor code and as raw-blocking in nonisolated code; the task 003 seams are refused on main
and pass off main; the async overloads (`try await service.unregister()`) and look-alikes (`self?.launch()`,
`icons.icon(for:)`) pass. The rules run on in-memory changes (as check() builds them), so no git is needed.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the blocking rules:
  python3 -m pytest scripts/cmux-next/tests/test_guardrails.py
  python3 -I scripts/cmux-next/tests/test_guardrails.py
"""
from __future__ import annotations

import collections
import importlib.util
import sys
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
    guardrails.BLOCKING_CONTEXT.update(threading_doc=DOC, manifest=MANIFEST)
    guardrails.BLOCKING_CONTEXT.pop("ui_targets", None)
    for scan in (guardrails.RAW_SCAN, guardrails.MAIN_SCAN, guardrails.ALWAYS_SCAN):
        scan.answers.clear()
    changes = [change(f"{directory}/Added.swift", text)]
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
