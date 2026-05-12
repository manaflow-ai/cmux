import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PiVaultAgentPersistenceTests: XCTestCase {
    func testRegisteredSessionAgentCodablePreservesPresentation() throws {
        let encoded = try JSONEncoder().encode(
            SessionAgent.registered(RegisteredSessionAgent(
                id: "acme-agent",
                name: "Acme Agent",
                iconAssetName: "AgentIcons/Acme"
            ))
        )

        let decoded = try JSONDecoder().decode(SessionAgent.self, from: encoded)

        guard case .registered(let agent) = decoded else {
            return XCTFail("Expected registered agent")
        }
        XCTAssertEqual(agent.id, "acme-agent")
        XCTAssertEqual(agent.name, "Acme Agent")
        XCTAssertEqual(agent.iconAssetName, "AgentIcons/Acme")
    }

    func testRegisteredSessionAgentEqualityIncludesPresentation() {
        XCTAssertNotEqual(
            SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", name: "Acme Agent")),
            SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", name: "Renamed Agent"))
        )
        XCTAssertEqual(
            Set([
                SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", iconAssetName: "AgentIcons/Acme")),
                SessionAgent.registered(RegisteredSessionAgent(id: "acme-agent", iconAssetName: "AgentIcons/Renamed")),
            ]).count,
            2
        )
    }

    func testRegisteredAgentTemplateFailsClosedWhenPlaceholderIsUnavailable() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: nil,
            registrationOverride: registration
        )

        XCTAssertNil(command)
    }

    func testRegisteredAgentTemplateUsesExplicitWorkingDirectoryForCWDPlaceholder() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'")
    }

    func testRegisteredAgentTemplateDoesNotExpandPlaceholdersInsideReplacementValues() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}} --cwd {{cwd}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-{{cwd}}",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--session' 'session-{{cwd}}' '--cwd' '/tmp/acme'")
    }

    func testRegisteredAgentCWDIgnoreSuppressesResumeWorkingDirectory() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .ignore
        )
        let entry = SessionEntry(
            id: "acme-agent:session-123",
            agent: .registered(RegisteredSessionAgent(registration: registration)),
            sessionId: "session-123",
            title: "Acme",
            cwd: "/tmp/acme",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1),
            fileURL: nil,
            specifics: .registered(registration)
        )

        XCTAssertNil(entry.resumeWorkingDirectory)
        XCTAssertEqual(entry.resumeCommand, "'acme-agent' '--session' 'session-123'")
    }

    func testRegisteredAgentJSONLNativeSessionIDOverridesPathFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-native-id-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"sessionId":"native-session-123","cwd":"/tmp/acme","title":"Resume Acme"}
        {"gitBranch":"issue-3575-vault-pi-agent-support"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "acme-agent:native-session-123")
        XCTAssertEqual(entry.sessionId, "native-session-123")
        XCTAssertEqual(entry.title, "Resume Acme")
        XCTAssertEqual(entry.gitBranch, "issue-3575-vault-pi-agent-support")
    }

    func testRegisteredAgentCWDFilterUsesJSONLMetadataNotFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-registered-cwd-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionFile = tempDir.appendingPathComponent("metadata.jsonl")
        try """
        {"sessionId":"native-session-123","cwd":"/tmp/other","title":"Resume Acme"}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve,
            sessionDirectory: tempDir.path
        )

        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: "/tmp/acme",
            offset: 0,
            limit: 10
        )

        XCTAssertTrue(entries.isEmpty)
    }

    func testRegisteredAgentMetadataKeepsScanningForBranchWhenFallbackCWDSet() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cwd = "/tmp/pi repo"
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd))
        let sessionDir = tempDir.appendingPathComponent(projectDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let sessionFile = sessionDir.appendingPathComponent("018f2b35-7c75-7e1a-a6ff-cc1d5f9f0000.jsonl")
        try """
        {"message":{"content":"Implement Pi restore"}}
        {"git":{"branch":"issue-3575-vault-pi-agent-support"}}
        """.write(to: sessionFile, atomically: true, encoding: .utf8)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = tempDir.path
        let entries = await SessionIndexStore.loadRegisteredAgentEntries(
            registration: registration,
            needle: "",
            cwdFilter: cwd,
            offset: 0,
            limit: 10
        )

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.title, "Implement Pi restore")
        XCTAssertEqual(entry.cwd, cwd)
        XCTAssertEqual(entry.gitBranch, "issue-3575-vault-pi-agent-support")
    }

    func testPiVaultAgentSnapshotRoundTripBuildsTargetedSessionCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionPath = tempDir
            .appendingPathComponent("--tmp-pi repo--", isDirectory: true)
            .appendingPathComponent("2026-05-05T12-00-00-000Z_018f2b35-7c75-7e1a-a6ff-cc1d5f9f0000.jsonl")
            .path
        let panelId = UUID(uuidString: "3D4D5F4B-CA09-4E5C-A65E-8423D7F4BEA0")!
        let piKind = try XCTUnwrap(RestorableAgentKind(rawValue: "pi"))

        var snapshot = makeSnapshot()
        snapshot.windows[0].tabManager.workspaces[0].focusedPanelId = panelId
        snapshot.windows[0].tabManager.workspaces[0].layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)
        )
        snapshot.windows[0].tabManager.workspaces[0].panels = [
            SessionPanelSnapshot(
                id: panelId,
                type: .terminal,
                title: "Pi",
                customTitle: nil,
                directory: "/tmp/pi repo",
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: "ttys001",
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: "/tmp/pi repo",
                    scrollback: nil,
                    agent: SessionRestorableAgentSnapshot(
                        kind: piKind,
                        sessionId: sessionPath,
                        workingDirectory: "/tmp/pi repo",
                        launchCommand: AgentLaunchCommandSnapshot(
                            launcher: "pi",
                            executablePath: "/opt/homebrew/bin/pi",
                            arguments: ["/opt/homebrew/bin/pi", "--session-dir", tempDir.path, "--session", "old-session", "--continue"],
                            workingDirectory: "/tmp/pi repo",
                            environment: ["PI_CODING_AGENT_SESSION_DIR": tempDir.path],
                            capturedAt: 1_777_777_777,
                            source: "process"
                        ),
                        registration: CmuxVaultAgentRegistration.builtInPi
                    ),
                    tmuxStartCommand: nil
                ),
                browser: nil,
                markdown: nil,
                filePreview: nil
            )
        ]

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let loadedAgent = try XCTUnwrap(
            SessionPersistenceStore.load(fileURL: snapshotURL)?.windows.first?
                .tabManager.workspaces.first?.panels.first?.terminal?.agent
        )

        XCTAssertEqual(loadedAgent.kind.rawValue, "pi")
        XCTAssertEqual(loadedAgent.sessionId, sessionPath)
        XCTAssertEqual(
            loadedAgent.resumeCommand,
            "cd '/tmp/pi repo' && '/opt/homebrew/bin/pi' '--session' '\(sessionPath)'"
        )
    }

    private func makeSnapshot() -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
                )
            ]
        )
    }
}
