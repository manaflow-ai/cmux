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
        let originalPaneID = PaneID(id: try #require(
            harness.controlPaneID(surfaceID: originalSurfaceID)
        ))

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

    @Test("session pane identities stay unique and stable across a window split")
    func sessionPaneIdentitiesStayUniqueAndStableAcrossAWindowSplit() throws {
        let harness = try Harness(
            initialWindowLines: [
                "@1 f92f,80x24,0,0,11 f92f,80x24,0,0,11 [] editor",
                "@2 abcd,80x24,0,0,44 abcd,80x24,0,0,44 [] logs",
            ],
            initialRectsByWindow: [
                1: ["%11 0 0 80 24 1 off :zsh"],
                2: ["%44 0 0 80 24 0 off :zsh"],
            ]
        )
        defer { harness.tearDown() }

        let editorPanel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        let logsPanel = try #require(harness.singlePanePanel(tmuxPaneID: 44))
        let editorSurfaceID = editorPanel.id
        let logsSurfaceID = logsPanel.id
        let editorControlID = try #require(harness.controlPaneID(surfaceID: editorSurfaceID))
        let logsControlID = try #require(harness.controlPaneID(surfaceID: logsSurfaceID))
        #expect(editorControlID != logsControlID)

        try harness.publishLayout(
            "beef,80x24,0,0[80x12,0,0,11,80x11,0,13,22]",
            rects: [
                "%11 0 0 80 12 1 off :zsh",
                "%22 0 13 80 11 0 off :zsh",
                "%44 0 0 80 24 0 off :zsh",
            ]
        )

        let mirror = try #require(harness.windowMirror(windowID: 1))
        #expect(mirror.panel(forPane: 11) === editorPanel)
        #expect(mirror.panel(forPane: 11)?.id == editorSurfaceID)
        #expect(harness.singlePanePanel(tmuxPaneID: 44) === logsPanel)
        #expect(harness.controlPaneID(surfaceID: editorSurfaceID) == editorControlID)
        #expect(harness.controlPaneID(surfaceID: logsSurfaceID) == logsControlID)
        let addedControlID = try #require(
            mirror.panel(forPane: 22).flatMap { harness.controlPaneID(surfaceID: $0.id) }
        )
        #expect(addedControlID != editorControlID)
        #expect(addedControlID != logsControlID)
    }

    @Test("leading-edge split adopts the panel for its original tmux pane")
    func leadingEdgeSplitAdoptsOriginalPanePanel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let originalPanel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        let originalSurfaceID = originalPanel.id
        let originalControlID = try #require(harness.controlPaneID(surfaceID: originalSurfaceID))

        try harness.publishLayout(
            "beef,80x24,0,0[80x12,0,0,22,80x11,0,13,11]",
            rects: [
                "%22 0 0 80 12 1 off :zsh",
                "%11 0 13 80 11 0 off :zsh",
            ]
        )

        let mirror = try #require(harness.windowMirror)
        #expect(mirror.panel(forPane: 11) === originalPanel)
        #expect(mirror.panel(forPane: 11)?.id == originalSurfaceID)
        #expect(mirror.panel(forPane: 22) !== originalPanel)
        #expect(harness.controlPaneID(surfaceID: originalSurfaceID) == originalControlID)
    }

    @Test("pane reorder keeps live panels and surface refs")
    func paneReorderKeepsLivePanelsAndSurfaceRefs() throws {
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
        let firstRef = try #require(
            TerminalController.shared.v2Ref(kind: .surface, uuid: firstPanel.id) as? String
        )
        let secondRef = try #require(
            TerminalController.shared.v2Ref(kind: .surface, uuid: secondPanel.id) as? String
        )

        try harness.publishLayout(
            "beef,80x24,0,0[80x12,0,0,22,80x11,0,13,11]",
            rects: [
                "%22 0 0 80 12 1 off :zsh",
                "%11 0 13 80 11 0 off :zsh",
            ]
        )

        #expect(mirror.panel(forPane: 11) === firstPanel)
        #expect(mirror.panel(forPane: 22) === secondPanel)
        #expect(TerminalController.shared.v2ResolveHandleRef(firstRef) == firstPanel.id)
        #expect(TerminalController.shared.v2ResolveHandleRef(secondRef) == secondPanel.id)
    }

    @Test(
        "cross-window pane moves preserve identity in either publication order",
        arguments: [false, true]
    )
    func crossWindowPaneMovesPreserveIdentity(destinationFirst: Bool) throws {
        let harness = try Harness(
            initialWindowLines: [
                "@1 f92f,80x24,0,0[80x12,0,0,11,80x11,0,13,22] "
                    + "f92f,80x24,0,0[80x12,0,0,11,80x11,0,13,22] [] editor",
                "@2 abcd,80x24,0,0,44 abcd,80x24,0,0,44 [] logs",
            ],
            initialRectsByWindow: [
                1: ["%11 0 0 80 12 1 off :zsh", "%22 0 13 80 11 0 off :zsh"],
                2: ["%44 0 0 80 24 1 off :zsh"],
            ]
        )
        defer { harness.tearDown() }

        let sourceMirror = try #require(harness.windowMirror(windowID: 1))
        let oldSurfaceID = try #require(sourceMirror.panel(forPane: 22)?.id)
        let stablePaneID = try #require(harness.controlPaneID(surfaceID: oldSurfaceID))
        weak var oldPanel = sourceMirror.panel(forPane: 22)

        let source = Harness.LayoutUpdate(
            windowID: 1,
            layout: "beef,80x24,0,0,11",
            rects: ["%11 0 0 80 24 1 off :zsh"]
        )
        let destination = Harness.LayoutUpdate(
            windowID: 2,
            layout: "cafe,80x24,0,0[80x12,0,0,44,80x11,0,13,22]",
            rects: ["%44 0 0 80 12 1 off :zsh", "%22 0 13 80 11 0 off :zsh"]
        )
        try harness.publishLayouts(destinationFirst ? [destination, source] : [source, destination])

        let destinationMirror = try #require(harness.windowMirror(windowID: 2))
        let newSurfaceID = try #require(destinationMirror.panel(forPane: 22)?.id)
        #expect(newSurfaceID != oldSurfaceID)
        #expect(harness.controlPaneID(surfaceID: oldSurfaceID) == nil)
        #expect(harness.controlPaneID(surfaceID: newSurfaceID) == stablePaneID)
        #expect(harness.sessionMirror.controlPaneID(forPane: 22)?.id == stablePaneID)
        #expect(oldPanel == nil)
        let paneIDs = TerminalController.shared
            .controlPaneList(workspace: harness.workspace, tabManager: harness.manager)
            .panes.map(\.paneID)
        #expect(Set(paneIDs).count == paneIDs.count)
    }

    @Test("moving a window's only pane preserves its control identity")
    func movingOnlyPanePreservesControlIdentity() throws {
        let harness = try Harness(
            initialWindowLines: [
                "@1 f92f,80x24,0,0,11 f92f,80x24,0,0,11 [] editor",
                "@2 abcd,80x24,0,0,44 abcd,80x24,0,0,44 [] logs",
            ],
            initialRectsByWindow: [
                1: ["%11 0 0 80 24 1 off :zsh"],
                2: ["%44 0 0 80 24 1 off :zsh"],
            ]
        )
        defer { harness.tearDown() }

        let oldPanel = try #require(harness.singlePanePanel(tmuxPaneID: 11))
        let oldSurfaceID = oldPanel.id
        let stablePaneID = try #require(harness.controlPaneID(surfaceID: oldSurfaceID))

        harness.connection.handleMessageForTesting(.windowClose(windowId: 1))
        #expect(harness.workspace.panels[oldSurfaceID] == nil)
        #expect(harness.sessionMirror.controlPaneID(forPane: 11)?.id == stablePaneID)
        harness.connection.handleMessageForTesting(.windowRenamed(windowId: 2, name: "renamed"))
        #expect(harness.sessionMirror.controlPaneID(forPane: 11)?.id == stablePaneID)
        let layout = "cafe,80x24,0,0[80x12,0,0,44,80x11,0,13,11]"
        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2, layout: layout, visibleLayout: layout, zoomed: false
        ))
        harness.connection.handleMessageForTesting(.commandResult(
            commandNumber: 0,
            lines: ["@2 \(layout) \(layout) [] logs"],
            isError: false
        ))
        while let command = harness.connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            if case .paneRects(let windowID, _) = command, windowID == 2 {
                lines = ["%44 0 0 80 12 1 off :zsh", "%11 0 13 80 11 0 off :zsh"]
            } else {
                lines = []
            }
            harness.connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: lines, isError: false)
            )
        }

        let destination = try #require(harness.windowMirror(windowID: 2))
        let newSurfaceID = try #require(destination.panel(forPane: 11)?.id)
        #expect(newSurfaceID != oldSurfaceID)
        #expect(harness.controlPaneID(surfaceID: newSurfaceID) == stablePaneID)
        #expect(harness.sessionMirror.controlPaneID(forPane: 11)?.id == stablePaneID)
    }
}

