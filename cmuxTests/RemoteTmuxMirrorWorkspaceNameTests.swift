import AppKit
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for `cmux ssh-tmux --name` (cosmetic local workspace title,
/// applied at mirror time — see `RemoteTmuxController.mirrorSession(customTitle:)`).
@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorWorkspaceNameTests {
    private func session(_ name: String, id: String? = nil) -> RemoteTmuxSession {
        RemoteTmuxSession(
            id: id ?? "$\(name)",
            name: name,
            windowCount: 1,
            attached: false,
            createdUnix: nil
        )
    }

    private struct Wire {
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
    }

    private func makeConnectedWire(host: RemoteTmuxHost, sessionName: String, label: String) -> Wire {
        let connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: label,
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        return Wire(connection: connection, writer: writer, pipe: pipe)
    }

    private func sentCommands(_ wire: Wire) throws -> [String] {
        wire.writer.close()
        let data = try wire.pipe.fileHandleForReading.readToEnd() ?? Data()
        try? wire.pipe.fileHandleForReading.close()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// `--name` sets a cosmetic local title on the mirrored workspace. Unlike an
    /// interactive rename of an already-mirrored workspace, it must never issue
    /// `rename-session` on the remote host (propagateToRemoteTmux: false).
    @Test func mirrorSessionAppliesCustomTitleWithoutRenamingRemoteSession() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        defer {
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
        }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@workspace-name.test")
        let wire = makeConnectedWire(host: host, sessionName: "work", label: "ssh-tmux-name-single")
        controller.cacheConnection(wire.connection)

        #expect(try controller.mirrorSession(
            host: host,
            sessionName: "work",
            into: manager,
            customTitle: "prod db"
        ))
        defer {
            controller.detach(host: host, sessionName: "work")
        }

        let workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })
        #expect(workspace.customTitle == "prod db")
        #expect(workspace.effectiveCustomTitleSource == .user)

        let commands = try sentCommands(wire)
        #expect(commands.allSatisfy { !$0.contains("rename-session") })
    }

    /// A bulk attach can mirror several not-yet-mirrored sessions in one call;
    /// there is no single unambiguous target for a caller-supplied name among
    /// them, so it applies only to the first newly-mirrored workspace.
    @Test func mirrorSessionsAppliesWorkspaceNameOnlyToFirstNewlyMirroredSession() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        defer {
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
        }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@workspace-name-bulk.test")

        let wireA = makeConnectedWire(host: host, sessionName: "alpha", label: "ssh-tmux-name-bulk-a")
        let wireB = makeConnectedWire(host: host, sessionName: "beta", label: "ssh-tmux-name-bulk-b")
        controller.cacheConnection(wireA.connection)
        controller.cacheConnection(wireB.connection)

        controller.mirrorSessions(
            [session("alpha"), session("beta")],
            host: host,
            into: manager,
            workspaceName: "custom"
        )
        defer {
            controller.detach(host: host, sessionName: "alpha")
            controller.detach(host: host, sessionName: "beta")
        }

        // `setCustomTitle` also overwrites `title` to the custom value, so the
        // alpha/beta workspaces must be told apart by the controller's stable
        // session-name mapping, not by their (now-mutated) `title`.
        let alphaWorkspaceID = try #require(
            controller.sessionMirrors.values.first { $0.sessionName == "alpha" }?.mirroredWorkspaceId
        )
        let betaWorkspaceID = try #require(
            controller.sessionMirrors.values.first { $0.sessionName == "beta" }?.mirroredWorkspaceId
        )
        let alphaWorkspace = try #require(manager.tabs.first { $0.id == alphaWorkspaceID })
        let betaWorkspace = try #require(manager.tabs.first { $0.id == betaWorkspaceID })
        #expect(alphaWorkspace.customTitle == "custom")
        #expect(!betaWorkspace.hasCustomTitle)
    }
}
