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
        let windowPrimaryBrowserID = UUID()
        let windowSecondaryBrowserID = UUID()
        let windowTertiaryBrowserID = UUID()
        let profileID = UUID()
        let sourceWorkspaceID = UUID()
        let windowSourceWorkspaceID = UUID()
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
        let workspaceDock = SessionSplitContainerSnapshot(
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
        let windowPrimaryBrowser = browserSnapshot(
            id: windowPrimaryBrowserID,
            title: "Window primary",
            urlString: "https://window.example.com/primary"
        )
        let windowSecondaryBrowser = browserSnapshot(
            id: windowSecondaryBrowserID,
            title: "Window secondary",
            urlString: "https://window.example.com/secondary"
        )
        let windowTertiaryBrowser = browserSnapshot(
            id: windowTertiaryBrowserID,
            title: "Window tertiary",
            urlString: "https://window.example.com/tertiary"
        )
        let windowDock = SessionSplitContainerSnapshot(
            focusedPanelId: windowTertiaryBrowserID,
            layout: .split(SessionSplitLayoutSnapshot(
                orientation: .vertical,
                dividerPosition: 0.62,
                first: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [windowPrimaryBrowserID, windowSecondaryBrowserID],
                    selectedPanelId: windowPrimaryBrowserID
                )),
                second: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [windowTertiaryBrowserID],
                    selectedPanelId: windowTertiaryBrowserID
                ))
            )),
            panels: [windowPrimaryBrowser, windowSecondaryBrowser, windowTertiaryBrowser],
            sourceWorkspaceIdsByPanelId: [windowTertiaryBrowserID: windowSourceWorkspaceID]
        )
        let snapshot = makeAppSnapshot(workspaceDock: workspaceDock, windowDock: windowDock)

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: encoded)
        let decodedWorkspaceDock = try #require(decoded.windows.first?.tabManager.workspaces.first?.dock)
        let decodedWindowDock = try #require(decoded.windows.first?.dock)

        #expect(decodedWorkspaceDock.focusedPanelId == browserID)
        #expect(decodedWorkspaceDock.sourceWorkspaceIdsByPanelId?[terminalID] == sourceWorkspaceID)
        guard case .split(let decodedWorkspaceLayout) = decodedWorkspaceDock.layout else {
            Issue.record("Expected restored workspace Dock split layout")
            return
        }
        #expect(decodedWorkspaceLayout.orientation.rawValue == SessionSplitOrientation.horizontal.rawValue)
        #expect(decodedWorkspaceLayout.dividerPosition == 0.37)
        guard case .pane(let workspaceFirstPane) = decodedWorkspaceLayout.first else {
            Issue.record("Expected first restored workspace Dock pane")
            return
        }
        #expect(workspaceFirstPane.panelIds == [terminalID, browserID])
        #expect(workspaceFirstPane.selectedPanelId == browserID)
        guard case .pane(let workspaceSecondPane) = decodedWorkspaceLayout.second else {
            Issue.record("Expected second restored workspace Dock pane")
            return
        }
        #expect(workspaceSecondPane.panelIds == [secondaryBrowserID])
        #expect(workspaceSecondPane.selectedPanelId == secondaryBrowserID)

        #expect(decodedWindowDock.focusedPanelId == windowTertiaryBrowserID)
        #expect(
            decodedWindowDock.sourceWorkspaceIdsByPanelId?[windowTertiaryBrowserID]
                == windowSourceWorkspaceID
        )
        guard case .split(let decodedWindowLayout) = decodedWindowDock.layout else {
            Issue.record("Expected restored window Dock split layout")
            return
        }
        #expect(decodedWindowLayout.orientation.rawValue == SessionSplitOrientation.vertical.rawValue)
        #expect(decodedWindowLayout.dividerPosition == 0.62)
        guard case .pane(let windowFirstPane) = decodedWindowLayout.first else {
            Issue.record("Expected first restored window Dock pane")
            return
        }
        #expect(windowFirstPane.panelIds == [windowPrimaryBrowserID, windowSecondaryBrowserID])
        #expect(windowFirstPane.selectedPanelId == windowPrimaryBrowserID)
        guard case .pane(let windowSecondPane) = decodedWindowLayout.second else {
            Issue.record("Expected second restored window Dock pane")
            return
        }
        #expect(windowSecondPane.panelIds == [windowTertiaryBrowserID])
        #expect(windowSecondPane.selectedPanelId == windowTertiaryBrowserID)

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

        let decodedWindowBrowser = try #require(
            decodedWindowDock.panels.first { $0.id == windowSecondaryBrowserID }?.browser
        )
        #expect(decodedWindowBrowser.urlString == "https://window.example.com/secondary")
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

    @Test(
        "Dock resume follows the stable surface across owner rotations",
        arguments: [DockScope.global, DockScope.workspace]
    )
    @MainActor
    func resumeFollowsStableSurfaceAcrossOwnerRotations(scope: DockScope) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dock-owner-rotation-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map {
            String(cString: $0)
        }
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        defer {
            if let previousHookStateDirectory {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
        }

        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let previousOwnerID = UUID()
        let persistedOwnerID = UUID()
        let restoredOwnerID = UUID()
        let panelID = UUID()
        let stableSurfaceID = UUID()
        let currentSessionID = UUID().uuidString
        let staleSessionID = UUID().uuidString

        try writeCodexHookStore(
            directory: hookStateDirectory,
            sessions: [
                currentSessionID: codexHookRecord(
                    sessionID: currentSessionID,
                    workspaceID: previousOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
                staleSessionID: codexHookRecord(
                    sessionID: staleSessionID,
                    workspaceID: persistedOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 100
                ),
            ]
        )
        let agentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: previousOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: currentSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
            .init(workspaceId: persistedOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: staleSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 100
            ),
        ])

        let sourceStore = DockSplitStore(
            workspaceId: persistedOwnerID,
            scope: scope,
            baseDirectoryProvider: { workingDirectory.path }
        )
        defer { sourceStore.closeAllPanels() }
        sourceStore.restoreSessionSnapshot(emptyTerminalDockSnapshot(
            panelID: panelID,
            stableSurfaceID: stableSurfaceID,
            workingDirectory: workingDirectory.path
        ))
        sourceStore.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)

        let persisted = sourceStore.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: agentIndex,
            surfaceResumeBindingIndex: bindingIndex
        )
        let persistedTerminal = try #require(
            persisted.panels.first { $0.id == panelID }?.terminal
        )
        #expect(persistedOwnerID != previousOwnerID)
        #expect(persistedTerminal.agent?.sessionId == currentSessionID)
        #expect(persistedTerminal.resumeBinding?.checkpointId == currentSessionID)
        #expect(persistedTerminal.wasAgentRunning == true)

        sourceStore.closeAllPanels()

        let restoredStore = DockSplitStore(
            workspaceId: restoredOwnerID,
            scope: scope,
            baseDirectoryProvider: { workingDirectory.path }
        )
        defer { restoredStore.closeAllPanels() }
        let restoredIDs = restoredStore.restoreSessionSnapshot(persisted)
        let restoredPanelID = try #require(restoredIDs[panelID])
        let restoredTerminal = try #require(
            restoredStore.panels[restoredPanelID] as? TerminalPanel
        )
        let restoredAgent = try #require(
            restoredStore.restoredAgentLifecycle.snapshotsByPanelId[restoredPanelID]
        )
        let startupInput = try #require(restoredTerminal.surface.initialInput)
        let launcherPath = try #require(
            TerminalStartupWorkingDirectoryPrefix.shellWordRanges(
                startupInput.trimmingCharacters(in: .whitespacesAndNewlines)
            ).map(\.value).last
        )
        defer { try? fileManager.removeItem(atPath: launcherPath) }
        let startupPayload = try String(contentsOfFile: launcherPath, encoding: .utf8)

        #expect(restoredOwnerID != persistedOwnerID)
        #expect(restoredTerminal.stableSurfaceId == stableSurfaceID)
        #expect(restoredAgent.kind == .codex)
        #expect(restoredAgent.sessionId == currentSessionID)
        #expect(startupInput.contains("/cmux-r/"), Comment(rawValue: startupInput))
        #expect(startupPayload.contains(currentSessionID), Comment(rawValue: startupPayload))
        #expect(!startupPayload.contains(staleSessionID), Comment(rawValue: startupPayload))
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

    private func emptyTerminalDockSnapshot(
        panelID: UUID,
        stableSurfaceID: UUID,
        workingDirectory: String
    ) -> SessionSplitContainerSnapshot {
        SessionSplitContainerSnapshot(
            focusedPanelId: panelID,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: [panelID],
                selectedPanelId: panelID
            )),
            panels: [
                SessionPanelSnapshot(
                    id: panelID,
                    stableSurfaceId: stableSurfaceID,
                    type: .terminal,
                    title: "Agent",
                    customTitle: nil,
                    directory: workingDirectory,
                    isPinned: false,
                    isManuallyUnread: false,
                    listeningPorts: [],
                    ttyName: nil,
                    terminal: SessionTerminalPanelSnapshot(
                        workingDirectory: workingDirectory
                    ),
                    browser: nil,
                    markdown: nil,
                    filePreview: nil,
                    rightSidebarTool: nil
                ),
            ]
        )
    }

    private func codexHookRecord(
        sessionID: String,
        workspaceID: UUID,
        panelID: UUID,
        workingDirectory: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": workingDirectory,
            "pid": NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex"],
                "workingDirectory": workingDirectory,
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }

    private func codexResumeBinding(
        sessionID: String,
        workingDirectory: String,
        updatedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Codex",
            kind: "codex",
            command: "codex resume \(sessionID)",
            cwd: workingDirectory,
            checkpointId: sessionID,
            source: "agent-hook",
            autoResume: true,
            updatedAt: updatedAt
        )
    }

    private func writeCodexHookStore(
        directory: URL,
        sessions: [String: [String: Any]]
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: directory.appendingPathComponent("codex-hook-sessions.json"),
            options: .atomic
        )
    }

    private func browserSnapshot(id: UUID, title: String, urlString: String) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .browser,
            title: title,
            customTitle: nil,
            directory: nil,
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: nil,
            browser: SessionBrowserPanelSnapshot(
                urlString: urlString,
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
    }
}
