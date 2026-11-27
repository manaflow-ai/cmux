import CmuxAgentSessionStore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Vault labels a Claude Code session with the name the user gave it. Claude
/// Code records that name in the transcript as a `custom-title` line, and
/// writes a new line each time the name changes, so the most recent one is
/// the current name. Sessions without a name keep their first-prompt label.
@Suite(.serialized)
struct VaultClaudeCustomTitleTests {
    @Test
    func namedSessionIsLabeledWithItsLatestName() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        try fixture.writeTranscript(
            sessionId: "named",
            lines: [
                fixture.userLine("/login"),
                fixture.assistantLine("Signed in."),
                fixture.customTitleLine("First draft name"),
                fixture.userLine("Now fix the billing export"),
                fixture.customTitleLine("Billing export fix"),
            ]
        )

        let entry = try await fixture.loadEntry(sessionId: "named")

        #expect(entry.title == "Billing export fix")
        #expect(entry.displayTitle == "Billing export fix")
    }

    @Test
    func unnamedSessionKeepsItsFirstPromptLabel() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        try fixture.writeTranscript(
            sessionId: "unnamed",
            lines: [
                fixture.userLine("Fix the billing export"),
                fixture.assistantLine("On it."),
            ]
        )

        let entry = try await fixture.loadEntry(sessionId: "unnamed")

        #expect(entry.title == "Fix the billing export")
    }

    @Test
    func nameRecordedPastTheHeadWindowStillLabelsTheSession() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        let padding = String(repeating: "x", count: 2_000)
        var lines = [fixture.userLine("This session is being continued from a previous conversation")]
        let paddedLineCount = (SessionIndexStore.headByteCap / padding.utf8.count) + 4
        for _ in 0..<paddedLineCount {
            lines.append(fixture.assistantLine(padding))
        }
        lines.append(fixture.customTitleLine("Deep in the transcript"))
        try fixture.writeTranscript(sessionId: "deep", lines: lines)

        let entry = try await fixture.loadEntry(sessionId: "deep")

        #expect(entry.title == "Deep in the transcript")
    }

    @Test
    func nameRecordedBetweenTheWindowsStillLabelsTheSession() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        let padding = String(repeating: "x", count: 2_000)
        var lines = [fixture.userLine("/login")]
        for _ in 0..<((SessionIndexStore.headByteCap / padding.utf8.count) + 4) {
            lines.append(fixture.assistantLine(padding))
        }
        lines.append(fixture.customTitleLine("Named a few turns in"))
        for _ in 0..<((SessionIndexStore.tailByteCap / padding.utf8.count) + 4) {
            lines.append(fixture.assistantLine(padding))
        }
        try fixture.writeTranscript(sessionId: "between", lines: lines)

        let entry = try await fixture.loadEntry(sessionId: "between")

        #expect(entry.title == "Named a few turns in")
    }

    @Test
    func renameBetweenTheWindowsOutranksTheNameInTheHead() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        let padding = String(repeating: "x", count: 2_000)
        var lines = [
            fixture.userLine("Fix the billing export"),
            fixture.customTitleLine("Early name"),
        ]
        for _ in 0..<((SessionIndexStore.headByteCap / padding.utf8.count) + 4) {
            lines.append(fixture.assistantLine(padding))
        }
        lines.append(fixture.customTitleLine("Later name"))
        for _ in 0..<((SessionIndexStore.tailByteCap / padding.utf8.count) + 4) {
            lines.append(fixture.assistantLine(padding))
        }
        try fixture.writeTranscript(sessionId: "renamed", lines: lines)

        let entry = try await fixture.loadEntry(sessionId: "renamed")

        #expect(entry.title == "Later name")
    }

    @Test
    func nameClearedBetweenTheWindowsFallsBackToTheFirstPrompt() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        let padding = String(repeating: "x", count: 2_000)
        var lines = [
            fixture.userLine("Fix the billing export"),
            fixture.customTitleLine("Early name"),
        ]
        for _ in 0..<((SessionIndexStore.headByteCap / padding.utf8.count) + 4) {
            lines.append(fixture.assistantLine(padding))
        }
        lines.append(fixture.customTitleLine(""))
        for _ in 0..<((SessionIndexStore.tailByteCap / padding.utf8.count) + 4) {
            lines.append(fixture.assistantLine(padding))
        }
        try fixture.writeTranscript(sessionId: "cleared-later", lines: lines)

        let entry = try await fixture.loadEntry(sessionId: "cleared-later")

        #expect(entry.title == "Fix the billing export")
    }

    @Test
    func clearedNameFallsBackToTheFirstPrompt() async throws {
        let fixture = try ClaudeTranscriptFixture()
        defer { fixture.tearDown() }
        try fixture.writeTranscript(
            sessionId: "cleared",
            lines: [
                fixture.userLine("Fix the billing export"),
                fixture.customTitleLine("Temporary name"),
                fixture.customTitleLine("   "),
            ]
        )

        let entry = try await fixture.loadEntry(sessionId: "cleared")

        #expect(entry.title == "Fix the billing export")
    }
}

/// A throwaway `CLAUDE_CONFIG_DIR` with one project directory, loaded through
/// the same Claude provider the Vault uses.
private struct ClaudeTranscriptFixture {
    let root: URL
    let configDir: URL
    let cwd: URL
    private let projectDir: URL
    private let previousConfigDir: String?

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-claude-custom-title-\(UUID().uuidString)", isDirectory: true)
        configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        cwd = root.appendingPathComponent("repo", isDirectory: true)
        projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        previousConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        setenv("CLAUDE_CONFIG_DIR", configDir.path, 1)
    }

    func tearDown() {
        if let previousConfigDir {
            setenv("CLAUDE_CONFIG_DIR", previousConfigDir, 1)
        } else {
            unsetenv("CLAUDE_CONFIG_DIR")
        }
        try? FileManager.default.removeItem(at: root)
    }

    func writeTranscript(sessionId: String, lines: [String]) throws {
        let url = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func loadEntry(sessionId: String) async throws -> SessionEntry {
        let entries = await SessionIndexStore.searchAgent(
            needle: "",
            agent: .claude,
            cwdFilter: cwd.path,
            offset: 0,
            limit: 50,
            errorBag: SessionIndexStore.ErrorBag(),
            registry: CmuxVaultAgentRegistry(registrations: []),
            ampSessionRepository: AmpHookSessionRepository()
        )
        return try #require(entries.first { $0.sessionId == sessionId })
    }

    func userLine(_ content: String) -> String {
        jsonLine([
            "type": "user",
            "cwd": cwd.path,
            "message": ["role": "user", "content": content],
        ])
    }

    func assistantLine(_ text: String) -> String {
        jsonLine([
            "type": "assistant",
            "cwd": cwd.path,
            "message": [
                "role": "assistant",
                "model": "claude-opus-5-5",
                "content": [["type": "text", "text": text]],
            ],
        ])
    }

    func customTitleLine(_ title: String) -> String {
        jsonLine(["type": "custom-title", "customTitle": title, "sessionId": "ignored"])
    }

    private func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
