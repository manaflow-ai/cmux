import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxMirrorLayoutIdentityTests {
    @Test("remote layout changes reconcile pane identities incrementally")
    func remoteLayoutChangesReconcilePaneIdentitiesIncrementally() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let originalPanel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        let originalSurfaceID = originalPanel.id
        let originalPaneID = try #require(
            harness.workspace.paneId(forPanelId: originalSurfaceID)
        )

        try harness.publishLayout(
            "abcd,80x24,0,0[80x12,0,0,11,80x11,0,13,22]",
            rects: [
                "%11 0 0 80 12 1 off :zsh",
                "%22 0 13 80 11 0 off :zsh",
            ]
        )

        let mirror = try #require(harness.windowMirror)
        #expect(mirror.panel(forPane: 11) === originalPanel)
        #expect(mirror.panel(forPane: 11)?.id == originalSurfaceID)
        #expect(mirror.syntheticPaneID(forPane: 11) == originalPaneID)
        #expect(Set(mirror.controlPanes().map(\.panel.id)).count == 2)
        #expect(Set(mirror.controlPanes().map(\.panel.id)).contains(originalSurfaceID))

        let secondSurfaceID = try #require(mirror.panel(forPane: 22)?.id)
        let secondPaneID = try #require(mirror.syntheticPaneID(forPane: 22))
        try harness.publishLayout(
            "abcd,80x24,0,0[80x12,0,0,11,80x11,0,13{40x11,0,13,22,39x11,41,13,33}]",
            rects: [
                "%11 0 0 80 12 1 off :zsh",
                "%22 0 13 40 11 0 off :zsh",
                "%33 41 13 39 11 0 off :zsh",
            ]
        )

        #expect(harness.windowMirror === mirror)
        #expect(mirror.panel(forPane: 11) === originalPanel)
        #expect(mirror.panel(forPane: 11)?.id == originalSurfaceID)
        #expect(mirror.syntheticPaneID(forPane: 11) == originalPaneID)
        #expect(mirror.panel(forPane: 22)?.id == secondSurfaceID)
        #expect(mirror.syntheticPaneID(forPane: 22) == secondPaneID)
        #expect(Set(mirror.controlPanes().map(\.panel.id)).count == 3)

        weak var removedSecondPanel: TerminalPanel?
        removedSecondPanel = mirror.panel(forPane: 22)
        try harness.publishLayout(
            "abcd,80x24,0,0[80x12,0,0,11,80x11,0,13,33]",
            rects: [
                "%11 0 0 80 12 1 off :zsh",
                "%33 0 13 80 11 0 off :zsh",
            ]
        )

        #expect(mirror.panel(forPane: 11) === originalPanel)
        #expect(mirror.panel(forPane: 11)?.id == originalSurfaceID)
        #expect(mirror.syntheticPaneID(forPane: 11) == originalPaneID)
        #expect(mirror.panel(forPane: 22) == nil)
        #expect(mirror.controlPane(surfaceID: secondSurfaceID) == nil)
        #expect(harness.sessionMirror.paneId(forSurfaceId: secondSurfaceID) == nil)
        #expect(removedSecondPanel == nil)
        #expect(Set(mirror.controlPanes().map(\.tmuxPaneID)) == [11, 33])

        let thirdSurfaceID = try #require(mirror.panel(forPane: 33)?.id)
        weak var removedThirdPanel: TerminalPanel?
        removedThirdPanel = mirror.panel(forPane: 33)
        try harness.publishLayout(
            "abcd,80x24,0,0,11",
            rects: ["%11 0 0 80 24 1 off :zsh"]
        )

        #expect(harness.windowMirror === mirror)
        #expect(mirror.panel(forPane: 11) === originalPanel)
        #expect(mirror.panel(forPane: 11)?.id == originalSurfaceID)
        #expect(mirror.syntheticPaneID(forPane: 11) == originalPaneID)
        #expect(mirror.panel(forPane: 33) == nil)
        #expect(mirror.controlPane(surfaceID: thirdSurfaceID) == nil)
        #expect(harness.sessionMirror.paneId(forSurfaceId: thirdSurfaceID) == nil)
        #expect(removedThirdPanel == nil)
        #expect(mirror.controlPanes().map(\.tmuxPaneID) == [11])
    }

    @Test("fallback rebuild keeps control identities unique and stable")
    func fallbackRebuildKeepsControlIdentitiesUniqueAndStable() throws {
        let harness = try Harness(
            initialLayout: "f92f,80x24,0,0[80x12,0,0,11,80x11,0,13,22]",
            initialRects: [
                "%11 0 0 80 12 1 off :zsh",
                "%22 0 13 80 11 0 off :zsh",
            ]
        )
        defer { harness.tearDown() }

        let mirror = try #require(harness.windowMirror)
        let firstPanel = try #require(mirror.panel(forPane: 11))
        let secondPanel = try #require(mirror.panel(forPane: 22))
        let firstControlID = try #require(mirror.syntheticPaneID(forPane: 11))
        let secondControlID = try #require(mirror.syntheticPaneID(forPane: 22))

        // Two coalesced additions cannot use the targeted single-leaf path. Put
        // a new pane first so Bonsplit reuses its retained root node for it.
        try harness.publishLayout(
            "abcd,80x24,0,0[80x6,0,0,33,80x5,0,7,11,80x5,0,13,22,80x5,0,19,44]",
            rects: [
                "%33 0 0 80 6 0 off :zsh",
                "%11 0 7 80 5 1 off :zsh",
                "%22 0 13 80 5 0 off :zsh",
                "%44 0 19 80 5 0 off :zsh",
            ]
        )

        #expect(harness.windowMirror === mirror)
        #expect(mirror.panel(forPane: 11) === firstPanel)
        #expect(mirror.panel(forPane: 22) === secondPanel)
        #expect(mirror.syntheticPaneID(forPane: 11) == firstControlID)
        #expect(mirror.syntheticPaneID(forPane: 22) == secondControlID)
        let controlIDs = mirror.controlPanes().map(\.paneID)
        #expect(controlIDs.count == 4)
        #expect(Set(controlIDs).count == controlIDs.count)
    }
}

