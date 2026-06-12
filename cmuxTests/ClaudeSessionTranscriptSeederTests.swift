import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudeSessionTranscriptSeederTests: XCTestCase {
    private let sessionId = "39c1eb84-201c-4c90-a54a-9dc31b076127"
    private var configRoot: URL!
    private var targetCwd: URL!

    override func setUpWithError() throws {
        configRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeder-config-\(UUID().uuidString)")
        targetCwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeder-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: targetCwd, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [configRoot, targetCwd] {
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func writeSourceTranscript(
        in root: URL,
        projectDir: String = "-Users-someone-fun-repo",
        content: String = "origin-transcript",
        withSidecar: Bool = false
    ) throws -> URL {
        let project = root.appendingPathComponent("projects").appendingPathComponent(projectDir)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("\(sessionId).jsonl")
        try content.write(to: transcript, atomically: true, encoding: .utf8)
        if withSidecar {
            let sidecar = project.appendingPathComponent(sessionId).appendingPathComponent("subagents")
            try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
            try "sub".write(
                to: sidecar.appendingPathComponent("agent-1.jsonl"), atomically: true, encoding: .utf8)
        }
        return transcript
    }

    private var targetProjectDir: URL {
        configRoot.appendingPathComponent("projects").appendingPathComponent(
            ClaudeSessionTranscriptSeeder.encodedProjectDirName(forWorkingDirectory: targetCwd.path))
    }

    func testEncodedProjectDirNameReplacesNonAlphanumerics() {
        XCTAssertEqual(
            ClaudeSessionTranscriptSeeder.encodedProjectDirName(
                forWorkingDirectory: "/Users/x/fun/repo_a.b"),
            "-Users-x-fun-repo-a-b")
    }

    func testEncodedProjectDirNameResolvesSymlinkedTmp() {
        // Node's process.cwd() resolves symlinks, so /tmp records as /private/tmp.
        XCTAssertEqual(
            ClaudeSessionTranscriptSeeder.encodedProjectDirName(forWorkingDirectory: "/tmp/x"),
            "-private-tmp-x")
    }

    func testSeedCopiesTranscriptAndSidecarIntoTargetProjectDir() throws {
        _ = try writeSourceTranscript(in: configRoot, withSidecar: true)

        let seeded = ClaudeSessionTranscriptSeeder.seedIfNeeded(
            sessionId: sessionId,
            targetWorkingDirectory: targetCwd.path,
            configDirCandidates: [configRoot])

        XCTAssertTrue(seeded)
        let copied = targetProjectDir.appendingPathComponent("\(sessionId).jsonl")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "origin-transcript")
        let sidecar = targetProjectDir
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
            .appendingPathComponent("agent-1.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testSeedNoopWhenTargetAlreadyHasTranscript() throws {
        _ = try writeSourceTranscript(in: configRoot)
        try FileManager.default.createDirectory(at: targetProjectDir, withIntermediateDirectories: true)
        let existing = targetProjectDir.appendingPathComponent("\(sessionId).jsonl")
        try "already-here".write(to: existing, atomically: true, encoding: .utf8)

        let seeded = ClaudeSessionTranscriptSeeder.seedIfNeeded(
            sessionId: sessionId,
            targetWorkingDirectory: targetCwd.path,
            configDirCandidates: [configRoot])

        XCTAssertTrue(seeded)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "already-here")
    }

    func testSeedFromFallbackCandidateLandsInAuthoritativeRoot() throws {
        let authoritativeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeder-auth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: authoritativeRoot) }
        try FileManager.default.createDirectory(at: authoritativeRoot, withIntermediateDirectories: true)
        _ = try writeSourceTranscript(in: configRoot)

        XCTAssertTrue(
            ClaudeSessionTranscriptSeeder.seedIfNeeded(
                sessionId: sessionId,
                targetWorkingDirectory: targetCwd.path,
                configDirCandidates: [authoritativeRoot, configRoot]))
        // The copy must land in the root the resumed claude reads (the first
        // candidate), not in the fallback root that held the source.
        let landed = authoritativeRoot
            .appendingPathComponent("projects")
            .appendingPathComponent(
                ClaudeSessionTranscriptSeeder.encodedProjectDirName(forWorkingDirectory: targetCwd.path))
            .appendingPathComponent("\(sessionId).jsonl")
        XCTAssertEqual(try String(contentsOf: landed, encoding: .utf8), "origin-transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetProjectDir.path))
        XCTAssertFalse(
            ClaudeSessionTranscriptSeeder.seedIfNeeded(
                sessionId: "../escape",
                targetWorkingDirectory: targetCwd.path,
                configDirCandidates: [configRoot]))
    }

    func testDefaultConfigDirCandidatesMapLegacyPathToPreferredRoot() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeder-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = home.appendingPathComponent(".subrouter/codex/claude/_p1")
        let preferred = home.appendingPathComponent(".codex-accounts/claude/_p1")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: preferred, withIntermediateDirectories: true)

        let candidates = ClaudeSessionTranscriptSeeder.defaultConfigDirCandidates(
            launchEnvironment: ["CLAUDE_CONFIG_DIR": legacy.path],
            processEnvironment: [:],
            homeDirectory: home)
        // The captured legacy path must map to the preferred root the launch
        // environment policy rewrites it to, mirroring ClaudeConfigDirectoryPath.
        XCTAssertEqual(candidates.first?.path, preferred.path)
    }

    func testSeedReturnsFalseWhenTranscriptMissingEverywhere() {
        XCTAssertFalse(
            ClaudeSessionTranscriptSeeder.seedIfNeeded(
                sessionId: sessionId,
                targetWorkingDirectory: targetCwd.path,
                configDirCandidates: [configRoot]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetProjectDir.path))
    }

    func testDefaultConfigDirCandidatesOrderAndDedup() {
        let candidates = ClaudeSessionTranscriptSeeder.defaultConfigDirCandidates(
            launchEnvironment: ["CLAUDE_CONFIG_DIR": "/captured/dir"],
            processEnvironment: ["CLAUDE_CONFIG_DIR": "/captured/dir"],
            homeDirectory: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(candidates.map(\.path), ["/captured/dir", "/Users/someone/.claude"])
    }

    func testForkStartupInputSeedsTranscriptForNewWorkingDirectory() throws {
        _ = try writeSourceTranscript(in: configRoot)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: targetCwd.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/usr/local/bin/claude",
                arguments: ["claude"],
                workingDirectory: nil,
                environment: ["CLAUDE_CONFIG_DIR": configRoot.path],
                capturedAt: nil,
                source: nil))

        XCTAssertNotNil(snapshot.forkStartupInput())

        let copied = targetProjectDir.appendingPathComponent("\(sessionId).jsonl")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "origin-transcript")
    }

    func testResumeStartupInputSeedsTranscriptForNewWorkingDirectory() throws {
        _ = try writeSourceTranscript(in: configRoot)
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: targetCwd.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: nil,
                executablePath: "/usr/local/bin/claude",
                arguments: ["claude"],
                workingDirectory: nil,
                environment: ["CLAUDE_CONFIG_DIR": configRoot.path],
                capturedAt: nil,
                source: nil))

        XCTAssertNotNil(snapshot.resumeStartupInput())

        let copied = targetProjectDir.appendingPathComponent("\(sessionId).jsonl")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "origin-transcript")
    }
}
