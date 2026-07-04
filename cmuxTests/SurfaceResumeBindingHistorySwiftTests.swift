import AppKit
import CMUXAgentLaunch
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SurfaceResumeBindingHistorySwiftTests {
    private func makeMainWindow(id: UUID) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(id.uuidString)")
        return window
    }

    private func decodeV2Response(_ response: String) throws -> [String: Any] {
        let data = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func v2Envelope(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil
    ) throws -> (raw: String, envelope: [String: Any]) {
        let request: [String: Any] = [
            "id": id ?? method,
            "method": method,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let requestLine = try #require(String(data: requestData, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(requestLine)
        return (raw, try decodeV2Response(raw))
    }

    private func v2Result(
        method: String,
        params: [String: Any] = [:],
        id: String? = nil
    ) throws -> [String: Any] {
        let (_, envelope) = try v2Envelope(method: method, params: params, id: id)
        #expect(envelope["ok"] as? Bool == true)
        return try #require(envelope["result"] as? [String: Any])
    }

    private func makeCodexRestorableAgentIndex(
        workspaceId: UUID,
        panelId: UUID,
        sessionId: String,
        arguments: [String]
    ) throws -> RestorableAgentSessionIndex {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(homeDirectory: home.path)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionRecord: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": "/tmp/repo",
            "updatedAt": Date.now.timeIntervalSince1970,
            "launchCommand": [
                "launcher": "codex",
                "executablePath": arguments.first ?? "/usr/local/bin/codex",
                "arguments": arguments,
                "workingDirectory": "/tmp/repo",
                "environment": ["CODEX_HOME": "/tmp/codex"],
                "capturedAt": Date.now.timeIntervalSince1970,
                "source": "process",
            ],
        ]
        let jsonObject: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionId: sessionRecord,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted])
        try data.write(to: storeURL, options: .atomic)

        return RestorableAgentSessionIndex.load(homeDirectory: home.path)
    }

    @Test func surfaceResumeGetKeepsDisplacedAgentHookBindingReachable() throws {
        _ = NSApplication.shared
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let windowId = UUID()
        let window = makeMainWindow(id: windowId)
        defer {
            TerminalController.shared.setActiveTabManager(nil)
            app.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        app.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState(),
            fileExplorerState: FileExplorerState()
        )
        TerminalController.shared.setActiveTabManager(manager)

        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        _ = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "name": "Codex",
                "kind": "codex",
                "command": "codex resume real-thread",
                "checkpoint_id": "real-thread",
                "source": "agent-hook",
                "auto_resume": true,
            ]
        )
        _ = try v2Result(
            method: "surface.resume.set",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
                "name": "Codex",
                "kind": "codex",
                "command": "codex resume recap-thread",
                "checkpoint_id": "recap-thread",
                "source": "agent-hook",
                "auto_resume": true,
            ]
        )

        let getResult = try v2Result(
            method: "surface.resume.get",
            params: [
                "window_id": windowId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "surface_id": panelId.uuidString,
            ]
        )
        let activeBinding = try #require(getResult["resume_binding"] as? [String: Any])
        #expect(activeBinding["checkpoint_id"] as? String == "recap-thread")
        let history = try #require(getResult["resume_binding_history"] as? [[String: Any]])
        #expect(history.compactMap { $0["checkpoint_id"] as? String } == ["recap-thread", "real-thread"])
        #expect(history.compactMap { $0["source"] as? String } == ["agent-hook", "agent-hook"])
    }

    @Test func restoredAgentInvalidationPrunesInvalidResumeBindingHistory() throws {
        let source = Workspace()
        let sourcePanelId = try #require(source.focusedPanelId)
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume previous-session",
                cwd: "/tmp/repo",
                checkpointId: "previous-session",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: sourcePanelId
        ))
        #expect(source.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume codex-restored-session",
                cwd: "/tmp/repo",
                checkpointId: "codex-restored-session",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 20
            ),
            panelId: sourcePanelId
        ))
        let sourceIndex = try makeCodexRestorableAgentIndex(
            workspaceId: source.id,
            panelId: sourcePanelId,
            sessionId: "codex-restored-session",
            arguments: [
                "/usr/local/bin/codex",
                "--model",
                "gpt-5.4",
            ]
        )
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: sourceIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try #require(restored.focusedPanelId)
        #expect(
            restored.surfaceResumeBindingHistory(panelId: restoredPanelId).compactMap(\.checkpointId)
                == ["codex-restored-session", "previous-session"]
        )

        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .commandRunning)
        restored.updatePanelShellActivityState(panelId: restoredPanelId, state: .promptIdle)

        #expect(restored.surfaceResumeBinding(panelId: restoredPanelId) == nil)
        #expect(
            restored.surfaceResumeBindingHistory(panelId: restoredPanelId).compactMap(\.checkpointId)
                == ["previous-session"]
        )
    }

    @Test func snapshotPersistsDisplacedAgentHookResumeBindingHistory() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume real-thread",
                cwd: "/tmp/real",
                checkpointId: "real-thread",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: panelId
        ))
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume recap-thread",
                cwd: "/tmp/recap",
                checkpointId: "recap-thread",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 20
            ),
            panelId: panelId
        ))

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let panels = try #require(object["panels"] as? [[String: Any]])
        let terminal = try #require(panels.first?["terminal"] as? [String: Any])
        let activeBinding = try #require(terminal["resumeBinding"] as? [String: Any])
        let history = try #require(terminal["resumeBindingHistory"] as? [[String: Any]])

        #expect(activeBinding["checkpointId"] as? String == "recap-thread")
        #expect(history.compactMap { $0["checkpointId"] as? String } == ["recap-thread", "real-thread"])
        #expect(history.compactMap { $0["source"] as? String } == ["agent-hook", "agent-hook"])
    }

    @Test(arguments: ["agent-hook", nil])
    func clearingCheckpointlessBindingPreservesDifferentHistoryEntries(activeSource: String?) throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume real-thread",
                cwd: "/tmp/real",
                checkpointId: "real-thread",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: panelId
        ))
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume scratch-thread",
                cwd: "/tmp/scratch",
                checkpointId: nil,
                source: activeSource,
                autoResume: true,
                updatedAt: 20
            ),
            panelId: panelId
        ))

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId))
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
        let history = workspace.surfaceResumeBindingHistory(panelId: panelId)
        #expect(history.map(\.command) == ["codex resume real-thread"])
        #expect(history.compactMap(\.checkpointId) == ["real-thread"])

        #expect(!workspace.clearSurfaceResumeBinding(panelId: panelId))
        let retainedHistory = workspace.surfaceResumeBindingHistory(panelId: panelId)
        #expect(retainedHistory.map(\.command) == ["codex resume real-thread"])
        #expect(retainedHistory.compactMap(\.checkpointId) == ["real-thread"])
    }

    @Test func clearingProcessDetectedBindingPreservesAgentHookHistory() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume real-thread",
                cwd: "/tmp/real",
                checkpointId: "real-thread",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: panelId
        ))

        workspace.reconcileSurfaceResumeBindings(using: SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t real-thread",
                cwd: "/tmp/real",
                checkpointId: "real-thread",
                source: "process-detected",
                autoResume: true,
                updatedAt: 20
            ),
        ]))
        #expect(workspace.surfaceResumeBinding(panelId: panelId)?.source == "process-detected")

        #expect(workspace.clearSurfaceResumeBinding(panelId: panelId))
        #expect(workspace.surfaceResumeBinding(panelId: panelId) == nil)
        let history = workspace.surfaceResumeBindingHistory(panelId: panelId)
        #expect(history.compactMap(\.source) == ["agent-hook"])
        #expect(history.compactMap(\.checkpointId) == ["real-thread"])
    }
}
