import AppKit
import XCTest
@_spi(CmuxHostTransport) import CmuxExtensionKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceActionDispatcherTests: XCTestCase {
    func testSingleAndSidebarTargetsResolveTheSamePinState() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.tabs.first)

        let singleState = try XCTUnwrap(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: .single(workspace.id)
            )
        )
        let sidebarState = try XCTUnwrap(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: WorkspaceActionDispatcher.Target(
                    workspaceIds: [workspace.id],
                    anchorWorkspaceId: workspace.id
                )
            )
        )

        XCTAssertEqual(singleState, sidebarState)
        XCTAssertEqual(singleState.pinned, !workspace.isPinned)
    }

    func testPinActionPinsMultipleTargetsFromAnchorState() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        let target = WorkspaceActionDispatcher.Target(
            workspaceIds: [second.id, third.id],
            anchorWorkspaceId: second.id
        )

        let state = try XCTUnwrap(WorkspaceActionDispatcher.pinState(in: manager, target: target))
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        XCTAssertTrue(state.pinned)
        XCTAssertEqual(result.targetWorkspaceIds, [second.id, third.id])
        XCTAssertEqual(result.changedWorkspaceIds, [second.id, third.id])
        XCTAssertTrue(second.isPinned)
        XCTAssertTrue(third.isPinned)
        XCTAssertFalse(first.isPinned)
        XCTAssertEqual(manager.tabs.map(\.id), [second.id, third.id, first.id])
    }

    func testPinActionUnpinsMultipleTargetsWithExistingOrdering() throws {
        let manager = TabManager()
        let first = try XCTUnwrap(manager.tabs.first)
        let second = manager.addWorkspace()
        let third = manager.addWorkspace()
        manager.setPinned(first, pinned: true)
        manager.setPinned(second, pinned: true)
        manager.setPinned(third, pinned: true)
        let target = WorkspaceActionDispatcher.Target(
            workspaceIds: [second.id, third.id],
            anchorWorkspaceId: second.id
        )

        let state = try XCTUnwrap(WorkspaceActionDispatcher.pinState(in: manager, target: target))
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        XCTAssertFalse(state.pinned)
        XCTAssertEqual(result.targetWorkspaceIds, [second.id, third.id])
        XCTAssertEqual(result.changedWorkspaceIds, [second.id, third.id])
        XCTAssertTrue(first.isPinned)
        XCTAssertFalse(second.isPinned)
        XCTAssertFalse(third.isPinned)
        XCTAssertEqual(manager.tabs.map(\.id), [first.id, third.id, second.id])
    }

    func testCapturedPinStateKeepsLabelAndActionConsistent() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.tabs.first)
        let state = try XCTUnwrap(
            WorkspaceActionDispatcher.pinState(
                in: manager,
                target: .single(workspace.id)
            )
        )

        manager.setPinned(workspace, pinned: true)
        let result = WorkspaceActionDispatcher.performPinAction(state, in: manager)

        XCTAssertTrue(state.pinned)
        XCTAssertTrue(workspace.isPinned)
        XCTAssertTrue(result.changedWorkspaceIds.isEmpty)
    }
}

@MainActor
final class CMUXSidebarRunCommandTerminalAdapterTests: XCTestCase {
    private struct HostedTerminalPanel {
        let panel: TerminalPanel
        let window: NSWindow
    }

    private let adapter = CMUXSidebarRunCommandTerminalAdapter()

