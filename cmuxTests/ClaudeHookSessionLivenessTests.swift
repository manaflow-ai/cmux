import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A Claude session that is still running when cmux saves its session must be
/// indexed as running, or quit and update-relaunch saves record it as exited
/// and restore skips its automatic resume.
@MainActor
@Suite(.serialized)
struct ClaudeHookSessionLivenessTests {
    private struct Fixture {
        let root: URL
        let capturedAt: TimeInterval = 1_790_627_600
        let workspaceId = UUID()
        var panelId = UUID()
        let sessionId = UUID().uuidString.lowercased()
        var transcriptPath: URL { root.appendingPathComponent("\(sessionId).jsonl") }
        var executablePath: String { root.appendingPathComponent("bin/claude").path }
    }

    @Test("A live native Claude hook session is indexed as running")
    func liveNativeClaudeHookSessionIsIndexedAsRunning() throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-liveness")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 7_700
        let agentPID = 7_701
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
                processInfo(
                    fixture: fixture,
                    pid: agentPID,
                    parentPID: shellPID,
                    name: "claude",
                    path: fixture.executablePath
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: fixture.capturedAt),
            includesProcessDetails: true
        )

        let index = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { fixture.capturedAt },
            processArgumentsProvider: { pid in
                guard pid == agentPID else { return nil }
                return CmuxTopProcessArguments(
                    arguments: liveArguments(fixture: fixture),
                    environment: liveEnvironment(fixture: fixture)
                )
            },
            processIdentityProvider: { pid in pid == agentPID ? identity : nil }
        ).loadSynchronously()

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.snapshot.kind == .claude)
        #expect(entry.snapshot.sessionId == fixture.sessionId)
        #expect(entry.lifecycle == .idle)
        #expect(entry.processLiveness == .running)
    }

    @Test("A live idle Stop session survives the full snapshot and relaunch path")
    func liveIdleClaudeSessionSurvivesSnapshotAndRelaunch() throws {
        var fixture = try makeFixture(prefix: "cmux-claude-snapshot-restore")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaultsName = "cmux-claude-snapshot-restore-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let source = Workspace(id: fixture.workspaceId, agentSessionAutoResumeDefaults: defaults)
        defer { source.teardownAllPanels() }
        fixture.panelId = try #require(source.focusedPanelId)

        let agentPID = 7_750
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let reader = ExitingProcessCensusReader(
            processes: [
                .init(pid: 7_749, parentPID: 1, startSeconds: 1_790_627_000, scoped: true),
                .init(
                    pid: agentPID,
                    parentPID: 7_749,
                    startSeconds: identity.startSeconds,
                    startMicroseconds: identity.startMicroseconds,
                    scoped: true
                ),
                .init(pid: 7_752, parentPID: 1, startSeconds: 1_790_627_100, scoped: false),
            ],
            exitedPID: 7_752,
            workspaceId: fixture.workspaceId,
            panelId: fixture.panelId
        )
        let sampler = CmuxTopProcessSampler(reader: reader)
        let processSnapshot = try sampler.enrich(sampler.capture(), fields: [.details, .scope]).snapshot
        #expect(processSnapshot.enumerationIsComplete)
        #expect(processSnapshot.process(pid: 7_752) == nil)
        let index = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { fixture.capturedAt },
            processArgumentsProvider: { pid in
                guard pid == agentPID else { return nil }
                return CmuxTopProcessArguments(
                    arguments: liveArguments(fixture: fixture),
                    environment: liveEnvironment(fixture: fixture)
                )
            },
            processIdentityProvider: { pid in pid == agentPID ? identity : nil }
        ).loadSynchronously()
        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.lifecycle == .idle)
        #expect(entry.processLiveness == .running)
        let panelID = try #require(source.focusedPanelId)
        let binding = SurfaceResumeBindingSnapshot(
            name: "Claude Code",
            kind: "claude",
            command: "claude --resume \(fixture.sessionId)",
            cwd: fixture.root.path,
            checkpointId: fixture.sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: fixture.capturedAt
        )
        #expect(source.setSurfaceResumeBinding(binding, panelId: panelID))
        let snapshot = source.sessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: index,
            surfaceResumeBindingIndex: .empty,
            currentAgentProcessIdentity: { pid in pid == agentPID ? identity : nil },
            agentProcessPresence: { pid in pid == agentPID ? .present : .absent }
        )
        let terminal = try #require(snapshot.panels.first?.terminal)
        #expect(terminal.wasAgentRunning == true)
        #expect(terminal.resumeBinding?.autoResume == true)
        #expect(terminal.resumeBinding?.checkpointId == fixture.sessionId)

        let restored = Workspace(
            agentSessionAutoResumeDefaults: defaults,
            restorableAgentIndexProvider: { .empty }
        )
        defer { restored.teardownAllPanels() }
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanelID = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelID))
        #expect(restoredPanel.surface.debugInitialInputMetadata().hasInitialInput)
        #expect(restoredPanel.surface.initialInput?.contains(fixture.sessionId) == true)
    }

    /// A busy Mac always has some process exiting between the PID listing and
    /// the per-process reads. That process is gone, not unreadable, so the census
    /// must stay complete and the live Claude session must stay running.
    @Test("An unrelated process exiting mid-census keeps a live Claude session running")
    func unrelatedProcessExitingMidCensusKeepsClaudeRunning() throws {
        let fixture = try makeFixture(prefix: "cmux-claude-census-churn")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 7_800
        let agentPID = 7_801
        let exitedPID = 7_802
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let reader = ExitingProcessCensusReader(
            processes: [
                .init(pid: shellPID, parentPID: 1, startSeconds: 1_790_627_000, scoped: true),
                .init(
                    pid: agentPID,
                    parentPID: shellPID,
                    startSeconds: identity.startSeconds,
                    startMicroseconds: identity.startMicroseconds,
                    scoped: true
                ),
                .init(pid: exitedPID, parentPID: 1, startSeconds: 1_790_627_100, scoped: false),
            ],
            exitedPID: exitedPID,
            workspaceId: fixture.workspaceId,
            panelId: fixture.panelId
        )
        let sampler = CmuxTopProcessSampler(reader: reader)
        let processSnapshot = try sampler.enrich(sampler.capture(), fields: [.details, .scope]).snapshot
        #expect(processSnapshot.enumerationIsComplete)
        #expect(processSnapshot.process(pid: exitedPID) == nil)

        let index = SharedLiveAgentIndexLoader(
            homeDirectory: fixture.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            processSnapshotProvider: { processSnapshot },
            capturedAtProvider: { fixture.capturedAt },
            processArgumentsProvider: { pid in
                guard pid == agentPID, processSnapshot.process(pid: pid) != nil else { return nil }
                return CmuxTopProcessArguments(
                    arguments: liveArguments(fixture: fixture),
                    environment: liveEnvironment(fixture: fixture)
                )
            },
            processIdentityProvider: { pid in pid == agentPID ? identity : nil }
        ).loadSynchronously()

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.snapshot.sessionId == fixture.sessionId)
        #expect(entry.processLiveness == .running)
    }

    /// Claude is indexed from its hook record, never by process detection, so
    /// the hook PID alone must not leave an exclusive pane unsafe to hibernate.
    @Test("A live Claude hook session in an exclusive pane is safe to hibernate")
    func liveClaudeHookSessionInExclusivePaneIsSafeToHibernate() throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-scope")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 7_900
        let agentPID = 7_901
        let mcpServerPID = 7_902
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        let mcpServerIdentity = AgentPIDProcessIdentity(
            pid: pid_t(mcpServerPID),
            startSeconds: 1_790_627_505,
            startMicroseconds: 0
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let index = loadIndex(
            fixture: fixture,
            processes: [
                processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
                processInfo(
                    fixture: fixture,
                    pid: agentPID,
                    parentPID: shellPID,
                    name: "claude",
                    path: fixture.executablePath,
                    processGroupID: agentPID
                ),
                processInfo(
                    fixture: fixture,
                    pid: mcpServerPID,
                    parentPID: agentPID,
                    name: "cmux-cua",
                    path: "/usr/local/bin/cmux-cua",
                    processGroupID: agentPID
                ),
            ],
            agentPID: agentPID,
            identities: [agentPID: identity, mcpServerPID: mcpServerIdentity]
        )

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.processLiveness == .running)
        #expect(entry.terminationProcessIDs == [agentPID, mcpServerPID])
        #expect(entry.containsUnrelatedProcess == false)
        #expect(entry.processSafetyAllowsScheduledHibernation)
    }

    @Test("An unrelated process in a Claude hook session's pane keeps it unsafe to hibernate")
    func unrelatedProcessInClaudeHookPaneKeepsItUnsafeToHibernate() throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-scope-unrelated")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 7_950
        let agentPID = 7_951
        let unrelatedPID = 7_952
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let index = loadIndex(
            fixture: fixture,
            processes: [
                processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
                processInfo(
                    fixture: fixture,
                    pid: agentPID,
                    parentPID: shellPID,
                    name: "claude",
                    path: fixture.executablePath,
                    processGroupID: agentPID
                ),
                processInfo(fixture: fixture, pid: unrelatedPID, parentPID: 1, name: "sleep", path: "/bin/sleep"),
            ],
            agentPID: agentPID,
            identities: [agentPID: identity]
        )

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.processLiveness == .running)
        #expect(entry.containsUnrelatedProcess)
        #expect(!entry.processSafetyAllowsScheduledHibernation)
    }

    /// The two indexes that gate hibernation: the shared live index, and the
    /// process census that manual hibernation, memory-pressure reclaim and
    /// the teardown's final revalidation load.
    enum HibernationIndexLoader: String, CaseIterable, Sendable {
        case shared
        case processCensus
    }

    /// cmux's Claude wrapper starts `cmux hooks claude inbox-wait` on
    /// SessionStart and Stop. Claude Code runs it detached: a child of the
    /// agent that leads its own session and process group, with no terminal.
    enum DetachedWork: String, CaseIterable, Sendable {
        /// The registered helper, but scoped to another surface.
        case helperForAnotherSurface
        /// A cmux hook the wrapper runs but that does work, so it is not registered.
        case unregisteredCmuxHook
        /// A user's background job, detached the same way.
        case userJob
        /// The registered helper argv, but in the agent's process group.
        case helperInAgentProcessGroup
        /// The registered helper argv, but with a child of its own.
        case helperWithChild
    }

    /// Every live Claude used to refuse manual hibernation with
    /// `process_scope_unsafe`: the census index left the hook PID unscoped.
    @Test(
        "A live Claude alone in its pane is safe to hibernate from every index",
        arguments: HibernationIndexLoader.allCases
    )
    func claudeAloneInItsPaneIsSafeFromEveryIndex(loader: HibernationIndexLoader) throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-scope-\(loader.rawValue)")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 8_000
        let agentPID = 8_001
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let index = loadIndex(
            fixture: fixture,
            loader: loader,
            processes: [
                processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
                processInfo(
                    fixture: fixture,
                    pid: agentPID,
                    parentPID: shellPID,
                    name: "claude",
                    path: fixture.executablePath,
                    processGroupID: agentPID
                ),
            ],
            agentPID: agentPID,
            identities: [agentPID: identity]
        )

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.processLiveness == .running)
        #expect(entry.terminationProcessIDs == [agentPID])
        #expect(entry.cmuxHelperProcessIDs.isEmpty)
        #expect(entry.containsUnrelatedProcess == false)
        #expect(entry.processSafetyAllowsScheduledHibernation)
    }

    @Test(
        "A wrapped Claude's detached inbox helper is terminated with it",
        arguments: HibernationIndexLoader.allCases
    )
    func wrappedClaudeInboxHelperIsTerminatedWithIt(loader: HibernationIndexLoader) throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-helper-\(loader.rawValue)")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 8_100
        let agentPID = 8_101
        let helperPID = 8_102
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        let helperIdentity = AgentPIDProcessIdentity(
            pid: pid_t(helperPID),
            startSeconds: 1_790_627_560,
            startMicroseconds: 0
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        let index = loadIndex(
            fixture: fixture,
            loader: loader,
            processes: [
                processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
                processInfo(
                    fixture: fixture,
                    pid: agentPID,
                    parentPID: shellPID,
                    name: "claude",
                    path: fixture.executablePath,
                    processGroupID: agentPID
                ),
                processInfo(
                    fixture: fixture,
                    pid: helperPID,
                    parentPID: agentPID,
                    name: "cmux",
                    path: Self.bundledCLIPath,
                    processGroupID: helperPID,
                    ttyDevice: nil
                ),
            ],
            agentPID: agentPID,
            identities: [agentPID: identity, helperPID: helperIdentity],
            otherArguments: [
                helperPID: CmuxTopProcessArguments(
                    arguments: Self.inboxWaitArguments,
                    environment: liveEnvironment(fixture: fixture)
                ),
            ]
        )

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.processLiveness == .running)
        #expect(entry.terminationProcessIDs == [agentPID, helperPID])
        #expect(Set(entry.terminationProcessIdentities.keys) == [agentPID, helperPID])
        #expect(entry.cmuxHelperProcessIDs == [helperPID])
        #expect(entry.containsUnrelatedProcess == false)
        #expect(entry.processSafetyAllowsScheduledHibernation)
    }

    @Test(
        "Detached work beside a Claude that is not its registered helper keeps it unsafe",
        arguments: DetachedWork.allCases, HibernationIndexLoader.allCases
    )
    func detachedWorkBesideClaudeKeepsItUnsafe(
        work: DetachedWork,
        loader: HibernationIndexLoader
    ) throws {
        let fixture = try makeFixture(prefix: "cmux-claude-hook-detached-\(work.rawValue)")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let shellPID = 8_200
        let agentPID = 8_201
        let detachedPID = 8_202
        let grandchildPID = 8_203
        let identity = AgentPIDProcessIdentity(
            pid: pid_t(agentPID),
            startSeconds: 1_790_627_504,
            startMicroseconds: 891_303
        )
        try writeHookRecord(fixture: fixture, identity: identity)
        var environment = liveEnvironment(fixture: fixture)
        var arguments = Self.inboxWaitArguments
        var processGroupID = detachedPID
        switch work {
        case .helperForAnotherSurface:
            environment["CMUX_SURFACE_ID"] = UUID().uuidString
            environment["CMUX_PANEL_ID"] = environment["CMUX_SURFACE_ID"]
        case .unregisteredCmuxHook:
            arguments = [Self.bundledCLIPath, "hooks", "claude", "auto-name"]
        case .userJob:
            arguments = ["/usr/bin/python3", "-m", "http.server"]
        case .helperInAgentProcessGroup:
            processGroupID = agentPID
        case .helperWithChild:
            break
        }
        var processes = [
            processInfo(fixture: fixture, pid: shellPID, parentPID: 1, name: "zsh", path: "/bin/zsh"),
            processInfo(
                fixture: fixture,
                pid: agentPID,
                parentPID: shellPID,
                name: "claude",
                path: fixture.executablePath,
                processGroupID: agentPID
            ),
            processInfo(
                fixture: fixture,
                pid: detachedPID,
                parentPID: agentPID,
                name: (arguments[0] as NSString).lastPathComponent,
                path: arguments[0],
                processGroupID: processGroupID,
                ttyDevice: nil
            ),
        ]
        if work == .helperWithChild {
            processes.append(processInfo(
                fixture: fixture,
                pid: grandchildPID,
                parentPID: detachedPID,
                name: "sleep",
                path: "/bin/sleep",
                processGroupID: detachedPID,
                ttyDevice: nil
            ))
        }
        let index = loadIndex(
            fixture: fixture,
            loader: loader,
            processes: processes,
            agentPID: agentPID,
            identities: [
                agentPID: identity,
                detachedPID: AgentPIDProcessIdentity(
                    pid: pid_t(detachedPID), startSeconds: 1_790_627_560, startMicroseconds: 0
                ),
                grandchildPID: AgentPIDProcessIdentity(
                    pid: pid_t(grandchildPID), startSeconds: 1_790_627_561, startMicroseconds: 0
                ),
            ],
            otherArguments: [
                detachedPID: CmuxTopProcessArguments(arguments: arguments, environment: environment),
            ]
        )

        let entry = try #require(index.entry(workspaceId: fixture.workspaceId, panelId: fixture.panelId))
        #expect(entry.processLiveness == .running)
        #expect(entry.cmuxHelperProcessIDs.isEmpty)
        #expect(entry.containsUnrelatedProcess)
        #expect(!entry.processSafetyAllowsScheduledHibernation)
    }

    private static let bundledCLIPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    private static let inboxWaitArguments = [bundledCLIPath, "hooks", "claude", "inbox-wait"]

    private func loadIndex(
        fixture: Fixture,
        loader: HibernationIndexLoader = .shared,
        processes: [CmuxTopProcessInfo],
        agentPID: Int,
        identities: [Int: AgentPIDProcessIdentity],
        otherArguments: [Int: CmuxTopProcessArguments] = [:]
    ) -> RestorableAgentSessionIndex {
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: fixture.capturedAt),
            includesProcessDetails: true
        )
        let agentArguments = CmuxTopProcessArguments(
            arguments: liveArguments(fixture: fixture),
            environment: liveEnvironment(fixture: fixture)
        )
        let processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = { pid in
            pid == agentPID ? agentArguments : otherArguments[pid]
        }
        switch loader {
        case .shared:
            return SharedLiveAgentIndexLoader(
                homeDirectory: fixture.root.path,
                fileManager: .default,
                registry: CmuxVaultAgentRegistry(registrations: []),
                processSnapshotProvider: { processSnapshot },
                capturedAtProvider: { fixture.capturedAt },
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: { pid in identities[pid] }
            ).loadSynchronously()
        case .processCensus:
            return RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshotsSynchronously(
                processSnapshot: processSnapshot,
                homeDirectory: fixture.root.path,
                fileManager: .default,
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: { pid in identities[pid] }
            )
        }
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fixture = Fixture(root: root)
        try """
        {"type":"user","sessionId":"\(fixture.sessionId)","cwd":"\(root.path)","message":{"role":"user","content":"hello"}}

        """.write(to: fixture.transcriptPath, atomically: true, encoding: .utf8)
        return fixture
    }

    /// The argv a cmux-wrapped native Claude install runs with.
    private func liveArguments(fixture: Fixture) -> [String] {
        [fixture.executablePath, "--session-id", fixture.sessionId, "--settings", "{}"]
    }

    private func liveEnvironment(fixture: Fixture) -> [String: String] {
        [
            "CMUX_WORKSPACE_ID": fixture.workspaceId.uuidString,
            "CMUX_TAB_ID": fixture.workspaceId.uuidString,
            "CMUX_SURFACE_ID": fixture.panelId.uuidString,
            "CMUX_PANEL_ID": fixture.panelId.uuidString,
            "CMUX_AGENT_LAUNCH_KIND": "claude",
            "CMUX_AGENT_LAUNCH_EXECUTABLE": fixture.executablePath,
            "CLAUDE_CONFIG_DIR": fixture.root.path,
            "PWD": fixture.root.path,
        ]
    }

    /// Mirrors what `cmux claude-hook` records for a running session.
    private func writeHookRecord(fixture: Fixture, identity: AgentPIDProcessIdentity) throws {
        let now = fixture.capturedAt
        let record: [String: Any] = [
            "sessionId": fixture.sessionId,
            "workspaceId": fixture.workspaceId.uuidString,
            "surfaceId": fixture.panelId.uuidString,
            "cwd": fixture.root.path,
            "transcriptPath": fixture.transcriptPath.path,
            "pid": Int(identity.pid),
            "pidStartSeconds": identity.startSeconds,
            "pidStartMicroseconds": identity.startMicroseconds,
            "hookEventName": "Stop",
            "agentLifecycle": "idle",
            "isRestorable": true,
            "lastPermissionMode": "auto",
            "startedAt": now,
            "updatedAt": now,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": fixture.executablePath,
                "arguments": [fixture.executablePath],
                "workingDirectory": fixture.root.path,
                "environment": ["CLAUDE_CONFIG_DIR": fixture.root.path],
                "capturedAt": now,
                "source": "environment",
            ],
        ]
        let stateDirectory = fixture.root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let store: [String: Any] = ["version": 1, "sessions": [fixture.sessionId: record]]
        try JSONSerialization.data(withJSONObject: store, options: [.prettyPrinted])
            .write(to: stateDirectory.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)
    }

    private func processInfo(
        fixture: Fixture,
        pid: Int,
        parentPID: Int,
        name: String,
        path: String,
        processGroupID: Int? = nil,
        ttyDevice: Int64? = 0x123
    ) -> CmuxTopProcessInfo {
        let resolvedProcessGroupID = processGroupID ?? (parentPID == 1 ? pid : parentPID)
        return CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: path,
            ttyDevice: ttyDevice,
            cmuxWorkspaceID: fixture.workspaceId,
            cmuxSurfaceID: fixture.panelId,
            cmuxAttributionReason: "cmux-test",
            processGroupID: resolvedProcessGroupID,
            terminalProcessGroupID: resolvedProcessGroupID,
            cpuPercent: 0,
            residentBytes: 0,
            virtualBytes: 0,
            threadCount: 1
        )
    }
}
