import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct RemoteDisconnectLifecycleTests {
    @Test func twoPendingRemoteExitsKeepIndependentReplacementState() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))
        let third = try #require(workspace.newTerminalSplit(
            from: second.id,
            orientation: .vertical,
            focus: false
        ))
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [first.id, second.id]) }
        workspace.restoredTerminalScrollbackByPanelId[first.id] = "first-output\n"
        workspace.restoredTerminalScrollbackByPanelId[second.id] = "second-output\n"

        #expect(workspace.activeRemoteTerminalSessionCount == 3)
        workspace.markRemoteTerminalSessionEnded(surfaceId: first.id, relayPort: 64007)
        workspace.markRemoteTerminalSessionEnded(surfaceId: second.id, relayPort: 64007)

        #expect(workspace.pendingRemoteTerminalChildExitSurfaceIds == Set([first.id, second.id]))
        #expect(workspace.activeRemoteTerminalSessionCount == 1)
        #expect(workspace.isRemoteTerminalSurface(third.id))
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: first.id))
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: second.id))
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(first.id))
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(second.id))
        #expect(workspace.pendingRemoteTerminalChildExitSurfaceIds.isEmpty)
        #expect(workspace.isRemoteTerminalSurface(third.id))
    }

    @Test func wrapperCreationFailurePreservesOriginalDeadSurface() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        let originalSurface = panel.surface
        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-disconnect-not-directory-\(UUID().uuidString)")
        try Data("file".utf8).write(to: invalidDirectory)
        defer { try? FileManager.default.removeItem(at: invalidDirectory) }

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        let handled = workspace.transitionRemoteTerminalToDisconnectedPlaceholder(
            surfaceId: panel.id,
            temporaryDirectory: invalidDirectory
        )

        #expect(handled)
        #expect(workspace.terminalPanel(for: panel.id)?.surface === originalSurface)
        #expect(workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
        #expect(!workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))

        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id]) }
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
    }

    private static func remoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: "ssh cmux-macmini"
        )
    }

    private static func removeTransitionArtifacts(workspace: Workspace, panelIds: [UUID]) {
        for panelId in panelIds {
            guard let surface = workspace.terminalPanel(for: panelId)?.surface else { continue }
            let paths = [
                surface.initialCommand,
                surface.startupEnvironmentValue(SessionScrollbackReplayStore.environmentKey),
            ].compactMap { $0 }
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}
