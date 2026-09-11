import CMUXAgentLaunch
import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #11043: restore admission follows the Vault session
/// identity even when the surviving process escaped its original terminal scope.
///
/// Also covers #12158: admission must stay decidable while other agents keep
/// rewriting the shared hook-store directory, must not be blocked by an
/// unreadable store of an unrelated agent kind, and must admit the same Amp
/// thread across chained quit/restore cycles with one thread positional.
@MainActor
@Suite("Agent restore live-owner admission", .serialized)
struct AgentRestoreLiveOwnerAdmissionTests {
    enum OwnerState: Equatable, Sendable {
        case absent
        case dead
        case live
        case staleGeneration
    }

    @Test(
        "A live unscoped owner suppresses autoresume and leaves a takeover notice",
        arguments: [RestorableAgentKind.grok, RestorableAgentKind.amp]
    )
    func liveUnscopedOwnerSuppressesAutoresumeWithNotice(kind: RestorableAgentKind) throws {
        // Amp's argv never names its thread; the hook record that recorded the
        // PID generation is the identity (#12158: a resumed Amp that outlives
        // the previous cmux must be reported, not silently skipped).
        let fixture = try makeFixture(kind: kind, ownerState: .live)
        defer { fixture.cleanup() }

        let input = try restoredStartupInput(fixture)

        #expect(!input.contains(" restore \(kind.rawValue) \(fixture.sessionID)"), Comment(rawValue: input))
        #expect(input.contains("already running in process \(fixture.processID)"), Comment(rawValue: input))
        #expect(input.contains("stop process \(fixture.processID)"), Comment(rawValue: input))
        #expect(input.contains("cmux restore --surface"), Comment(rawValue: input))
    }

