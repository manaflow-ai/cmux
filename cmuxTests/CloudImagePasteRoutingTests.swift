import AppKit
import CmuxCloud
import CmuxTerminal
import CmuxCore
import CmuxSurfaceCatalogModel
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud clipboard image routing")
struct CloudImagePasteRoutingTests {
    /// Covers paste and drop before a native SSH projection registers a legacy remote surface.
    @Test("Native SSH image paste and file drop use the SSH upload route", arguments: [TerminalImageTransferMode.paste, .drop])
    @MainActor
    func nativeSSHTuiUsesRemoteFileUpload(mode: TerminalImageTransferMode) async throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        let configuration = WorkspaceRemoteConfiguration(
            destination: "test@host", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil
        )
        workspace.remoteConfiguration = configuration
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration).id),
            kind: .terminal, key: "term_" + UUID().uuidString
        ))], workspaceID: workspace.id, restoringWorkspace: workspace)
        #expect(workspace.usesSSHTui)
        #expect(workspace.activeRemoteTerminalSurfaceIds.isEmpty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-upload-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let target = await panel.surface.resolvedImageTransferTargetAsync(
            mode: mode, in: workspace,
            detector: { _ in
                Issue.record("Native SSH must use its configured endpoint without local process detection")
                return nil
            }
        )
        #expect(target == .remote(.workspaceRemote))
        #expect(TerminalImageTransferPlanner.plan(fileURLs: [url], target: target, mode: mode)
            == .uploadFiles([url], .workspaceRemote))
    }

    /// Test-only gate shared with the detached detector closure. The semaphore
    /// is immutable and provides the only cross-task mutation.
    private final class DetectionBlocker: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)

        func wait() {
            semaphore.wait()
        }

        func signal() {
            semaphore.signal()
        }
    }

    /// A `cmux ssh` workspace routes from its stored configuration, never from
    /// the processes on a pane's TTY, even when that TTY runs `ssh`.
    @Test("A cmux ssh workspace never scans processes to route a drop", arguments: [TerminalImageTransferMode.paste, .drop])
    @MainActor
    func cmuxSSHWorkspaceNeverScansProcesses(mode: TerminalImageTransferMode) async throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        defer { workspace.teardownAllPanels() }
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test@host", port: nil, identityFile: nil,
            sshOptions: ["__cmux_route_sensitive=" + String(repeating: "a1", count: 32)],
            localProxyPort: nil, relayPort: 41_000, relayID: "relay", relayToken: "token",
            localSocketPath: nil, terminalStartupCommand: nil
        )
        // The pane is not tracked yet, and its TTY would report an `ssh`.
        workspace.surfaceTTYNames[panelID] = "/dev/ttys20279"
        #expect(!workspace.isRemoteTerminalSurface(panelID))

        #expect(panel.surface.imageTransferDetectionTTY(mode: mode, in: workspace) == nil)
        let target = await panel.surface.resolvedImageTransferTargetAsync(
            mode: mode, in: workspace,
            detector: { _ in
                Issue.record("A cmux ssh workspace must not route from a process scan")
                return DetectedSSHSession(
                    destination: "scanned-host", port: nil, identityFile: nil,
                    configFile: nil, jumpHost: nil, controlPath: nil,
                    useIPv4: false, useIPv6: false, forwardAgent: false,
                    compressionEnabled: false, sshOptions: []
                )
            }
        )
        #expect(target == panel.surface.resolvedImageTransferTarget(mode: mode, in: workspace))

        // A restored pane's stored PTY binding makes it remote before the
        // remote reports the session connected.
        workspace.remotePTYSessionIDsByPanelId[panelID] = "restored-session"
        #expect(panel.surface.resolvedImageTransferTarget(mode: mode, in: workspace) == .remote(.workspaceRemote))
        workspace.remotePTYSessionIDsByPanelId.removeValue(forKey: panelID)

        workspace.activeRemoteTerminalSurfaceIds.insert(panelID)
        #expect(panel.surface.resolvedImageTransferTarget(mode: mode, in: workspace) == .remote(.workspaceRemote))
    }

    /// A local workspace has no stored remote configuration: the drop decides
    /// local from memory and never reaches the remote upload machinery.
    @Test("A local workspace drop never touches the remote path", arguments: [TerminalImageTransferMode.paste, .drop])
    @MainActor
    func localWorkspaceDropStaysLocal(mode: TerminalImageTransferMode) async throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        defer { workspace.teardownAllPanels() }
        #expect(workspace.remoteConfiguration == nil)

        #expect(panel.surface.resolvedImageTransferTarget(mode: mode, in: workspace) == .local)
        // No TTY report yet: no detection either.
        #expect(panel.surface.imageTransferDetectionTTY(mode: mode, in: workspace) == nil)
        let target = await panel.surface.resolvedImageTransferTargetAsync(
            mode: mode, in: workspace,
            detector: { _ in
                Issue.record("A local pane without a TTY report must not be scanned")
                return nil
            }
        )
        #expect(target == .local)
        let url = URL(fileURLWithPath: "/tmp/cmux-local-drop.png")
        #expect(TerminalImageTransferPlanner.plan(fileURLs: [url], target: target, mode: mode)
            == .insertText(TerminalImageTransferPlanner.escapeForShell(url.path)))
    }

    @Test @MainActor
    func legacyCloudSSHWorkspaceKeepsItsExistingUploadRoute() throws {
        let workspace = Workspace()
        let id = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: id))
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "test@host", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, managedCloudVMID: "vm-legacy-test", terminalStartupCommand: nil
        )
        workspace.activeRemoteTerminalSurfaceIds.insert(id)
        #expect(workspace.cloudVMID == "vm-legacy-test")
        #expect(panel.surface.resolvedImageTransferTarget(in: workspace) == .remote(.workspaceRemote))
    }

    @Test @MainActor
    func queuedImagePasteHoldsLaterInputAndReleasesItOnCompletion() {
        let surface = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                                      configTemplate: nil, workingDirectory: nil)
        let view = GhosttyNSView(frame: .zero)
        view.terminalSurface = surface
        let operation = TerminalImageTransferOperation()
        let lease = CloudImagePasteInputLease(view: view, operation: operation)
        var sent = false
        #expect(view.deferRuntimeInputDuringClipboardRead(estimatedBytes: 1) { sent = true })
        #expect(!sent)
        lease.finish()
        #expect(sent)
        #expect(!view.hasClipboardInputDeferral)
    }

    @Test @MainActor
    func queuedImagePasteDoesNotReplayInputIntoAReplacementSurface() {
        let original = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                                       configTemplate: nil, workingDirectory: nil)
        let replacement = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                                          configTemplate: nil, workingDirectory: nil)
        let view = GhosttyNSView(frame: .zero)
        view.terminalSurface = original
        let lease = CloudImagePasteInputLease(view: view, operation: TerminalImageTransferOperation())
        var sent = false
        #expect(view.deferRuntimeInputDuringClipboardRead(estimatedBytes: 1) { sent = true })
        view.terminalSurface = replacement
        lease.finish()
        #expect(!sent)
        #expect(!view.hasClipboardInputDeferral)
    }

    @Test @MainActor
    func disconnectedManagedMirrorNeverPlansAMacPath() {
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let session = CloudTuiManualMirrorSession(
            machineID: "image-test-machine",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 17,
            onNeedsReconnect: {}
        )
        surface.hostedView.cloudTerminalOverlay.session = session
        defer { session.stop() }
        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: [URL(fileURLWithPath: "/var/folders/clipboard.png")],
            target: surface.resolvedImageTransferTarget(),
            mode: .paste
        )
        if case .insertText = plan {
            Issue.record("A managed Cloud terminal must never receive a Mac-local image path")
        }
        #expect(surface.resolvedImageTransferTarget() != .local)
    }

    @Test
    func localAndSSHPlansRetainTheirDeliveryRoutes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-image-routing-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(TerminalImageTransferPlanner.plan(fileURLs: [url], target: .local)
            == .insertText(TerminalImageTransferPlanner.escapeForShell(url.path)))
        #expect(TerminalImageTransferPlanner.plan(fileURLs: [url], target: .remote(.workspaceRemote))
            == .uploadFiles([url], .workspaceRemote))
        let ssh = DetectedSSHSession(
            destination: "image-test-host", port: nil, identityFile: nil,
            configFile: nil, jumpHost: nil, controlPath: nil,
            useIPv4: false, useIPv6: false, forwardAgent: false,
            compressionEnabled: false, sshOptions: []
        )
        // Detected SSH and manual tmux both resolve to this existing upload target.
        #expect(TerminalImageTransferPlanner.plan(fileURLs: [url], target: .remote(.detectedSSH(ssh)))
            == .uploadFiles([url], .detectedSSH(ssh)))
        #expect(TerminalImageTransferPlanner.plan(fileURLs: [url], target: .local, mode: .drop)
            == .insertText(TerminalImageTransferPlanner.escapeForShell(url.path)))
    }

    @Test
    func cloudNeverFallsBackForMissingFilesOrNonImageTypes() {
        for path in ["/var/folders/missing.png", "/Users/example/report.txt"] {
            let urls = [URL(fileURLWithPath: path)]
            #expect(TerminalImageTransferPlanner.plan(fileURLs: urls, target: .cloud) == .pasteCloudImages(urls))
        }
    }

    @Test
    func cloudPlainTextPasteRetainsTheExistingTextPath() {
        #expect(TerminalImageTransferPlanner.plan(preparedContent: .insertText("ordinary clipboard text"), target: .cloud)
            == .insertText("ordinary clipboard text"))
    }

    @Test @MainActor
    func stalledAdHocSSHDetectionFallsBackToLocalPaste() async throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelID))
        workspace.surfaceTTYNames[panelID] = "/dev/ttys15073"
        let url = URL(fileURLWithPath: "/tmp/cmux-image-15073.png")
        let releaseDetector = DetectionBlocker()

        let target = await panel.surface.resolvedImageTransferTargetAsync(
            in: workspace,
            detector: { _ in
                releaseDetector.wait()
                return DetectedSSHSession(
                    destination: "slow-host", port: nil, identityFile: nil,
                    configFile: nil, jumpHost: nil, controlPath: nil,
                    useIPv4: false, useIPv6: false,
                    forwardAgent: false, compressionEnabled: false,
                    sshOptions: []
                )
            },
            timeoutSleep: { _ in }
        )
        releaseDetector.signal()

        #expect(target == .local)
        #expect(
            TerminalImageTransferPlanner.plan(
                fileURLs: [url],
                target: target
            ) == .insertText(
                TerminalImageTransferPlanner.escapeForShell(url.path)
            )
        )
    }
}
