import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the on-disk Claude transcript presence resolver (U10
/// adapter): transcript-at-the-window's-cwd vs. under a different project dir vs.
/// absent — the three signals that drive verified resume, cwd-mismatch honest
/// recovery (anti-Example-3), and transcript-missing honest recovery.
@Suite struct ClaudeTranscriptPresenceTests {

    private let fm = FileManager.default

    /// Build an isolated fake home; returns its path. Caller seeds transcripts.
    private func makeHome() throws -> String {
        let base = NSTemporaryDirectory() as NSString
        let dir = base.appendingPathComponent("cmux-transcript-test-\(UUID().uuidString)")
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a transcript at `<home>/.claude/projects/<encode(cwd)>/<id>.jsonl`.
    @discardableResult
    private func seedTranscript(home: String, cwd: String, sessionId: String, nested: Bool = false) throws -> String {
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        var dir = (home as NSString).appendingPathComponent(".claude/projects/\(projectDir)")
        if nested {
            dir = ((dir as NSString).appendingPathComponent(sessionId) as NSString)
                .appendingPathComponent("messages")
        }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
        try "{\"type\":\"summary\"}\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    private func seedCodexRollout(
        home: String,
        cwd: String,
        sessionId: String,
        payloadSessionId: String? = nil
    ) throws -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: Date())
        let year = try #require(components.year)
        let month = try #require(components.month)
        let day = try #require(components.day)
        let dir = (home as NSString).appendingPathComponent(
            String(format: ".codex/sessions/%04d/%02d/%02d", year, month, day)
        )
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("rollout-2026-06-25T000000-\(sessionId).jsonl")
        let payloadId = payloadSessionId ?? sessionId
        let escapedCwd = cwd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedId = payloadId.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let transcript = #"{"type":"session_meta","payload":{"id":"\#(escapedId)","cwd":"\#(escapedCwd)"}}"# + "\n"
        try transcript.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func transcriptAtWindowCwdIsFoundAndResolved() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "sess-abc"
        let path = try seedTranscript(home: home, cwd: cwd, sessionId: id)

        let presence = ClaudeTranscriptPresenceResolver.resolve(
            sessionId: id, cwd: cwd, homeDirectory: home
        )
        #expect(presence.existsAtWindowCwd == true)
        #expect(presence.existsElsewhere == false)
        #expect(presence.resolvedPathAtWindowCwd == path)
    }

    @Test func nestedMessagesLayoutIsFound() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "sess-nested"
        try seedTranscript(home: home, cwd: cwd, sessionId: id, nested: true)

        let presence = ClaudeTranscriptPresenceResolver.resolve(sessionId: id, cwd: cwd, homeDirectory: home)
        #expect(presence.existsAtWindowCwd == true)
        #expect(presence.resolvedPathAtWindowCwd?.contains("/messages/") == true)
    }

    @Test func transcriptUnderDifferentCwdIsElsewhereNotAtCwd() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let id = "sess-foreign"
        // Seed under a DIFFERENT cwd than the window's.
        try seedTranscript(home: home, cwd: "/Users/me/other-repo", sessionId: id)

        let presence = ClaudeTranscriptPresenceResolver.resolve(
            sessionId: id, cwd: "/Users/me/repo", homeDirectory: home
        )
        #expect(presence.existsAtWindowCwd == false)
        #expect(presence.existsElsewhere == true) // anti-Example-3 cwd mismatch
        #expect(presence.resolvedPathAtWindowCwd == nil)
    }

    @Test func elsewhereScanCanBeSkippedForLaunchRefresh() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let id = "sess-foreign"
        try seedTranscript(home: home, cwd: "/Users/me/other-repo", sessionId: id)

        let presence = ClaudeTranscriptPresenceResolver.resolve(
            sessionId: id,
            cwd: "/Users/me/repo",
            searchElsewhere: false,
            homeDirectory: home
        )

        #expect(presence.existsAtWindowCwd == false)
        #expect(presence.existsElsewhere == false)
        #expect(presence.searchedElsewhere == false)
    }

    @Test func noTranscriptAnywhereIsAbsent() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let presence = ClaudeTranscriptPresenceResolver.resolve(
            sessionId: "sess-missing", cwd: "/Users/me/repo", homeDirectory: home
        )
        #expect(presence == .absent)
    }

    @Test func emptyOrUnsafeSessionIdIsAbsent() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        #expect(ClaudeTranscriptPresenceResolver.resolve(sessionId: nil, cwd: "/x", homeDirectory: home) == .absent)
        #expect(ClaudeTranscriptPresenceResolver.resolve(sessionId: "  ", cwd: "/x", homeDirectory: home) == .absent)
        #expect(ClaudeTranscriptPresenceResolver.resolve(sessionId: "../escape", cwd: "/x", homeDirectory: home) == .absent)
        #expect(ClaudeTranscriptPresenceResolver.resolve(sessionId: "a/b", cwd: "/x", homeDirectory: home) == .absent)
    }

    @Test func emptyCwdIsAbsent() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        #expect(ClaudeTranscriptPresenceResolver.resolve(sessionId: "sess", cwd: nil, homeDirectory: home) == .absent)
    }

    @Test func configDirOverrideRootIsSearched() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "sess-override"
        // Seed under a custom config dir, NOT ~/.claude.
        let customRoot = (home as NSString).appendingPathComponent("custom-claude")
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let dir = (customRoot as NSString).appendingPathComponent("projects/\(projectDir)")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(id).jsonl")
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)

        let presence = ClaudeTranscriptPresenceResolver.resolve(
            sessionId: id, cwd: cwd, configDirOverride: customRoot, homeDirectory: home
        )
        #expect(presence.existsAtWindowCwd == true)
    }

    @Test func configDirOverrideDoesNotFallbackToDefaultClaudeRoot() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "sess-default-only"
        try seedTranscript(home: home, cwd: cwd, sessionId: id)
        let customRoot = (home as NSString).appendingPathComponent("custom-claude")

        let presence = ClaudeTranscriptPresenceResolver.resolve(
            sessionId: id,
            cwd: cwd,
            configDirOverride: customRoot,
            homeDirectory: home
        )

        #expect(presence == .absent)
    }

    @Test func emptyTranscriptFileIsNotCounted() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "sess-empty"
        let projectDir = RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd)
        let dir = (home as NSString).appendingPathComponent(".claude/projects/\(projectDir)")
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(id).jsonl")
        try "".write(toFile: path, atomically: true, encoding: .utf8) // zero bytes

        let presence = ClaudeTranscriptPresenceResolver.resolve(sessionId: id, cwd: cwd, homeDirectory: home)
        #expect(presence.existsAtWindowCwd == false)
    }

    @Test func codexRolloutAtWindowCwdIsFoundAndResolved() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "codex-session-abc"
        let path = try seedCodexRollout(home: home, cwd: cwd, sessionId: id)

        let presence = CodexTranscriptPresenceResolver.resolve(
            sessionId: id,
            cwd: cwd,
            homeDirectory: home
        )

        #expect(presence.existsAtWindowCwd == true)
        #expect(presence.existsElsewhere == false)
        #expect(presence.resolvedPathAtWindowCwd == path)
    }

    @Test func codexRestoreTimeLookupSkipsHistoricalRolloutScan() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "codex-session-restore-time"
        try seedCodexRollout(home: home, cwd: cwd, sessionId: id)

        let presence = CodexTranscriptPresenceResolver.resolve(
            sessionId: id,
            cwd: cwd,
            searchElsewhere: false,
            homeDirectory: home
        )

        #expect(presence == .absent)
        #expect(presence.searchedElsewhere == false)
    }

    @Test func codexRestoreTimePlaceholderRequiresFullRecoveryVerification() {
        let facts = ResumeBindingFacts(
            hasBinding: true,
            agentKind: .codex,
            sessionId: "codex-session-restore-time",
            resumeCommandConstructable: true,
            transcriptExistsAtWindowCwd: false,
            transcriptExistsElsewhere: false
        )
        let verification = CrashRecoveryVerification(
            facts: facts,
            presence: .absent,
            fingerprint: CrashRecoveryVerificationFingerprint(
                kind: .codex,
                sessionId: "codex-session-restore-time",
                cwd: "/Users/me/repo",
                claudeConfigDir: nil,
                codexHome: nil
            )
        )

        #expect(verification.needsFullRecoveryVerification)
    }

    @Test func codexRolloutUnderDifferentCwdIsElsewhereNotAtCwd() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let id = "codex-session-foreign"
        try seedCodexRollout(home: home, cwd: "/Users/me/other-repo", sessionId: id)

        let presence = CodexTranscriptPresenceResolver.resolve(
            sessionId: id,
            cwd: "/Users/me/repo",
            homeDirectory: home
        )

        #expect(presence.existsAtWindowCwd == false)
        #expect(presence.existsElsewhere == true)
        #expect(presence.resolvedPathAtWindowCwd == nil)
    }

    @Test func codexRolloutRequiresExactSessionMetaId() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        try seedCodexRollout(
            home: home,
            cwd: cwd,
            sessionId: "codex-session-requested",
            payloadSessionId: "codex-session-other"
        )

        let presence = CodexTranscriptPresenceResolver.resolve(
            sessionId: "codex-session-requested",
            cwd: cwd,
            homeDirectory: home
        )

        #expect(presence == .absent)
    }

    @Test func codexHomeOverrideDoesNotFallbackToDefaultRoot() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cwd = "/Users/me/repo"
        let id = "codex-session-default-only"
        try seedCodexRollout(home: home, cwd: cwd, sessionId: id)
        let customRoot = (home as NSString).appendingPathComponent("custom-codex")

        let presence = CodexTranscriptPresenceResolver.resolve(
            sessionId: id,
            cwd: cwd,
            codexHomeOverride: customRoot,
            homeDirectory: home
        )

        #expect(presence == .absent)
    }
}
