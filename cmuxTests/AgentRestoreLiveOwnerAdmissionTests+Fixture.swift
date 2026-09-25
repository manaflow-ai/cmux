import CmuxFoundation
import CMUXAgentLaunch
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension AgentRestoreLiveOwnerAdmissionTests {
    struct Fixture {
        let root: URL
        let hookStateDirectory: URL
        let hookEnvironment: [String: String]
        let defaults: UserDefaults
        let defaultsName: String
        let kind: RestorableAgentKind
        let sessionID: String
        let executable: String
        let processID: Int
        let ownerProcess: Process?
        let ownerWorkspaceID: UUID
        let ownerSurfaceID: UUID
        let agent: SessionRestorableAgentSnapshot
        let loadIndex: @Sendable () -> RestorableAgentSessionIndex
        var index: RestorableAgentSessionIndex

        var storeURL: URL {
            kind.hookStoreFileURL(homeDirectory: root.path, environment: hookEnvironment)
        }

        /// Rewrites this session's hook record the way a later instance of the
        /// agent would: same thread, a new PID generation, and the argv that
        /// launch was captured with.
        func writeOwnerRecord(processID: Int, launchArguments: [String]) throws {
            try AgentRestoreLiveOwnerAdmissionTests.writeOwnerStore(
                at: storeURL,
                kind: kind,
                sessionID: sessionID,
                workspaceID: ownerWorkspaceID,
                surfaceID: ownerSurfaceID,
                processID: processID,
                processIdentity: AgentPIDProcessIdentity(
                    pid: pid_t(processID),
                    startSeconds: 110,
                    startMicroseconds: 43
                ),
                executable: executable,
                launchArguments: launchArguments,
                workingDirectory: agent.workingDirectory ?? root.path
            )
        }

        mutating func reloadIndex() {
            index = loadIndex()
        }

        @MainActor
        func cleanup() {
            if let ownerProcess, ownerProcess.isRunning {
                ownerProcess.terminate()
                ownerProcess.waitUntilExit()
            }
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: agent.kind.rawValue,
                sessionId: sessionID
            )
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func makeFixture(
        kind: RestorableAgentKind = .grok,
        ownerState: OwnerState,
        launchOptions: [String] = [],
        launchSessionArguments: [String]? = nil,
        scopedProcess: Bool = false,
        corruptStoreKinds: Set<RestorableAgentKind> = []
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-issue-11043-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsName = "cmux-issue-11043-\(UUID().uuidString)"
        let defaults: UserDefaults
        do {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        var fixtureCreated = false
        var ownerProcessForCleanup: Process?
        defer {
            if !fixtureCreated {
                if let ownerProcessForCleanup, ownerProcessForCleanup.isRunning {
                    ownerProcessForCleanup.terminate()
                    ownerProcessForCleanup.waitUntilExit()
                }
                defaults.removePersistentDomain(forName: defaultsName)
                try? FileManager.default.removeItem(at: root)
            }
        }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let sessionID: String
        let sessionArguments: [String]
        switch kind {
        case .amp:
            // Amp threads are `T-` identifiers that never appear in the argv
            // of a freshly started process; the hook store carries them.
            sessionID = "T-" + UUID().uuidString.lowercased()
            sessionArguments = []
        default:
            sessionID = UUID().uuidString.lowercased()
            sessionArguments = ["--session-id", sessionID]
        }
        let executable = "/usr/local/bin/\(kind.rawValue)"
        let launchArguments = [executable] + launchOptions + (launchSessionArguments ?? sessionArguments)
        let ownerProcess: Process?
        let processID: Int
        if ownerState == .live || ownerState == .staleGeneration {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["60"]
            try process.run()
            ownerProcess = process
            ownerProcessForCleanup = process
            processID = Int(process.processIdentifier)
        } else {
            ownerProcess = nil
            processID = Int(Int32.max) - 11_043
        }
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let agent = SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: sessionID,
            workingDirectory: workingDirectory.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: kind.rawValue,
                executablePath: executable,
                arguments: launchArguments,
                workingDirectory: workingDirectory.path,
                capturedAt: 1_800_110_043,
                source: "test"
            )
        )
        let ownerWorkspaceID = UUID()
        let ownerSurfaceID = UUID()
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let hookEnvironment = ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]
        try FileManager.default.createDirectory(at: hookStateDirectory, withIntermediateDirectories: true)
        let recordedIdentity: AgentPIDProcessIdentity
        if ownerState == .dead || ownerState == .absent {
            recordedIdentity = AgentPIDProcessIdentity(
                pid: pid_t(processID),
                startSeconds: 110,
                startMicroseconds: 43
            )
        } else {
            recordedIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(processID)))
        }
        if ownerState != .absent {
            try Self.writeOwnerStore(
                at: kind.hookStoreFileURL(homeDirectory: root.path, environment: hookEnvironment),
                kind: kind,
                sessionID: sessionID,
                workspaceID: ownerWorkspaceID,
                surfaceID: ownerSurfaceID,
                processID: processID,
                processIdentity: recordedIdentity,
                executable: executable,
                launchArguments: launchArguments,
                workingDirectory: workingDirectory.path
            )
        }
        for corruptKind in corruptStoreKinds {
            try Data("{".utf8).write(
                to: corruptKind.hookStoreFileURL(homeDirectory: root.path, environment: hookEnvironment),
                options: .atomic
            )
        }
        let currentIdentity: AgentPIDProcessIdentity? = switch ownerState {
        case .live:
            recordedIdentity
        case .staleGeneration:
            AgentPIDProcessIdentity(
                pid: pid_t(processID),
                startSeconds: recordedIdentity.startSeconds + 1,
                startMicroseconds: recordedIdentity.startMicroseconds
            )
        case .absent, .dead:
            nil
        }
        let rootPath = root.path
        let loadIndex: @Sendable () -> RestorableAgentSessionIndex = {
            RestorableAgentSessionIndex.load(
                homeDirectory: rootPath,
                fileManager: .default,
                registry: CmuxVaultAgentRegistry(registrations: [.builtInGrok, .builtInAmp, .builtInPi]),
                detectedSnapshots: [:],
                environment: hookEnvironment,
                processArgumentsProvider: { candidatePID in
                    guard candidatePID == processID else { return nil }
                    // Deliberately no CMUX_WORKSPACE_ID / CMUX_SURFACE_ID: this is
                    // the nohup/setsid/daemonized shape from #11043.
                    return CmuxTopProcessArguments(
                        arguments: launchArguments,
                        environment: scopedProcess ? [
                            "CMUX_WORKSPACE_ID": ownerWorkspaceID.uuidString,
                            "CMUX_SURFACE_ID": ownerSurfaceID.uuidString,
                        ] : [:]
                    )
                },
                processPresenceProvider: { candidatePID in
                    candidatePID == processID && ownerState != .dead ? .present : .absent
                },
                processIdentityProvider: { candidatePID in
                    candidatePID == processID ? currentIdentity : nil
                }
            )
        }
        fixtureCreated = true
        return Fixture(
            root: root,
            hookStateDirectory: hookStateDirectory,
            hookEnvironment: hookEnvironment,
            defaults: defaults,
            defaultsName: defaultsName,
            kind: kind,
            sessionID: sessionID,
            executable: executable,
            processID: processID,
            ownerProcess: ownerProcess,
            ownerWorkspaceID: ownerWorkspaceID,
            ownerSurfaceID: ownerSurfaceID,
            agent: agent,
            loadIndex: loadIndex,
            index: loadIndex()
        )
    }

    nonisolated private static func writeOwnerStore(
        at storeURL: URL,
        kind: RestorableAgentKind,
        sessionID: String,
        workspaceID: UUID,
        surfaceID: UUID,
        processID: Int,
        processIdentity: AgentPIDProcessIdentity,
        executable: String,
        launchArguments: [String],
        workingDirectory: String
    ) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let transcriptPath = URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent("\(sessionID).jsonl").path
        if kind == .claude {
            try Data("{\"type\":\"user\"}\n".utf8).write(to: URL(fileURLWithPath: transcriptPath))
        }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                sessionID: [
                    "sessionId": sessionID,
                    "workspaceId": workspaceID.uuidString,
                    "surfaceId": surfaceID.uuidString,
                    "pid": processID,
                    "pidStartSeconds": processIdentity.startSeconds,
                    "pidStartMicroseconds": processIdentity.startMicroseconds,
                    "cwd": workingDirectory,
                    "isRestorable": true,
                    "transcriptPath": transcriptPath,
                    "updatedAt": 1_800_110_043,
                    "launchCommand": [
                        "launcher": kind.rawValue,
                        "executablePath": executable,
                        "arguments": launchArguments,
                        "workingDirectory": workingDirectory,
                        "capturedAt": 1_800_110_043,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: storeURL, options: .atomic)
    }

    func restoredStartupInput(_ fixture: Fixture) throws -> String {
        let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        snapshot.panels[panelIndex].terminal?.agent = fixture.agent
        snapshot.panels[panelIndex].terminal?.wasAgentRunning = true

        let index = fixture.index
        let restored = Workspace(
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { index }
        )
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredIDs[sourcePanelID])
        let terminal = try #require(restored.terminalPanel(for: restoredPanelID))
        return try #require(terminal.surface.debugInitialInputForTesting())
    }
}
