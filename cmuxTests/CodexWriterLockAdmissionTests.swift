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

/// Regression coverage for #12805: restore admission must consult Codex's own
/// writer lock, not only cmux's PID scan.
///
/// Codex keeps a kernel `flock` on `$CODEX_HOME/thread-writer-locks/<thread>.lock`
/// for the life of the process that owns the thread. After quit and reopen the
/// previous Codex can still be shutting down while cmux relaunches
/// `codex resume <thread>`; a second writer then opens read-only ("This
/// conversation is open in another app"). cmux's hook-store scan does not see
/// that process, so the lock is the only truth that can refuse the launch.
@MainActor
@Suite("Codex writer lock restore admission", .serialized)
struct CodexWriterLockAdmissionTests {
    @Test("A held Codex writer lock refuses admission and names the lock file")
    func heldWriterLockRefusesAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let holder = try fixture.holdWriterLock()
        defer { close(holder) }

        let answer = try await fixture.admit()

        #expect(answer["admitted"] as? Bool == false, Comment(rawValue: "\(answer)"))
        #expect(answer["writer_lock_held"] as? Bool == true, Comment(rawValue: "\(answer)"))
        #expect(answer["retryable"] as? Bool == true, Comment(rawValue: "\(answer)"))
        #expect(answer["lock_path"] as? String == fixture.kernelLockPath, Comment(rawValue: "\(answer)"))
        // The holder is this test process. Naming it is best effort: the
        // same-user descriptor scan is bounded and reports a holder only when
        // every candidate could be inspected, so the PID may be absent, but it
        // must never name a different process.
        if let holderPID = (answer["live_owner_pid"] as? NSNumber)?.int32Value {
            #expect(holderPID == getpid(), Comment(rawValue: "\(answer)"))
        }
    }

    @Test("A released Codex writer lock admits the resume")
    func releasedWriterLockAdmits() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let holder = try fixture.holdWriterLock()
        _ = flock(holder, LOCK_UN)
        close(holder)

        let answer = try await fixture.admit()

        #expect(answer["admitted"] as? Bool == true, Comment(rawValue: "\(answer)"))
        #expect(answer["writer_lock_held"] == nil, Comment(rawValue: "\(answer)"))
        if let claimID = answer["claim_id"] as? String {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: "codex",
                sessionId: fixture.sessionID,
                claim: AgentResumeLaunchGuard.Claim(id: try #require(UUID(uuidString: claimID)))
            )
        }
    }

    /// One main window with a managed Codex resume binding on a split surface,
    /// the same shape `cmux restore --surface` admits through the socket.
    @MainActor
    private struct Fixture {
        let root: URL
        let codexHome: URL
        let sessionID: String
        let windowID: UUID
        let window: NSWindow
        let app: AppDelegate
        let previousAppDelegate: AppDelegate?
        let workspaceID: UUID
        let surfaceID: UUID

        var lockPath: String {
            codexHome.appendingPathComponent("thread-writer-locks/\(sessionID).lock").path
        }

        /// The inspector reports realpath-resolved paths (`/var` -> `/private/var`).
        var kernelLockPath: String {
            guard let resolved = realpath(lockPath, nil) else { return lockPath }
            defer { free(resolved) }
            return String(cString: resolved)
        }

        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-issue-12805-\(UUID().uuidString)", isDirectory: true)
            codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createDirectory(
                at: codexHome.appendingPathComponent("thread-writer-locks", isDirectory: true),
                withIntermediateDirectories: true
            )
            sessionID = UUID().uuidString.lowercased()
            previousAppDelegate = AppDelegate.shared
            app = AppDelegate()
            windowID = UUID()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
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
            let focusedPanel = try #require(workspace.focusedTerminalPanel)
            let splitPanel = try #require(workspace.newTerminalSplit(
                from: focusedPanel.id,
                orientation: .horizontal,
                focus: false
            ))
            workspaceID = workspace.id
            surfaceID = splitPanel.id

            let setResult = try Self.v2Result(method: "surface.resume.set", params: [
                "window_id": windowID.uuidString,
                "surface_id": surfaceID.uuidString,
                "kind": "codex",
                "source": "agent-hook",
                "command": "codex resume \(sessionID)",
                "checkpoint_id": sessionID,
                "cwd": root.path,
                "environment": ["CODEX_HOME": codexHome.path],
                "launch_command": [
                    "launcher": "codex",
                    "arguments": ["codex", "resume", sessionID],
                    "working_directory": root.path,
                    "environment": ["CODEX_HOME": codexHome.path],
                    "source": "test",
                ],
            ])
            #expect(setResult["surface_id"] as? String == surfaceID.uuidString)
        }

        func holdWriterLock() throws -> Int32 {
            let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(fd >= 0)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw CocoaError(.fileWriteUnknown)
            }
            return fd
        }

        func admit() async throws -> [String: Any] {
            let request = ControlRequest(
                id: .string("admit"),
                method: "agent.restore.admit",
                params: [
                    "workspace_id": .string(workspaceID.uuidString),
                    "surface_id": .string(surfaceID.uuidString),
                    "kind": .string("codex"),
                    "session_id": .string(sessionID),
                ]
            )
            let raw = await TerminalController.shared.agentRestoreAdmissionResponse(request)
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                Comment(rawValue: raw)
            )
            try #require(envelope["ok"] as? Bool == true, Comment(rawValue: raw))
            return try #require(envelope["result"] as? [String: Any], Comment(rawValue: raw))
        }

        private static func v2Result(method: String, params: [String: Any]) throws -> [String: Any] {
            let request = ["id": method, "method": method, "params": params] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: request)
            let requestLine = try #require(String(data: data, encoding: .utf8))
            let raw = TerminalController.shared.handleSocketLine(requestLine)
            let envelope = try #require(
                JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                Comment(rawValue: raw)
            )
            try #require(envelope["ok"] as? Bool == true, Comment(rawValue: raw))
            return try #require(envelope["result"] as? [String: Any], Comment(rawValue: raw))
        }

        func cleanup() {
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: "codex", sessionId: sessionID)
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            window.orderOut(nil)
            AppDelegate.shared = previousAppDelegate
            try? FileManager.default.removeItem(at: root)
        }
    }
}
