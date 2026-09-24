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
        let reportIndex = try #require(commands.firstIndex {
            $0.hasPrefix("refresh-client -r ") && $0.contains("%4:")
        })
        let captureIndex = try #require(commands.firstIndex {
            $0.hasPrefix("capture-pane ") && $0.contains("%4")
        })
        #expect(reportIndex < captureIndex)
        #expect(commands[reportIndex].contains("]10;rgb:"))
        #expect(commands[reportIndex].contains("]11;rgb:"))
        #expect(!commands[reportIndex].contains("send-keys"))
        #expect(!commands[reportIndex].contains("set-option"))
    }
}
