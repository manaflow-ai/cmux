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

    @Test func sameConfigurationReconnectPreservesSiblingPlaceholderOwnership() throws {
        let workspace = Workspace()
        let configuration = Self.remoteConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [first.id, second.id]) }

        for panel in [first, second] {
            workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"
            workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
            #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        }
        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([first.id, second.id]))

        workspace.configureRemoteConnection(configuration, autoConnect: false)

        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([first.id, second.id]))
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

    @Test func restoredFallbackWithTerminalControlsIsNotReplayed() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "\u{001B}]0;unterminated-title"

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id]) }

        let placeholder = try #require(workspace.terminalPanel(for: panel.id))
        #expect(placeholder.surface.startupEnvironmentValue(SessionScrollbackReplayStore.environmentKey) == nil)
    }

    @Test func disconnectedPlaceholderChildExitPreservesWorkspaceAndPanel() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let sibling = try #require(workspace.newTerminalSplit(
            from: panel.id,
            orientation: .horizontal,
            focus: false
        ))
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panel.id)

        let firstPlaceholder = try #require(workspace.terminalPanel(for: panel.id))
        let firstWrapperPath = firstPlaceholder.surface.initialCommand
        let firstReplayPath = try #require(
            firstPlaceholder.surface.startupEnvironmentValue(SessionScrollbackReplayStore.environmentKey)
        )
        defer {
            if let firstWrapperPath { try? FileManager.default.removeItem(atPath: firstWrapperPath) }
            try? FileManager.default.removeItem(atPath: firstReplayPath)
            Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id])
        }
        let replayedScrollback = try String(contentsOfFile: firstReplayPath, encoding: .utf8)
        #expect(replayedScrollback == "remote-output\n")

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panel.id)

        let secondPlaceholder = try #require(workspace.terminalPanel(for: panel.id))
        #expect(manager.tabs.contains(where: { $0.id == workspace.id }))
        #expect(secondPlaceholder.surface !== firstPlaceholder.surface)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(workspace.isRemoteTerminalSurface(sibling.id))
        #expect(workspace.remoteConnectionState == .connected)
        #expect(!FileManager.default.fileExists(atPath: firstReplayPath))
    }

    @Test func closingDisconnectedPlaceholderRemovesReplayArtifact() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        let placeholder = try #require(workspace.terminalPanel(for: panel.id))
        let replayPath = try #require(
            placeholder.surface.startupEnvironmentValue(SessionScrollbackReplayStore.environmentKey)
        )
        defer {
            try? FileManager.default.removeItem(atPath: replayPath)
            Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id])
        }
        #expect(FileManager.default.fileExists(atPath: replayPath))

        workspace.teardownAllPanels()

        #expect(!FileManager.default.fileExists(atPath: replayPath))
    }

    @Test func staleChildExitCannotReplaceNewRuntimeWithSameSurfaceID() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let exitedRuntime = panel.surface
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        let replacementRuntime = try #require(workspace.terminalPanel(for: panel.id)?.surface)
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id]) }

        manager.closePanelAfterChildExited(
            tabId: workspace.id,
            surfaceId: panel.id,
            runtimeSurface: exitedRuntime
        )

        #expect(workspace.terminalPanel(for: panel.id)?.surface === replacementRuntime)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
    }

    @Test func failedLegacyWrapperReplacementRetainsRemoteOwnership() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-disconnect-not-directory-\(UUID().uuidString)")
        try Data("file".utf8).write(to: invalidDirectory)
        defer { try? FileManager.default.removeItem(at: invalidDirectory) }

        let replacement = workspace.createReplacementTerminalPanel(temporaryDirectory: invalidDirectory)

        #expect(replacement.surface.initialCommand == "/usr/bin/false")
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(replacement.id))
        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: replacement.id)
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [replacement.id]) }
        #expect(workspace.panels[replacement.id] != nil)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(replacement.id))
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
