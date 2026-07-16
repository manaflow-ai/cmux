import AppKit
import CmuxControlSocket
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RemoteTmuxMirrorTargetingTests {
    @Test func multiPaneMirrorSurfaceTitlesUseWindowName() throws {
        let harness = try MirrorTitleHarness()
        defer { harness.tearDown() }
        harness.publishListWindows([
            "@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] editor",
            "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]} abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]} [] logs",
        ])
        try harness.drainThroughPaneRects([
            1: ["%0 0 0 80 24 1 off :0 \"cmuxs-Mac-mini.local\""],
            2: [
                "%4 0 0 60 40 1 off :0 \"cmuxs-Mac-mini.local\"",
                "%5 61 0 59 20 0 off :1 \"cmuxs-Mac-mini.local\"",
                "%8 61 21 59 19 0 off :2 \"cmuxs-Mac-mini.local\"",
            ],
        ])
        #expect(try harness.surfaceTitles() == ["editor", "logs", "logs [1]", "logs [2]"])
    }

    @Test func singlePaneMirrorSurfaceTitleStillUsesWindowName() throws {
        let harness = try MirrorTitleHarness()
        defer { harness.tearDown() }
        harness.publishListWindows(["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] editor"])
        try harness.drainThroughPaneRects([1: ["%0 0 0 80 24 1 off :0 \"cmuxs-Mac-mini.local\""]])
        #expect(try harness.surfaceTitles() == ["editor"])
    }

    @Test func singlePaneToMultiPaneTransitionKeepsWindowNameInSurfaceTitles() throws {
        let harness = try MirrorTitleHarness()
        defer { harness.tearDown() }
        harness.publishListWindows(["@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] logs"])
        try harness.drainThroughPaneRects([2: ["%4 0 0 80 24 1 off :0 \"cmuxs-Mac-mini.local\""]])
        #expect(try harness.surfaceTitles() == ["logs"])

        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2, layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}", visibleLayout: nil, zoomed: false
        ))
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 1 off :0 \"cmuxs-Mac-mini.local\"",
            "%5 61 0 59 40 0 off :1 \"cmuxs-Mac-mini.local\"",
        ]])

        #expect(try harness.surfaceTitles() == ["logs", "logs [1]"])
    }

    @MainActor private struct MirrorTitleHarness {
        let windowId: UUID
        let controller: RemoteTmuxController
        let host: RemoteTmuxHost
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let workspace: Workspace

        init() throws {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let controller = RemoteTmuxController()
            let host = RemoteTmuxHost(destination: "user@host")
            let connection = RemoteTmuxControlConnection(host: host, sessionName: "dogfood-a")
            let pipe = Pipe()
            let writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting, label: "remote-tmux-title-test", maxPendingBytes: 1 << 16, onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(.commandResult(commandNumber: 0, lines: [], isError: false))
            controller.cacheConnection(connection)
            try controller.mirrorSession(host: host, sessionName: "dogfood-a", into: manager)
            workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
            self.windowId = windowId
            self.controller = controller
            self.host = host
            self.connection = connection
            self.writer = writer
            self.pipe = pipe
        }

        func publishListWindows(_ lines: [String]) {
            connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: lines, isError: false))
        }

        func drainThroughPaneRects(_ linesByWindow: [Int: [String]]) throws {
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                if case let .paneRects(windowId, _) = kind {
                    lines = try #require(linesByWindow[windowId])
                } else {
                    lines = []
                }
                connection.handleMessageForTesting(.commandResult(commandNumber: 2, lines: lines, isError: false))
            }
        }

        func surfaceTitles() throws -> [String] {
            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: workspace.id,
                surfaceID: nil,
                paneID: nil
            )
            let snapshot = try #require(TerminalController.shared.controlSurfaceList(routing: routing))
            return snapshot.surfaces.map(\.title)
        }

        func tearDown() {
            controller.detach(host: host, sessionName: "dogfood-a")
            writer.close()
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowId.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
