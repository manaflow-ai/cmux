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

    /// See `RemoteTmuxController.mirrorSession`'s doc for why this must never
    /// issue `rename-session` on the remote host.
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

    /// See `RemoteTmuxController.mirrorSessions`'s doc for the first-session-only
    /// rationale.
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

    @Test func multiplexedAttachAppliesWorkspaceNameToTheFirstPublishedSession() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        defer {
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
        }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@workspace-name-multiplexed.test")
        let shared = RemoteTmuxControlConnection(host: host, sessionName: "cmux-view")
        controller.multiplexedViewsByHost[host.connectionHash] = RemoteTmuxViewConnection(
            host: host, ownerId: "workspace-name-test")
        controller.pendingMultiplexWorkspaceNamesByHost[host.connectionHash] = "custom"

        controller.applyMultiplexedWorkspaces(
            host: host,
            manager: manager,
            workspaces: [
                .init(sessionName: "alpha", windowIds: ["@1"], sessionId: 1),
                .init(sessionName: "beta", windowIds: ["@2"], sessionId: 2),
            ],
            shared: shared
        )
        defer { controller.stopMultiplexedHost(host: host) }

        let alpha = try #require(controller.sessionMirrors.values.first { $0.sessionName == "alpha" }?.mirroredWorkspace)
        let beta = try #require(controller.sessionMirrors.values.first { $0.sessionName == "beta" }?.mirroredWorkspace)
        #expect(alpha.customTitle == "custom")
        #expect(!beta.hasCustomTitle)
        #expect(controller.pendingMultiplexWorkspaceNamesByHost[host.connectionHash] == nil)
    }
    @Test func aClosedWorkspaceDoesNotBlockRecreatingItsMultiplexedMirror() throws {
        let appDelegate = try #require(AppDelegate.shared)
        let windowId = appDelegate.createMainWindow(shouldActivate: false)
        defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "stale-mirror-\(UUID().uuidString).test")
        let shared = RemoteTmuxControlConnection(host: host, sessionName: "cmux-view")
        let published: [RemoteTmuxLinkedWorkspaceModel.Workspace] = [
            .init(sessionName: "work", windowIds: ["@1"], sessionId: 1),
        ]
        controller.applyMultiplexedWorkspaces(host: host, manager: manager, workspaces: published, shared: shared)
        defer { controller.stopMultiplexedHost(host: host) }
        let key = RemoteTmuxController.connectionKey(host: host, sessionName: "work")
        let stale = try #require(controller.sessionMirrors[key])
        let oldChannel = try #require(controller.channelsByHostSession[key])
        if let workspace = stale.mirroredWorkspace {
            manager.closeWorkspace(workspace, recordHistory: false)
        }
        // Model the weak workspace reference after an external close, even if
        // AppKit temporarily retains the closed workspace during this test.
        stale.workspace = nil
        #expect(!controller.hostHasLiveMirror(host))

        controller.applyMultiplexedWorkspaces(host: host, manager: manager, workspaces: published, shared: shared)

        let replacement = try #require(controller.sessionMirrors[key])
        #expect(replacement !== stale)
        #expect(replacement.mirroredWorkspaceId != nil)
        #expect(controller.channelsByHostSession[key] !== oldChannel)
        #expect(controller.hostHasLiveMirror(host))
    }

}
