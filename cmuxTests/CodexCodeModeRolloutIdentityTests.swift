import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CodexCodeModeRolloutIdentityTests {
    private static let primaryID = "019f8a6d-e3af-7882-9470-c5824a40ec86"
    private static let childID = "019f8a6d-f2c9-7ad0-9df4-4c1d28f04e3e"
    private static let grandchildID = "019f8a6d-fa11-7ad0-9df4-4c1d28f04e3e"

    @Test
    func codeModeGuardianRolloutResolvesToOpenParent() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let primary = try writeRollout(directory: fixture.rollouts, sessionID: Self.primaryID)
        let child = try writeRollout(
            directory: fixture.rollouts,
            sessionID: Self.childID,
            parentThreadID: Self.primaryID,
            trailingBytes: 4 * 1_024 * 1_024 + 1
        )

        let session = try #require(observedSession(
            openRollouts: [child, primary],
            preferredSessionID: nil
        ))

        #expect(session.sessionID == Self.primaryID)
        #expect(session.transcriptPath == primary)
    }

    @Test
    func codeModeRolloutChainResolvesToRootParent() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let primary = try writeRollout(directory: fixture.rollouts, sessionID: Self.primaryID)
        let child = try writeRollout(
            directory: fixture.rollouts,
            sessionID: Self.childID,
            parentThreadID: Self.primaryID
        )
        let grandchild = try writeRollout(
            directory: fixture.rollouts,
            sessionID: Self.grandchildID,
            parentThreadID: Self.childID
        )

        let session = try #require(observedSession(
            openRollouts: [grandchild, child, primary],
            preferredSessionID: nil
        ))

        #expect(session.sessionID == Self.primaryID)
        #expect(session.transcriptPath == primary)
    }

    @Test
    func canonicalSessionIDResolvesAcrossClosedIntermediateRollout() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let primary = try writeRollout(directory: fixture.rollouts, sessionID: Self.primaryID)
        let grandchild = try writeRollout(
            directory: fixture.rollouts,
            sessionID: Self.grandchildID,
            canonicalSessionID: Self.primaryID,
            parentThreadID: Self.childID
        )

        let session = try #require(observedSession(
            openRollouts: [grandchild, primary],
            preferredSessionID: nil
        ))

        #expect(session.sessionID == Self.primaryID)
        #expect(session.transcriptPath == primary)
    }

    @Test
    func partialMetadataFallsBackToStoredSurfaceBinding() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let primary = try writeRollout(directory: fixture.rollouts, sessionID: Self.primaryID)
        let partial = try writePartialRollout(directory: fixture.rollouts, sessionID: Self.childID)

        let session = try #require(observedSession(
            openRollouts: [partial, primary],
            preferredSessionID: Self.primaryID
        ))

        #expect(session.sessionID == Self.primaryID)
        #expect(session.transcriptPath == primary)
    }

    @Test
    func ambiguousPartialMetadataDoesNotChooseDescriptorOrder() throws {
        let fixture = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let child = try writePartialRollout(directory: fixture.rollouts, sessionID: Self.childID)
        let grandchild = try writePartialRollout(
            directory: fixture.rollouts,
            sessionID: Self.grandchildID
        )

        #expect(observedSession(
            openRollouts: [grandchild, child],
            preferredSessionID: nil
        ) == nil)
    }

    private func observedSession(
        openRollouts: [String],
        preferredSessionID: String?
    ) -> ObservedAgentSession? {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let snapshot = CmuxTopProcessSnapshot(
            processes: [CmuxTopProcessInfo(
                pid: 202,
                parentPID: 1,
                name: "codex",
                path: "/opt/homebrew/bin/codex",
                ttyDevice: nil,
                cmuxWorkspaceID: workspaceID,
                cmuxSurfaceID: surfaceID,
                cmuxAttributionReason: "test",
                processGroupID: 202,
                terminalProcessGroupID: 202,
                cpuPercent: 0,
                residentBytes: 1,
                virtualBytes: 1,
                threadCount: 1
            )],
            sampledAt: Date(timeIntervalSince1970: 200),
            includesProcessDetails: true
        )
        let preferred = preferredSessionID.map { [surfaceID.uuidString: $0] } ?? [:]
        return AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            preferredCodexSessionIDBySurfaceID: preferred,
            processArgumentsAndEnvironment: { _ in nil },
            codexRolloutPaths: { pid in pid == 202 ? openRollouts : [] }
        ).first
    }

    private func makeFixtureDirectory() throws -> (root: URL, rollouts: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-code-mode-\(UUID().uuidString)", isDirectory: true)
        let rollouts = root
            .appendingPathComponent(".codex/sessions/2026/07/22", isDirectory: true)
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        return (root, rollouts)
    }

    private func writeRollout(
        directory: URL,
        sessionID: String,
        canonicalSessionID: String? = nil,
        parentThreadID: String? = nil,
        trailingBytes: Int = 0
    ) throws -> String {
        var payload: [String: Any] = [
            "id": sessionID,
            "cwd": "/Users/example/project",
            "originator": "codex-tui",
        ]
        if let parentThreadID {
            payload["session_id"] = canonicalSessionID ?? parentThreadID
            payload["parent_thread_id"] = parentThreadID
            payload["source"] = ["subagent": ["other": "guardian"]]
            payload["multi_agent_version"] = "1"
        }
        let line: [String: Any] = [
            "timestamp": "2026-07-22T12:00:00.000Z",
            "type": "session_meta",
            "payload": payload,
        ]
        var data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        data.append(0x0A)
        data.append(Data(repeating: 0x20, count: trailingBytes))
        let url = directory.appendingPathComponent(
            "rollout-2026-07-22T12-00-00-\(sessionID).jsonl",
            isDirectory: false
        )
        try data.write(to: url, options: .atomic)
        return url.path
    }

    private func writePartialRollout(directory: URL, sessionID: String) throws -> String {
        let url = directory.appendingPathComponent(
            "rollout-2026-07-22T12-00-01-\(sessionID).jsonl",
            isDirectory: false
        )
        try Data(#"{"type":"session_meta","payload":{"id":"partial""#.utf8)
            .write(to: url, options: .atomic)
        return url.path
    }
}
