import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for `cmux vm secrets …` and its `cmux secrets` alias: the real CLI
/// binary against a mock control socket playing the app's `vm.secrets_*` side. Pins
/// what an agent or a person hits: values come from stdin or a .env file (never argv),
/// a `NAME=value` argument is refused before any socket traffic, scopes become the
/// wire values the app parses, and nothing the CLI prints contains a value. CLI-target
/// code is not linked into this bundle (see CLIVMTransferTests), so behavior is
/// observed through the process and the requests it sends.
extension CLINotifyProcessIntegrationRegressionTests {
    private final class VMSecretsRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []

        func append(_ request: [String: Any]) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        var methods: [String] {
            lock.lock()
            defer { lock.unlock() }
            return requests.compactMap { $0["method"] as? String }
        }

        func params(ofFirst method: String) -> [String: Any]? {
            lock.lock()
            defer { lock.unlock() }
            return requests.first { ($0["method"] as? String) == method }?["params"] as? [String: Any]
        }
    }

    private func vmSecretsEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-secrets-home-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        return environment
    }

    /// The app's side of `vm.secrets_set` / `vm.secrets_list`: names and kinds back,
    /// never values. Any `vm.exec` or `vm.env_set` is a failure.
    private func startVMSecretsMock(
        listenerFD: Int32,
        state: MockSocketServerState,
        log: VMSecretsRequestLog
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            switch method {
            case "vm.secrets_set":
                let scope = (params["scope"] as? String) ?? "all"
                let entries = (params["entries"] as? [[String: Any]]) ?? []
                let changes = entries.map { ["name": ($0["key"] as? String) ?? "?", "scope": scope, "kind": "added"] }
                return self.v2Response(id: id, ok: true, result: ["changes": changes, "synced": [], "dry_run": params["dry_run"] as? Bool ?? false])
            case "vm.secrets_list":
                return self.v2Response(id: id, ok: true, result: [
                    "secrets": [["name": "ANTHROPIC_API_KEY", "scope": "all", "fingerprint": "3f9a1c2e", "updated_at": "2026-10-15T00:00:00Z", "source": "manual"]],
                    "machines": [],
                    "auto_sync": true,
                    "well_known": ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"],
                ])
            default:
                return self.v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }
    }

    private func assertNoSocketConnection(_ listenerFD: Int32, file: StaticString = #filePath, line: UInt = #line) {
        var connection = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Darwin.poll(&connection, 1, 0), 0, "a refused command must not connect to the socket", file: file, line: line)
    }

    func testVMSecretsRefusesInlineValuesWithoutTouchingTheSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-inline")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let cases: [[String]] = [
            ["vm", "secrets", "set", "ANTHROPIC_API_KEY=sk-inline-secret"],
            ["cloud", "secrets", "set", "OK_NAME", "OPENAI_API_KEY=sk-inline-secret"],
            ["secrets", "set", "ANTHROPIC_API_KEY=sk-inline-secret"],
            ["vm", "secrets", "import", "--from-shell", "GH_TOKEN=sk-inline-secret"],
        ]
        for arguments in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: vmSecretsEnvironment(socketPath: socketPath),
                timeout: 30
            )
            XCTAssertFalse(result.timedOut, "\(arguments) timed out")
            XCTAssertEqual(result.status, 2, "\(arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            XCTAssertTrue(result.stderr.contains("refusing"), "\(arguments): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("cmux vm secrets set"), "the refusal points at the safe form: \(result.stderr)")
            XCTAssertFalse(result.stderr.contains("sk-inline-secret"), "the value is never echoed: \(result.stderr)")
            XCTAssertFalse(result.stdout.contains("sk-inline-secret"), "the value is never echoed: \(result.stdout)")
        }
        assertNoSocketConnection(listenerFD)
    }

    func testVMSecretsSetReadsOneValuePerNameFromStdinAndPrintsNamesOnly() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-set")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMSecretsRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMSecretsMock(listenerFD: listenerFD, state: state, log: log)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "secrets", "set", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "--scope", "project:github.com/owner/repo", "--no-sync"],
            environment: vmSecretsEnvironment(socketPath: socketPath),
            standardInput: "sk-ant-first value\r\nsk-openai-second\n",
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.secrets_set"], log.methods.description)
        let params = try XCTUnwrap(log.params(ofFirst: "vm.secrets_set"))
        XCTAssertEqual(params["scope"] as? String, "project:github.com/owner/repo")
        XCTAssertEqual(params["sync"] as? Bool, false)
        XCTAssertEqual(params["source"] as? String, "manual")
        let entries = (params["entries"] as? [[String: Any]]) ?? []
        // One line per name, in order; a CRLF line ending is not part of the value.
        XCTAssertEqual(entries.map { "\(($0["key"] as? String) ?? "?")=\(($0["value"] as? String) ?? "?")" }, [
            "ANTHROPIC_API_KEY=sk-ant-first value",
            "OPENAI_API_KEY=sk-openai-second",
        ])
        XCTAssertTrue(result.stdout.contains("+ ANTHROPIC_API_KEY [project:github.com/owner/repo] added"), result.stdout)
        XCTAssertFalse(result.stdout.contains("sk-ant"), "values never echo back: \(result.stdout)")
        XCTAssertFalse(result.stderr.contains("sk-ant"), "values never echo back: \(result.stderr)")
    }

    func testVMSecretsMachineFlagAndAliasBecomeTheMachineScope() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-machine")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMSecretsRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMSecretsMock(listenerFD: listenerFD, state: state, log: log)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["secrets", "set", "HF_TOKEN", "--machine", "brave-otter"],
            environment: vmSecretsEnvironment(socketPath: socketPath),
            standardInput: "hf-value\n",
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let params = try XCTUnwrap(log.params(ofFirst: "vm.secrets_set"))
        XCTAssertEqual(params["scope"] as? String, "machine:brave-otter")
        // No --no-sync: the app's auto-sync setting decides.
        XCTAssertNil(params["sync"])
    }

    func testVMSecretsRejectsBadScopesAndStdinCountsBeforeTheSocket() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-bad")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let cases: [(arguments: [String], stdin: String, expected: String)] = [
            (["vm", "secrets", "set", "A_KEY", "--scope", "galaxy"], "v\n", "unknown scope 'galaxy'"),
            (["vm", "secrets", "set", "A_KEY", "--scope", "machine:"], "v\n", "unknown scope 'machine:'"),
            (["vm", "secrets", "set", "A_KEY", "--scope", "all", "--machine", "m1"], "v\n", "give one scope"),
            (["vm", "secrets", "set", "A_KEY", "B_KEY"], "only-one-line-secret\n", "expected 2 line(s) on stdin"),
            (["vm", "secrets", "set", "1BAD"], "v\n", "invalid variable name '1BAD'"),
            (["vm", "secrets", "rm"], "", "give at least one NAME"),
            (["vm", "secrets", "set", "A_KEY", "--bogus"], "v\n", "unknown flag '--bogus'"),
        ]
        for testCase in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: testCase.arguments,
                environment: vmSecretsEnvironment(socketPath: socketPath),
                standardInput: testCase.stdin,
                timeout: 30
            )
            XCTAssertEqual(result.status, 2, "\(testCase.arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            XCTAssertTrue(result.stderr.contains(testCase.expected), "\(testCase.arguments): \(result.stderr)")
            XCTAssertFalse(result.stderr.contains("only-one-line-secret"), result.stderr)
        }
        assertNoSocketConnection(listenerFD)
    }

    func testVMSecretsImportDryRunSendsTheDotenvAndAMalformedLineIsNotEchoed() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-import")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMSecretsRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-secrets-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let good = tempDir.appendingPathComponent("agents.env")
        try """
        # keys
        export ANTHROPIC_API_KEY="sk-ant-dotenv"
        OPENAI_API_KEY='sk-openai-dotenv' # trailing comment
        """.write(to: good, atomically: true, encoding: .utf8)
        let bad = tempDir.appendingPathComponent("bad.env")
        try "GOOD=1\nsk-bare-token-line\n".write(to: bad, atomically: true, encoding: .utf8)

        // A malformed line names its number only: it may be a bare token.
        let rejected = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "secrets", "import", bad.path],
            environment: vmSecretsEnvironment(socketPath: socketPath),
            timeout: 30
        )
        XCTAssertEqual(rejected.status, 2, "stdout=\(rejected.stdout) stderr=\(rejected.stderr)")
        XCTAssertTrue(rejected.stderr.contains("line 2"), rejected.stderr)
        XCTAssertFalse(rejected.stderr.contains("sk-bare-token-line"), rejected.stderr)
        assertNoSocketConnection(listenerFD)

        let serverHandled = startVMSecretsMock(listenerFD: listenerFD, state: state, log: log)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "secrets", "import", good.path, "--dry-run"],
            environment: vmSecretsEnvironment(socketPath: socketPath),
            timeout: 30
        )
        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let params = try XCTUnwrap(log.params(ofFirst: "vm.secrets_set"))
        XCTAssertEqual(params["dry_run"] as? Bool, true)
        XCTAssertEqual(params["scope"] as? String, "all")
        XCTAssertEqual(params["source"] as? String, "dotenv:agents.env")
        let entries = (params["entries"] as? [[String: Any]]) ?? []
        XCTAssertEqual(entries.compactMap { $0["value"] as? String }, ["sk-ant-dotenv", "sk-openai-dotenv"])
        XCTAssertTrue(result.stdout.contains("+ ANTHROPIC_API_KEY [all] would add"), result.stdout)
        XCTAssertFalse(result.stdout.contains("sk-ant-dotenv"), result.stdout)
    }

    func testVMSecretsImportFromShellTakesWellKnownNamesTheAppLists() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-shell")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMSecretsRequestLog()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let serverHandled = startVMSecretsMock(listenerFD: listenerFD, state: state, log: log)
        var environment = vmSecretsEnvironment(socketPath: socketPath)
        environment["OPENAI_API_KEY"] = "sk-openai-from-shell"
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        environment["UNRELATED_SECRET"] = "must-not-be-imported"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "secrets", "import", "--from-shell", "--no-sync"],
            environment: environment,
            timeout: 30
        )

        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.secrets_list", "vm.secrets_set"], log.methods.description)
        let params = try XCTUnwrap(log.params(ofFirst: "vm.secrets_set"))
        let entries = (params["entries"] as? [[String: Any]]) ?? []
        XCTAssertEqual(entries.compactMap { $0["key"] as? String }, ["OPENAI_API_KEY"])
        XCTAssertEqual(params["source"] as? String, "shell")
        XCTAssertFalse(result.stdout.contains("sk-openai-from-shell"), result.stdout)
    }

    func testVMSecretsHelpPrintsWithoutASocket() throws {
        let cliPath = try bundledCLIPath()
        let environment = vmSecretsEnvironment(socketPath: makeSocketPath("secrets-help"))
        let cases: [(arguments: [String], expected: [String])] = [
            (["vm", "secrets", "--help"], ["cmux vm secrets set NAME", "is refused", "machine:<id>"]),
            (["secrets", "--help"], ["cmux secrets set NAME", "cmux secrets import"]),
        ]
        for testCase in cases {
            let result = runProcess(executablePath: cliPath, arguments: testCase.arguments, environment: environment, timeout: 30)
            XCTAssertFalse(result.timedOut, "\(testCase.arguments) timed out")
            XCTAssertEqual(result.status, 0, "\(testCase.arguments): stdout=\(result.stdout) stderr=\(result.stderr)")
            for expected in testCase.expected {
                XCTAssertTrue(result.stdout.contains(expected), "\(testCase.arguments) should mention '\(expected)':\n\(result.stdout)")
            }
        }
    }
}
