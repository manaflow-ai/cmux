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
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)

        let object = try parseSSHListJSON(result.stdout)
        let hosts = try XCTUnwrap(object["hosts"] as? [[String: Any]])
        let aliases = hosts.compactMap { $0["alias"] as? String }
        XCTAssertTrue(aliases.contains("top"), result.stdout)
        XCTAssertTrue(aliases.contains("alpha"), result.stdout)
        XCTAssertTrue(aliases.contains("beta"), result.stdout)

        let alpha = try XCTUnwrap(hosts.first { ($0["alias"] as? String) == "alpha" })
        XCTAssertEqual(alpha["hostName"] as? String, "alpha.example.com")
        XCTAssertEqual(alpha["localForwards"] as? [String], ["8080 localhost:80"])
        XCTAssertEqual(alpha["dynamicForwards"] as? [String], ["1080"])

        let top = try XCTUnwrap(hosts.first { ($0["alias"] as? String) == "top" })
        XCTAssertEqual(top["user"] as? String, "alice")
        XCTAssertEqual(top["port"] as? Int, 2222)
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
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("--config"), result.stdout)
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
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
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
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stdout.contains("--bogus"), result.stdout)
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
        let data = try XCTUnwrap(String(output[start...end]).data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private enum SSHListJSONError: Error {
        case notFound(String)
    }
}
