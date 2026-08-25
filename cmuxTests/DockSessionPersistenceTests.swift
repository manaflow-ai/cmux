import Foundation
import Testing
import CmuxControlSocket
import CmuxWorkspaces

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
        let defaultsName = "cmux-dock-owner-rotation-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let testEnvironment = ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]

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
            environment: testEnvironment,
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
            baseDirectoryProvider: { workingDirectory.path },
            agentSessionAutoResumeDefaults: defaults
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

        let closedPanelSnapshot = try #require(
            sourceStore.closedPanelSessionSnapshot(
                panelId: panelID,
                restorableAgentIndex: agentIndex
            )
        )
        #expect(closedPanelSnapshot.terminal?.agent?.sessionId == currentSessionID)

        sourceStore.closeAllPanels()

        let restoredStore = DockSplitStore(
            workspaceId: restoredOwnerID,
            scope: scope,
            baseDirectoryProvider: { workingDirectory.path },
            agentSessionAutoResumeDefaults: defaults
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

        #expect(restoredOwnerID != persistedOwnerID)
        #expect(restoredTerminal.stableSurfaceId == stableSurfaceID)
        #expect(restoredAgent.kind == .codex)
        #expect(restoredAgent.sessionId == currentSessionID)
        if startupInput.contains("/cmux-r/") {
            let launcherPath = try #require(
                TerminalStartupWorkingDirectoryPrefix.shellWordRanges(
                    startupInput.trimmingCharacters(in: .whitespacesAndNewlines)
                ).map(\.value).last
            )
            defer { try? fileManager.removeItem(atPath: launcherPath) }
            let startupPayload = try String(contentsOfFile: launcherPath, encoding: .utf8)
            #expect(startupPayload.contains(currentSessionID), Comment(rawValue: startupPayload))
            #expect(!startupPayload.contains(staleSessionID), Comment(rawValue: startupPayload))
        } else {
            #expect(startupInput.contains(currentSessionID), Comment(rawValue: startupInput))
            #expect(!startupInput.contains(staleSessionID), Comment(rawValue: startupInput))
        }
    }

    @Test(
        "Dock stable-panel lookup prefers live process state over stale owner hook",
        arguments: [DockScope.global, DockScope.workspace]
    )
    @MainActor
    func stablePanelLookupPrefersLiveProcessStateOverStaleOwnerHook(
        scope: DockScope
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-dock-live-process-fallback-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let testEnvironment = ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]
        let staleOwnerID = UUID()
        let liveOwnerID = UUID()
        let panelID = UUID()
        let stableSurfaceID = UUID()
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let staleSessionID = UUID().uuidString
        let liveSessionID = UUID().uuidString
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try writeCodexHookStore(
            directory: hookStateDirectory,
            sessions: [
                staleSessionID: codexHookRecord(
                    sessionID: staleSessionID,
                    workspaceID: staleOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
            ]
        )

        let processID = 42_001
        let processIdentity = AgentPIDProcessIdentity(
            pid: pid_t(processID),
            startSeconds: 10,
            startMicroseconds: 20
        )
        let liveKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: liveOwnerID,
            panelId: panelID
        )
        let agentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                liveKey: (
                    snapshot: SessionRestorableAgentSnapshot(
                        kind: .codex,
                        sessionId: liveSessionID,
                        workingDirectory: workingDirectory.path,
                        launchCommand: nil
                    ),
                    updatedAt: 200,
                    processIDs: [processID],
                    agentProcessIDs: [processID],
                    sessionIDSource: .explicit
                ),
            ],
            environment: testEnvironment,
            processArgumentsProvider: { _ in nil },
            processIdentityProvider: { pid in
                pid == processID ? processIdentity : nil
            }
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: staleOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: staleSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
            .init(workspaceId: liveOwnerID, panelId: panelID): codexProcessDetectedResumeBinding(
                sessionID: liveSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
        ])

        let store = DockSplitStore(
            workspaceId: staleOwnerID,
            scope: scope,
            baseDirectoryProvider: { workingDirectory.path }
        )
        defer { store.closeAllPanels() }
        store.restoreSessionSnapshot(emptyTerminalDockSnapshot(
            panelID: panelID,
            stableSurfaceID: stableSurfaceID,
            workingDirectory: workingDirectory.path
        ))
        store.updatePanelShellActivityState(panelId: panelID, state: .commandRunning)

        let snapshot = store.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: agentIndex,
            surfaceResumeBindingIndex: bindingIndex,
            currentAgentProcessIdentity: { pid in
                pid == processID ? processIdentity : nil
            },
            agentProcessPresence: { _ in .present }
        )
        let terminal = try #require(snapshot.panels.first?.terminal)

        #expect(terminal.agent?.sessionId == liveSessionID)
        #expect(terminal.resumeBinding?.checkpointId == liveSessionID)
        #expect(terminal.wasAgentRunning == true)
        #expect(terminal.agent?.sessionId != staleSessionID)
        #expect(terminal.resumeBinding?.checkpointId != staleSessionID)
    }

    @Test("Panel-only Dock lookups fail closed for equal-timestamp owner records")
    func panelOnlyLookupsFailClosedForEqualTimestampOwnerRecords() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-dock-equal-timestamp-ambiguity-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let testEnvironment = ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]

        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        let panelID = UUID()
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let firstSessionID = UUID().uuidString
        let secondSessionID = UUID().uuidString
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try writeCodexHookStore(
            directory: hookStateDirectory,
            sessions: [
                firstSessionID: codexHookRecord(
                    sessionID: firstSessionID,
                    workspaceID: firstOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
                secondSessionID: codexHookRecord(
                    sessionID: secondSessionID,
                    workspaceID: secondOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
            ]
        )

        let agentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: testEnvironment,
            processArgumentsProvider: { _ in nil }
        )
        #expect(agentIndex.entry(panelId: panelID) == nil)
        #expect(agentIndex.entry(workspaceId: UUID(), panelId: panelID) == nil)
        #expect(agentIndex.entryForStablePanel(workspaceId: firstOwnerID, panelId: panelID) == nil)

        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: firstOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: firstSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
            .init(workspaceId: secondOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: secondSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
        ])
        #expect(bindingIndex.binding(panelId: panelID) == nil)
        #expect(bindingIndex.binding(workspaceId: UUID(), panelId: panelID) == nil)
        #expect(bindingIndex.bindingForStablePanel(workspaceId: firstOwnerID, panelId: panelID) == nil)

        let newestOwnerID = UUID()
        let newestSessionID = UUID().uuidString
        try writeCodexHookStore(
            directory: hookStateDirectory,
            sessions: [
                firstSessionID: codexHookRecord(
                    sessionID: firstSessionID,
                    workspaceID: firstOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
                secondSessionID: codexHookRecord(
                    sessionID: secondSessionID,
                    workspaceID: secondOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
                newestSessionID: codexHookRecord(
                    sessionID: newestSessionID,
                    workspaceID: newestOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 300
                ),
            ]
        )
        let newestAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: testEnvironment,
            processArgumentsProvider: { _ in nil }
        )
        #expect(newestAgentIndex.entry(panelId: panelID)?.snapshot.sessionId == newestSessionID)
        let newestBindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            .init(workspaceId: firstOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: firstSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
            .init(workspaceId: secondOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: secondSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 200
            ),
            .init(workspaceId: newestOwnerID, panelId: panelID): codexResumeBinding(
                sessionID: newestSessionID,
                workingDirectory: workingDirectory.path,
                updatedAt: 300
            ),
        ])
        #expect(newestBindingIndex.binding(panelId: panelID)?.checkpointId == newestSessionID)
    }

    @Test("Stable-panel lookup revalidates a cached owner PID before preferring it")
    func stablePanelLookupRevalidatesCachedOwnerPID() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "cmux-dock-stale-owner-pid-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let staleOwnerID = UUID()
        let restoredOwnerID = UUID()
        let panelID = UUID()
        let staleSessionID = UUID().uuidString
        let currentSessionID = UUID().uuidString
        let stalePID = 43_001
        let recordedIdentity = AgentPIDProcessIdentity(
            pid: pid_t(stalePID),
            startSeconds: 10,
            startMicroseconds: 20
        )
        var staleRecord = codexHookRecord(
            sessionID: staleSessionID,
            workspaceID: staleOwnerID,
            panelID: panelID,
            workingDirectory: workingDirectory.path,
            updatedAt: 300
        )
        staleRecord["pid"] = stalePID
        staleRecord["pidStartSeconds"] = recordedIdentity.startSeconds
        staleRecord["pidStartMicroseconds"] = recordedIdentity.startMicroseconds
        try writeCodexHookStore(
            directory: hookStateDirectory,
            sessions: [
                staleSessionID: staleRecord,
                currentSessionID: codexHookRecord(
                    sessionID: currentSessionID,
                    workspaceID: restoredOwnerID,
                    panelID: panelID,
                    workingDirectory: workingDirectory.path,
                    updatedAt: 200
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path],
            processArgumentsProvider: { pid in
                pid == stalePID
                    ? CmuxTopProcessArguments(
                        arguments: ["/usr/local/bin/codex"],
                        environment: [
                            "CMUX_WORKSPACE_ID": staleOwnerID.uuidString,
                            "CMUX_SURFACE_ID": panelID.uuidString,
                        ]
                    )
                    : nil
            },
            processPresenceProvider: { _ in .present },
            processIdentityProvider: { pid in
                pid == stalePID ? recordedIdentity : nil
            }
        )

        let resolved = index.entryForStablePanel(
            workspaceId: staleOwnerID,
            panelId: panelID
        )
        #expect(resolved?.snapshot.sessionId == currentSessionID)
    }

    @Test("Dock file-preview session round-trip preserves path, kind, and binding")
    @MainActor
    func filePreviewSessionRoundTripPreservesPathKindAndBinding() throws {
        let sourceStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { "/tmp" }
        )
        let restoredStore = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { "/tmp" }
        )
        defer {
            sourceStore.closeAllPanels()
            restoredStore.closeAllPanels()
        }

        let sourcePaneID = try #require(
            sourceStore.bonsplitController.allPaneIds.first
        )
        let filePath = "/tmp/cmux dock session/preview.md"
        let sourcePanel = try #require(
            sourceStore.newFilePreviewSurface(
                inPane: sourcePaneID,
                filePath: filePath,
                focus: false
            )
        )
        let snapshot = sourceStore.sessionSnapshot(includeScrollback: false)

        let restoredPanelIDs = restoredStore.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredPanelIDs[sourcePanel.id])
        let restoredPanel = try #require(
            restoredStore.panels[restoredPanelID] as? FilePreviewPanel
        )
        let restoredTabID = try #require(
            restoredStore.surfaceId(forPanelId: restoredPanelID)
        )
        let restoredHost = try #require(restoredPanel.tabMetadataHost)

        #expect(restoredPanel.filePath == filePath)
        #expect(
            restoredStore.bonsplitController.tab(restoredTabID)?.kind
                == SurfaceKind.filePreview.rawValue
        )
        #expect(restoredStore.panel(for: restoredTabID) === restoredPanel)
        #expect(
            restoredStore.filePreviewTabId(forPanelId: restoredPanelID)
                == restoredTabID
        )
        #expect((restoredHost as AnyObject) === restoredStore)
    }

    @Test(
        "Directly restored Dock terminal protects its persisted title through startup",
        arguments: [DockScope.workspace, DockScope.global]
    )
    @MainActor
    func directlyRestoredTerminalProtectsPersistedTitle(
        scope: DockScope
    ) throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let store: DockSplitStore
        switch scope {
        case .workspace:
            store = workspace.dockSplit
        case .global:
            store = manager.makeWindowDockStore(windowId: UUID())
        }
        defer {
            store.closeAllPanels()
            workspace.teardownAllPanels()
        }

        let snapshotPanelID = UUID()
        let persistedTitle = "Persisted Dock task"
        let panelSnapshot = SessionPanelSnapshot(
            id: snapshotPanelID,
            type: .terminal,
            title: persistedTitle,
            customTitle: nil,
            directory: "/tmp",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: "/tmp"),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        let restoredPanelIDs = store.restoreSessionSnapshot(
            SessionSplitContainerSnapshot(
                focusedPanelId: snapshotPanelID,
                layout: .pane(SessionPaneLayoutSnapshot(
                    panelIds: [snapshotPanelID],
                    selectedPanelId: snapshotPanelID
                )),
                panels: [panelSnapshot]
            )
        )
        let panelID = try #require(restoredPanelIDs[snapshotPanelID])
        let tabID = try #require(store.surfaceId(forPanelId: panelID))
        let terminal = try #require(store.panels[panelID] as? TerminalPanel)
        #expect(store.bonsplitController.tab(tabID)?.title == persistedTitle)
        #expect(store.bonsplitController.tab(tabID)?.hasCustomTitle == false)

        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: store.workspaceId,
                surfaceId: panelID,
                title: "zsh",
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )
        store.flushPendingTerminalTitleUpdates()
        #expect(store.bonsplitController.tab(tabID)?.title == persistedTitle)

        let detached = try #require(store.detachSurface(panelId: panelID))
        #expect(detached.title == persistedTitle)
        #expect(detached.cachedTitle == persistedTitle)
        #expect(detached.restoredPanelTitleBoundary != nil)

        let destinationManager = TabManager()
        let destinationWorkspace = try #require(destinationManager.selectedWorkspace)
        let destinationStore = destinationWorkspace.dockSplit
        defer {
            destinationStore.closeAllPanels()
            destinationWorkspace.teardownAllPanels()
        }
        let destinationPane = try #require(
            destinationStore.bonsplitController.allPaneIds.first
        )
        #expect(
            destinationStore.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            ) == panelID
        )
        let destinationTabID = try #require(
            destinationStore.surfaceId(forPanelId: panelID)
        )
        #expect(
            destinationStore.bonsplitController.tab(destinationTabID)?.title
                == persistedTitle
        )

        destinationStore.updatePanelShellActivityState(
            panelId: panelID,
            state: .promptIdle
        )
        destinationStore.updatePanelShellActivityState(
            panelId: panelID,
            state: .commandRunning
        )
        destinationStore.flushPendingTerminalTitleUpdates()
        #expect(
            destinationStore.bonsplitController.tab(destinationTabID)?.title
                == persistedTitle
        )

        let commandTitle = "codex · restored Dock"
        NotificationCenter.default.post(
            name: .ghosttyDidSetTitle,
            object: nil,
            userInfo: GhosttyTitleChange(
                tabId: destinationStore.workspaceId,
                surfaceId: panelID,
                title: commandTitle,
                sourceSurfaceIdentifier: ObjectIdentifier(terminal.surface)
            ).userInfo
        )
        destinationStore.flushPendingTerminalTitleUpdates()
        #expect(terminal.displayTitle == commandTitle)
        #expect(
            destinationStore.bonsplitController.tab(destinationTabID)?.title
                == commandTitle
        )
    }

    @Test("Idle Dock snapshot trusts live shell state over Ghostty close fallback")
    @MainActor
    func idleSnapshotTrustsLiveShellStateOverGhosttyCloseFallback() throws {
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { "/tmp" }
        )
        defer { store.closeAllPanels() }

        let paneID = try #require(store.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            store.newSurface(
                kind: .terminal,
                inPane: paneID,
                workingDirectory: "/tmp",
                focus: false
            )
        )
        let terminal = try #require(
            store.panels[panelID] as? TerminalPanel
        )
        #expect(terminal.shellActivity.state == .promptIdle)

        terminal.surface.setNeedsConfirmCloseOverrideForTesting(true)
        defer {
            terminal.surface.setNeedsConfirmCloseOverrideForTesting(nil)
        }
        let fallbackScrollback = "persisted idle Dock output"
        store.restoredTerminalScrollbackByPanelId[panelID] = fallbackScrollback

        let snapshot = store.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(
            snapshot.panels.first { $0.id == panelID }
        )

        #expect(panelSnapshot.terminal?.scrollback == fallbackScrollback)
    }

    @Test("Tokenless queued shell report stays bound to its admitted lifecycle")
    @MainActor
    func tokenlessQueuedShellReportRejectsLifecycleReplacement() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let controller = TerminalController.shared
        let previousManager = controller
            .activeTabManagerForCallerNotification()
        controller.setActiveTabManager(manager)
        let mutationBus = TerminalMutationBus.shared
        mutationBus.setDrainsSuspendedForTesting(true)
        defer {
            mutationBus.drainForTesting()
            mutationBus.setDrainsSuspendedForTesting(false)
            controller.setActiveTabManager(previousManager)
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let workspace = try #require(manager.selectedWorkspace)
        let terminal = try #require(workspace.focusedTerminalPanel)
        let panelID = terminal.id
        let originalState = terminal.shellActivity.state
        let originalLifecycleID = terminal.surface.terminalLifecycleId
        controller.socketFastPathState.removeShellActivity(panelIds: [panelID])
        defer {
            controller.socketFastPathState.removeShellActivity(panelIds: [panelID])
        }

        #expect(controller.controlScheduleScopedShellActivityState(
            scope: ControlSidebarPanelScope(
                workspaceID: workspace.id,
                panelID: panelID,
                terminalLifecycleID: nil
            ),
            stateRawValue: PanelShellActivityState.commandRunning.rawValue
        ))

        #expect(terminal.surface.suspendRuntimeSurfaceForAgentHibernation(
            reason: "test.tokenlessQueuedShellReport"
        ))
        #expect(terminal.surface.terminalLifecycleId != originalLifecycleID)

        mutationBus.drainForTesting()

        #expect(terminal.shellActivity.state == originalState)
    }

    @Test("Reopened Dock terminal accepts the replacement shell's initial prompt")
    @MainActor
    func reopenedTerminalAcceptsReplacementShellInitialPrompt() throws {
        let workspaceID = UUID()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let store = manager.makeWindowDockStore(
            windowId: workspaceID
        )
        let history = store.closedItemHistoryStore
        let controller = TerminalController.shared
        let previousManager = controller
            .activeTabManagerForCallerNotification()
        controller.setActiveTabManager(manager)
        defer {
            controller.setActiveTabManager(previousManager)
            store.closeAllPanels()
            manager.tabs.forEach { $0.teardownAllPanels() }
        }

        let paneID = try #require(store.bonsplitController.allPaneIds.first)
        let panelID = try #require(
            store.newSurface(
                kind: .terminal,
                inPane: paneID,
                workingDirectory: "/tmp",
                focus: false
            )
        )
        let originalTerminal = try #require(
            store.panels[panelID] as? TerminalPanel
        )
        let originalLifecycleID = originalTerminal.surface.terminalLifecycleId
        controller.socketFastPathState.removeShellActivity(panelIds: [panelID])
        defer {
            controller.socketFastPathState.removeShellActivity(panelIds: [panelID])
        }

        controller.controlSidebarScheduleScopedShellState(
            scope: ControlSidebarPanelScope(
                workspaceID: workspaceID,
                panelID: panelID,
                terminalLifecycleID: originalLifecycleID
            ),
            stateRawValue: PanelShellActivityState.promptIdle.rawValue
        )
        TerminalMutationBus.shared.drainForTesting()
        #expect(originalTerminal.shellActivity.state == .promptIdle)

        let titleAtClose = "codex · closing Dock"
        #expect(store.applyTerminalTitleChange(GhosttyTitleChange(
            tabId: workspaceID,
            surfaceId: panelID,
            title: titleAtClose,
            sourceSurfaceIdentifier: ObjectIdentifier(originalTerminal.surface)
        )))

        #expect(store.closePanel(panelID))
        #expect(history.canReopen)
        #expect(store.reopenMostRecentlyClosedPanel())

        let restoredPanelID = try #require(store.panels.keys.first)
        try #require(restoredPanelID == panelID)
        let restoredTerminal = try #require(
            store.panels[restoredPanelID] as? TerminalPanel
        )
        let restoredTabID = try #require(
            store.surfaceId(forPanelId: restoredPanelID)
        )
        #expect(
            store.bonsplitController.tab(restoredTabID)?.title == titleAtClose
        )
        let replacementLifecycleID = restoredTerminal.surface.terminalLifecycleId
        #expect(replacementLifecycleID != originalLifecycleID)

        // This report came from the process that owned the persisted panel ID
        // before close. Admission must reject it before it can occupy the
        // replacement surface's queue slot.
        #expect(!controller.controlScheduleScopedShellActivityState(
            scope: ControlSidebarPanelScope(
                workspaceID: workspaceID,
                panelID: restoredPanelID,
                terminalLifecycleID: originalLifecycleID
            ),
            stateRawValue: PanelShellActivityState.commandRunning.rawValue
        ))
        TerminalMutationBus.shared.drainForTesting()
        #expect(restoredTerminal.shellActivity.state == .promptIdle)

        let runningTitle = "codex · reopened Dock"
        #expect(store.applyTerminalTitleChange(GhosttyTitleChange(
            tabId: workspaceID,
            surfaceId: restoredPanelID,
            title: runningTitle,
            sourceSurfaceIdentifier: ObjectIdentifier(restoredTerminal.surface)
        )))
        store.flushPendingTerminalTitleUpdates()
        #expect(restoredTerminal.displayTitle != runningTitle)

        controller.controlSidebarScheduleScopedShellState(
            scope: ControlSidebarPanelScope(
                workspaceID: workspaceID,
                panelID: restoredPanelID,
                terminalLifecycleID: replacementLifecycleID
            ),
            stateRawValue: PanelShellActivityState.promptIdle.rawValue
        )
        TerminalMutationBus.shared.drainForTesting()
        store.flushPendingTerminalTitleUpdates()
        #expect(restoredTerminal.shellActivity.state == .promptIdle)
        #expect(restoredTerminal.displayTitle != runningTitle)

        controller.controlSidebarScheduleScopedShellState(
            scope: ControlSidebarPanelScope(
                workspaceID: workspaceID,
                panelID: restoredPanelID,
                terminalLifecycleID: replacementLifecycleID
            ),
            stateRawValue: PanelShellActivityState.commandRunning.rawValue
        )
        TerminalMutationBus.shared.drainForTesting()

        #expect(restoredTerminal.displayTitle == runningTitle)
        #expect(
            store.bonsplitController.tab(restoredTabID)?.title == runningTitle
        )
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

    @Test("Window Dock unread survives a session snapshot and direct restore")
    @MainActor
    func windowDockUnreadSurvivesSessionRestore() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            let notificationStore = TerminalNotificationStore.shared
            let sourceWindowID = UUID()
            let restoredWindowID = UUID()
            let sourceDock = DockSplitStore(
                workspaceId: sourceWindowID,
                scope: .global,
                baseDirectoryProvider: { nil }
            )
            let restoredDock = DockSplitStore(
                workspaceId: restoredWindowID,
                scope: .global,
                baseDirectoryProvider: { nil }
            )
            sourceDock.notificationStore = notificationStore
            restoredDock.notificationStore = notificationStore
            AppDelegate.shared = appDelegate
            defer {
                sourceDock.closeAllPanels()
                restoredDock.closeAllPanels()
                notificationStore.markRead(forTabId: sourceWindowID)
                notificationStore.markRead(forTabId: restoredWindowID)
                AppDelegate.shared = previousAppDelegate
            }

            let sourcePane = try #require(
                sourceDock.bonsplitController.allPaneIds.first
            )
            let sourcePanelID = try #require(sourceDock.newSurface(
                kind: .terminal,
                inPane: sourcePane,
                focus: false
            ))
            notificationStore.markWindowDockSurfaceUnread(
                windowId: sourceWindowID,
                surfaceId: sourcePanelID
            )

            let snapshot = sourceDock.sessionSnapshot(includeScrollback: false)
            let persistedPanel = try #require(
                snapshot.panels.first { $0.id == sourcePanelID }
            )
            #expect(persistedPanel.isManuallyUnread)

            let restoredPanelIDs = restoredDock.restoreSessionSnapshot(snapshot)
            let restoredPanelID = try #require(restoredPanelIDs[sourcePanelID])
            #expect(notificationStore.hasManualUnread(
                forTabId: restoredWindowID,
                surfaceId: restoredPanelID
            ))

            let restoredSnapshot = restoredDock.sessionSnapshot(
                includeScrollback: false
            )
            #expect(restoredSnapshot.panels.first {
                $0.id == restoredPanelID
            }?.isManuallyUnread == true)
        }
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

    private func codexProcessDetectedResumeBinding(
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
            source: "process-detected",
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
