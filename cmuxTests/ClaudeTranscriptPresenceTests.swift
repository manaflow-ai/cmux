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
        if nested { dir = (dir as NSString).appendingPathComponent("messages") }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
        try "{\"type\":\"summary\"}\n".write(toFile: path, atomically: true, encoding: .utf8)
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
}