    @Test(
        "No current owner admits autoresume",
        arguments: [
            (RestorableAgentKind.grok, OwnerState.absent),
            (RestorableAgentKind.grok, OwnerState.dead),
            (RestorableAgentKind.grok, OwnerState.staleGeneration),
            (RestorableAgentKind.amp, OwnerState.absent),
            (RestorableAgentKind.amp, OwnerState.dead),
            (RestorableAgentKind.amp, OwnerState.staleGeneration),
        ]
    )
    func missingDeadOrStaleOwnerAdmitsAutoresume(
        kind: RestorableAgentKind,
        ownerState: OwnerState
    ) throws {
        let fixture = try makeFixture(kind: kind, ownerState: ownerState)
        defer { fixture.cleanup() }

        let input = try restoredStartupInput(fixture)

        #expect(
            input.contains(" restore \(kind.rawValue) \(fixture.sessionID)"),
            "An absent or stale PID generation must not block restore: \(input)"
        )
        #expect(!input.contains("already running in process"), Comment(rawValue: input))
    }

    @Test("Admission stays decidable while other agents rewrite the hook-store directory during every scan")
    func ampAdmissionSurvivesHookStoreChurn() async throws {
        let fixture = try makeFixture(kind: .amp, ownerState: .dead)
        defer { fixture.cleanup() }
        let scanCount = OSAllocatedUnfairLock(initialState: 0)
        let hookStateDirectory = fixture.hookStateDirectory
        let loadIndex = fixture.loadIndex
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let pass = scanCount.withLock { count in
                    count += 1
                    return count
                }
                // Another agent kind rewriting its own store lands in the
                // same watched directory as an atomic create-and-rename. A
                // real scan runs long enough for that event to be observed
                // before the scan reports, so give the watcher the same
                // window here.
                let churn = hookStateDirectory.appendingPathComponent("churn-\(pass).json")
                try? Data("{}".utf8).write(to: churn, options: .atomic)
                let index = loadIndex()
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint()
                        .union(index.liveSessionOwnerFingerprint),
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { hookStateDirectory.path }
        )

        let refreshed = await sharedIndex.indexRefreshingNow()

        let index = try #require(
            refreshed,
            "A scan that started after the request is fresh evidence; hook-store churn from other agents must not fail admission closed (#12158)"
        )
        #expect(scanCount.withLock { $0 } >= 1)
        #expect(index.isComplete(
            forWorkspaceId: fixture.ownerWorkspaceID,
            panelId: fixture.ownerSurfaceID,
            kind: "amp"
        ))
        #expect(index.liveSessionOwner(
            kind: "amp",
            sessionID: fixture.sessionID,
            revalidateProcessEvidence: true,
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent }
        ) == nil)
    }

    @Test("An unreadable store for another agent kind does not block Amp admission")
    func corruptStoreForAnotherKindDoesNotBlockAmpAdmission() throws {
        // Pi is registry-owned: its store loads as `.custom("pi")` while the
        // kind string parses to the native case. Both must name the same
        // (corrupt) store.
        let fixture = try makeFixture(
            kind: .amp,
            ownerState: .dead,
            corruptStoreKinds: [.claude, .custom("pi")]
        )
        defer { fixture.cleanup() }
        let index = fixture.index

        #expect(!index.isComplete)
        #expect(!index.isComplete(
            forWorkspaceId: fixture.ownerWorkspaceID,
            panelId: fixture.ownerSurfaceID,
            kind: "pi"
        ))
        #expect(!index.isComplete(forPanelId: fixture.ownerSurfaceID, kind: "pi"))
        #expect(
            index.isComplete(
                forWorkspaceId: fixture.ownerWorkspaceID,
                panelId: fixture.ownerSurfaceID,
                kind: "amp"
            ),
            "Only the claude store is unreadable; amp owners are recorded in the amp store"
        )
        #expect(index.isComplete(forPanelId: fixture.ownerSurfaceID, kind: "amp"))
        #expect(!index.isComplete(
            forWorkspaceId: fixture.ownerWorkspaceID,
            panelId: fixture.ownerSurfaceID,
            kind: "claude"
        ))
        #expect(!index.isComplete(
            forWorkspaceId: fixture.ownerWorkspaceID,
            panelId: fixture.ownerSurfaceID,
            kind: nil
        ))

        let input = try restoredStartupInput(fixture)

        #expect(input.contains(" restore amp \(fixture.sessionID)"), Comment(rawValue: input))
    }

    @Test("Chained quit/restore cycles admit the same Amp thread with one thread positional")
    func chainedAmpRestoresAdmitAndKeepArgvSane() throws {
        var fixture = try makeFixture(
            kind: .amp,
            ownerState: .dead,
            launchOptions: ["--mode", "smart"]
        )
        defer { fixture.cleanup() }
        var capturedArguments = [fixture.executable, "--mode", "smart"]

        for cycle in 1...3 {
            // The previous instance leaves a hook record whose PID generation
            // is gone, carrying the argv its launch was captured with.
            try fixture.writeOwnerRecord(
                processID: fixture.processID - cycle,
                launchArguments: capturedArguments
            )
            fixture.reloadIndex()
            #expect(
                fixture.index.liveSessionOwner(
                    kind: "amp",
                    sessionID: fixture.sessionID,
                    revalidateProcessEvidence: true,
                    processArgumentsProvider: { _ in nil },
                    processPresenceProvider: { _ in .absent }
                ) == nil,
                "cycle \(cycle): a stale process record is not a live owner"
            )

            let input = try restoredStartupInput(fixture)
            #expect(input.contains(" restore amp \(fixture.sessionID)"), "cycle \(cycle): \(input)")

            let claim = try #require(
                AgentResumeLaunchGuard.shared.claimResumeLaunchWithToken(
                    kind: "amp",
                    sessionId: fixture.sessionID
                ),
                "cycle \(cycle): the pre-exec claim must be free once the previous launch exited"
            )
            let reloadedArguments = try #require(
                fixture.index.snapshot(
                    workspaceId: fixture.ownerWorkspaceID,
                    panelId: fixture.ownerSurfaceID
                )?.launchCommand?.arguments
            )
            let argv = try #require(AgentResumeArgv().builtInKind(
                kind: "amp",
                sessionId: fixture.sessionID,
                executablePath: fixture.executable,
                arguments: reloadedArguments
            ))
            #expect(
                argv == ["amp", "threads", "continue", "--mode", "smart", fixture.sessionID],
                "cycle \(cycle)"
            )
            #expect(
                argv.filter { $0.hasPrefix("T-") } == [fixture.sessionID],
                "cycle \(cycle): amp threads continue foregrounds the first positional thread, so the restored thread must be the only one"
            )
            // The wrapper execs the real binary with the same tail, and the
            // plugin captures that argv for the next restore.
            capturedArguments = [fixture.executable] + argv.dropFirst()
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(
                kind: "amp",
                sessionId: fixture.sessionID,
                claim: claim
            )
        }
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

    @Test("A fresh Antigravity launch without --conversation still owns the session its hooks recorded")
    func antigravityFreshLaunchOwnsHookRecordedSession() {
        let sessionID = "58057d57-0ce6-4008-99ec-77f1b7e2c470"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .antigravity,
            sessionId: sessionID,
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "antigravity",
                executablePath: "agy",
                arguments: ["agy", "--dangerously-skip-permissions"],
                workingDirectory: nil,
                capturedAt: nil,
                source: "process"
            ),
            registration: .builtInAntigravity
        )
        let validator = CachedAgentProcessIdentityValidator()
        let freshLaunch = CmuxTopProcessArguments(
            arguments: ["agy", "--dangerously-skip-permissions"],
            environment: [:]
        )

        // agy mints the conversation id in-process and reports it through its
        // hooks, so the current hook record behind this snapshot came from this
        // very process. Rejecting the bare argv retired every fresh binding on
        // the next autosave (https://github.com/manaflow-ai/cmux/issues/5473).
        #expect(validator.currentProcess(
            freshLaunch,
            matches: snapshot,
            hermesSessionValidation: .currentHookRecord
        ))
        // A cached snapshot cannot rule out an in-process conversation switch.
        #expect(!validator.currentProcess(
            freshLaunch,
            matches: snapshot,
            hermesSessionValidation: .cachedSnapshot
        ))
        #expect(!validator.currentProcess(freshLaunch, matches: snapshot))
        // An explicit selector still has to name this session.
        #expect(validator.currentProcess(
            CmuxTopProcessArguments(arguments: ["agy", "--conversation", sessionID], environment: [:]),
            matches: snapshot
        ))
        #expect(!validator.currentProcess(
            CmuxTopProcessArguments(
                arguments: ["agy", "--conversation", "11111111-2222-3333-4444-555555555555"],
                environment: [:]
            ),
            matches: snapshot,
            hermesSessionValidation: .currentHookRecord
        ))
        // So does an exported process identity.
        #expect(!validator.currentProcess(
            CmuxTopProcessArguments(
                arguments: ["agy"],
                environment: ["CMUX_AGENT_SESSION_ID": "11111111-2222-3333-4444-555555555555"]
            ),
            matches: snapshot,
            hermesSessionValidation: .currentHookRecord
        ))
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

    @Test("Pi selector flags do not consume the following prompt as a session", arguments: ["--resume", "-r"])
    func piBooleanSelectorDoesNotClaimPrompt(flag: String) {
        let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("pi"),
            sessionId: sessionID,
            workingDirectory: nil,
            registration: .builtInPi
        )
        let validator = CachedAgentProcessIdentityValidator()
        let arguments = ["/usr/local/bin/pi", flag, sessionID]
        #expect(!validator.currentProcess(
            CmuxTopProcessArguments(arguments: arguments, environment: [:]),
            matches: snapshot
        ))
        #expect(validator.currentProcess(
            CmuxTopProcessArguments(
                arguments: arguments,
                environment: ["CMUX_AGENT_SESSION_ID": sessionID]
            ),
            matches: snapshot
        ))
        #expect(validator.currentProcess(
            CmuxTopProcessArguments(
                arguments: ["/usr/local/bin/pi", "--session", sessionID],
                environment: [:]
            ),
            matches: snapshot
        ))
    }

    @Test("A custom executable alone does not prove session ownership")
    func customProcessWithoutSessionIdentityFailsClosed() {
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom("custom-agent"),
            sessionId: "saved-session",
            workingDirectory: nil
        )
        #expect(!CachedAgentProcessIdentityValidator().currentProcess(
            CmuxTopProcessArguments(arguments: ["/usr/local/bin/custom-agent"], environment: [:]),
            matches: snapshot
        ))
    }

    @Test("Revalidation rejects PID reuse during argv inspection")
    func cachedOwnerRejectsGenerationChangeDuringArgvRead() throws {
        let fixture = try makeFixture(ownerState: .live)
        defer { fixture.cleanup() }
        let identity = try #require(AgentPIDProcessIdentity(pid: pid_t(fixture.processID)))
        var inspectedArguments = false
        let index = fixture.index.liveSessionOwners.revalidated(
            processArgumentsProvider: { _ in
                inspectedArguments = true
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/grok", "--session-id", fixture.sessionID],
                    environment: [:]
                )
            },
            processIdentityProvider: { _ in inspectedArguments ? nil : identity }
        )
        #expect(index.owner(
            kind: fixture.agent.kind.rawValue,
            sessionID: fixture.sessionID,
            revalidateProcessEvidence: false
        ) == nil)
    }

    private struct Fixture {
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

    private func makeFixture(
        kind: RestorableAgentKind = .grok,
        ownerState: OwnerState,
        launchOptions: [String] = [],
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
        let launchArguments = [executable] + launchOptions + sessionArguments
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

    private func restoredStartupInput(_ fixture: Fixture) throws -> String {
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
