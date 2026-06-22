import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Unit tests for the title-detected adoption transcript resolver. These cover
/// the subtle, silently-regressing cases that confounded earlier debugging:
/// the cwd-collision disambiguation (excludingSessionIDs) and the $HOME
/// junk-drawer guard. The resolver takes an injectable home directory, so the
/// whole thing runs against a temp filesystem with no app launch.
@Suite struct AgentChatTranscriptResolverTests {
    /// Creates a temp home with a claude project dir for `cwd`, writes the
    /// given session-id `.jsonl` files in ascending mtime order, and returns
    /// the resolver bound to that home plus the cwd used.
    private static func fixture(
        sessionsOldestFirst: [String],
        cwdName: String = "proj"
    ) throws -> (resolver: AgentChatTranscriptResolver, home: URL, cwd: String) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent(cwdName, isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let projectDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        // Stamp ascending modification dates so "newest" is deterministic
        // without relying on write-order timing.
        for (index, sessionID) in sessionsOldestFirst.enumerated() {
            let file = projectDir.appendingPathComponent("\(sessionID).jsonl")
            try Data("{}\n".utf8).write(to: file)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index))],
                ofItemAtPath: file.path
            )
        }
        return (AgentChatTranscriptResolver(homeDirectory: home), home, cwd.path)
    }

    @Test("returns the newest transcript when nothing is claimed")
    func newestUnclaimed() throws {
        let (resolver, _, cwd) = try Self.fixture(sessionsOldestFirst: ["older", "newer"])
        let result = resolver.newestClaudeTranscript(workingDirectory: cwd)
        #expect(result?.sessionID == "newer")
    }

    @Test("skips a claimed session so a same-dir second agent gets a distinct transcript")
    func excludesClaimedSession() throws {
        let (resolver, _, cwd) = try Self.fixture(sessionsOldestFirst: ["older", "newer"])
        // The first surface already adopted "newer"; the second must resolve
        // to "older" rather than colliding on the same file (or getting nil).
        let result = resolver.newestClaudeTranscript(
            workingDirectory: cwd,
            excludingSessionIDs: ["newer"]
        )
        #expect(result?.sessionID == "older")
    }

    @Test("returns nil when every transcript is already claimed")
    func allClaimedYieldsNil() throws {
        let (resolver, _, cwd) = try Self.fixture(sessionsOldestFirst: ["a", "b"])
        let result = resolver.newestClaudeTranscript(
            workingDirectory: cwd,
            excludingSessionIDs: ["a", "b"]
        )
        #expect(result == nil)
    }

    @Test("refuses to adopt from the home directory junk drawer")
    func homeDirectoryIsGuarded() throws {
        // A claude rooted directly at $HOME would match the home project dir,
        // which accumulates every home-rooted conversation; newest-by-mtime is
        // almost never this terminal's session, so the resolver returns nil.
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-home-\(UUID().uuidString)", isDirectory: true)
        let projectDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(home.path),
                isDirectory: true
            )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: projectDir.appendingPathComponent("home-sess.jsonl"))

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        #expect(resolver.newestClaudeTranscript(workingDirectory: home.path) == nil)
    }

    @Test("/private-toggled cwd resolves a /private-encoded project dir")
    func privatePrefixToggle() throws {
        // Simulate claude encoding the /private form while the panel cwd is the
        // bare form: create the project dir under the /private-prefixed path and
        // resolve from the non-prefixed one.
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-priv-\(UUID().uuidString)", isDirectory: true)
        let bareCwd = "/tmp/agentchat-resolver-\(UUID().uuidString)"
        let projectDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir("/private" + bareCwd),
                isDirectory: true
            )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: projectDir.appendingPathComponent("priv-sess.jsonl"))

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        #expect(resolver.newestClaudeTranscript(workingDirectory: bareCwd)?.sessionID == "priv-sess")
    }

    @Test("preferred cwd untitled transcript beats lower-priority exact-title alias")
    func preferredCwdUntitledBeatsLowerRankExactTitle() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-rank-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/agentchat-resolver-rank-\(UUID().uuidString)"
        let preferredDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd),
                isDirectory: true
            )
        let lowerRankDir = home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir("/private" + cwd),
                isDirectory: true
            )
        try fm.createDirectory(at: preferredDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: lowerRankDir, withIntermediateDirectories: true)

        let freshUntitled = preferredDir.appendingPathComponent("fresh-untitled.jsonl")
        try Data("{}\n".utf8).write(to: freshUntitled)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_001)],
            ofItemAtPath: freshUntitled.path
        )
        let staleExact = lowerRankDir.appendingPathComponent("stale-exact.jsonl")
        try Data("{\"type\":\"ai-title\",\"aiTitle\":\"Target\"}\n".utf8).write(to: staleExact)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)],
            ofItemAtPath: staleExact.path
        )

        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let result = resolver.newestClaudeTranscript(workingDirectory: cwd, titleHint: "Target")
        #expect(result?.sessionID == "fresh-untitled")
    }

    @MainActor
    @Test("hook session keeps matching provisional transcript path")
    func hookSessionKeepsMatchingProvisionalTranscriptPath() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-service-transfer-\(UUID().uuidString)", isDirectory: true)
        let cwd = home.appendingPathComponent("proj", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)

        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let hookSessionID = "real-session"
        let hookStore = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        try fm.createDirectory(at: hookStore.deletingLastPathComponent(), withIntermediateDirectories: true)
        let hookStorePayload: [String: Any] = [
            "sessions": [
                hookSessionID: [
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "cwd": cwd.path,
                    "updatedAt": 2_000_031,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: hookStorePayload).write(to: hookStore)

        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(
                hookStore: AgentChatHookSessionStore(homeDirectory: home)
            ),
            resolver: AgentChatTranscriptResolver(homeDirectory: home)
        )
        #expect(service.adoptDetectedClaudeSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            workingDirectory: cwd.path,
            titleHint: "Claude Code"
        ))
        let provisional = try #require(service.sessionRecords(workspaceID: workspaceID).first)
        service.cancelTranscriptResolution(surfaceID: surfaceID)

        let transcript = home.appendingPathComponent("\(hookSessionID).jsonl", isDirectory: false)
        try Data("{}\n".utf8).write(to: transcript)
        let key: AgentChatTranscriptService.ClaudeTranscriptResolutionKey = (
            targetSessionID: provisional.sessionID,
            workingDirectory: cwd.path,
            claimedSessionIDs: [],
            titleKey: nil,
            forceScan: false
        )
        service.transcriptResolutionKeys[surfaceID] = key
        service.applyClaudeTranscriptResolution(
            (sessionID: hookSessionID, path: transcript.path),
            key: key,
            workspaceID: workspaceID,
            workingDirectory: cwd.path,
            surfaceID: surfaceID,
            titleHint: nil
        )

        let sessionStart = Date(timeIntervalSince1970: 2_000_000)
        service.noteHookEvent(WorkstreamEvent(
            sessionId: "claude-\(hookSessionID)",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            cwd: cwd.path,
            receivedAt: sessionStart
        ))
        service.noteHookEvent(WorkstreamEvent(
            sessionId: "claude-\(hookSessionID)",
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: workspaceID,
            cwd: cwd.path,
            receivedAt: sessionStart.addingTimeInterval(31)
        ))

        #expect(service.sessionRecord(sessionID: provisional.sessionID) == nil)
        let real = try #require(service.sessionRecord(sessionID: hookSessionID))
        #expect(real.transcriptPath == transcript.path)
    }
}
