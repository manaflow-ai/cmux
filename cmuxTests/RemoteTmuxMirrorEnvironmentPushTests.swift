import AppKit
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the mirror-identity environment push (issue #833).
///
/// An ssh-tmux mirror attaches with `tmux -CC` directly — there is no cmux
/// wrapper shell outside tmux on the remote host, so nothing ever re-publishes
/// cmux identity into the tmux environment after an app relaunch. The
/// connection now pushes a marker + identity pairs itself, on first connect
/// AND on every reconnect, using SESSION scope (`set-environment -t`) because
/// the shell-integration refresh path runs a session-scoped
/// `show-environment` that cannot see `-g` values.
@MainActor
@Suite struct RemoteTmuxMirrorEnvironmentPushTests {

    // MARK: - Pure command construction

    @Test func buildsSessionScopedSortedQuotedCommands() {
        let commands = RemoteTmuxControlConnection.mirrorEnvironmentCommands(
            target: "'work'",
            pairs: [
                "CMUX_WORKSPACE_ID": "ABC-123",
                "CMUX_REMOTE_TMUX_MIRROR": "1",
            ]
        )
        #expect(commands == [
            "set-environment -t 'work' CMUX_REMOTE_TMUX_MIRROR '1'",
            "set-environment -t 'work' CMUX_WORKSPACE_ID 'ABC-123'",
        ])
    }

    @Test func valueSingleQuotingEscapesEmbeddedQuote() {
        let commands = RemoteTmuxControlConnection.mirrorEnvironmentCommands(
            target: "$5",
            pairs: ["K": "it's"]
        )
        #expect(commands == ["set-environment -t $5 K 'it'\\''s'"])
    }

    @Test func dropsPairsThatWouldBreakTheControlLine() {
        // CR/LF or control bytes would terminate the command line before tmux
        // parses the quotes; a spaced key would splice into extra arguments.
        let commands = RemoteTmuxControlConnection.mirrorEnvironmentCommands(
            target: "'s'",
            pairs: [
                "GOOD": "value",
                "BAD_VALUE": "line1\nline2",
                "BAD KEY": "x",
            ]
        )
        #expect(commands == ["set-environment -t 's' GOOD 'value'"])
    }

    // MARK: - Connection wire behavior

    private struct Wire {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
    }

    private func makeWire(label: String) -> Wire {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@env-push.test"), sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: label,
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        return Wire(connection: connection, writer: writer, pipe: pipe)
    }

    private func attachWriter(_ wire: inout Wire, label: String) {
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: label,
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        wire.connection.installStdinWriterForTesting(writer)
        wire = Wire(connection: wire.connection, writer: writer, pipe: pipe)
    }

    private func drainPendingCommands(_ connection: RemoteTmuxControlConnection) {
        while let kind = connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            if case .paneRects = kind {
                lines = ["%0 0 0 80 24 1 off :0 \"host\""]
            } else {
                lines = []
            }
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 2, lines: lines, isError: false)
            )
        }
    }

    private func sentCommands(_ wire: Wire) throws -> [String] {
        wire.writer.close()
        let data = try wire.pipe.fileHandleForReading.readToEnd() ?? Data()
        try? wire.pipe.fileHandleForReading.close()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// First connect: the push rides the same post-attach alignment point as
    /// `applyClientSize` — after the attach block is drained and the first
    /// `list-windows` result lands.
    @Test func firstConnectPushesMarkerAndIdentitySessionScoped() throws {
        var wire = makeWire(label: "remote-tmux-env-push-first-connect")
        let connection = wire.connection
        connection.setMirrorEnvironment(["CMUX_WORKSPACE_ID": "11111111-2222-3333-4444-555555555555"])

        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.pendingAttachRedrawKick = false
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1,
            lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"],
            isError: false
        ))
        drainPendingCommands(connection)

        let commands = try sentCommands(wire)
        let pushes = commands.filter { $0.hasPrefix("set-environment") }
        // No %session-changed arrived, so the target is the quoted session name.
        #expect(pushes.contains("set-environment -t 'work' CMUX_REMOTE_TMUX_MIRROR '1'"))
        #expect(pushes.contains(
            "set-environment -t 'work' CMUX_WORKSPACE_ID '11111111-2222-3333-4444-555555555555'"
        ))
        let localRouteClears: Set<String> = [
            "set-environment -t 'work' CMUX_PANEL_ID ''",
            "set-environment -t 'work' CMUX_SOCKET ''",
            "set-environment -t 'work' CMUX_SOCKET_PATH ''",
            "set-environment -t 'work' CMUX_SURFACE_ID ''",
        ]
        #expect(Set(pushes).isSuperset(of: localRouteClears))
        // Session scope is the point of the fix: `-g` values are invisible to
        // the session-scoped `show-environment` the shell integration runs.
        #expect(pushes.allSatisfy { !$0.contains(" -g ") })
        // No relay exists on the ssh-tmux transport, so a non-empty local
        // socket or surface route must never survive in the mirrored session.
        #expect(pushes.allSatisfy {
            !$0.contains("CMUX_SOCKET_PATH '") || $0.hasSuffix("CMUX_SOCKET_PATH ''")
        })
        wire.connection.stop()
    }

    /// Reconnect: the `.reseed` post-attach branch pushes again, so values
    /// stale from before the drop (or an app relaunch) are refreshed.
    @Test func reconnectPushesAgain() throws {
        var wire = makeWire(label: "remote-tmux-env-push-reconnect-a")
        let connection = wire.connection
        connection.setMirrorEnvironment(["CMUX_WORKSPACE_ID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1,
            lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"],
            isError: false
        ))
        drainPendingCommands(connection)
        _ = try sentCommands(wire)

        connection.beginReconnecting()
        attachWriter(&wire, label: "remote-tmux-env-push-reconnect-b")
        connection.handleMessageForTesting(.enter)
        // The FIFO was drained above; requesting windows and answering models
        // the post-reconnect list-windows that consumes `.reseed`.
        connection.requestWindows()
        connection.handleMessageForTesting(.commandResult(
            commandNumber: 3,
            lines: ["@1 f92f,80x24,0,0,0 f92f,80x24,0,0,0 [] main"],
            isError: false
        ))
        drainPendingCommands(connection)

        let commands = try sentCommands(wire)
        let pushes = commands.filter { $0.hasPrefix("set-environment") }
        #expect(pushes.contains("set-environment -t 'work' CMUX_REMOTE_TMUX_MIRROR '1'"))
        #expect(pushes.contains(
            "set-environment -t 'work' CMUX_WORKSPACE_ID 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'"
        ))
        let localRouteClears: Set<String> = [
            "set-environment -t 'work' CMUX_PANEL_ID ''",
            "set-environment -t 'work' CMUX_SOCKET ''",
            "set-environment -t 'work' CMUX_SOCKET_PATH ''",
            "set-environment -t 'work' CMUX_SURFACE_ID ''",
        ]
        #expect(Set(pushes).isSuperset(of: localRouteClears))
        #expect(pushes.allSatisfy { !$0.contains(" -g ") })
        connection.stop()
    }

    /// The controller seeds the identity pairs when it creates the mirror, so
    /// the connection knows the workspace before the first push fires.
    @Test func mirrorSessionSeedsWorkspaceIdentity() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        defer {
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
        }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@env-identity.test")
        let connection = RemoteTmuxControlConnection(host: host, sessionName: "work")
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-env-push-identity",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        controller.cacheConnection(connection)
        #expect(try controller.mirrorSession(host: host, sessionName: "work", into: manager))
        defer {
            controller.detach(host: host, sessionName: "work")
            writer.close()
            try? pipe.fileHandleForReading.close()
        }

        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        #expect(connection.mirrorEnvironment["CMUX_WORKSPACE_ID"] == workspace.id.uuidString)
        #expect(connection.mirrorEnvironment["CMUX_TAB_ID"] == workspace.id.uuidString)
        #expect(connection.mirrorEnvironment["CMUX_SOCKET_PATH"] == nil)
    }
}
