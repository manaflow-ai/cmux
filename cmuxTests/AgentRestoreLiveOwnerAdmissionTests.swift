import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #11043: restore admission follows the Vault session
/// identity even when the surviving process escaped its original terminal scope.
@MainActor
@Suite("Agent restore live-owner admission", .serialized)
struct AgentRestoreLiveOwnerAdmissionTests {
    enum OwnerState: Equatable, Sendable {
        case absent
        case dead
        case live
        case staleGeneration
    }

    @Test("A live unscoped owner suppresses autoresume and leaves a takeover notice")
    func liveUnscopedOwnerSuppressesAutoresumeWithNotice() throws {
        let fixture = try makeFixture(ownerState: .live)
        defer { fixture.cleanup() }

        let input = try restoredStartupInput(fixture)

        #expect(!input.contains(" restore grok \(fixture.sessionID)"), Comment(rawValue: input))
        #expect(input.contains("already running in process \(fixture.processID)"), Comment(rawValue: input))
        #expect(input.contains("stop process \(fixture.processID)"), Comment(rawValue: input))
        #expect(input.contains("cmux restore --surface"), Comment(rawValue: input))
    }

    @Test(
        "No current owner admits autoresume",
        arguments: [OwnerState.absent, OwnerState.dead, OwnerState.staleGeneration]
    )
    func missingDeadOrStaleOwnerAdmitsAutoresume(ownerState: OwnerState) throws {
        let fixture = try makeFixture(ownerState: ownerState)
        defer { fixture.cleanup() }

        let input = try restoredStartupInput(fixture)

        #expect(
            input.contains(" restore grok \(fixture.sessionID)"),
            "An absent or stale PID generation must not block restore: \(input)"
        )
        #expect(!input.contains("already running in process"), Comment(rawValue: input))
    }

    @Test("A non-ASCII localized notice remains one shell argument")
    func nonASCIINoticePreservesSpaces() throws {
        let message = "日本語 notice with spaces"
        let input = AgentRestoreLiveOwnerNotice(processID: 41_043).startupInput(
            message: message,
            dialect: .posix
        )
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", input]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(process.terminationStatus == 0)
        #expect(output == message + "\n", Comment(rawValue: output))
    }

    @Test("Cached owners are discarded when current process identity evidence changes")
    func cachedOwnerRequiresCurrentProcessEvidence() throws {
        let fixture = try makeFixture(ownerState: .live)
        defer { fixture.cleanup() }

        let revalidated = fixture.index.liveSessionOwners.revalidated(
            processArgumentsProvider: { _ in
                CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/not-grok"],
                    environment: [:]
                )
            },
            processIdentityProvider: { candidatePID in
                candidatePID == fixture.processID
                    ? AgentPIDProcessIdentity(pid: pid_t(candidatePID))
                    : nil
            }
        )

        #expect(
            revalidated.owner(
                kind: fixture.agent.kind.rawValue,
                sessionID: fixture.sessionID,
                revalidateProcessEvidence: false
            ) == nil
        )
        #expect(
            fixture.index.liveSessionOwner(
                kind: fixture.agent.kind.rawValue,
                sessionID: fixture.sessionID,
                processArgumentsProvider: { _ in
                    CmuxTopProcessArguments(
                        arguments: ["/usr/local/bin/not-grok"],
                        environment: [:]
                    )
                },
                processPresenceProvider: { _ in .present }
            ) == nil
        )
    }

    @Test("A reused Claude PID with another session id is not an owner")
    func claudeSessionArgumentMustMatch() {
        let expectedSessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: expectedSessionID,
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/usr/local/bin/claude",
                arguments: ["/usr/local/bin/claude", "--session-id", expectedSessionID],
                workingDirectory: nil,
                capturedAt: nil,
                source: "test"
            )
        )
        let process = CmuxTopProcessArguments(
            arguments: ["/usr/local/bin/claude", "--session-id", "different-session"],
            environment: [:]
        )

        #expect(!CachedAgentProcessIdentityValidator().currentProcess(process, matches: snapshot))
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let defaultsName: String
        let sessionID: String
        let processID: Int
        let ownerProcess: Process?
        let agent: SessionRestorableAgentSnapshot
        let index: RestorableAgentSessionIndex

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

    private func makeFixture(ownerState: OwnerState) throws -> Fixture {
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

        let sessionID = UUID().uuidString.lowercased()
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
            kind: .grok,
            sessionId: sessionID,
            workingDirectory: workingDirectory.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "/usr/local/bin/grok",
                arguments: ["/usr/local/bin/grok", "--session-id", sessionID],
                workingDirectory: workingDirectory.path,
                capturedAt: 1_800_110_043,
                source: "test"
            )
        )
        let index = try liveOwnerIndex(
            root: root,
            agent: agent,
            processID: processID,
            ownerState: ownerState
        )
        fixtureCreated = true
        return Fixture(
            root: root,
            defaults: defaults,
            defaultsName: defaultsName,
            sessionID: sessionID,
            processID: processID,
            ownerProcess: ownerProcess,
            agent: agent,
            index: index
        )
    }

    private func liveOwnerIndex(
        root: URL,
        agent: SessionRestorableAgentSnapshot,
        processID: Int,
        ownerState: OwnerState
    ) throws -> RestorableAgentSessionIndex {
        guard ownerState != .absent else { return .empty }

        let ownerWorkspaceID = UUID()
        let ownerSurfaceID = UUID()
        let stateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let environment = ["CMUX_AGENT_HOOK_STATE_DIR": stateDirectory.path]
        let storeURL = RestorableAgentKind.grok.hookStoreFileURL(
            homeDirectory: root.path,
            environment: environment
        )
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recordedIdentity: AgentPIDProcessIdentity
        if ownerState == .dead {
            recordedIdentity = AgentPIDProcessIdentity(
                pid: pid_t(processID),
                startSeconds: 110,
                startMicroseconds: 43
            )
        } else {
            recordedIdentity = try #require(AgentPIDProcessIdentity(pid: pid_t(processID)))
        }
        let store: [String: Any] = [
            "version": 1,
            "sessions": [
                agent.sessionId: [
                    "sessionId": agent.sessionId,
                    "workspaceId": ownerWorkspaceID.uuidString,
                    "surfaceId": ownerSurfaceID.uuidString,
                    "pid": processID,
                    "pidStartSeconds": recordedIdentity.startSeconds,
                    "pidStartMicroseconds": recordedIdentity.startMicroseconds,
                    "cwd": agent.workingDirectory ?? root.path,
                    "isRestorable": true,
                    "updatedAt": 1_800_110_043,
                    "launchCommand": [
                        "launcher": "grok",
                        "executablePath": "/usr/local/bin/grok",
                        "arguments": ["/usr/local/bin/grok", "--session-id", agent.sessionId],
                        "workingDirectory": agent.workingDirectory ?? root.path,
                        "capturedAt": 1_800_110_043,
                        "source": "test",
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: store, options: [.sortedKeys])
            .write(to: storeURL, options: .atomic)

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
        return RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: [.builtInGrok]),
            detectedSnapshots: [:],
            environment: environment,
            processArgumentsProvider: { candidatePID in
                guard candidatePID == processID else { return nil }
                // Deliberately no CMUX_WORKSPACE_ID / CMUX_SURFACE_ID: this is
                // the nohup/setsid/daemonized shape from #11043.
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/grok", "--session-id", agent.sessionId],
                    environment: [:]
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

    private func restoredStartupInput(_ fixture: Fixture) throws -> String {
        let source = Workspace(agentSessionAutoResumeDefaults: fixture.defaults)
        defer { source.teardownAllPanels() }
        let sourcePanelID = try #require(source.focusedPanelId)
        var snapshot = source.sessionSnapshot(includeScrollback: false)
        let panelIndex = try #require(snapshot.panels.firstIndex { $0.id == sourcePanelID })
        snapshot.panels[panelIndex].terminal?.agent = fixture.agent
        snapshot.panels[panelIndex].terminal?.wasAgentRunning = true

        let restored = Workspace(
            agentSessionAutoResumeDefaults: fixture.defaults,
            restorableAgentIndexProvider: { fixture.index }
        )
        defer { restored.teardownAllPanels() }
        let restoredIDs = restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restoredIDs[sourcePanelID])
        let terminal = try #require(restored.terminalPanel(for: restoredPanelID))
        return try #require(terminal.surface.debugInitialInputForTesting())
    }
}
