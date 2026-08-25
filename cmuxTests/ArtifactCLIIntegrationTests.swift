import Foundation
import Testing

@Suite("Artifact CLI integration")
struct ArtifactCLIIntegrationTests {
    @Test("Commands persist, list, resolve, and search without a cmux socket")
    func commandsPersistListResolveAndSearchWithoutSocket() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-artifact-cli-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--quiet", projectRoot.path]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        #expect(git.terminationStatus == 0)
        defer { try? fileManager.removeItem(at: projectRoot) }
        let source = projectRoot.appendingPathComponent("source/launch-plan.md", isDirectory: false)
        try fileManager.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "release needle".write(to: source, atomically: true, encoding: .utf8)
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)

        let added = try runCLI(
            cliPath,
            ["artifact", "add", source.path, "--project", projectRoot.path, "--json"]
        )
        #expect(added.status == 0, Comment(rawValue: added.stderr))
        let addedPayload = try jsonObject(added.stdout)
        let storedPath = try #require(addedPayload["path"] as? String)
        let relativePath = try #require(addedPayload["relative_path"] as? String)
        #expect(fileManager.fileExists(atPath: storedPath))
        #expect(relativePath.hasSuffix("/launch-plan.md"))

        let listed = try runCLI(
            cliPath,
            ["artifact", "list", "--project", projectRoot.path, "--json"]
        )
        #expect(listed.status == 0, Comment(rawValue: listed.stderr))
        let listedPayload = try jsonObject(listed.stdout)
        let artifacts = try #require(listedPayload["artifacts"] as? [[String: Any]])
        #expect(artifacts.compactMap { $0["relative_path"] as? String } == [relativePath])

        let resolved = try runCLI(
            cliPath,
            ["artifact", "path", relativePath, "--project", projectRoot.path]
        )
        #expect(resolved.status == 0, Comment(rawValue: resolved.stderr))
        #expect(resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == storedPath)

        let searched = try runCLI(
            cliPath,
            ["artifact", "search", "needle", "--project", projectRoot.path, "--json"]
        )
        #expect(searched.status == 0, Comment(rawValue: searched.stderr))
        let searchedPayload = try jsonObject(searched.stdout)
        let results = try #require(searchedPayload["results"] as? [[String: Any]])
        #expect(results.compactMap { $0["relative_path"] as? String } == [relativePath])
        #expect(results.first?["matched_content"] as? Bool == true)

        let missing = try runCLI(
            cliPath,
            ["artifact", "open", "missing.md", "--project", projectRoot.path]
        )
        #expect(missing.status != 0)
        #expect(missing.stderr.contains("Artifact not found"))
    }

    private func runCLI(
        _ executablePath: String,
        _ arguments: [String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_WORKSPACE_ID"] = "artifact-cli-test-workspace"
        environment["CMUX_CODEX_SESSION_ID"] = "artifact-cli-test-session"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "Expected JSON object, got: \(text)"
        )
    }
}