private typealias Harness = RemoteTmuxSessionMirrorLayoutHarness

@MainActor
final class RemoteTmuxSessionMirrorLayoutHarness {
    struct LayoutUpdate {
        let windowID: Int
        let layout: String
        let rects: [String]
    }

    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe
    let manager: TabManager
    let workspace: Workspace
    let sessionMirror: RemoteTmuxSessionMirror

    init(
        initialLayout: String = "f92f,80x24,0,0,11",
        initialWindowLines: [String]? = nil,
        initialRects: [String] = ["%11 0 0 80 24 1 off :zsh"],
        initialRectsByWindow: [Int: [String]]? = nil
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
            lines: initialWindowLines ?? ["@1 \(initialLayout) \(initialLayout) [] editor"],
            isError: false
        ))
        let rectsByWindow = initialRectsByWindow ?? [1: initialRects]
        while let kind = connection.pendingCommandKindsForTesting.first {
            guard case .paneRects(let windowID, _) = kind else { break }
            connection.handleMessageForTesting(.commandResult(
                commandNumber: 2,
                lines: rectsByWindow[windowID] ?? [],
                isError: false
            ))
        }

        manager = TabManager(autoWelcomeIfNeeded: false)
        workspace = try #require(manager.selectedWorkspace)
        workspace.isRemoteTmuxMirror = true
        sessionMirror = RemoteTmuxSessionMirror(
            host: connection.host,
            sessionName: "work",
            connection: connection,
            tabManager: manager,
            workspace: workspace,
            onControlPaneRemoved: TerminalController.remoteTmuxControlPaneRemovalHandler(),
            onControlSurfaceRemoved: TerminalController.remoteTmuxControlSurfaceRemovalHandler()
        )
        drainCommandsBeforeLayout()
    }

    var windowMirror: RemoteTmuxWindowMirror? {
        windowMirror(windowID: nil)
    }

    func windowMirror(windowID: Int?) -> RemoteTmuxWindowMirror? {
        workspace.panels.keys.lazy.compactMap {
            self.workspace.remoteTmuxWindowMirror(forPanelId: $0)
        }.first(where: { windowID == nil || $0.windowId == windowID })
    }

    func controlPaneID(surfaceID: UUID) -> UUID? {
        TerminalController.shared.controlPaneList(workspace: workspace, tabManager: manager)
            .panes.first(where: { $0.surfaceIDs.contains(surfaceID) })?.paneID
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

    func publishLayouts(_ updates: [LayoutUpdate]) throws {
        drainCommandsBeforeLayout()
        var parser = RemoteTmuxControlStreamParser()
        for update in updates {
            let line = "%layout-change @\(update.windowID) \(update.layout) \(update.layout) *\r\n"
            let message = try #require(parser.feed(Data(line.utf8)).only)
            connection.handleMessageForTesting(message)
        }
        let rectsByWindow = Dictionary(uniqueKeysWithValues: updates.map { ($0.windowID, $0.rects) })
        while let first = connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            if case .paneRects(let windowID, _) = first {
                lines = rectsByWindow[windowID] ?? []
            } else {
                lines = []
            }
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: lines, isError: false)
            )
        }
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
