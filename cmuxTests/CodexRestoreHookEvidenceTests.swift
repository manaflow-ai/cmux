import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CodexRestoreHookEvidenceTests {
    @Test("A hook-only wrapper restores ownership without a process census")
    func targetedHookOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(sessionID: fixture.sessionID)
        let reader = CodexRestoreHookEvidence(storeURL: fixture.url)
        let identity = fixture.identity
        let result = await reader.load(sessionID: fixture.sessionID) { _ in identity }
        #expect(result.isComplete)
        #expect(result.owner?.sessionID == fixture.sessionID)
        #expect(result.owner?.processIdentity == identity)
    }

    @Test("Cached hook bytes cannot make a dead or reused PID own the conversation", arguments: [false, true])
    func cachedRecordRevalidatesGeneration(reused: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(sessionID: fixture.sessionID)
        let reader = CodexRestoreHookEvidence(storeURL: fixture.url)
        let identity = fixture.identity
        let initial = await reader.load(sessionID: fixture.sessionID) { _ in identity }
        #expect(initial.owner != nil)
        let current = reused ? AgentPIDProcessIdentity(
            pid: identity.pid, startSeconds: identity.startSeconds + 1,
            startMicroseconds: identity.startMicroseconds
        ) : nil
        let result = await reader.load(sessionID: fixture.sessionID) { _ in current }
        #expect(result.isComplete)
        #expect(result.owner == nil)
    }

    @Test("Unreadable hook evidence recovers after an atomic rewrite")
    func corruptStoreRecovers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{".utf8).write(to: fixture.url)
        let reader = CodexRestoreHookEvidence(storeURL: fixture.url)
        let identity = fixture.identity
        let corrupt = await reader.load(sessionID: fixture.sessionID) { _ in identity }
        #expect(!corrupt.isComplete)
        try fixture.write(sessionID: fixture.sessionID)
        let result = await reader.load(sessionID: fixture.sessionID) { _ in identity }
        #expect(result.isComplete)
        #expect(result.owner?.sessionID == fixture.sessionID)
    }

    @Test("A FIFO cannot hang the targeted ownership reader")
    func nonregularStoreIsUnavailable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(mkfifo(fixture.url.path, S_IRUSR | S_IWUSR) == 0)
        let result = await CodexRestoreHookEvidence(storeURL: fixture.url).load(
            sessionID: fixture.sessionID, processIdentity: { _ in nil }
        )
        #expect(!result.isComplete)
    }

    @Test("A missing store after reboot contains no surviving owner")
    func missingStore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = await CodexRestoreHookEvidence(storeURL: fixture.url).load(
            sessionID: fixture.sessionID, processIdentity: { _ in nil }
        )
        #expect(result.isComplete)
        #expect(result.owner == nil)
    }

    private struct Fixture {
        let directory: URL
        let sessionID = UUID().uuidString.lowercased()
        let identity = AgentPIDProcessIdentity(pid: 1234, startSeconds: 100, startMicroseconds: 1)
        var url: URL { directory.appendingPathComponent("codex-hook-sessions.json") }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(sessionID: String) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "version": 1,
                "sessions": [sessionID: [
                    "sessionId": sessionID, "workspaceId": UUID().uuidString,
                    "surfaceId": UUID().uuidString, "updatedAt": 1_800_000_000,
                    "pid": Int(identity.pid), "pidStartSeconds": identity.startSeconds,
                    "pidStartMicroseconds": identity.startMicroseconds
                ]]
            ])
            try data.write(to: url, options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
