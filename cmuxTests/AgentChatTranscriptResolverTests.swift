import Foundation
import CMUXAgentLaunch
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite struct AgentChatTranscriptResolverTests {
    @Test("Codex sessions without hook-recorded transcript paths fail closed")
    func codexWithoutRecordedTranscriptPathFailsClosed() throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex-no-recorded-path")
        defer { try? fm.removeItem(at: home) }

        let sessionID = "codex-session-with-rollout-on-disk"
        _ = try Self.writeCodexRollout(
            home: home,
            sessionID: sessionID
        )
        let resolver = Self.codexResolver(home: home)

        #expect(resolver.transcriptPath(for: Self.codexRecord(sessionID: sessionID)) == nil)
    }

    @Test("Codex uses the hook-recorded transcript path when it exists")
    func codexUsesHookRecordedTranscriptPath() throws {
        let fm = FileManager.default
        let home = Self.makeTemporaryHome("agentchat-resolver-codex-recorded-path")
        defer { try? fm.removeItem(at: home) }

        let sessionID = "codex-session-with-recorded-path"
        let rollout = try Self.writeCodexRollout(
            home: home,
            sessionID: "different-session-in-file"
        )
        let resolver = Self.codexResolver(home: home)
        let record = Self.codexRecord(
            sessionID: sessionID,
            transcriptPath: rollout.path
        )

        #expect(Self.resolvedPathsMatch(resolver.transcriptPath(for: record), rollout))
    }

    private static func codexRecord(
        sessionID: String,
        transcriptPath: String? = nil
    ) -> AgentChatSessionRecord {
        AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .codex,
            workspaceID: nil,
            surfaceID: nil,
            workingDirectory: nil,
            transcriptPath: transcriptPath,
            state: .idle,
            lastActivityAt: Date(timeIntervalSince1970: 0),
            title: nil,
            pid: nil
        )
    }

    private static func codexResolver(home: URL) -> AgentChatTranscriptResolver {
        AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: [:]
        )
    }

    /// Unique temp home for a Codex resolver test. Depending on the runner,
    /// `temporaryDirectory` reports the path under `/var` or `/private/var`;
    /// tests compare resolved real paths (`resolvedPathsMatch`) so the surface
    /// representation does not matter.
    private static func makeTemporaryHome(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Canonicalizes an existing path with `realpath(3)`. `URL`'s
    /// `resolvingSymlinksInPath()` does NOT resolve `/var` -> `/private/var` on
    /// some macOS versions, but `realpath` reliably resolves both spellings, so
    /// a resolver-returned `/private/var` output and a test's `/var` rollout path
    /// compare equal regardless of which form `temporaryDirectory` reports.
    private static func canonicalExistingPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when a resolver-returned path and the expected rollout URL refer to
    /// the same on-disk file, compared by fully symlink-resolved real paths.
    private static func resolvedPathsMatch(_ actual: String?, _ expected: URL) -> Bool {
        guard let actual else { return false }
        return canonicalExistingPath(actual) == canonicalExistingPath(expected.path)
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

}
