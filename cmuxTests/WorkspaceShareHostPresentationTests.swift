import AppKit
import CmuxCommandPalette
import CmuxWorkspaceShare
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace share host presentation", .serialized)
struct WorkspaceShareHostPresentationTests {
    @Test("Guest bubble renders passively and stale expiry cannot clear its replacement")
    func guestBubbleRendersPassivelyAndExpiresByGeneration() throws {
        _ = NSApplication.shared
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = NSWindow(
            contentRect: pane.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = pane
        defer { window.orderOut(nil) }

        let controller = ShareCursorOverlayController(
            bubbleLifetime: .seconds(3_600)
        )
        controller.resolvePaneView = { ws, paneID in
            ws == "workspace" && paneID == "pane" ? pane : nil
        }
        controller.isWorkspaceVisible = { $0 == "workspace" }
        let anchor = ShareCursorPos(
            ws: "workspace",
            pane: "pane",
            x: 0.25,
            y: 0.5
        )

        #expect(controller.showRemoteBubble(
            user: "guest",
            email: "guest@example.com",
            colorIndex: 2,
            text: "First",
            anchor: anchor
        ))
        let firstGeneration = try #require(
            controller.remoteBubbleGeneration(for: "guest")
        )
        let pointer = try #require(
            pane.subviews.compactMap { $0 as? ShareCursorPointerView }.first
        )
        #expect(pointer.bubbleText == "First")
        #expect(pointer.hitTest(NSPoint(x: 5, y: 5)) == nil)

        let longText = String(repeating: "🙂", count: 200)
        #expect(controller.showRemoteBubble(
            user: "guest",
            email: "guest@example.com",
            colorIndex: 2,
            text: longText,
            anchor: anchor
        ))
        let replacementGeneration = try #require(
            controller.remoteBubbleGeneration(for: "guest")
        )
        let boundedText = try #require(
            controller.remoteBubbleText(for: "guest")
        )
        #expect(replacementGeneration != firstGeneration)
        #expect(boundedText.utf8.count <= ShareCursorPointerView.maximumBubbleTextBytes)
        #expect(boundedText.hasSuffix("…"))

        controller.expireRemoteBubble(
            user: "guest",
            generation: firstGeneration
        )
        #expect(controller.remoteBubbleText(for: "guest") == boundedText)

        controller.expireRemoteBubble(
            user: "guest",
            generation: replacementGeneration
        )
        #expect(controller.remoteBubbleText(for: "guest") == nil)
        #expect(pointer.bubbleText == nil)
    }

    @Test("Cursor, participant, and session teardown remove guest bubbles")
    func bubbleRemovalFollowsOwnerLifecycle() {
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let controller = ShareCursorOverlayController(
            bubbleLifetime: .seconds(3_600)
        )
        controller.resolvePaneView = { _, _ in pane }
        let anchor = ShareCursorPos(
            ws: "workspace",
            pane: "pane",
            x: 0.5,
            y: 0.5
        )

        #expect(controller.showRemoteBubble(
            user: "guest",
            email: "guest@example.com",
            colorIndex: 1,
            text: "Cursor",
            anchor: anchor
        ))
        controller.updateRemoteCursor(
            user: "guest",
            email: "guest@example.com",
            colorIndex: 1,
            pos: nil
        )
        #expect(controller.remoteBubbleText(for: "guest") == nil)
        #expect(controller.remoteBubbleGeneration(for: "guest") == nil)

        #expect(controller.showRemoteBubble(
            user: "guest",
            email: "guest@example.com",
            colorIndex: 1,
            text: "Participant",
            anchor: anchor
        ))
        controller.removeRemoteUser("guest")
        #expect(!controller.remoteUserIDs.contains("guest"))

        #expect(controller.showRemoteBubble(
            user: "guest",
            email: "guest@example.com",
            colorIndex: 1,
            text: "Session",
            anchor: anchor
        ))
        controller.teardown()
        #expect(controller.remoteUserIDs.isEmpty)
        #expect(controller.remoteBubbleGeneration(for: "guest") == nil)
    }

    @Test("Missing auth opens the panel and a later attempt replaces the error")
    func missingAuthIsVisibleInSharePanel() throws {
        _ = NSApplication.shared
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = ShareSessionController { nil }
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        controller.startSharing(
            tabManager: manager,
            focusedWorkspace: workspace
        )

        #expect(controller.status == .idle)
        #expect(controller.lastErrorText == String(
            localized: "share.error.notSignedIn",
            defaultValue: "Sign in to cmux to share a workspace."
        ))
        let panel = try #require(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0))
                && $0.identifier?.rawValue == "cmux.shareSession"
        })
        defer { panel.orderOut(nil) }
        #expect(panel.isVisible)

        let otherManager = TabManager()
        controller.startSharing(
            tabManager: otherManager,
            focusedWorkspace: workspace
        )
        #expect(controller.lastErrorText == String(
            localized: "share.error.noWorkspaceContext",
            defaultValue: "Sharing is unavailable: no workspace window is open."
        ))
        #expect(panel.isVisible)
    }

    @Test("Active sharing keeps both panel and stop actions reachable")
    func activeSharingCanReopenItsPanel() {
        var context = CommandPaletteContextSnapshot()
        context.setBool(CommandPaletteContextKeys.shareSessionActive, true)

        let visibleCommandIDs = ContentView.commandPaletteShareCommandContributions(
            isFeatureEnabled: true
        )
        .filter { $0.when(context) }
        .map(\.commandId)

        #expect(
            Set(visibleCommandIDs)
                == ["palette.showShareSession", "palette.stopSharing"]
        )
    }

    @Test("A stale create completion cannot clear a newer start attempt")
    func staleCreateCompletionCannotOwnNewerAttempt() async throws {
        let api = DelayedShareSessionAPI()
        let controller = ShareSessionController(testingAPI: api)
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)

        controller.startSharing(
            tabManager: manager,
            focusedWorkspace: workspace
        )
        try await api.waitForCreateCount(1)
        controller.stopSharing()

        controller.startSharing(
            tabManager: manager,
            focusedWorkspace: workspace
        )
        try await api.waitForCreateCount(2)

        await api.failCreate(
            at: 0,
            error: ShareSessionAPIError.httpStatus(500, retryAfter: nil)
        )
        await Task.yield()
        #expect(controller.status == .starting)

        await api.failCreate(
            at: 1,
            error: ShareSessionAPIError.httpStatus(500, retryAfter: nil)
        )
        for _ in 0..<20 where controller.status != .idle {
            await Task.yield()
        }
        #expect(controller.status == .idle)
    }

    @Test("A rejected host chat send retains its draft")
    func rejectedChatRetainsDraft() {
        var draft = "keep this message"

        ShareChatView.submitDraft(&draft) { _ in false }
        #expect(draft == "keep this message")

        ShareChatView.submitDraft(&draft) { _ in true }
        #expect(draft.isEmpty)
    }
}

