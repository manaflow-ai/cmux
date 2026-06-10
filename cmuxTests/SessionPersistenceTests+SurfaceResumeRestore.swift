import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Restore-time surface resume binding behavior
extension SessionPersistenceTests {
    @MainActor
    func testRestoreRunsSurfaceResumeBindingFromBindingCwd() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        source.panelDirectories[sourcePanelId] = "/tmp/old"
        let bindingCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-binding-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bindingCwd, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: bindingCwd)
        }
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "script",
                kind: "custom",
                command: "./resume.sh",
                cwd: bindingCwd.path,
                checkpointId: "script",
                source: "process-detected",
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertEqual(restoredPanel.requestedWorkingDirectory, bindingCwd.path)
        XCTAssertTrue(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    @MainActor
    func testRestoreDoesNotPassDeletedAgentHookCwdToTerminalRuntime() throws {
        try withAutoResumeAgentSessionsEnabled {
            let source = Workspace()
            let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
            let missingCwd = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-deleted-agent-hook-cwd-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("repo", isDirectory: true)
            let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                    name: "Codex",
                    kind: "codex",
                    command: "cd '\(missingCwd.path)' && codex resume session-duplicate-turn --yolo",
                    cwd: missingCwd.path,
                    checkpointId: "session-duplicate-turn",
                    source: "agent-hook",
                    environment: [
                        "CLAUDE_CONFIG_DIR": "/tmp/claude-profile"
                    ],
                    autoResume: true,
                    updatedAt: 10
                ),
            ])
            let snapshot = source.sessionSnapshot(
                includeScrollback: false,
                surfaceResumeBindingIndex: bindingIndex
            )

            let restored = Workspace()
            restored.restoreSessionSnapshot(snapshot)
            let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
            let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
            let startupPayload = try restoredStartupPayload(for: restoredPanel)

            XCTAssertNil(restoredPanel.requestedWorkingDirectory)
            XCTAssertTrue(startupPayload.contains("codex resume session-duplicate-turn --yolo"), startupPayload)
            let guardStart = try XCTUnwrap(startupPayload.range(of: "{ cd -- "), startupPayload)
            let guardSuffix = String(startupPayload[guardStart.lowerBound...])
            let guardEnd = try XCTUnwrap(guardSuffix.range(of: "]; } &&")?.upperBound, guardSuffix)
            let guardSnippet = String(guardSuffix[..<guardEnd])
            XCTAssertTrue(guardSnippet.contains(missingCwd.path), guardSnippet)
            XCTAssertTrue(guardSnippet.contains("2>/dev/null || [ ! -d"), guardSnippet)
        }
    }

    @MainActor
    func testRestorePreservesUnmountedVolumeCwdBindingsWhenInitialReportsAreScrambled() throws {
        try withAutoResumeAgentSessionsEnabled {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let volumeName = "cmux-issue-5278-\(UUID().uuidString)"
            let expectedCwdsByWorkspaceAndPanel = try makeUnmountedVolumeCwdSnapshot(
                manager: manager,
                volumeName: volumeName
            )
            let snapshotData = try JSONEncoder().encode(manager.sessionSnapshot(includeScrollback: false))
            let decodedSnapshot = try JSONDecoder().decode(SessionTabManagerSnapshot.self, from: snapshotData)
            let restored = TabManager(autoWelcomeIfNeeded: false)

            restored.restoreSessionSnapshot(decodedSnapshot)
            let allExpectedCwds = expectedCwdsByWorkspaceAndPanel
                .values
                .flatMap { $0.values }
                .sorted()
            let rotatedExpectedCwds = Array(allExpectedCwds.dropFirst()) + [allExpectedCwds[0]]
            let scrambledCwds = Dictionary(uniqueKeysWithValues: zip(allExpectedCwds, rotatedExpectedCwds))
            for workspace in restored.tabs {
                let workspaceTitle = try XCTUnwrap(workspace.customTitle)
                let expectedPanelCwds = try XCTUnwrap(expectedCwdsByWorkspaceAndPanel[workspaceTitle])
                for (panelId, panelTitle) in workspace.panelCustomTitles {
                    let expectedCwd = try XCTUnwrap(expectedPanelCwds[panelTitle])
                    let scrambledCwd = try XCTUnwrap(scrambledCwds[expectedCwd])
                    restored.updateSurfaceDirectory(
                        tabId: workspace.id,
                        surfaceId: panelId,
                        directory: scrambledCwd
                    )
                }
            }

            let postReportSnapshot = restored.sessionSnapshot(includeScrollback: false)
            for workspaceSnapshot in postReportSnapshot.workspaces {
                let workspaceTitle = try XCTUnwrap(workspaceSnapshot.customTitle)
                let expectedPanelCwds = try XCTUnwrap(expectedCwdsByWorkspaceAndPanel[workspaceTitle])
                for panelSnapshot in workspaceSnapshot.panels {
                    let panelTitle = try XCTUnwrap(panelSnapshot.customTitle)
                    let expectedCwd = try XCTUnwrap(expectedPanelCwds[panelTitle])
                    XCTAssertEqual(panelSnapshot.directory, expectedCwd, "\(workspaceTitle) / \(panelTitle)")
                    XCTAssertEqual(panelSnapshot.terminal?.workingDirectory, expectedCwd, "\(workspaceTitle) / \(panelTitle)")
                    XCTAssertEqual(panelSnapshot.terminal?.resumeBinding?.cwd, expectedCwd, "\(workspaceTitle) / \(panelTitle)")
                }
            }
        }
    }

    @MainActor
    private func withAutoResumeAgentSessionsEnabled<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let key = AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }

    @MainActor
    private func restoredStartupPayload(for panel: TerminalPanel) throws -> String {
        if let input = panel.surface.debugInitialInputForTesting() {
            return input
        }

        let command = try XCTUnwrap(panel.surface.debugInitialCommand())
        let launcherPrefix = "/bin/zsh '"
        guard command.hasPrefix(launcherPrefix), command.hasSuffix("'") else {
            return try XCTUnwrap(
                Optional<String>.none,
                "Unexpected restored startup command format: \(command)"
            )
        }
        let scriptPath = String(command.dropFirst(launcherPrefix.count).dropLast())
        return try String(contentsOfFile: scriptPath, encoding: .utf8)
    }

    @MainActor
    private func makeUnmountedVolumeCwdSnapshot(
        manager: TabManager,
        volumeName: String
    ) throws -> [String: [String: String]] {
        let workspaces = [
            try XCTUnwrap(manager.selectedWorkspace),
            manager.addWorkspace(inheritWorkingDirectory: false, select: true, autoWelcomeIfNeeded: false),
            manager.addWorkspace(inheritWorkingDirectory: false, select: true, autoWelcomeIfNeeded: false),
        ]
        var expected: [String: [String: String]] = [:]

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let workspaceTitle = "Project \(workspaceIndex + 1)"
            workspace.setCustomTitle(workspaceTitle)
            let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
            let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
            let secondPanelId = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: true)?.id)
            for (panelIndex, panelId) in [firstPanelId, secondPanelId].enumerated() {
                let panelTitle = "Tab \(workspaceIndex + 1).\(panelIndex + 1)"
                let cwd = "/Volumes/\(volumeName)/project-\(workspaceIndex + 1)/tab-\(panelIndex + 1)"
                workspace.setPanelCustomTitle(panelId: panelId, title: panelTitle)
                workspace.updatePanelDirectory(panelId: panelId, directory: cwd)
                XCTAssertTrue(
                    workspace.setSurfaceResumeBinding(
                        SurfaceResumeBindingSnapshot(
                            name: "Codex",
                            kind: "codex",
                            command: "cd '\(cwd)' && codex resume session-\(workspaceIndex)-\(panelIndex) --yolo",
                            cwd: cwd,
                            checkpointId: "session-\(workspaceIndex)-\(panelIndex)",
                            source: "agent-hook",
                            autoResume: true,
                            updatedAt: 10 + Double(workspaceIndex * 10 + panelIndex)
                        ),
                        panelId: panelId
                    )
                )
                expected[workspaceTitle, default: [:]][panelTitle] = cwd
            }
        }

        return expected
    }

    @MainActor
    func testRestoreDoesNotRunResumeBindingForHibernatedSnapshot() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let sourcePanel = try XCTUnwrap(source.terminalPanel(for: sourcePanelId))
        let sourcePaneId = try XCTUnwrap(source.paneId(forPanelId: sourcePanelId))
        _ = try XCTUnwrap(source.newTerminalSurface(inPane: sourcePaneId, focus: true))
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-hibernated-restore",
            workingDirectory: "/tmp/agent",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/usr/local/bin/codex",
                arguments: ["/usr/local/bin/codex"],
                workingDirectory: "/tmp/agent",
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        sourcePanel.enterAgentHibernation(
            agent: agent,
            lastActivityAt: Date(timeIntervalSince1970: 10),
            hibernatedAt: Date(timeIntervalSince1970: 20)
        )
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "script",
                kind: "custom",
                command: "./resume.sh",
                cwd: "/tmp/binding",
                checkpointId: "script",
                source: "process-detected",
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let sourcePanelSnapshot = try XCTUnwrap(snapshot.panels.first { $0.id == sourcePanelId })
        XCTAssertNotNil(sourcePanelSnapshot.terminal?.hibernation)
        XCTAssertNotNil(sourcePanelSnapshot.terminal?.agent?.resumeCommand)
        XCTAssertNotEqual(snapshot.focusedPanelId, sourcePanelId)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredSnapshot = restored.sessionSnapshot(includeScrollback: false)
        let restoredPanelSnapshot = try XCTUnwrap(
            restoredSnapshot.panels.first {
                $0.terminal?.resumeBinding?.command == "./resume.sh"
            }
        )
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelSnapshot.id))

        XCTAssertFalse(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        XCTAssertEqual(restoredPanelSnapshot.terminal?.agent?.sessionId, "codex-hibernated-restore")
    }

    @MainActor
    func testRestoreDoesNotRunUntrustedSurfaceResumeBindingByDefault() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "script",
                kind: "custom",
                command: "./resume.sh",
                cwd: "/tmp/sticky",
                checkpointId: "script",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertFalse(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        XCTAssertEqual(
            restored.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding?.command,
            "./resume.sh"
        )
    }

    @MainActor
    func testRestoreScopesSurfaceResumeBindingEnvironmentToInitialInput() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "process-detected",
                environment: [
                    "CODEX_HOME": "/tmp/codex home",
                    "EMPTY": "",
                ],
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertNil(restoredPanel.surface.debugAdditionalEnvironmentForTesting()["CODEX_HOME"])
        XCTAssertNil(restoredPanel.surface.debugAdditionalEnvironmentForTesting()["EMPTY"])
        XCTAssertEqual(
            restoredPanel.surface.debugInitialInputForTesting(),
            "'/usr/bin/env' 'CODEX_HOME=/tmp/codex home' 'EMPTY=' '/bin/zsh' '-lc' 'codex resume session'\n"
        )
    }

    @MainActor
    func testRestoreUsesLauncherScriptForLongSurfaceResumeBinding() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let longPath = "/tmp/" + String(repeating: "nested-project-", count: 120)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume session --add-dir \(longPath)",
                cwd: "/tmp/project",
                checkpointId: "session",
                source: "process-detected",
                environment: [
                    "CODEX_HOME": "/tmp/codex home",
                ],
                autoResume: true,
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))

        XCTAssertNil(restoredPanel.surface.debugAdditionalEnvironmentForTesting()["CODEX_HOME"])
        let input = try XCTUnwrap(restoredPanel.surface.debugInitialInputForTesting())
        XCTAssertTrue(input.hasPrefix("/bin/zsh '"))
        XCTAssertFalse(input.contains(longPath))

        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "/bin/zsh '"
        let scriptPath = String(trimmedInput.dropFirst(prefix.count).dropLast())
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }
        let scriptContents = try String(contentsOfFile: scriptPath, encoding: .utf8)
        XCTAssertTrue(scriptContents.contains(longPath))
        XCTAssertTrue(scriptContents.contains("'CODEX_HOME=/tmp/codex home'"))
        XCTAssertTrue(scriptContents.contains("codex resume session"))
    }

    @MainActor
    func testRestoreRetainsProcessDetectedSurfaceResumeBindingBeforeRedetection() throws {
        let source = Workspace()
        let sourcePanelId = try XCTUnwrap(source.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: source.id, panelId: sourcePanelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t restored",
                cwd: "/tmp/project",
                checkpointId: "restored",
                source: "process-detected",
                updatedAt: 10
            ),
        ])
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let immediateSnapshot = restored.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(immediateSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "restored")
        XCTAssertEqual(immediateSnapshot.panels.first?.terminal?.resumeBinding?.command, "tmux attach -t restored")
    }

    @MainActor
    func testSnapshotDropsStaleProcessDetectedSurfaceResumeBindingAfterCleanRedetection() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t stale",
                    cwd: "/tmp/stale",
                    checkpointId: "stale",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let snapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: .empty
        )

        XCTAssertNil(snapshot.panels.first?.terminal?.resumeBinding)
        XCTAssertNil(workspace.sessionSnapshot(includeScrollback: false).panels.first?.terminal?.resumeBinding)
    }

    @MainActor
    func testSnapshotCachesNewProcessDetectedSurfaceResumeBindingForLaterNoScanSave() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let bindingIndex = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: workspace.id, panelId: panelId): SurfaceResumeBindingSnapshot(
                name: "tmux",
                kind: "tmux",
                command: "tmux attach -t cached",
                cwd: "/tmp/project",
                checkpointId: "cached",
                source: "process-detected",
                updatedAt: 10
            ),
        ])

        let scannedSnapshot = workspace.sessionSnapshot(
            includeScrollback: false,
            surfaceResumeBindingIndex: bindingIndex
        )
        let laterSnapshot = workspace.sessionSnapshot(includeScrollback: false)

        XCTAssertEqual(scannedSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "cached")
        XCTAssertEqual(laterSnapshot.panels.first?.terminal?.resumeBinding?.checkpointId, "cached")
    }

    @MainActor
    func testAppDelegateSnapshotPreservesRestoredProcessDetectedSurfaceResumeBindingBeforeScan() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        AppDelegate.shared = app
        defer {
            AppDelegate.shared = previousAppDelegate
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = app.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: windowId)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertTrue(
            workspace.setSurfaceResumeBinding(
                SurfaceResumeBindingSnapshot(
                    name: "tmux",
                    kind: "tmux",
                    command: "tmux attach -t restored",
                    cwd: "/tmp/project",
                    checkpointId: "restored",
                    source: "process-detected",
                    updatedAt: 10
                ),
                panelId: panelId
            )
        )

        let noScanSnapshot = try XCTUnwrap(app.debugBuildSessionSnapshotForTesting(includeScrollback: false))
        let noScanBinding = noScanSnapshot.windows.first?.tabManager.workspaces.first?.panels
            .first(where: { $0.id == panelId })?
            .terminal?
            .resumeBinding
        XCTAssertEqual(noScanBinding?.checkpointId, "restored")

        let cleanScanSnapshot = try XCTUnwrap(
            app.debugBuildSessionSnapshotForTesting(
                includeScrollback: false,
                surfaceResumeBindingIndex: .empty
            )
        )
        let cleanScanBinding = cleanScanSnapshot.windows.first?.tabManager.workspaces.first?.panels
            .first(where: { $0.id == panelId })?
            .terminal?
            .resumeBinding
        XCTAssertNil(cleanScanBinding)
    }

}
