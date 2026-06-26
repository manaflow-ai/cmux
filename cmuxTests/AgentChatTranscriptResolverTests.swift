import Foundation
import CMUXAgentLaunch
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

    @Test("Codex fallback ignores a rollout whose session_meta id belongs to another session")
    func codexFallbackRequiresMatchingSessionMetaID() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-codex-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let liveSessionID = "live-wedged-session-actual"
        let liveRollout = try Self.writeCodexRollout(
            home: home,
            sessionID: liveSessionID
        )
        let resolver = AgentChatTranscriptResolver(homeDirectory: home)
        let wedgedRecord = Self.codexRecord(sessionID: "wedged-session")

        #expect(resolver.transcriptPath(for: wedgedRecord) == nil)

        let liveRecord = Self.codexRecord(sessionID: liveSessionID)
        #expect(resolver.transcriptPath(for: liveRecord) == liveRollout.path)
    }

    @Test("Codex fallback fails closed when session_meta id is unavailable")
    func codexFallbackRequiresSessionMetaID() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("agentchat-resolver-codex-missing-meta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: home) }

        let sessionID = "live-wedged-session-actual"
        _ = try Self.writeCodexRollout(
            home: home,
            sessionID: sessionID,
            includeSessionMeta: false
        )
        let resolver = AgentChatTranscriptResolver(homeDirectory: home)

        #expect(resolver.transcriptPath(for: Self.codexRecord(sessionID: sessionID)) == nil)
    }

    @MainActor
    @Test("compaction telemetry preserves mobile session state")
    func compactionTelemetryPreservesMobileSessionState() {
        let registry = AgentChatSessionRegistry()
        let sessionID = "codex-compact-state"
        let start = Date(timeIntervalSince1970: 100)
        var record = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .sessionStart,
                source: "codex",
                receivedAt: start
            )
        )

        #expect(record.state == .idle)

        record = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .preCompact,
                source: "codex",
                receivedAt: Date(timeIntervalSince1970: 101)
            )
        )
        #expect(record.state == .idle)

        record = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .postCompact,
                source: "codex",
                receivedAt: Date(timeIntervalSince1970: 102)
            )
        )
        #expect(record.state == .idle)

        record = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .userPromptSubmit,
                source: "codex",
                receivedAt: Date(timeIntervalSince1970: 103)
            )
        )
        let workingSince: Date
        if case .working(let since) = record.state {
            workingSince = since
        } else {
            Issue.record("expected prompt submit to mark the session working")
            return
        }

        record = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .preCompact,
                source: "codex",
                receivedAt: Date(timeIntervalSince1970: 104)
            )
        )
        #expect(record.state == .working(since: workingSince))

        record = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .postCompact,
                source: "codex",
                receivedAt: Date(timeIntervalSince1970: 105)
            )
        )
        #expect(record.state == .working(since: workingSince))
    }

    private static func codexRecord(sessionID: String) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )
    }

    private static func writeCodexRollout(
        home: URL,
        sessionID: String,
        includeSessionMeta: Bool = true
    ) throws -> URL {
        let dir = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("06", isDirectory: true)
            .appendingPathComponent("26", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rolloutURL = dir.appendingPathComponent(
            "rollout-2026-06-26T00-00-00-\(sessionID).jsonl",
            isDirectory: false
        )
        var lines: [String] = []
        if includeSessionMeta {
            lines.append(#"{"timestamp":"2026-06-26T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/tmp/project"}}"#)
        }
        lines.append(#"{"timestamp":"2026-06-26T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}}"#)
        let contents = lines.joined(separator: "\n")
        try (contents + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)
        return rolloutURL
    }
}
