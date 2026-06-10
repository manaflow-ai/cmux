import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalNotificationPolicyEngineTests: XCTestCase {
    private func evaluate(
        request: TerminalNotificationPolicyRequest,
        hooks: [CmuxResolvedNotificationHook]
    ) async -> Result<TerminalNotificationPolicyEnvelope, TerminalNotificationPolicyFailure> {
        await TerminalNotificationPolicyEngine.evaluate(
            request: request,
            hooks: hooks
        )
    }

    func testHookCanDisableDesktopAndTransformBody() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Title",
            subtitle: "Subtitle",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "filter",
            command: #"sed 's/"desktop":true/"desktop":false/; s/"body":"Body"/"body":"Filtered"/'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        let envelope = try result.get()
        XCTAssertFalse(envelope.effects.desktop)
        XCTAssertEqual(envelope.notification.body, "Filtered")
    }

    func testHookCanFilterExistingPolicyEnvelope() async throws {
        var effects = TerminalNotificationPolicyEffects()
        effects.record = false
        effects.markUnread = false
        effects.reorderWorkspace = false
        effects.sound = false
        effects.command = false
        effects.paneFlash = false
        let envelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: "feed-session",
                surfaceId: nil,
                title: "Permission",
                subtitle: "",
                body: "Decision needed"
            ),
            context: TerminalNotificationPolicyContext(
                cwd: FileManager.default.temporaryDirectory.path,
                configPath: nil,
                hookId: nil,
                appFocused: false,
                focusedPanel: false
            ),
            effects: effects
        )
        let hook = CmuxResolvedNotificationHook(
            id: "feed-filter",
            command: #"sed 's/"desktop":true/"desktop":false/; s/"title":"Permission"/"title":"Filtered"/'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await TerminalNotificationPolicyEngine.evaluate(envelope: envelope, hooks: [hook])
        let filtered = try result.get()
        XCTAssertFalse(filtered.effects.desktop)
        XCTAssertEqual(filtered.notification.title, "Filtered")
        XCTAssertEqual(filtered.notification.workspaceId, "feed-session")
    }

    func testHookCanReturnPartialEffectsEnvelope() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: UUID(),
            title: "Title",
            subtitle: "Subtitle",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "partial",
            command: #"printf '{"effects":{"desktop":false},"stop":true}'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        let envelope = try result.get()
        XCTAssertEqual(envelope.notification.title, "Title")
        XCTAssertEqual(envelope.notification.body, "Body")
        XCTAssertFalse(envelope.effects.desktop)
        XCTAssertTrue(envelope.effects.sound)
        XCTAssertTrue(envelope.effects.command)
        XCTAssertEqual(envelope.stop, true)
    }

    func testPartialEffectsPatchPreservesOmittedExistingFlags() async throws {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = false
        effects.command = false
        let envelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: UUID().uuidString,
                surfaceId: nil,
                title: "Title",
                subtitle: "Subtitle",
                body: "Body"
            ),
            context: TerminalNotificationPolicyContext(
                cwd: FileManager.default.temporaryDirectory.path,
                configPath: nil,
                hookId: nil,
                appFocused: false,
                focusedPanel: false
            ),
            effects: effects
        )
        let hook = CmuxResolvedNotificationHook(
            id: "partial",
            command: #"printf '{"effects":{"desktop":false}}'"#,
            timeoutSeconds: 5,
            sourcePath: nil,
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await TerminalNotificationPolicyEngine.evaluate(envelope: envelope, hooks: [hook])
        let patched = try result.get()
        XCTAssertFalse(patched.effects.desktop)
        XCTAssertFalse(patched.effects.sound)
        XCTAssertFalse(patched.effects.command)
        XCTAssertTrue(patched.effects.record)
    }

    func testPartialNotificationPatchPreservesOmittedPayloadFields() async throws {
        let envelope = TerminalNotificationPolicyEnvelope(
            notification: TerminalNotificationPolicyPayload(
                workspaceId: "workspace-1",
                surfaceId: "surface-1",
                title: "Title",
                subtitle: "Subtitle",
                body: "Body"
            ),
            context: TerminalNotificationPolicyContext(
                cwd: "/tmp/original",
                configPath: nil,
                hookId: nil,
                appFocused: false,
                focusedPanel: false
            )
        )
        let hook = CmuxResolvedNotificationHook(
            id: "partial-notification",
            command: #"printf '{"notification":{"title":"Retitled"},"context":{"appFocused":true}}'"#,
            timeoutSeconds: 5,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await TerminalNotificationPolicyEngine.evaluate(envelope: envelope, hooks: [hook])
        let patched = try result.get()
        XCTAssertEqual(patched.notification.workspaceId, "workspace-1")
        XCTAssertEqual(patched.notification.surfaceId, "surface-1")
        XCTAssertEqual(patched.notification.title, "Retitled")
        XCTAssertEqual(patched.notification.subtitle, "Subtitle")
        XCTAssertEqual(patched.notification.body, "Body")
        XCTAssertEqual(patched.context.configPath, "/tmp/cmux.json")
        XCTAssertEqual(patched.context.hookId, "partial-notification")
        XCTAssertTrue(patched.context.appFocused)
        XCTAssertFalse(patched.context.focusedPanel)
    }

    func testHookFailureReturnsFailureForDefaultFallback() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Title",
            subtitle: "",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "bad",
            command: "printf nope",
            timeoutSeconds: 5,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        switch result {
        case .success:
            XCTFail("Expected invalid JSON to fail")
        case .failure(let failure):
            XCTAssertEqual(failure.hookId, "bad")
            XCTAssertTrue(failure.message.contains("invalid JSON"))
        }
    }

    func testHookTimeoutReturnsFailureForDefaultFallback() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Title",
            subtitle: "",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "slow",
            command: "sleep 2; cat",
            timeoutSeconds: 0.1,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let result = await evaluate(request: request, hooks: [hook])
        switch result {
        case .success:
            XCTFail("Expected timeout to fail")
        case .failure(let failure):
            XCTAssertEqual(failure.hookId, "slow")
            XCTAssertTrue(failure.message.contains("timed out"))
        }
    }

    func testHookWithBackgroundChildInheritingStdoutDoesNotStall() async throws {
        let request = TerminalNotificationPolicyRequest(
            tabId: UUID(),
            surfaceId: nil,
            title: "Title",
            subtitle: "",
            body: "Body",
            cwd: FileManager.default.temporaryDirectory.path,
            isAppFocused: false,
            isFocusedPanel: false
        )
        let hook = CmuxResolvedNotificationHook(
            id: "background-stdout",
            command: "sleep 3 & cat",
            timeoutSeconds: 5,
            sourcePath: "/tmp/cmux.json",
            cwd: FileManager.default.temporaryDirectory.path
        )

        let startedAt = Date()
        let result = await evaluate(request: request, hooks: [hook])
        let envelope = try result.get()
        XCTAssertEqual(envelope.notification.body, "Body")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }
}

