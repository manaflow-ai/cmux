import CmuxCore
import CmuxRemoteSession
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
    @Test func placeholderReplayEmitsNotificationRestoreBoundaries() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-replay-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let replayFileURL = try #require(SessionScrollbackReplayStore.replayFileURL(
            for: "remote-output\n",
            tempDirectory: temporaryDirectory
        ))
        let scriptPath = try #require(Workspace.remoteDisconnectPlaceholderScript(
            target: "example-host",
            reconnectCommand: nil,
            temporaryDirectory: temporaryDirectory
        ))
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(
            [SessionScrollbackReplayStore.environmentKey: replayFileURL.path],
            uniquingKeysWith: { _, new in new }
        )

        try process.run()
        process.waitUntilExit()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let startBoundary = SessionScrollbackReplayStore.startBoundaryValue(forReplayFilePath: replayFileURL.path)
        let endBoundary = SessionScrollbackReplayStore.endBoundaryValue(forReplayFilePath: replayFileURL.path)
        let startRange = try #require(output.range(of: startBoundary))
        let replayRange = try #require(output.range(of: "remote-output"))
        let endRange = try #require(output.range(of: endBoundary))

        #expect(process.terminationStatus == 0)
        #expect(startRange.lowerBound < replayRange.lowerBound)
        #expect(replayRange.lowerBound < endRange.lowerBound)
    }

    @Test func missingPlaceholderReplayFileStillCompletesNotificationRestoreLifecycle() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-missing-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let missingPath = temporaryDirectory.appendingPathComponent("missing-replay").path
        let scriptPath = try #require(Workspace.remoteDisconnectPlaceholderScript(
            target: "example-host",
            reconnectCommand: nil,
            temporaryDirectory: temporaryDirectory
        ))
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(
            [SessionScrollbackReplayStore.environmentKey: missingPath],
            uniquingKeysWith: { _, new in new }
        )

        try process.run()
        process.waitUntilExit()
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(process.terminationStatus == 0)
        #expect(output.contains(SessionScrollbackReplayStore.startBoundaryValue(forReplayFilePath: missingPath)))
        #expect(output.contains(SessionScrollbackReplayStore.endBoundaryValue(forReplayFilePath: missingPath)))
    }

    @Test func twoPendingRemoteExitsKeepIndependentReplacementState() async throws {
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
        await workspace.waitForRemoteDisconnectTransition(surfaceId: first.id)
        await workspace.waitForRemoteDisconnectTransition(surfaceId: second.id)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(first.id))
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(second.id))
        #expect(workspace.pendingRemoteTerminalChildExitSurfaceIds.isEmpty)
        #expect(workspace.isRemoteTerminalSurface(third.id))
    }

    @Test func sameConfigurationReconnectPreservesSiblingPlaceholderOwnership() async throws {
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
            await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)
        }
        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([first.id, second.id]))

        workspace.configureRemoteConnection(configuration, autoConnect: false)

        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([first.id, second.id]))
    }

    @Test func changedConfigurationClearsPendingExitOwnership() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))

        workspace.configureRemoteConnection(Self.remoteConfiguration(port: 2222), autoConnect: false)

        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
    }

    @Test func wrapperCreationFailurePreservesOriginalDeadSurface() async throws {
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
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)

        #expect(handled)
        #expect(workspace.terminalPanel(for: panel.id)?.surface === originalSurface)
        #expect(workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
        #expect(!workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))

        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id]) }
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
    }

    @Test func duplicateSessionEndPreservesInFlightDisconnectPreparation() async throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id]) }

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))

        workspace.markRemoteTerminalSessionEnded(
            surfaceId: panel.id,
            relayPort: 64007,
            allowUntracked: true
        )
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)

        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
    }

    @Test func restoredFallbackWithTerminalControlsIsNotReplayed() async throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "\u{001B}]0;unterminated-title"

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id]) }

        let placeholder = try #require(workspace.terminalPanel(for: panel.id))
        #expect(placeholder.ownedSessionScrollbackReplayFileURL == nil)
    }

    @Test func disconnectedPlaceholderChildExitPreservesWorkspaceAndPanel() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to cmux-macmini via shared local proxy 127.0.0.1:64007",
            target: "cmux-macmini"
        )
        let sibling = try #require(workspace.newTerminalSplit(
            from: panel.id,
            orientation: .horizontal,
            focus: false
        ))
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panel.id)
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)

        let firstPlaceholder = try #require(workspace.terminalPanel(for: panel.id))
        let firstWrapperPath = firstPlaceholder.surface.initialCommand
        let firstReplayPath = try #require(firstPlaceholder.ownedSessionScrollbackReplayFileURL?.path)
        defer {
            if let firstWrapperPath { try? FileManager.default.removeItem(atPath: firstWrapperPath) }
            try? FileManager.default.removeItem(atPath: firstReplayPath)
            Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id])
        }
        let replayedScrollback = try String(contentsOfFile: firstReplayPath, encoding: .utf8)
        #expect(replayedScrollback == "remote-output\n")

        manager.closePanelAfterChildExited(tabId: workspace.id, surfaceId: panel.id)
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)

        let secondPlaceholder = try #require(workspace.terminalPanel(for: panel.id))
        #expect(manager.tabs.contains(where: { $0.id == workspace.id }))
        #expect(secondPlaceholder.surface !== firstPlaceholder.surface)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(workspace.isRemoteTerminalSurface(sibling.id))
        #expect(workspace.remoteConnectionState == .connected)
        #expect(!FileManager.default.fileExists(atPath: firstReplayPath))
    }

    @Test func closingDisconnectedPlaceholderRemovesReplayArtifact() async throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)
        let placeholder = try #require(workspace.terminalPanel(for: panel.id))
        let replayPath = try #require(placeholder.ownedSessionScrollbackReplayFileURL?.path)
        defer {
            try? FileManager.default.removeItem(atPath: replayPath)
            Self.removeTransitionArtifacts(workspace: workspace, panelIds: [panel.id])
        }
        #expect(FileManager.default.fileExists(atPath: replayPath))

        workspace.teardownAllPanels()

        #expect(!FileManager.default.fileExists(atPath: replayPath))
    }

    @Test func closingLastDisconnectedPlaceholderCreatesAnotherPlaceholder() async throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)

        #expect(workspace.closePanel(panel.id, force: true))

        let replacement = try #require(workspace.focusedTerminalPanel)
        defer { Self.removeTransitionArtifacts(workspace: workspace, panelIds: [replacement.id]) }
        #expect(replacement.id != panel.id)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([replacement.id]))
        #expect(replacement.surface.initialCommand != nil)
    }

    @Test func staleChildExitCannotReplaceNewRuntimeWithSameSurfaceID() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let exitedRuntime = panel.surface
        workspace.configureRemoteConnection(Self.remoteConfiguration(), autoConnect: false)
        workspace.restoredTerminalScrollbackByPanelId[panel.id] = "remote-output\n"

        workspace.markRemoteTerminalSessionEnded(surfaceId: panel.id, relayPort: 64007)
        #expect(workspace.transitionRemoteTerminalToDisconnectedPlaceholder(surfaceId: panel.id))
        await workspace.waitForRemoteDisconnectTransition(surfaceId: panel.id)
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

    private static func remoteConfiguration(port: Int? = nil) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: port,
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
            guard let panel = workspace.terminalPanel(for: panelId) else { continue }
            let paths = [
                panel.surface.initialCommand,
                panel.ownedSessionScrollbackReplayFileURL?.path,
            ].compactMap { $0 }
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
        }
    }
}
