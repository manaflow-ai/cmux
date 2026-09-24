import AppKit
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns a real manual-I/O Ghostty terminal and its scripted daemon socket.
@MainActor
final class CloudRestoreReplayFixture {
    private let workspace = TerminalPortalTestWorkspace()
    let surface: TerminalSurface
    private let window: NSWindow
    let socket: CloudManualMirrorSocketFixture
    private let session: CloudTuiManualMirrorSession

    init(initiallyClaimsGeometry: Bool = true) throws {
        _ = NSApplication.shared
        socket = try CloudManualMirrorSocketFixture()
        session = CloudTuiManualMirrorSession(
            machineID: "restore-grid-test", terminalID: "term_restore_grid",
            remoteSurfaceID: 17, initiallyClaimsGeometry: initiallyClaimsGeometry,
            onNeedsReconnect: {}
        )
        surface = TerminalSurface(
            tabId: workspace.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, ioMode: .manualMirror, manualInputHandler: { _ in }
        )
        surface.setManualIONoReflow(false)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let hosted = surface.hostedView
        hosted.frame = content.bounds
        content.addSubview(hosted)
        content.layoutSubtreeIfNeeded()
        hosted.setVisibleInUI(false)
        hosted.setActive(false)
        session.bind(surface: surface)
    }

    func setGrid(columns: Int, rows: Int) async throws {
        try await waitUntil { self.surface.hasLiveSurface }
        let runtime = try #require(surface.surface)
        #expect(ghostty_surface_set_grid_size(runtime, UInt16(columns), UInt16(rows), nil))
        // The app-facing size cache leads Ghostty's IO-thread resize. Read
        // actual terminal rows through the existing render-grid export.
        try await waitUntil {
            let frame = self.surface.mobileRenderGridFrame(
                stateSeq: 0, scrollbackLines: 0, includeTheme: false
            )?.frame
            return frame?.columns == columns && frame?.rows == rows
        }
    }

    func attach(replay: Data) async throws {
        session.reconnect(socketPath: socket.socketPath)
        let identify = try #require(await socket.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        socket.send(["id": identify.id, "ok": true, "data": ["capabilities": ["attach-initial-size"]]])
        let registration = try #require(await socket.nextCommand(timeout: .seconds(5)))
        #expect(registration.cmd == "set-client-info")
        socket.send(["id": registration.id, "ok": true, "data": [:]])
        let attach = try #require(await socket.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        #expect(!attach.hasInitialSize, "Hidden restores must not claim their temporary grid")
        socket.send(["id": attach.id, "ok": true, "data": [:]])
        try await deliver(replay, event: "vt-state", marker: "STATUS_READY")
        try await waitUntil { self.session.phase == .attached }
    }

    func setVisible(_ visible: Bool) {
        surface.hostedView.setVisibleInUI(visible)
    }

    func focus() { session.claimGeometry() }

    func deliver(_ bytes: Data, event: String, marker: String) async throws {
        socket.send([
            "event": event, "surface": 17, "cols": 80, "rows": 24,
            "data": bytes.base64EncodedString()
        ])
        try await waitUntil { self.surface.readText(region: .screen)?.contains(marker) == true }
    }

    func close() {
        session.stop()
        socket.close()
        surface.teardownSurface()
        window.orderOut(nil)
        workspace.tearDown()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for the native terminal state")
    }
}
