import AppKit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A connected, in-process two-pane tmux mirror used by rename behavior tests.
@MainActor
final class RemoteTmuxMirrorRenameHarness {
    let windowID: UUID
    let controller: RemoteTmuxController
    let host: RemoteTmuxHost
    let sessionName: String
    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe
    let workspace: Workspace

    init(includeSecondWindow: Bool = false) throws {
        let appDelegate = try #require(AppDelegate.shared)
        windowID = appDelegate.createMainWindow()
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        controller = appDelegate.remoteTmuxController
        host = RemoteTmuxHost(destination: "issue-8380-\(UUID().uuidString)@host")
        sessionName = "dogfood-issue-8380"
        connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-mirror-rename-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        controller.cacheConnection(connection)
        try controller.mirrorSession(
            host: host,
            sessionName: sessionName,
            into: manager
        )
        workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })

        var windowLines = [
            "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} "
                + "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} [] main",
        ]
        if includeSecondWindow {
            windowLines.append("@3 efgh,80x24,0,0,6 efgh,80x24,0,0,6 [] logs")
        }
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1,
            lines: windowLines,
            isError: false
        ))
        while let kind = connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            if case let .paneRects(windowID, _) = kind {
                lines = windowID == 2 ? [
                    "%4 0 0 60 40 1 off :0 \"remote-host\"",
                    "%5 61 0 59 40 0 off :1 \"remote-host\"",
                ] : ["%6 0 0 80 24 1 off :0 \"remote-host\""]
            } else {
                lines = []
            }
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 2, lines: lines, isError: false)
            )
        }
    }

    func surfaces() throws -> [ControlSurfaceSummary] {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: nil,
            paneID: nil
        )
        return try #require(
            TerminalController.shared.controlSurfaceList(routing: routing)
        ).surfaces
    }

    func finishCommands() throws -> [String] {
        writer.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    func tearDown() {
        controller.detach(host: host, sessionName: sessionName)
        writer.close()
        try? pipe.fileHandleForReading.close()
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
