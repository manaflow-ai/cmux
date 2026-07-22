import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Dock session persistence", .serialized)
struct DockSessionPersistenceTests {
    @Test("Dock snapshot round-trip preserves layout and panel state")
    func snapshotRoundTripPreservesLayoutAndPanelState() throws {
        let terminalID = UUID()
        let browserID = UUID()
        let secondaryBrowserID = UUID()
        let profileID = UUID()
        let sourceWorkspaceID = UUID()
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "dock-agent-session",
            workingDirectory: "/tmp/dock-project",
            launchCommand: nil
        )
        let resumeBinding = SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume dock-agent-session",
            cwd: "/tmp/dock-project",
            checkpointId: "dock-agent-session",
            source: "agent-hook",
            autoResume: true,
            updatedAt: 123
        )
        let terminal = SessionPanelSnapshot(
            id: terminalID,
            type: .terminal,
            title: "Agent",
            customTitle: nil,
            directory: "/tmp/dock-project",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: "ttys001",
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: "/tmp/dock-project",
                fontSize: 15,
                scrollback: "saved output",
                agent: agent,
                hibernation: SessionAgentHibernationSnapshot(
                    hibernatedAt: 120,
                    lastActivityAt: 119
                ),
                resumeBinding: resumeBinding,
                textBoxDraft: SessionTextBoxInputDraftSnapshot(
                    isActive: true,
                    parts: [.text("draft prompt")]
                ),
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let browser = SessionPanelSnapshot(
            id: browserID,
            type: .browser,
            title: "Docs",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: "https://example.com/current",
                profileID: profileID,
                shouldRenderWebView: true,
                pageZoom: 1.25,
                developerToolsVisible: true,
                isMuted: true,
                omnibarVisible: false,
                backHistoryURLStrings: ["https://example.com/one"],
                forwardHistoryURLStrings: ["https://example.com/three"]
            ),
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let secondaryBrowser = SessionPanelSnapshot(
            id: secondaryBrowserID,
            type: .browser,
            title: "Reference",
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: "https://example.com/reference",
                profileID: nil,
                shouldRenderWebView: true,
                pageZoom: 1,
                developerToolsVisible: false,
                backHistoryURLStrings: [],
                forwardHistoryURLStrings: []
            ),
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let dock = SessionSplitContainerSnapshot(
            focusedPanelId: browserID,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .horizontal,
                dividerPosition: 0.37,
                first: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [terminalID, browserID],
                    selectedPanelId: browserID
                )),
                second: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [secondaryBrowserID],
                    selectedPanelId: secondaryBrowserID
                ))
            )),
            panels: [terminal, browser, secondaryBrowser],
            sourceWorkspaceIdsByPanelId: [terminalID: sourceWorkspaceID]
        )
        let snapshot = makeAppSnapshot(workspaceDock: dock, windowDock: dock)

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: encoded)
        let decodedWorkspaceDock = try #require(decoded.windows.first?.tabManager.workspaces.first?.dock)
        let decodedWindowDock = try #require(decoded.windows.first?.dock)

        #expect(decodedWorkspaceDock.focusedPanelId == browserID)
        #expect(decodedWindowDock.focusedPanelId == browserID)
        #expect(decodedWorkspaceDock.sourceWorkspaceIdsByPanelId?[terminalID] == sourceWorkspaceID)
        guard case .split(let decodedLayout) = decodedWorkspaceDock.layout else {
            Issue.record("Expected restored Dock split layout")
            return
        }
        #expect(decodedLayout.orientation.rawValue == SessionSplitOrientation.horizontal.rawValue)
        #expect(decodedLayout.dividerPosition == 0.37)
        guard case .pane(let firstPane) = decodedLayout.first else {
            Issue.record("Expected first restored Dock pane")
            return
        }
        #expect(firstPane.panelIds == [terminalID, browserID])
        #expect(firstPane.selectedPanelId == browserID)

        let decodedTerminal = try #require(decodedWorkspaceDock.panels.first { $0.id == terminalID }?.terminal)
        #expect(decodedTerminal.agent?.sessionId == "dock-agent-session")
        #expect(decodedTerminal.resumeBinding?.checkpointId == "dock-agent-session")
        #expect(decodedTerminal.wasAgentRunning == true)
        #expect(decodedTerminal.hibernation?.hibernatedAt == 120)
        #expect(decodedTerminal.textBoxDraft?.parts.first?.text == "draft prompt")
        #expect(decodedTerminal.scrollback == "saved output")
        #expect(decodedTerminal.fontSize == 15)

        let decodedBrowser = try #require(decodedWorkspaceDock.panels.first { $0.id == browserID }?.browser)
        #expect(decodedBrowser.urlString == "https://example.com/current")
        #expect(decodedBrowser.profileID == profileID)
        #expect(decodedBrowser.backHistoryURLStrings == ["https://example.com/one"])
        #expect(decodedBrowser.forwardHistoryURLStrings == ["https://example.com/three"])
        #expect(decodedBrowser.pageZoom == 1.25)
        #expect(decodedBrowser.developerToolsVisible)
        #expect(decodedBrowser.isMuted)
        #expect(decodedBrowser.omnibarVisible == false)
    }

    @Test("Legacy session JSON without Dock fields decodes cleanly")
    func legacySessionWithoutDockFieldsDecodesCleanly() throws {
        let current = makeAppSnapshot(workspaceDock: nil, windowDock: nil)
        let encoded = try JSONEncoder().encode(current)
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var windows = try #require(root["windows"] as? [[String: Any]])
        windows[0].removeValue(forKey: "dock")
        var tabManager = try #require(windows[0]["tabManager"] as? [String: Any])
        var workspaces = try #require(tabManager["workspaces"] as? [[String: Any]])
        workspaces[0].removeValue(forKey: "dock")
        tabManager["workspaces"] = workspaces
        windows[0]["tabManager"] = tabManager
        root["windows"] = windows

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: legacyData)

        #expect(decoded.windows.first?.dock == nil)
        #expect(decoded.windows.first?.tabManager.workspaces.first?.dock == nil)
    }

    @Test("Restored Dock snapshot wins over a late initial config seed")
    @MainActor
    func restoredSnapshotSuppressesInitialConfigSeed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dock-session-precedence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { root.path })
        defer { store.closeAllPanels() }
        store.restoreSessionSnapshot(SessionSplitContainerSnapshot(
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: []
        ))
        store.applyConfigurationIdentityForTesting(DockConfigIdentity(
            sourcePath: nil,
            baseDirectory: root.path
        ))

        #expect(store.panels.isEmpty)
        #expect(store.hasAppliedConfigurationSeed)

        let generation = store.markConfigurationLoadInFlightForTesting(rootDirectory: root.path)
        let config = DockConfigResolution(
            controls: [DockControlDefinition(
                id: "configured",
                title: "Configured",
                command: "echo configured"
            )],
            sourceURL: nil,
            baseDirectory: root.path,
            isProjectSource: false
        )
        store.applyConfigurationLoadResult(.resolved(config), generation: generation, replacingPanels: false)

        #expect(store.panels.isEmpty)
        #expect(store.bonsplitController.allTabIds.isEmpty)
        #expect(store.hasAppliedConfigurationSeed)
    }

    private func makeAppSnapshot(
        workspaceDock: SessionSplitContainerSnapshot?,
        windowDock: SessionSplitContainerSnapshot?
    ) -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            dock: workspaceDock
        )
        let window = SessionWindowSnapshot(
            frame: nil,
            display: nil,
            tabManager: SessionTabManagerSnapshot(
                selectedWorkspaceIndex: 0,
                workspaces: [workspace]
            ),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            ),
            dock: windowDock
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: 123,
            windows: [window]
        )
    }
}
