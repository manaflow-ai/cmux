import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #13369: `surface.resume.set` over the control socket
/// ran `NSAlert.runModal()` inside the command's main-actor job whenever the
/// proposed command had no approval record. The modal parked the command
/// coordinator, the socket stopped answering, and new clients saw EPIPE.
///
/// A socket request must not present approval UI. It stores the binding without
/// resume trust and reports `approval_required`, so the caller learns that a
/// person has to approve the command in the app.
///
/// The test host never presents the modal (the approval gate refuses under
/// XCTest), so these tests assert the reply the socket path returns instead of
/// observing the modal itself.
@MainActor
@Suite(.serialized)
struct SurfaceResumeSocketApprovalTests {
    @Test
    func socketResumeSetReportsApprovalRequiredForUnapprovedCommand() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { windowID, workspace, panelID in
            // A command no approval record can match, so it needs a decision.
            let command = "cmux-issue-13369-probe --session \(UUID().uuidString.lowercased())"

            let result = try v2Result(method: "surface.resume.set", params: [
                "window_id": windowID.uuidString,
                "surface_id": panelID.uuidString,
                "command": command,
                "cwd": "/tmp/cmux-issue-13369",
            ])

            #expect(result["approval_required"] as? Bool == true)
            let binding = try #require(result["resume_binding"] as? [String: Any])
            #expect(binding["command"] as? String == command)
            #expect(binding["auto_resume"] as? Bool == false)

            let stored = try #require(workspace.surfaceResumeBinding(panelId: panelID))
            #expect(stored.command == command)
            #expect(stored.approvalRecordId == nil)
            #expect(!stored.allowsAutomaticResume)
        }
    }

    @Test
    func socketResumeSetReportsNoApprovalRequiredForTrustedAgentHook() async throws {
        await Self.waitForSigningSecret()
        try withRegisteredWindow { windowID, workspace, panelID in
            let sessionID = UUID().uuidString.lowercased()

            let result = try v2Result(method: "surface.resume.set", params: [
                "window_id": windowID.uuidString,
                "surface_id": panelID.uuidString,
                "command": "codex resume \(sessionID)",
                "checkpoint_id": sessionID,
                "source": "agent-hook",
                "auto_resume": true,
            ])

            #expect(result["approval_required"] as? Bool == false)
            #expect(workspace.surfaceResumeBinding(panelId: panelID)?.allowsAutomaticResume == true)
        }
    }

    // MARK: - Harness

    private static func waitForSigningSecret() async {
        await withCheckedContinuation { continuation in
            SurfaceResumeApprovalStore.whenSigningSecretReady {
                continuation.resume()
            }
        }
    }

    private func withRegisteredWindow(
        _ body: (UUID, Workspace, UUID) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        try body(windowID, workspace, panel.id)
    }

    private func v2Result(method: String, params: [String: Any]) throws -> [String: Any] {
        let request = ["id": method, "method": method, "params": params] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        let responseData = try #require(raw.data(using: .utf8))
        let envelope = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(envelope["ok"] as? Bool == true, Comment(rawValue: raw))
        return try #require(envelope["result"] as? [String: Any], Comment(rawValue: raw))
    }
}
