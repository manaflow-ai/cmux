import AppKit
import CmuxTerminal
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
    }
}
