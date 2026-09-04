import Foundation
import Testing
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Feed jump resolution")
struct FeedJumpResolverTests {
    @Test func resolvesVersionedHermesAgentAndHyphenatedSession() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeStore(
            home: home,
            agent: "hermes-agent",
            sessions: ["session-with-hyphens": [
                "workspaceId": "workspace-1",
                "surfaceId": "surface-1",
            ]]
        )
        let workstreamID = try #require(
            FeedWorkstreamIdentifier(agentID: "hermes-agent", sessionID: "session-with-hyphens")?.rawValue
        )

        #expect(
            FeedJumpResolver.resolve(workstreamID, homeDirectory: home)
                == FeedJumpResolver.Target(workspaceId: "workspace-1", surfaceId: "surface-1")
        )
    }

    @Test func resolvesLegacyHyphenatedAgentAndSession() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeStore(
            home: home,
            agent: "hermes-agent",
            sessions: ["session-with-hyphens": [
                "workspaceId": "workspace-legacy",
                "surfaceId": "surface-legacy",
            ]]
        )

        #expect(
            FeedJumpResolver.resolve(
                "hermes-agent-session-with-hyphens",
                homeDirectory: home
            ) == FeedJumpResolver.Target(
                workspaceId: "workspace-legacy",
                surfaceId: "surface-legacy"
            )
        )
    }

    @Test func failsClosedWhenLegacySplitsResolveConflictingTargets() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeStore(
            home: home,
            agent: "hermes",
            sessions: ["agent-session": [
                "workspaceId": "workspace-a",
                "surfaceId": "surface-a",
            ]]
        )
        try writeStore(
            home: home,
            agent: "hermes-agent",
            sessions: ["session": [
                "workspaceId": "workspace-b",
                "surfaceId": "surface-b",
            ]]
        )

        #expect(
            FeedJumpResolver.resolve("hermes-agent-session", homeDirectory: home) == nil
        )
    }

    @Test(arguments: ["", "not-an-id", "cmux-feed-v1::", "../-session"])
    func rejectsMalformedOrUnsafeIDs(_ workstreamID: String) throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(FeedJumpResolver.resolve(workstreamID, homeDirectory: home) == nil)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-feed-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".cmuxterm", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func writeStore(
        home: URL,
        agent: String,
        sessions: [String: [String: String]]
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: ["sessions": sessions])
        try data.write(
            to: home
                .appendingPathComponent(".cmuxterm", isDirectory: true)
                .appendingPathComponent("\(agent)-hook-sessions.json")
        )
    }
}
