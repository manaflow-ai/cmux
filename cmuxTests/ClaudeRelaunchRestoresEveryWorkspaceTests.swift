import AppKit
import CMUXAgentLaunch
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// After a relaunch every terminal that ran Claude Code comes back on its own
/// session: the selected workspace and the ones behind it, each with the
/// account (`CLAUDE_CONFIG_DIR`) it ran under, so no tab sits idle or opens
/// "Not logged in". The relaunch is a saved window snapshot, written and read
/// back as JSON, restored by a fresh `TabManager` the way launch restores it.
@MainActor
@Suite(.serialized)
struct ClaudeRelaunchRestoresEveryWorkspaceTests {
    private struct Saved {
        let sessionID: String
        let configDirectory: String
    }

    @Test("Every workspace's Claude reattaches after a relaunch, each to its own session and account")
    func everyClaudeWorkspaceReattachesAfterRelaunch() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-claude-relaunch-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            // Three workspaces each running Claude; the second runs under another
            // account's config directory, as a second Claude login does.
            let defaultConfig = root.appendingPathComponent("claude", isDirectory: true).path
            let otherConfig = root.appendingPathComponent("claude-work", isDirectory: true).path
            var saved: [Saved] = []
            var workspaces: [SessionWorkspaceSnapshot] = []
            for index in 0..<3 {
                let directory = root.appendingPathComponent("repo-\(index)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let entry = Saved(
                    sessionID: UUID().uuidString.lowercased(),
                    configDirectory: index == 1 ? otherConfig : defaultConfig
                )
                saved.append(entry)
                workspaces.append(try runningClaudeWorkspace(entry, directory: directory.path))
            }
            let persisted = try JSONEncoder().encode(
                SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: workspaces)
            )
            let snapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: persisted)

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
                for entry in saved {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: "claude", sessionId: entry.sessionID)
                }
                TerminalController.shared.setActiveTabManager(previousManager)
                app.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.finalizeAllWorkspacesForWindowClose()
                window.orderOut(nil)
                AppDelegate.shared = previousApp
            }

            // Workspaces the TabManager restores read auto-resume from the app's own
            // defaults, as at launch; it is on unless the person turned it off.
            let restoredIDs = manager.restoreSessionSnapshot(snapshot)
            #expect(manager.tabs.count == 3)
            #expect(manager.selectedWorkspace === manager.tabs.first)

            for (index, entry) in saved.enumerated() {
                let context = Comment(rawValue: "workspace \(index)")
                let workspace = try #require(manager.tabs.dropFirst(index).first, context)
                await workspace.deferredAgentResumeIndexTask?.value
                let sourcePanelID = try #require(workspaces[index].panels.first?.id, context)
                let panelID = try #require(restoredIDs.dropFirst(index).first?[sourcePanelID], context)
                let panel = try #require(workspace.terminalPanel(for: panelID), context)

                // The terminal starts and types the restore verb for its own session.
                #expect(panel.surface.canCreateRuntimeSurface, context)
                #expect(
                    panel.surface.debugInitialInputForTesting() == " cmux restore claude \(entry.sessionID)\n",
                    Comment(rawValue: "workspace \(index): \(panel.surface.debugInitialInputForTesting() ?? "nil")")
                )

                // `cmux restore claude` reads this record; it must name the session and
                // carry the account it ran under.
                let get = try result(TerminalController.shared.handleSocketLine(line([
                    "id": "get-\(index)", "method": "surface.resume.get", "params": [
                        "workspace_id": workspace.id.uuidString, "surface_id": panelID.uuidString,
                    ],
                ])))
                let record = try #require(get["restore_record"] as? [String: Any], context)
                #expect(record["kind"] as? String == "claude", context)
                #expect(record["checkpoint_id"] as? String == entry.sessionID, context)
                let launch = try #require(record["launch_command"] as? [String: Any], context)
                let environment = launch["environment"] as? [String: String] ?? [:]
                #expect(environment["CLAUDE_CONFIG_DIR"] == entry.configDirectory, context)

                // The restore verb's admission lets each one launch.
                let admission = ControlRequest(id: .string("admit-\(index)"), method: "agent.restore.admit", params: [
                    "workspace_id": .string(workspace.id.uuidString), "surface_id": .string(panelID.uuidString),
                    "kind": .string("claude"), "session_id": .string(entry.sessionID),
                ])
                let admitted = try result(await TerminalController.shared.agentRestoreAdmissionResponse(admission))
                #expect(admitted["admitted"] as? Bool == true, Comment(rawValue: "workspace \(index): \(admitted)"))
            }
        }
    }

    /// A saved workspace whose one terminal was running Claude when the app quit.
    private func runningClaudeWorkspace(
        _ entry: Saved,
        directory: String
    ) throws -> SessionWorkspaceSnapshot {
        let source = Workspace(workingDirectory: directory, restorableAgentIndexProvider: { .empty })
        defer { source.teardownAllPanels() }
        let panelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == panelID })
        snapshot.panels[panelIndex].terminal?.agent = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: entry.sessionID,
            workingDirectory: directory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude"],
                workingDirectory: directory,
                environment: ["CLAUDE_CONFIG_DIR": entry.configDirectory],
                capturedAt: 1_800_200_000,
                source: "test"
            )
        )
        snapshot.panels[panelIndex].terminal?.wasAgentRunning = true
        return snapshot
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func result(_ raw: String) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        try #require(envelope["ok"] as? Bool == true, Comment(rawValue: raw))
        return try #require(envelope["result"] as? [String: Any])
    }
}