    private func makeHostedTerminalPanel() throws -> HostedTerminalPanel {
        _ = NSApplication.shared
        let panel = TerminalPanel(workspaceId: UUID())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try XCTUnwrap(window.contentView)
        panel.hostedView.frame = contentView.bounds
        panel.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(panel.hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        panel.hostedView.layoutSubtreeIfNeeded()
        panel.hostedView.setVisibleInUI(true)
        panel.hostedView.setActive(true)
        return HostedTerminalPanel(panel: panel, window: window)
    }

    private func waitForLiveSurface(
        _ panel: TerminalPanel,
        timeout: TimeInterval = 3
    ) async -> Bool {
        if panel.surface.hasLiveSurface { return true }

        let ready = expectation(description: "Ghostty terminal surface to become live")
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: panel.surface,
            queue: .main
        ) { _ in
            ready.fulfill()
        }
        defer { center.removeObserver(token) }

        if panel.surface.hasLiveSurface { return true }
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: timeout)
        return result == .completed && panel.surface.hasLiveSurface
    }

    private func waitForVisibleText(
        from panel: TerminalPanel,
        description: String,
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor (String) -> Bool
    ) async -> String? {
        if let text = panel.surface.visibleText(), condition(text) { return text }

        let releaseTicks = GhosttyApp.retainTickNotifications()
        let releaseFrames = GhosttyNSView.retainRenderedFrameNotifications()
        defer {
            releaseFrames()
            releaseTicks()
        }

        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: .ghosttyDidTick, object: nil, queue: .main) { _ in
                continuation.yield()
            },
            center.addObserver(forName: .ghosttyDidRenderFrame, object: nil, queue: .main) { _ in
                continuation.yield()
            },
            center.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: panel.surface,
                queue: .main
            ) { _ in
                continuation.yield()
            },
        ]
        defer {
            for token in tokens { center.removeObserver(token) }
            continuation.finish()
        }

        let observed = expectation(description: description)
        var matchingText: String?
        let observer = Task { @MainActor in
            for await _ in events {
                guard let text = panel.surface.visibleText(), condition(text) else { continue }
                matchingText = text
                observed.fulfill()
                return
            }
        }
        defer { observer.cancel() }

        if let text = panel.surface.visibleText(), condition(text) {
            matchingText = text
            observed.fulfill()
        } else {
            GhosttyApp.shared.scheduleTick()
        }

        let result = await XCTWaiter.fulfillment(of: [observed], timeout: timeout)
        guard result == .completed else {
            XCTFail(
                "Timed out after \(timeout)s waiting for \(description). " +
                    "Last visible terminal text:\n\(panel.surface.visibleText() ?? "<unavailable>")"
            )
            return panel.surface.visibleText()
        }
        return matchingText ?? panel.surface.visibleText()
    }

    func testDeferredTerminalIsClassifiedColdWithoutWaking() {
        let panel = TerminalPanel(workspaceId: UUID(), runtimeSpawnPolicy: .pacedSessionRestore)

        XCTAssertEqual(adapter.targetKind(for: panel), .terminal(.cold))
        XCTAssertFalse(panel.surface.hasLiveSurface)
    }

    func testMissingTargetMapsToLocalizedTerminalNotFoundRejection() {
        let result = adapter.dispatch(command: "printf hello", to: nil)

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(
            result.message,
            String(
                localized: "sidebar.extensions.action.terminalNotFound",
                defaultValue: "Terminal surface not found"
            )
        )
    }

    func testNonterminalPanelMapsToLocalizedTargetNotTerminalWithoutTerminalInput() {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }

        let result = adapter.dispatch(command: "printf hello", to: panel)

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(
            result.message,
            String(
                localized: "sidebar.extensions.action.targetNotTerminal",
                defaultValue: "Target surface is not a terminal"
            )
        )
    }

    func testInvalidCommandWinsBeforeMissingTarget() {
        let result = adapter.dispatch(command: "echo first\necho second", to: nil)

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(
            result.message,
            String(
                localized: "sidebar.extensions.action.commandRejected",
                defaultValue: "Command must be nonempty, no more than 8192 UTF-8 bytes, single-line, and contain no control or separator characters"
            )
        )
    }

    func testDeferredTerminalMapsToLocalizedUnavailableRejection() {
        let panel = TerminalPanel(workspaceId: UUID(), runtimeSpawnPolicy: .pacedSessionRestore)
        let result = adapter.dispatch(command: "printf hello", to: panel)

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(
            result.message,
            String(
                localized: "sidebar.extensions.action.terminalUnavailable",
                defaultValue: "Terminal surface is not live"
            )
        )
        XCTAssertFalse(panel.surface.hasLiveSurface)
    }

    func testLiveTerminalDispatchesExactCommandThenEnterAndAccepts() async throws {
        let hosted = try makeHostedTerminalPanel()
        defer {
            hosted.panel.close()
            hosted.window.orderOut(nil)
        }
        let liveSurfaceReady = await waitForLiveSurface(hosted.panel)
        try XCTSkipUnless(
            liveSurfaceReady,
            "Ghostty surface failed to initialize on this host; Metal/embedded_window unavailable."
        )
        let initialText = await waitForVisibleText(
            from: hosted.panel,
            description: "initial shell prompt"
        ) { text in
            text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
        }
        try XCTUnwrap(
            initialText,
            "Terminal shell never produced visible output before command dispatch."
        )

        let command = #"printf 'X42\n'"#

        let result = adapter.dispatch(command: command, to: hosted.panel)

        let observedText = await waitForVisibleText(
            from: hosted.panel,
            description: "echoed command followed by a standalone X42 output line"
        ) { text in
            let normalizedText = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalizedText.components(separatedBy: "\n")
            guard let commandLineIndex = lines.firstIndex(where: { $0.contains(command) }) else {
                return false
            }
            return lines[(commandLineIndex + 1)...].contains {
                $0.trimmingCharacters(in: .whitespaces) == "X42"
            }
        }
        let transcript = try XCTUnwrap(
            observedText,
            "Terminal transcript never exposed an echoed command followed by a standalone X42 output line. " +
                "Transcript:\n\(hosted.panel.surface.visibleText() ?? "<unavailable>")"
        )
        let normalizedTranscript = transcript
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedTranscript.components(separatedBy: "\n")
        let commandEchoIndices = lines.indices.filter { lines[$0].contains(command) }
        let outputIndices = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespaces) == "X42"
        }

        XCTAssertTrue(
            result.accepted,
            "Live terminal rejected the command: \(result.message ?? "<no reason>"). " +
                "Transcript:\n\(normalizedTranscript)"
        )
        XCTAssertNil(
            result.message,
            "Accepted live terminal command unexpectedly returned a message. " +
                "Transcript:\n\(normalizedTranscript)"
        )
        XCTAssertTrue(
            commandEchoIndices.contains { commandIndex in
                outputIndices.contains { commandIndex < $0 }
            },
            "Expected at least one echoed command line before the X42 output line. " +
                "Transcript:\n\(normalizedTranscript)"
        )
        XCTAssertEqual(
            outputIndices.count,
            1,
            "Expected exactly one standalone trimmed X42 output line; duplicate execution must fail. " +
                "Transcript:\n\(normalizedTranscript)"
        )
    }

    func testAllStructuredPackageRejectionsUseProductionLocalizedMapping() {
        let cases: [(rejection: CMUXSidebarRunCommandRejection, expected: String)] = [
            (
                .commandRejected,
                String(
                    localized: "sidebar.extensions.action.commandRejected",
                    defaultValue: "Command must be nonempty, no more than 8192 UTF-8 bytes, single-line, and contain no control or separator characters"
                )
            ),
            (
                .terminalNotFound,
                String(
                    localized: "sidebar.extensions.action.terminalNotFound",
                    defaultValue: "Terminal surface not found"
                )
            ),
            (
                .targetNotTerminal,
                String(
                    localized: "sidebar.extensions.action.targetNotTerminal",
                    defaultValue: "Target surface is not a terminal"
                )
            ),
            (
                .terminalUnavailable,
                String(
                    localized: "sidebar.extensions.action.terminalUnavailable",
                    defaultValue: "Terminal surface is not live"
                )
            ),
            (
                .terminalInputRejected,
                String(
                    localized: "sidebar.extensions.action.terminalInputRejected",
                    defaultValue: "Terminal surface did not accept input"
                )
            ),
        ]

        for testCase in cases {
            let result = adapter.result(for: .rejected(testCase.rejection))

            XCTAssertFalse(result.accepted, "\(testCase.rejection)")
            XCTAssertEqual(result.message, testCase.expected, "\(testCase.rejection)")
        }
    }
}