@Suite("Workspace share socket request")
struct WorkspaceShareSocketRequestTests {
    @Test("Native bearer stays in Authorization and token query items are removed")
    func bearerTokenIsHeaderOnly() throws {
        let token = "fresh.header.token"
        let request = try #require(ShareSocket.connectionRequest(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "wss://relay.example/connect?token=stale&keep=1&token=\(token)",
                token: token
            )
        ))

        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer \(token)"
        )
        let url = try #require(request.url)
        #expect(!url.absoluteString.contains(token))
        let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        #expect(!queryItems.contains { $0.name == "token" })
        #expect(queryItems.contains {
            $0.name == "keep" && $0.value == "1"
        })
    }

    @Test("Request construction preserves secure and loopback WebSocket endpoints")
    func endpointValidationRemainsIntact() {
        #expect(ShareSocket.connectionRequest(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "wss://relay.example/connect?keep=1",
                token: "valid-token"
            )
        ) != nil)
        #expect(ShareSocket.connectionRequest(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "ws://127.0.0.1:8787/connect",
                token: "valid-token"
            )
        ) != nil)
        #expect(ShareSocket.connectionRequest(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "ws://relay.example/connect",
                token: "valid-token"
            )
        ) == nil)
        #expect(ShareSocket.connectionRequest(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "wss://relay.example/connect",
                token: "bad\ntoken"
            )
        ) == nil)
    }

    @Test("A full socket event buffer reports backpressure instead of hiding a drop")
    func fullEventBufferReportsBackpressure() async {
        let socket = ShareSocket(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "wss://relay.example/connect",
                token: "valid-token"
            ),
            refresh: {
                ShareSocket.Endpoint(
                    wsUrl: "wss://relay.example/connect",
                    token: "valid-token"
                )
            },
            maximumBufferedEvents: 1
        )

        #expect(socket.enqueueEventForTesting(.connectionStateChanged(true)))
        #expect(socket.send(.chat(text: "before overflow", bubble: nil)) == .admitted)
        #expect(!socket.enqueueEventForTesting(.connectionStateChanged(false)))
        #expect(socket.send(.chat(text: "after overflow", bubble: nil)) == .backpressured)
        await socket.stop()
    }

    @Test("Critical backpressure joins an existing reconnect instead of ending the share")
    func criticalBackpressureDuringReconnectRemainsRecoverable() async {
        let lifecycle = WorkspaceShareSessionLifecycle(
            clockSleep: { _ in
                try await Task.sleep(for: .seconds(60))
            },
            randomUnitInterval: { 0 }
        )
        let socket = ShareSocket(
            endpoint: ShareSocket.Endpoint(
                wsUrl: "ws://127.0.0.1:1/connect",
                token: "valid-token"
            ),
            refresh: {
                ShareSocket.Endpoint(
                    wsUrl: "ws://127.0.0.1:1/connect",
                    token: "valid-token"
                )
            },
            lifecycle: lifecycle
        )

        await socket.start()
        #expect(await waitForReconnect(lifecycle))
        #expect(await socket.reconnectAfterOutboundBackpressure())
        await socket.stop()
    }

    private func waitForReconnect(
        _ lifecycle: WorkspaceShareSessionLifecycle
    ) async -> Bool {
        let states = await lifecycle.states()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in states {
                    if case .reconnecting = state {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let didReconnect = await group.next() ?? false
            group.cancelAll()
            return didReconnect
        }
    }
}

private actor DelayedShareSessionAPI: ShareSessionAPIProviding {
    private var createContinuations:
        [CheckedContinuation<ShareSessionCreateResult, any Error>] = []

    func createSession() async throws -> ShareSessionCreateResult {
        try await withCheckedThrowingContinuation { continuation in
            createContinuations.append(continuation)
        }
    }

    func hostToken(code: String) async throws -> ShareTokenResult {
        throw ShareSessionAPIError.malformedResponse(
            "hostToken is not expected in this test"
        )
    }

    func waitForCreateCount(_ expected: Int) async throws {
        for _ in 0..<200 {
            if createContinuations.count >= expected {
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw DelayedShareSessionAPITestError.timedOut
    }

    func failCreate(at index: Int, error: any Error) {
        guard createContinuations.indices.contains(index) else { return }
        createContinuations[index].resume(throwing: error)
    }
}

private enum DelayedShareSessionAPITestError: Error {
    case timedOut
}
