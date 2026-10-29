import Foundation
import Testing

@Suite("CLI Feed clear")
struct CLIFeedClearTests {
    @Test("Clear preserves the revision floor")
    func clearPreservesRevision() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let journal = try makeHistory(home: home)
        let revision = journal.appendingPathExtension("revision")
        try Data("2000".utf8).write(to: revision)
        let result = try runClear(home: home)
        #expect(!result.timedOut)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(try String(contentsOf: revision, encoding: .utf8) == "2000")
    }

    @Test("Clear failure is safe for users and leaves history intact")
    func clearFailureDoesNotExposeFilesystemDetails() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let journal = try makeHistory(home: home)
        // A directory at the sidecar path fails atomic replacement deterministically,
        // including when the runner has privileges that bypass file permissions.
        try FileManager.default.createDirectory(
            at: journal.appendingPathExtension("revision"), withIntermediateDirectories: false
        )
        let result = try runClear(home: home)
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(!result.stderr.isEmpty)
        #expect(!result.stderr.contains(home.path))
        #expect(!result.stderr.contains("workstream.jsonl"))
        #expect(!result.stderr.contains("NSCocoaErrorDomain"))
        #expect(try String(contentsOf: journal, encoding: .utf8) == "fixture\n")
    }

    private func makeHistory(home: URL) throws -> URL {
        let directory = home.appendingPathComponent(".cmuxterm")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("workstream.jsonl")
        try Data("fixture\n".utf8).write(to: journal)
        return journal
    }

    private func runClear(home: URL) throws -> CLIHookProcessRunner.Result {
        let executable = try BundledCLITestSupport.bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return CLIHookProcessRunner.run(
            executablePath: executable, arguments: ["feed", "clear", "--yes"],
            environment: environment, timeout: 10
        )
    }
}
