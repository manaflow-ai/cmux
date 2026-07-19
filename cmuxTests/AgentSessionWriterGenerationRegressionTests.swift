import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func committedHookMutationSurvivesLegacyProjectionLockContention() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-projection-contention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let descriptor = open(
            stateURL.path + ".lock",
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }

        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            ],
            agentName: "codex"
        )

        #expect(try store.upsert(
            sessionId: "committed-session",
            workspaceId: "workspace",
            surfaceId: "surface",
            cwd: root.path
        ))
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        #expect(
            try registry.hookRecord(provider: "codex", sessionID: "committed-session") != nil
        )
    }

    @Test func corruptLegacyReadFallsBackToLastCompleteRegistrySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-corrupt-legacy-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "last-complete"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ]).write(to: stateURL, options: .atomic)
        let bridge = AgentHookSessionRegistryBridge(
            provider: "codex",
            statePath: stateURL.path,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path],
            fileManager: .default
        )
        #expect(bridge.load().sessions[sessionID] != nil)

        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: "partial-record"],
        ]).write(to: stateURL, options: .atomic)

        #expect(bridge.load().sessions[sessionID] != nil)
    }

    @Test func permissionModeOnlyMutationAdvancesRegistryProjection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-permission-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("claude-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "permission-session"
        try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": "workspace",
                "surfaceId": "surface",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ], options: [.sortedKeys]).write(to: stateURL, options: .atomic)
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            ]
        )

        try store.updateLastPermissionMode(sessionId: sessionID, permissionMode: "plan")

        let saved = try #require(try store.lookup(sessionId: sessionID))
        #expect(saved.lastPermissionMode == "plan")
        #expect(saved.updatedAt > 200)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let projected = try #require(registry.snapshot(provider: "claude").records.first)
        let projectedRecord = try JSONDecoder().decode(ClaudeHookSessionRecord.self, from: projected.json)
        #expect(projectedRecord.lastPermissionMode == "plan")
    }

    @Test func futureGenerationRegistryRowRejectsOlderBridgeMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-future-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "future-codex"
        let record: [String: Any] = [
            "sessionId": sessionID,
            "workspaceId": "workspace-a",
            "surfaceId": "surface-a",
            "startedAt": 100.0,
            "updatedAt": 200.0,
        ]
        let recordJSON = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        try registry.apply(provider: "codex", records: [
            CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: 200,
                writerGeneration: CmuxAgentSessionRegistry.currentWriterGeneration + 1,
                json: recordJSON
            ),
        ])
        let bridge = AgentHookSessionRegistryBridge(
            provider: "codex",
            statePath: stateURL.path,
            environment: ["CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path],
            fileManager: .default
        )

        #expect(throws: (any Error).self) {
            try bridge.mutate { state in
                state.sessions[sessionID]?.updatedAt = 300
                return true
            }
        }

        let stored = try #require(registry.snapshot(provider: "codex").records.first)
        #expect(stored.updatedAt == 200)
        #expect(stored.writerGeneration == CmuxAgentSessionRegistry.currentWriterGeneration + 1)
        #expect(stored.json == recordJSON)
    }

    @Test func hookMutationPrunesTheInactiveRecordAddedBeyondTheRetentionCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-retention-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let registry = CmuxAgentSessionRegistry(url: registryURL)
        let now = Date().timeIntervalSince1970
        let records = try (0..<10_000).map { index in
            let sessionID = "retained-\(index)"
            let updatedAt = now + Double(index) / 100_000
            return CmuxAgentSessionRegistry.Record(
                provider: "codex",
                sessionID: sessionID,
                updatedAt: updatedAt,
                json: try JSONSerialization.data(withJSONObject: [
                    "sessionId": sessionID,
                    "workspaceId": "workspace-\(index)",
                    "surfaceId": "surface-\(index)",
                    "startedAt": now,
                    "updatedAt": updatedAt,
                ], options: [.sortedKeys])
            )
        }
        try registry.apply(provider: "codex", records: records)
        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
            ],
            agentName: "codex"
        )

        #expect(try store.upsert(
            sessionId: "newest",
            workspaceId: "workspace-new",
            surfaceId: "surface-new",
            cwd: root.path
        ))

        let snapshot = try registry.snapshot(provider: "codex")
        #expect(snapshot.records.count == 10_000)
        #expect(snapshot.records.contains { $0.sessionID == "newest" })
        #expect(!snapshot.records.contains { $0.sessionID == "retained-0" })
    }

    @Test func acceptedResumeHookClearsHibernationAttemptsAndPreservesFutureFields() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-resume-hook-cleanup-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("codex", isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/yes", toPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let process = Process()
        process.executableURL = executable
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let stateURL = root.appendingPathComponent("codex-hook-sessions.json")
        let registryURL = root.appendingPathComponent(CmuxAgentSessionRegistry.filename)
        let sessionID = "resumed-session"
        let hibernationAttemptID = UUID().uuidString
        let resumeAttemptID = UUID().uuidString
        let restoreAdoptionID = UUID().uuidString
        let original: [String: Any] = [
            "version": 2,
            "sessions": [sessionID: [
                "sessionId": sessionID,
                "workspaceId": "workspace-old",
                "surfaceId": "surface-old",
                "sessionState": "restoring",
                "restoreAuthority": true,
                "cmuxHibernationAttemptId": hibernationAttemptID,
                "cmuxHibernatedAt": 100.0,
                "cmuxHibernationDetached": true,
                "cmuxHibernationResumeAttemptId": resumeAttemptID,
                "cmuxHibernationResumeStartedAt": 200.0,
                "cmuxHibernationResumeFromAttemptId": hibernationAttemptID,
                "cmuxRestoreAdoptionId": restoreAdoptionID,
                "futureWriterField": "preserve-me",
                "startedAt": 100.0,
                "updatedAt": 200.0,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])
            .write(to: stateURL, options: .atomic)

        let store = ClaudeHookSessionStore(
            processEnv: [
                "CMUX_CLAUDE_HOOK_STATE_PATH": stateURL.path,
                "CMUX_AGENT_SESSION_REGISTRY_PATH": registryURL.path,
                "CMUX_RUNTIME_ID": "resumed-runtime",
            ],
            agentName: "codex"
        )
        #expect(try store.upsert(
            sessionId: sessionID,
            workspaceId: "workspace-new",
            surfaceId: "surface-new",
            cwd: root.path,
            pid: Int(process.processIdentifier),
            markActive: true
        ))

        let stored = try #require(
            try CmuxAgentSessionRegistry(url: registryURL)
                .snapshot(provider: "codex")
                .records
                .first { $0.sessionID == sessionID }
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: stored.json) as? [String: Any]
        )
        #expect(object["sessionState"] as? String == "active")
        #expect(object["cmuxHibernationAttemptId"] == nil)
        #expect(object["cmuxHibernatedAt"] == nil)
        #expect(object["cmuxHibernationDetached"] == nil)
        #expect(object["cmuxHibernationResumeAttemptId"] == nil)
        #expect(object["cmuxHibernationResumeStartedAt"] == nil)
        #expect(object["cmuxHibernationResumeFromAttemptId"] == nil)
        #expect(object["cmuxRestoreAdoptionId"] == nil)
        #expect(object["futureWriterField"] as? String == "preserve-me")
    }
}
