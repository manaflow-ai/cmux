import Darwin
import Foundation
import Testing

// End-to-end coverage for `cmux ssh list` (issue #6774): the local, no-socket
// subcommand that lists external SSH machines from ssh_config. These exercise
// the CLI glue (config reading, Include glob expansion, JSON output, and
// --config error handling) that the pure `SSHConfigParser` unit tests in
// CmuxFoundationTests cannot reach. They run the bundled CLI binary directly.
extension CMUXCLIErrorOutputRegressionTests {
    /// `cmux ssh list` follows an `Include` whose pattern has a wildcard
    /// *directory* component (`hosts/*/config`) — glob expansion must not be
    /// limited to the final path component — and surfaces forwarded ports.
    @Test func testSSHListExpandsWildcardDirectoryIncludeAndForwards() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-list-\(UUID().uuidString)", isDirectory: true)
        let hostsA = root.appendingPathComponent("hosts/a", isDirectory: true)
        let hostsB = root.appendingPathComponent("hosts/b", isDirectory: true)
        try FileManager.default.createDirectory(at: hostsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostsB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Absolute Include path: a relative path would resolve under ~/.ssh
        // (OpenSSH's rule for user configs), not this temp dir, so use an
        // absolute path to keep the test hermetic while still exercising
        // wildcard-directory glob expansion.
        let configPath = root.appendingPathComponent("config")
        try """
        Host top
            HostName top.example.com
            User alice
            Port 2222
        Include \(root.path)/hosts/*/config
        """.write(to: configPath, atomically: true, encoding: .utf8)
        try """
        Host alpha
            HostName alpha.example.com
            LocalForward 8080 localhost:80
            DynamicForward 1080
        """.write(to: hostsA.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        Host beta
            HostName beta.example.com
        """.write(to: hostsB.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "list", "--config", configPath.path, "--json"],
            environment: scrubbedSSHListEnvironment(),
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))

        let object = try parseSSHListJSON(result.stdout)
        let hosts = try #require(object["hosts"] as? [[String: Any]], Comment(rawValue: result.stdout))
        let aliases = hosts.compactMap { $0["alias"] as? String }
        #expect(aliases.contains("top"), Comment(rawValue: result.stdout))
        #expect(aliases.contains("alpha"), Comment(rawValue: result.stdout))
        #expect(aliases.contains("beta"), Comment(rawValue: result.stdout))

        let alpha = try #require(hosts.first { ($0["alias"] as? String) == "alpha" })
        #expect(alpha["hostName"] as? String == "alpha.example.com")
        #expect(alpha["localForwards"] as? [String] == ["8080 localhost:80"])
        #expect(alpha["dynamicForwards"] as? [String] == ["1080"])

        let top = try #require(hosts.first { ($0["alias"] as? String) == "top" })
        #expect(top["user"] as? String == "alice")
        #expect(top["port"] as? Int == 2222)
    }

    /// `Include dir/*` follows OpenSSH/glob behavior and does not match
    /// dotfiles unless the pattern explicitly names the leading dot.
    @Test func testSSHListIncludeGlobDoesNotReadDotfiles() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-list-dotfiles-\(UUID().uuidString)", isDirectory: true)
        let includes = root.appendingPathComponent("includes", isDirectory: true)
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configPath = root.appendingPathComponent("config")
        try "Include \(includes.path)/*\n".write(to: configPath, atomically: true, encoding: .utf8)
        try """
        Host visible
            HostName visible.example.com
        """.write(to: includes.appendingPathComponent("visible"), atomically: true, encoding: .utf8)
        try """
        Host hidden
            HostName hidden.example.com
        """.write(to: includes.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "list", "--config", configPath.path, "--json"],
            environment: scrubbedSSHListEnvironment(),
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))

        let object = try parseSSHListJSON(result.stdout)
        let hosts = try #require(object["hosts"] as? [[String: Any]], Comment(rawValue: result.stdout))
        let aliases = hosts.compactMap { $0["alias"] as? String }
        #expect(aliases.contains("visible"), Comment(rawValue: result.stdout))
        #expect(!aliases.contains("hidden"), Comment(rawValue: result.stdout))
    }

    /// An explicit `--config` path that cannot be read is an error, not a
    /// silently empty listing.
    @Test func testSSHListRejectsUnreadableExplicitConfig() throws {
        let cliPath = try bundledCLIPath()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("config")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "list", "--config", missing.path],
            environment: scrubbedSSHListEnvironment(),
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("--config"), Comment(rawValue: result.stdout))
    }

    /// `cmux ssh list --config` with no value must fail rather than silently
    /// reading the default config.
    @Test func testSSHListRejectsConfigFlagWithoutValue() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "list", "--config"],
            environment: scrubbedSSHListEnvironment(),
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
    }

    /// A non-regular top-level config (e.g. a FIFO) must error quickly, not
    /// block the command reading it.
    @Test func testSSHListDoesNotHangOnFIFOConfig() throws {
        let cliPath = try bundledCLIPath()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-fifo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fifoPath = dir.appendingPathComponent("config").path
        #expect(mkfifo(fifoPath, 0o600) == 0, "mkfifo failed")

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "list", "--config", fifoPath],
            environment: scrubbedSSHListEnvironment(),
            timeout: 8
        )
        #expect(!result.timedOut, Comment(rawValue: "ssh list hung on a FIFO config: \(result.stdout)"))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
    }

    /// An unknown or misspelled flag is rejected, not silently ignored.
    @Test func testSSHListRejectsUnknownOption() throws {
        let cliPath = try bundledCLIPath()
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "list", "--bogus"],
            environment: scrubbedSSHListEnvironment(),
            timeout: 10
        )
        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status != 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("--bogus"), Comment(rawValue: result.stdout))
    }

    private func scrubbedSSHListEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    /// Extract the JSON object from the CLI output. stderr is merged into the
    /// captured stream, so slice from the first `{` to the last `}` to tolerate
    /// any incidental diagnostic lines.
    private func parseSSHListJSON(_ output: String) throws -> [String: Any] {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start <= end else {
            throw SSHListJSONError.notFound(output)
        }
        let data = try #require(String(output[start...end]).data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private enum SSHListJSONError: Error {
        case notFound(String)
    }
}
