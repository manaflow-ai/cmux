import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RestorableAgentProcessGenerationTests {
    private typealias Fixture = (
        root: URL,
        hookStateDirectory: URL,
        fileManager: FileManager,
        workspaceID: UUID,
        panelID: UUID,
        sessionID: String,
        processID: Int,
        updatedAt: TimeInterval,
        storeURL: URL,
        previousHookStateDirectory: String?
    )

    @Test("Shared cache publishes unknown-to-exited liveness transitions")
    func sharedCachePublishesUnknownToExitedLivenessTransitions() async throws {
        let fixture = try makeFixture(prefix: "cmux-liveness-publication")
        defer { cleanup(fixture) }

        let unknownIndex = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .unknown },
            processIdentityProvider: { _ in nil }
        )
        let exitedIndex = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { _ in .absent },
            processIdentityProvider: { _ in nil }
        )
        let pendingIndexes = OSAllocatedUnfairLock(initialState: [unknownIndex, exitedIndex])
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = pendingIndexes.withLock { indexes in
                    indexes.isEmpty ? exitedIndex : indexes.removeFirst()
                }
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { fixture.hookStateDirectory.path }
        )

        await sharedIndex.refreshForkAvailabilityNow()
        #expect(sharedIndex.index?.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.processLiveness == .unknown)

        await sharedIndex.refreshForkAvailabilityNow()
        #expect(sharedIndex.index?.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.processLiveness == .exited)
    }

    @Test("Ownership-sensitive restore does not consume a warm cache")
    func ownershipSensitiveRestoreDoesNotConsumeWarmCache() async throws {
        let fixture = try makeFixture(prefix: "cmux-ownership-refresh")
        defer { cleanup(fixture) }
        let index = loadRunningFixture(
            fixture,
            processArguments: codexProcessArguments(for: fixture),
            processIdentity: AgentPIDProcessIdentity(
                pid: pid_t(fixture.processID),
                startSeconds: Int64(fixture.updatedAt),
                startMicroseconds: 0
            )
        )
        let loadCount = OSAllocatedUnfairLock(initialState: 0)
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                loadCount.withLock { $0 += 1 }
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { fixture.hookStateDirectory.path }
        )

        _ = await sharedIndex.indexRefreshingNow()
        #expect(loadCount.withLock { $0 } == 1)
        #expect(sharedIndex.currentIndexForOwnershipSensitiveRestore() == nil)
        _ = await sharedIndex.indexRefreshingNow()
        #expect(loadCount.withLock { $0 } == 2)
    }

    @Test("A later process generation cannot satisfy a stale hook PID")
    func laterProcessGenerationCannotSatisfyStaleHookPID() throws {
        let fixture = try makeFixture(prefix: "cmux-pid-generation")
        defer { cleanup(fixture) }

        let processArguments = CmuxTopProcessArguments(
            arguments: ["/usr/local/bin/codex"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                "CMUX_SURFACE_ID": fixture.panelID.uuidString,
            ]
        )
        let reusedIdentity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: Int64(fixture.updatedAt + 1),
            startMicroseconds: 0
        )
        let originalIdentity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: Int64(fixture.updatedAt - 1),
            startMicroseconds: 0
        )
        try writeStoredProcessIdentity(originalIdentity, to: fixture)
        let reusedIndex = loadRunningFixture(
            fixture,
            processArguments: processArguments,
            processIdentity: reusedIdentity
        )
        let originalIndex = loadRunningFixture(
            fixture,
            processArguments: processArguments,
            processIdentity: originalIdentity
        )

        #expect(reusedIndex.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.processLiveness == .exited)
        #expect(originalIndex.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.processLiveness == .running)
    }

    @Test("A current PID owner does not authenticate a record without stored generation identity")
    func currentPIDOwnerDoesNotAuthenticateRecordWithoutStoredGenerationIdentity() throws {
        let fixture = try makeFixture(prefix: "cmux-unbound-pid-generation")
        defer { cleanup(fixture) }
        let currentIdentity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: Int64(fixture.updatedAt - 1),
            startMicroseconds: 0
        )
        let index = loadRunningFixture(
            fixture,
            processArguments: codexProcessArguments(for: fixture),
            processIdentity: currentIdentity
        )

        #expect(index.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.processLiveness == .unknown)
    }

    @Test("Missing identity for a recorded live PID fails closed")
    func missingIdentityForRecordedLivePIDFailsClosed() throws {
        let fixture = try makeFixture(prefix: "cmux-partial-pid-identity")
        defer { cleanup(fixture) }

        let firstPID = fixture.processID
        let secondPID = fixture.processID - 1
        let recordedFirstIdentity = AgentPIDProcessIdentity(
            pid: pid_t(firstPID),
            startSeconds: Int64(fixture.updatedAt),
            startMicroseconds: 0
        )
        let currentFirstIdentity = AgentPIDProcessIdentity(
            pid: pid_t(firstPID),
            startSeconds: Int64(fixture.updatedAt + 1),
            startMicroseconds: 0
        )
        let key = RestorableAgentSessionIndex.PanelKey(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "partial-pid-session",
            workingDirectory: "/tmp/repo",
            launchCommand: nil
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (
                snapshot: snapshot,
                updatedAt: fixture.updatedAt + 1,
                processIDs: [firstPID, secondPID],
                agentProcessIDs: [firstPID, secondPID],
                sessionIDSource: .explicit
            )],
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": fixture.hookStateDirectory.path],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { pid in
                pid == secondPID ? .present : .absent
            },
            processIdentityProvider: { pid in
                pid == firstPID ? recordedFirstIdentity : nil
            }
        )

        #expect(
            index.hasUncertainStablePanelEntry(
                panelId: fixture.panelID,
                processIdentityProvider: { pid in
                    pid == firstPID ? currentFirstIdentity : nil
                },
                processPresenceProvider: { pid in
                    pid == secondPID ? .present : .absent
                }
            )
        )
    }

    @Test("Shared cache publishes a same-PID process generation change")
    func sharedCachePublishesSamePIDProcessGenerationChange() async throws {
        let fixture = try makeFixture(prefix: "cmux-same-pid-cache-generation")
        defer { cleanup(fixture) }
        let firstIdentity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: Int64(fixture.updatedAt - 2),
            startMicroseconds: 0
        )
        let secondIdentity = AgentPIDProcessIdentity(
            pid: pid_t(fixture.processID),
            startSeconds: Int64(fixture.updatedAt - 1),
            startMicroseconds: 0
        )
        let processArguments = codexProcessArguments(for: fixture)
        try writeStoredProcessIdentity(firstIdentity, to: fixture)
        let firstIndex = loadRunningFixture(
            fixture,
            processArguments: processArguments,
            processIdentity: firstIdentity
        )
        try writeStoredProcessIdentity(secondIdentity, to: fixture)
        let secondIndex = loadRunningFixture(
            fixture,
            processArguments: processArguments,
            processIdentity: secondIdentity
        )
        let pendingIndexes = OSAllocatedUnfairLock(initialState: [firstIndex, secondIndex])
        let sharedIndex = SharedLiveAgentIndex(
            indexLoader: {
                let index = pendingIndexes.withLock { indexes in
                    indexes.isEmpty ? secondIndex : indexes.removeFirst()
                }
                return (
                    index: index,
                    liveAgentProcessFingerprint: index.liveAgentProcessFingerprint(),
                    processScopeFingerprint: [],
                    forkValidatedPanels: []
                )
            },
            hookStoreDirectoryProvider: { fixture.hookStateDirectory.path }
        )

        await sharedIndex.refreshForkAvailabilityNow()
        #expect(sharedIndex.index?.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.agentProcessIdentities[fixture.processID] == firstIdentity)

        await sharedIndex.refreshForkAvailabilityNow()
        #expect(sharedIndex.index?.entry(
            workspaceId: fixture.workspaceID,
            panelId: fixture.panelID
        )?.agentProcessIdentities[fixture.processID] == secondIdentity)
    }

    private func loadRunningFixture(
        _ fixture: Fixture,
        processArguments: CmuxTopProcessArguments,
        processIdentity: AgentPIDProcessIdentity
    ) -> RestorableAgentSessionIndex {
        RestorableAgentSessionIndex.load(
            homeDirectory: fixture.root.path,
            fileManager: fixture.fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { pid in
                pid == fixture.processID ? processArguments : nil
            },
            processPresenceProvider: { _ in .present },
            processIdentityProvider: { pid in
                pid == fixture.processID ? processIdentity : nil
            }
        )
    }

    private func codexProcessArguments(for fixture: Fixture) -> CmuxTopProcessArguments {
        CmuxTopProcessArguments(
            arguments: ["/usr/local/bin/codex"],
            environment: [
                "CMUX_AGENT_LAUNCH_KIND": "codex",
                "CMUX_WORKSPACE_ID": fixture.workspaceID.uuidString,
                "CMUX_SURFACE_ID": fixture.panelID.uuidString,
            ]
        )
    }

    private func writeStoredProcessIdentity(
        _ identity: AgentPIDProcessIdentity,
        to fixture: Fixture
    ) throws {
        var store = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.storeURL)) as? [String: Any]
        )
        var sessions = try #require(store["sessions"] as? [String: Any])
        var record = try #require(sessions[fixture.sessionID] as? [String: Any])
        record["pidStartSeconds"] = identity.startSeconds
        record["pidStartMicroseconds"] = identity.startMicroseconds
        sessions[fixture.sessionID] = record
        store["sessions"] = sessions
        let data = try JSONSerialization.data(
            withJSONObject: store,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: fixture.storeURL, options: .atomic)
    }

    private func makeFixture(prefix: String) throws -> Fixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let hookStateDirectory = root.appendingPathComponent("hook-state", isDirectory: true)
        let previousHookStateDirectory = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }

        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "codex-generation-session"
        let processID = 987_654_321
        let updatedAt: TimeInterval = 1_777_777_777
        let storeURL = RestorableAgentKind.codex.hookStoreFileURL(
            homeDirectory: root.path,
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookStateDirectory.path]
        )
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": workspaceID.uuidString,
            "surfaceId": panelID.uuidString,
            "cwd": "/tmp/repo",
            "pid": processID,
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": ["/usr/local/bin/codex"],
                "workingDirectory": "/tmp/repo",
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": [sessionID: record]],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
        setenv("CMUX_AGENT_HOOK_STATE_DIR", hookStateDirectory.path, 1)
        return (
            root: root,
            hookStateDirectory: hookStateDirectory,
            fileManager: fileManager,
            workspaceID: workspaceID,
            panelID: panelID,
            sessionID: sessionID,
            processID: processID,
            updatedAt: updatedAt,
            storeURL: storeURL,
            previousHookStateDirectory: previousHookStateDirectory
        )
    }

    private func cleanup(_ fixture: Fixture) {
        if let previousHookStateDirectory = fixture.previousHookStateDirectory {
            setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDirectory, 1)
        } else {
            unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
        }
        try? fixture.fileManager.removeItem(at: fixture.root)
    }
}
