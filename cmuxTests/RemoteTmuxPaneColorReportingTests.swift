import AppKit
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct RemoteTmuxPaneColorReportingTests {
    @MainActor
    private struct Wire {
        let connection: RemoteTmuxControlConnection
        let pipe: Pipe
        let writer: RemoteTmuxControlPipeWriter

        init(connection: RemoteTmuxControlConnection? = nil, connected: Bool = true) {
            self.connection = connection ?? RemoteTmuxControlConnection(
                host: RemoteTmuxHost(destination: "user@pane-colors.test"),
                sessionName: "work"
            )
            pipe = Pipe()
            writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-pane-color-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            self.connection.installStdinWriterForTesting(writer)
            if connected {
                self.connection.handleMessageForTesting(.enter)
                self.connection.handleMessageForTesting(
                    .commandResult(commandNumber: 0, lines: [], isError: false)
                )
                drain()
            }
        }

        func drain(paneId: Int? = nil) {
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if let paneId {
                    switch kind {
                    case .listWindows:
                        lines = ["@1 f92f,80x24,0,0,\(paneId) f92f,80x24,0,0,\(paneId) [] main"]
                    case .paneRects:
                        lines = ["%\(paneId) 0 0 80 24 1 off :0 \"host\""]
                    default:
                        lines = []
                    }
                } else {
                    lines = []
                }
                connection.handleMessageForTesting(
                    .commandResult(commandNumber: 1, lines: lines, isError: false)
                )
            }
        }

        func colorCommands() throws -> [String] {
            writer.close()
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            try pipe.fileHandleForReading.close()
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
                .map(String.init).filter { $0.hasPrefix("refresh-client -r ") }
        }
    }

    private func darkColors() throws -> RemoteTmuxPaneColors {
        try #require(RemoteTmuxPaneColors(foreground: "#f0f6fc", background: "#0d1117"))
    }

    private func lightColors() throws -> RemoteTmuxPaneColors {
        try #require(RemoteTmuxPaneColors(foreground: "#1f2328", background: "#ffffff"))
    }

    @Test func reportsAreDeduplicatedAndUpdatedPerPane() throws {
        let wire = Wire()
        defer { wire.connection.stop() }
        let dark = try darkColors()
        let light = try lightColors()
        wire.connection.setPaneColors(dark, paneId: 4)
        wire.connection.setPaneColors(dark, paneId: 4)
        wire.connection.setPaneColors(light, paneId: 5)
        wire.connection.setPaneColors(light, paneId: 4)
        #expect(try wire.colorCommands() ==
            dark.reportCommands(paneId: 4)
            + light.reportCommands(paneId: 5)
            + light.reportCommands(paneId: 4))
    }

    @Test func colorsWaitForAttachAndReplayAfterReconnect() throws {
        let first = Wire(connected: false)
        let connection = first.connection
        defer { connection.stop() }
        let dark = try darkColors()
        connection.setPaneColors(dark, paneId: 4)
        connection.handleMessageForTesting(.enter)
        #expect(connection.pendingCommandKindsForTesting.isEmpty)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.pendingAttachRedrawKick = false
        first.drain(paneId: 4)
        #expect(try first.colorCommands() == dark.reportCommands(paneId: 4))

        connection.beginReconnecting()
        let light = try lightColors()
        connection.setPaneColors(light, paneId: 4)
        let second = Wire(connection: connection, connected: false)
        connection.handleMessageForTesting(.enter)
        connection.requestWindows()
        second.drain(paneId: 4)
        #expect(try second.colorCommands() == light.reportCommands(paneId: 4))
    }

    @Test func olderServersRejectReportingWithoutBreakingInput() throws {
        let wire = Wire()
        defer { wire.connection.stop() }
        let dark = try darkColors()
        wire.connection.setPaneColors(dark, paneId: 4)
        wire.connection.handleMessageForTesting(.commandResult(
            commandNumber: 2, lines: ["command refresh-client: unknown flag -r"], isError: true
        ))
        #expect(!wire.connection.supportsPaneColorReports)
        #expect(wire.connection.connectionState == .connected)
        wire.connection.setPaneColors(try lightColors(), paneId: 4)
        #expect(wire.connection.sendKeys(paneId: 4, data: Data("x".utf8)))
        #expect(try wire.colorCommands() == dark.reportCommands(paneId: 4))
    }

    @Test func anOlderFailedReportDoesNotEraseANewerColorUpdate() throws {
        let wire = Wire()
        defer { wire.connection.stop() }
        let dark = try darkColors()
        let light = try lightColors()
        wire.connection.setPaneColors(dark, paneId: 4)
        wire.connection.setPaneColors(light, paneId: 4)
        wire.connection.handleMessageForTesting(.commandResult(
            commandNumber: 2, lines: ["temporary report failure"], isError: true
        ))
        #expect(wire.connection.sentPaneColors[4] == light)
        #expect(wire.connection.supportsPaneColorReports)
        wire.connection.setPaneColors(light, paneId: 4)
        #expect(try wire.colorCommands().count == 4)
    }

    @Test func removedPanesAreNotReplayed() throws {
        let wire = Wire()
        defer { wire.connection.stop() }
        let dark = try darkColors()
        wire.connection.setPaneColors(dark, paneId: 4)
        wire.connection.setPaneColors(dark, paneId: 5)
        wire.connection.removePaneColors(paneId: 4)
        wire.connection.replayPaneColorReports()
        #expect(wire.connection.paneColors[4] == nil)
        #expect(try wire.colorCommands() ==
            dark.reportCommands(paneId: 4)
            + dark.reportCommands(paneId: 5)
            + dark.reportCommands(paneId: 5))
    }

    @Test func topologyGapsRetainColorsUntilPaneOwnershipIsResolved() throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@pane-colors.test"),
            sessionName: "work"
        )
        defer { connection.stop() }
        func layout(_ paneId: Int) -> RemoteTmuxLayoutNode {
            RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(paneId))
        }
        connection.windowsByID[1] = RemoteTmuxWindow(
            id: 1, name: "published", width: 80, height: 24, layout: layout(4)
        )
        connection.pendingLayouts[2] = RemoteTmuxPendingLayout(
            node: layout(5), visibleNode: layout(6), zoomed: true, name: "pending", generation: 1
        )
        connection.initialBatchStaged[3] = RemoteTmuxWindow(
            id: 3, name: "staged", width: 80, height: 24, layout: layout(7)
        )
        connection.paneIDsRetainedUntilWindowList = [8]
        let colors = try darkColors()
        for paneId in 4...9 {
            connection.paneColors[paneId] = colors
            connection.sentPaneColors[paneId] = colors
            connection.paneHeaderLabels[paneId] = "pane-\(paneId)"
        }

        connection.prunePaneState(keeping: connection.paneIDsForStatePruning())

        let retainedPaneIds: Set<Int> = [4, 5, 6, 7, 8]
        #expect(Set(connection.paneColors.keys) == retainedPaneIds)
        #expect(Set(connection.sentPaneColors.keys) == retainedPaneIds)
        #expect(Set(connection.paneHeaderLabels.keys) == retainedPaneIds)

        connection.pendingLayouts.removeAll()
        connection.initialBatchStaged.removeAll()
        connection.paneIDsRetainedUntilWindowList.removeAll()
        connection.prunePaneState(keeping: connection.paneIDsForStatePruning())

        #expect(connection.paneColors == [4: colors])
        #expect(connection.sentPaneColors == [4: colors])
        #expect(connection.paneHeaderLabels == [4: "pane-4"])
    }

    @Test func surfaceThemeChangesRefreshOnlyTheOwnedPane() async throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let wire = Wire()
        let dark = try darkColors()
        let light = try lightColors()
        var currentColors = dark
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: wire.connection,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(4)
            ),
            paneColorsSource: { _ in currentColors },
            makePanel: { _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
        )
        defer {
            mirror.teardown()
            wire.connection.stop()
        }
        let surfaceId = try #require(mirror.panel(forPane: 4)?.surface.id)
        currentColors = light
        NotificationCenter.default.post(name: .ghosttySurfaceThemeDidChange, object: UUID())
        await Task.yield()
        #expect(wire.connection.sentPaneColors[4] == dark)
        NotificationCenter.default.post(name: .ghosttySurfaceThemeDidChange, object: surfaceId)
        for _ in 0..<50 {
            if wire.connection.sentPaneColors[4] == light { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(wire.connection.sentPaneColors[4] == light)
        currentColors = dark
        NotificationCenter.default.post(name: .ghosttyDefaultBackgroundDidChange, object: nil)
        for _ in 0..<50 {
            if wire.connection.sentPaneColors[4] == dark { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(wire.connection.sentPaneColors[4] == dark)
        mirror.teardown()
        currentColors = light
        NotificationCenter.default.post(name: .ghosttySurfaceThemeDidChange, object: surfaceId)
        await Task.yield()
        #expect(wire.connection.paneColors[4] == nil)
        #expect(try wire.colorCommands() ==
            dark.reportCommands(paneId: 4)
            + light.reportCommands(paneId: 4)
            + dark.reportCommands(paneId: 4))
    }

    @Test func oldWindowTeardownDoesNotForgetAMovedPanesNewColors() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let wire = Wire()
        defer { wire.connection.stop() }
        let dark = try darkColors()
        let light = try lightColors()
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: wire.connection,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(4)
            ),
            paneColorsSource: { _ in dark },
            makePanel: { _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
        )
        wire.connection.publishedWindowIdByPane[4] = 2
        wire.connection.setPaneColors(light, paneId: 4)
        mirror.reportPaneColors(paneId: 4)
        mirror.teardown()
        #expect(wire.connection.paneColors[4] == light)
        #expect(try wire.colorCommands() ==
            dark.reportCommands(paneId: 4) + light.reportCommands(paneId: 4))
    }

    @Test func newMirrorReportsBothColorsBeforeSeedingPane() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, autoWelcomeIfNeeded: false)
        workspace.isRemoteTmuxMirror = true
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@pane-colors.test"),
            sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-pane-colors",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        while !connection.pendingCommandKindsForTesting.isEmpty {
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 1, lines: [], isError: false)
            )
        }

        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: UUID(),
            connection: connection,
            layout: RemoteTmuxLayoutNode(
                width: 80, height: 24, x: 0, y: 0, content: .pane(4)
            ),
            makePanel: { _ in workspace.makeRemoteTmuxPanePanel(onInput: { _ in }) }
        )
        defer {
            mirror.teardown()
            connection.stop()
            try? pipe.fileHandleForReading.close()
        }
        #expect(mirror.panel(forPane: 4) != nil)
        writer.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let commands = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        let reportIndices = commands.indices.filter {
            commands[$0].hasPrefix("refresh-client -r ") && commands[$0].contains("%4:")
        }
        #expect(reportIndices.count == 2)
        let lastReportIndex = try #require(reportIndices.last)
        // The seed goes out as one ` ; `-joined tmux command queue (output
        // pause, alt-screen query, capture-pane, ...), so capture-pane is not
        // at the start of its line.
        let captureIndex = try #require(commands.firstIndex {
            $0.contains("capture-pane ") && $0.contains("-t %4")
        })
        #expect(lastReportIndex < captureIndex)
        let reports = reportIndices.map { commands[$0] }.joined(separator: "\n")
        #expect(reports.contains("]10;rgb:"))
        #expect(reports.contains("]11;rgb:"))
        #expect(!reports.contains("send-keys"))
        #expect(!reports.contains("set-option"))
    }
}
