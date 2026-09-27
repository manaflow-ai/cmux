import AppKit
import CmuxControlSocket
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The same RPC used by restored and Vault panes must retain a held-writer intent.
@MainActor
@Suite(.serialized)
struct CodexWriterAdmissionRecoveryTests {
    @Test func heldForeignWriterIsPresentedAndReleaseAdmitsTheSameConversation() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-admission-\(UUID().uuidString)")
            let locks = root.appendingPathComponent("thread-writer-locks")
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let session = UUID().uuidString.lowercased()
            let fd = open(locks.appendingPathComponent(session + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            defer { close(fd) }
            try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
            let previousApp = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let app = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let windowID = UUID()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
            AppDelegate.shared = app
            app.registerMainWindow(
                window, windowId: windowID, tabManager: manager, sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(), fileExplorerState: FileExplorerState()
            )
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: "codex", sessionId: session)
                TerminalController.shared.setActiveTabManager(previousManager)
                app.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.finalizeAllWorkspacesForWindowClose()
                window.orderOut(nil)
                AppDelegate.shared = previousApp
            }
            let workspace = try #require(manager.selectedWorkspace)
            let panel = try #require(workspace.focusedTerminalPanel)
            let set: [String: Any] = ["id": "set", "method": "surface.resume.set", "params": [
                "window_id": windowID.uuidString, "surface_id": panel.id.uuidString,
                "kind": "codex", "source": "agent-hook", "command": "codex resume \(session)",
                "checkpoint_id": session, "cwd": root.path, "environment": ["CODEX_HOME": root.path],
                "launch_command": ["launcher": "codex", "arguments": ["codex", "resume", session],
                                   "working_directory": root.path, "environment": ["CODEX_HOME": root.path]]
            ]]
            let requestLine = String(decoding: try JSONSerialization.data(withJSONObject: set), as: UTF8.self)
            _ = try result(TerminalController.shared.handleSocketLine(requestLine))
            let admission = ControlRequest(id: .string("admit"), method: "agent.restore.admit", params: [
                "workspace_id": .string(workspace.id.uuidString), "surface_id": .string(panel.id.uuidString),
                "kind": .string("codex"), "session_id": .string(session), "codex_home": .string(root.path)
            ])
            let held = try result(await TerminalController.shared.agentRestoreAdmissionResponse(admission))
            #expect(held["admitted"] as? Bool == false)
            #expect(held["recovering"] as? Bool == true)
            guard case .writerLock? = panel.restoreRecovery.state else {
                Issue.record("Held writer must have a visible recovery message")
                return
            }
            #expect(workspace.surfaceResumeBinding(panelId: panel.id)?.checkpointId == session)
            try #require(flock(fd, LOCK_UN) == 0)
            let released = try result(await TerminalController.shared.agentRestoreAdmissionResponse(admission))
            #expect(released["admitted"] as? Bool == true)
            #expect(panel.restoreRecovery.state == nil)
        }
    }

    private func result(_ raw: String) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        try #require(envelope["ok"] as? Bool == true, Comment(rawValue: raw))
        return try #require(envelope["result"] as? [String: Any])
    }
}
