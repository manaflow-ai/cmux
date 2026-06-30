import Foundation
import CMUXAgentLaunch
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite struct AgentChatTranscriptResolverTests {
    @Test("Codex fallback ignores a rollout whose session_meta id belongs to another session")
    func codexFallbackRequiresMatchingSessionMetaID() throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex")
        defer { try? fm.removeItem(at: home) }

        let liveSessionID = "live-wedged-session-actual"
        let liveRollout = try Self.writeCodexRollout(
            home: home,
            sessionID: liveSessionID
        )
        let resolver = Self.codexResolver(home: home)
        let wedgedRecord = Self.codexRecord(sessionID: "wedged-session")

        #expect(resolver.transcriptPath(for: wedgedRecord) == nil)

        let liveRecord = Self.codexRecord(sessionID: liveSessionID)
        #expect(resolver.transcriptPath(for: liveRecord) == liveRollout.path)
    }

    @Test("Codex fallback fails closed when session_meta id is unavailable")
    func codexFallbackRequiresSessionMetaID() throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex-missing-meta")
        defer { try? fm.removeItem(at: home) }

        let sessionID = "live-wedged-session-actual"
        _ = try Self.writeCodexRollout(
            home: home,
            sessionID: sessionID,
            includeSessionMeta: false
        )
        let resolver = Self.codexResolver(home: home)

        #expect(resolver.transcriptPath(for: Self.codexRecord(sessionID: sessionID)) == nil)
    }

    @Test("Codex fallback trusts session_meta even when the filename lacks the session id")
    func codexFallbackUsesSessionMetaAsAuthority() throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex-meta-authority")
        defer { try? fm.removeItem(at: home) }

        let sessionID = "confirmed-session-from-meta"
        let rollout = try Self.writeCodexRollout(
            home: home,
            sessionID: sessionID,
            filenameSessionID: "opaque-rollout-name"
        )
        let resolver = Self.codexResolver(home: home)

        #expect(resolver.transcriptPath(for: Self.codexRecord(sessionID: sessionID)) == rollout.path)
    }

    @Test("Codex fallback only scans bounded recent day directories")
    func codexFallbackScansOnlyRecentDayDirectories() throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex-recent")
        defer { try? fm.removeItem(at: home) }

        let staleSessionID = "old-session-with-valid-meta"
        _ = try Self.writeCodexRollout(
            home: home,
            sessionID: staleSessionID,
            year: 2026,
            month: 5,
            day: 1
        )
        let recentSessionID = "recent-session-with-valid-meta"
        let recentRollout = try Self.writeCodexRollout(
            home: home,
            sessionID: recentSessionID,
            year: 2026,
            month: 6,
            day: 26
        )
        let resolver = Self.codexResolver(home: home)

        #expect(resolver.transcriptPath(for: Self.codexRecord(sessionID: staleSessionID)) == nil)
        #expect(resolver.transcriptPath(for: Self.codexRecord(sessionID: recentSessionID)) == recentRollout.path)
    }

    @MainActor
    @Test("Codex history resolves fallback transcript for ended sessions")
    func codexHistoryResolvesFallbackForEndedSession() async throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex-ended")
        defer { try? fm.removeItem(at: home) }

        let sessionID = "ended-session-with-valid-meta"
        let rollout = try Self.writeCodexRollout(home: home, sessionID: sessionID)
        let registry = AgentChatSessionRegistry()
        _ = registry.noteHookEvent(
            WorkstreamEvent(
                sessionId: sessionID,
                hookEventName: .sessionStart,
                source: "codex",
                receivedAt: Date(timeIntervalSince1970: 1)
            )
        )
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
            record.transcriptPath = nil
        }
        let service = AgentChatTranscriptService(
            registry: registry,
            resolver: Self.codexResolver(home: home)
        )

        let page = await service.history(sessionID: sessionID, beforeSeq: nil, limit: 20)

        #expect(page != nil)
        #expect(service.sessionRecord(sessionID: sessionID)?.transcriptPath == rollout.path)
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

    private static func codexResolver(home: URL) -> AgentChatTranscriptResolver {
        AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: [:],
            now: { Self.utcDate(year: 2026, month: 6, day: 26) }
        )
    }

    /// Unique temp home for a Codex resolver test, with symlinks resolved up
    /// front. The resolver returns paths from `contentsOfDirectory`, which on
    /// some macOS versions canonicalizes `/var` -> `/private/var`; resolving the
    /// home here keeps the paths the resolver returns equal to the rollout paths
    /// the test writes, so the exact-path `#expect` is not a macOS-version flake.
    private static func makeTemporaryHome(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    private static func writeCodexRollout(
        home: URL,
        sessionID: String,
        includeSessionMeta: Bool = true,
        filenameSessionID: String? = nil,
        year: Int = 2026,
        month: Int = 6,
        day: Int = 26
    ) throws -> URL {
        let dir = home
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dateStamp = String(format: "%04d-%02d-%02d", year, month, day)
        let rolloutURL = dir.appendingPathComponent(
            "rollout-\(dateStamp)T00-00-00-\(filenameSessionID ?? sessionID).jsonl",
            isDirectory: false
        )
        var lines: [String] = []
        if includeSessionMeta {
            lines.append(#"{"timestamp":"\#(dateStamp)T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","cwd":"/tmp/project"}}"#)
        }
        lines.append(#"{"timestamp":"\#(dateStamp)T00:00:01.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}}"#)
        let contents = lines.joined(separator: "\n")
        try (contents + "\n").write(to: rolloutURL, atomically: true, encoding: .utf8)
        return rolloutURL
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        )) ?? Date(timeIntervalSince1970: 0)
    }
}