@MainActor
private final class Harness {
    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe
    let manager: TabManager
    let workspace: Workspace
    let sessionMirror: RemoteTmuxSessionMirror

    init(
        initialLayout: String = "f92f,80x24,0,0,11",
        initialRects: [String] = ["%11 0 0 80 24 1 off :zsh"]
    ) throws {
        connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "work"
        )
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-layout-identity-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1,
            lines: ["@1 \(initialLayout) \(initialLayout) [] editor"],
            isError: false
        ))
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 2,
            lines: initialRects,
            isError: false
        ))

        manager = TabManager(autoWelcomeIfNeeded: false)
        workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        sessionMirror = RemoteTmuxSessionMirror(
            host: connection.host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace
        )
        drainCommandsBeforeLayout()
    }

    var windowMirror: RemoteTmuxWindowMirror? {
        workspace.panels.keys.lazy.compactMap {
            workspace.remoteTmuxWindowMirror(forPanelId: $0)
        }.first
    }

    func singlePanePanel(tmuxPaneID: Int) -> TerminalPanel? {
        workspace.panels.values.compactMap { $0 as? TerminalPanel }.first {
            sessionMirror.paneId(forSurfaceId: $0.id) == tmuxPaneID
        }
    }

    func publishLayout(_ layout: String, rects: [String]) throws {
        drainCommandsBeforeLayout()
        var parser = RemoteTmuxControlStreamParser()
        let messages = parser.feed(Data("%layout-change @1 \(layout) \(layout) *\r\n".utf8))
        let message = try #require(messages.only)
        connection.handleMessageForTesting(message)

        while let first = connection.pendingCommandKindsForTesting.first {
            if case .paneRects = first { break }
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
            )
        }
        guard let first = connection.pendingCommandKindsForTesting.first,
              case .paneRects = first else {
            Issue.record("expected a pane rects command for layout \(layout)")
            return
        }
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: rects, isError: false)
        )
    }

    func tearDown() {
        sessionMirror.detachObserver()
        workspace.isRemoteTmuxMirror = false
        manager.tabs.forEach { $0.teardownAllPanels() }
        writer.close()
        try? pipe.fileHandleForReading.close()
    }

    private func drainCommandsBeforeLayout() {
        while !connection.pendingCommandKindsForTesting.isEmpty {
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
            )
        }
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
