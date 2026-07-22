import Foundation
import Testing

@Suite("Artifact CLI terminal safety")
struct ArtifactCLITerminalSafetyTests {
    @Test("Human output sanitizes controls while JSON preserves artifact text")
    func sanitizesOnlyHumanOutput() throws {
        let fileManager = FileManager.default
        let projectRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-artifact-cli-safety-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: projectRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: projectRoot) }
        let controlledName = "artifact-\u{1B}]2;owned\u{7}\u{85}.md"
        let controlledContent = "needle \u{1B}[31mred\u{7}\rreturn"
        let source = projectRoot.appendingPathComponent("source", isDirectory: true)
            .appendingPathComponent(controlledName, isDirectory: false)
        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try controlledContent.write(to: source, atomically: true, encoding: .utf8)
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)

        let added = try runCLI(
            cliPath,
            ["artifact", "add", source.path, "--project", projectRoot.path, "--json"]
        )
        #expect(added.status == 0)
        let addedPayload = try jsonObject(added.stdout)
        let relativePath = try #require(addedPayload["relative_path"] as? String)
        #expect(relativePath.contains(controlledName))

        let humanList = try runCLI(
            cliPath,
            ["artifact", "list", "--project", projectRoot.path]
        )
        #expect(humanList.status == 0)
        #expect(!containsUnsafeTerminalControl(humanList.stdout))

        let humanPath = try runCLI(
            cliPath,
            ["artifact", "path", relativePath, "--project", projectRoot.path]
        )
        #expect(humanPath.status == 0)
        #expect(!containsUnsafeTerminalControl(humanPath.stdout))

        let humanSearch = try runCLI(
            cliPath,
            ["artifact", "search", "needle", "--project", projectRoot.path]
        )
        #expect(humanSearch.status == 0)
        #expect(!containsUnsafeTerminalControl(humanSearch.stdout))

        let jsonSearch = try runCLI(
            cliPath,
            ["artifact", "search", "needle", "--project", projectRoot.path, "--json"]
        )
        #expect(jsonSearch.status == 0)
        let searchPayload = try jsonObject(jsonSearch.stdout)
        let results = try #require(searchPayload["results"] as? [[String: Any]])
        #expect(results.first?["relative_path"] as? String == relativePath)
        #expect((results.first?["snippet"] as? String)?.contains("\u{1B}[31m") == true)

        let humanError = try runCLI(
            cliPath,
            ["artifact", "path", "missing-\u{1B}]2;owned\u{7}.md", "--project", projectRoot.path]
        )
        #expect(humanError.status != 0)
        #expect(!containsUnsafeTerminalControl(humanError.stderr))
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
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func containsUnsafeTerminalControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar != "\n" && (scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value))
        }
    }
}
