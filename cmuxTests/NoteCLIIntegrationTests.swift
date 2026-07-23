import Foundation
import Testing

@Suite("Note CLI integration")
struct NoteCLIIntegrationTests {
    @Test("Notes are ordinary movable files in the current agent session")
    func writesReadsSearchesAndRediscoversMovedNotes() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-note-cli-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: projectRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: projectRoot) }
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let environment = [
            "CMUX_AGENT_NAME": "codex",
            "CMUX_AGENT_SESSION_ID": "session:cli",
            "CMUX_WORKSPACE_ID": "workspace:cli",
        ]

        let written = try runCLI(
            cliPath,
            [
                "note", "write", "plan", "--text", "first needle",
                "--project", projectRoot.path, "--json",
            ],
            environment: environment
        )
        #expect(written.status == 0)
        let writtenPayload = try jsonObject(written.stdout)
        let relativePath = try #require(writtenPayload["relative_path"] as? String)
        #expect(relativePath.hasSuffix("/notes/plan.md"))
        let sessionRoot = try #require(relativePath.split(separator: "/").first)
        let path = try #require(writtenPayload["path"] as? String)
        #expect(fileManager.fileExists(atPath: path))

        let appended = try runCLI(
            cliPath,
            ["note", "append", "plan", "--stdin", "--project", projectRoot.path],
            standardInput: "\nsecond line",
            environment: environment
        )
        #expect(appended.status == 0)

        let read = try runCLI(
            cliPath,
            ["note", "read", "plan", "--project", projectRoot.path],
            environment: environment
        )
        #expect(read.status == 0)
        #expect(read.stdout == "first needle\nsecond line")

        let searched = try runCLI(
            cliPath,
            ["note", "search", "needle", "--project", projectRoot.path, "--json"],
            environment: environment
        )
        #expect(searched.status == 0)
        let searchedPayload = try jsonObject(searched.stdout)
        let results = try #require(searchedPayload["results"] as? [[String: Any]])
        #expect(results.first?["relative_path"] as? String == relativePath)

        let moved = projectRoot.appendingPathComponent(
            ".cmux/\(sessionRoot)/notes/organized/renamed.md"
        )
        try fileManager.createDirectory(
            at: moved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: URL(fileURLWithPath: path), to: moved)

        let movedRead = try runCLI(
            cliPath,
            ["note", "read", "renamed", "--project", projectRoot.path],
            environment: environment
        )
        #expect(movedRead.status == 0)
        #expect(movedRead.stdout == "first needle\nsecond line")

        let artifacts = try runCLI(
            cliPath,
            ["artifact", "search", "renamed", "--project", projectRoot.path, "--json"],
            environment: environment
        )
        #expect(artifacts.status == 0)
        let artifactPayload = try jsonObject(artifacts.stdout)
        let artifactResults = try #require(artifactPayload["results"] as? [[String: Any]])
        #expect(artifactResults.first?["relative_path"] as? String
            == "\(sessionRoot)/notes/organized/renamed.md")
    }

    @Test("Note removal requires an exact name")
    func removalDoesNotUseFuzzyMatches() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-note-rm-cli-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: projectRoot) }
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let environment = [
            "CMUX_AGENT_NAME": "codex",
            "CMUX_AGENT_SESSION_ID": "session:rm",
        ]
        let written = try runCLI(
            cliPath,
            [
                "note", "write", "planning", "--text", "keep me",
                "--project", projectRoot.path, "--json",
            ],
            environment: environment
        )
        #expect(written.status == 0)
        let path = try #require(jsonObject(written.stdout)["path"] as? String)

        let removed = try runCLI(
            cliPath,
            ["note", "rm", "plan", "--project", projectRoot.path],
            environment: environment
        )

        #expect(removed.status == 2)
        #expect(fileManager.fileExists(atPath: path))
    }

    private func runCLI(
        _ executablePath: String,
        _ arguments: [String],
        standardInput: String? = nil,
        environment additions: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment.merge(additions) { _, supplied in supplied }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let standardInput {
            try stdin.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
        }
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
