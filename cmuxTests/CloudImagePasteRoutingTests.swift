import AppKit
import CmuxTerminal
import CmuxCore
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud clipboard image routing")
struct CloudImagePasteRoutingTests {
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
}
