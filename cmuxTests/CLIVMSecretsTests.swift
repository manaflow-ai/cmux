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
            case "vm.list":
                // brave-otter is a label (displayName); calm-fox only a slug.
                return self.v2Response(id: id, ok: true, result: ["vms": [
                    ["id": "vm-1", "displayName": "brave-otter", "status": "running"],
                    ["id": "vm-2", "slug": "calm-fox", "status": "running"],
                ]])
            case "vm.secrets_status":
                // Before a sync: one name current, one out of date.
                return self.v2Response(id: id, ok: true, result: [
                    "machine": (params["id"] as? String) ?? "?",
                    "rows": [
                        ["name": "ANTHROPIC_API_KEY", "state": "current", "scope": "all"],
                        ["name": "OPENAI_API_KEY", "state": "stale", "scope": "all"],
                    ],
                ])
            case "vm.secrets_sync":
                // The app reports every delivered name, changed or not.
                return self.v2Response(id: id, ok: true, result: [
                    "machine": (params["id"] as? String) ?? "?",
                    "sent": ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "GH_TOKEN"],
                    "removed": ["OLD_KEY"],
                    "noop": false,
                ])
            case "vm.secrets_link":
                return self.v2Response(id: id, ok: true, result: [
                    "machine": (params["id"] as? String) ?? "?",
                    "project": (params["project"] as? String) ?? "?",
                    "linked": true,
                ])
            case "vm.secrets_rm":
                let names = (params["names"] as? [String]) ?? []
                let removed = names.filter { $0 == "ANTHROPIC_API_KEY" }
                return self.v2Response(id: id, ok: true, result: [
                    "changes": removed.map { ["name": $0, "scope": "all", "kind": "removed"] },
                    "synced": removed.isEmpty ? [] : [[
                        "machine": "vm-1",
                        "sent": ["OPENAI_API_KEY"],
                        "removed": removed,
                        "noop": false,
                    ]],
                ])
            case "vm.secrets_list":
                return self.v2Response(id: id, ok: true, result: [
                    "secrets": [["name": "ANTHROPIC_API_KEY", "scope": "all", "fingerprint": "3f9a1c2e", "updated_at": "2025-01-01T00:00:00Z", "source": "manual"]],
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
        // A label stores under the machine's id, the same machine `vm ls` shows.
        XCTAssertEqual(params["scope"] as? String, "machine:vm-1")
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
            (["vm", "secrets", "set", "A_KEY", "B_KEY"], "only-one-line-secret\n", "expected 2 lines on stdin"),
            // The name is never echoed: it may be a pasted value.
            (["vm", "secrets", "set", "1BAD_pasted_token"], "v\n", "a name is not a valid variable name"),
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
            XCTAssertFalse(result.stderr.contains("1BAD_pasted_token"), result.stderr)
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
        sk-bare-token-line
        EMPTY_KEY=
        OPENAI_API_KEY='sk-openai-dotenv' # trailing comment
        PATH=/tmp/should-be-skipped
        CMUX_SOCKET=/tmp/should-be-skipped
        """.write(to: good, atomically: true, encoding: .utf8)
        let onlyBad = tempDir.appendingPathComponent("bad.env")
        try "sk-bare-token-line\nEMPTY_KEY=\n".write(to: onlyBad, atomically: true, encoding: .utf8)

        // Nothing usable: exit 1 before the socket, naming line numbers only.
        let rejected = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "secrets", "import", onlyBad.path, "--dry-run"],
            environment: vmSecretsEnvironment(socketPath: socketPath),
            timeout: 30
        )
        XCTAssertEqual(rejected.status, 1, "stdout=\(rejected.stdout) stderr=\(rejected.stderr)")
        XCTAssertTrue(rejected.stderr.contains("line 1 (not NAME=value)"), rejected.stderr)
        XCTAssertTrue(rejected.stderr.contains("line 2 (empty value)"), rejected.stderr)
        XCTAssertFalse(rejected.stderr.contains("sk-bare-token-line"), rejected.stderr)
        assertNoSocketConnection(listenerFD)

        // One bad line and one empty value do not stop the rest, even in a dry run.
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
        XCTAssertEqual(entries.compactMap { $0["key"] as? String }, ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(entries.compactMap { $0["value"] as? String }, ["sk-ant-dotenv", "sk-openai-dotenv"])
        XCTAssertTrue(result.stdout.contains("+ ANTHROPIC_API_KEY [all] would add"), result.stdout)
        XCTAssertTrue(result.stdout.contains("! line 3 skipped (not NAME=value)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("! EMPTY_KEY skipped (empty value, line 4)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("! PATH skipped (reserved variable name, line 6)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("! CMUX_SOCKET skipped (reserved variable name, line 7)"), result.stdout)
        XCTAssertTrue(
            result.stdout.contains("Would import 2 \u{00B7} Skipped 4: line 3 (not NAME=value), line 4 (empty value), line 6 (reserved variable name), line 7 (reserved variable name)"),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains("sk-ant-dotenv"), result.stdout)
        XCTAssertFalse(result.stdout.contains("sk-bare-token-line"), result.stdout)
    }

    /// `vm secrets import` reads quotes like the vault's dotenv parser: `\"` is a quote
    /// inside double quotes, single quotes have no escapes, and a quoted value with text
    /// after its closing quote is skipped by line number without echoing the value.
    func testVMSecretsImportQuotingMatchesTheVaultDotenvRules() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("secrets-quotes")
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
        let file = tempDir.appendingPathComponent("quotes.env")
        try """
        ESCAPED="say \\"hi\\""
        WIN_PATH='C:\\dir\\'
        TRAILING="sk-trailing-secret"oops
        UNCLOSED="sk-unclosed-secret
        """.write(to: file, atomically: true, encoding: .utf8)

        let serverHandled = startVMSecretsMock(listenerFD: listenerFD, state: state, log: log)
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["vm", "secrets", "import", file.path, "--dry-run"],
            environment: vmSecretsEnvironment(socketPath: socketPath),
            timeout: 30
        )
        wait(for: [serverHandled], timeout: 30)
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let params = try XCTUnwrap(log.params(ofFirst: "vm.secrets_set"))
        let entries = (params["entries"] as? [[String: Any]]) ?? []
        XCTAssertEqual(entries.compactMap { $0["key"] as? String }, ["ESCAPED", "WIN_PATH"])
        XCTAssertEqual(entries.compactMap { $0["value"] as? String }, ["say \"hi\"", "C:\\dir\\"])
        XCTAssertTrue(result.stdout.contains("! TRAILING skipped (text after the closing quote, line 3)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("! UNCLOSED skipped (value spans several lines, line 4)"), result.stdout)
        XCTAssertFalse(result.stdout.contains("sk-trailing-secret"), result.stdout)
        XCTAssertFalse(result.stdout.contains("sk-unclosed-secret"), result.stdout)
    }

    /// `vm secrets` against the mock with the full app side (`vm.list` labels, status,
    /// sync, rm). Returns the result and the methods the CLI sent.
    private func runVMSecretsAgainstMock(_ name: String, arguments: [String]) throws -> (result: ProcessRunResult, log: VMSecretsRequestLog) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
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
            arguments: arguments,
            environment: vmSecretsEnvironment(socketPath: socketPath),
            timeout: 30
        )
        wait(for: [serverHandled], timeout: 30)
        XCTAssertFalse(result.timedOut, "\(arguments) timed out")
        return (result, log)
    }

    func testVMSecretsMachineVerbsTakeLabelsAndRefuseUnknownMachines() throws {
        // A label resolves to the machine's id before status runs.
        let (status, statusLog) = try runVMSecretsAgainstMock("secrets-status", arguments: ["vm", "secrets", "status", "brave-otter"])
        XCTAssertEqual(status.status, 0, "stdout=\(status.stdout) stderr=\(status.stderr)")
        XCTAssertEqual(statusLog.methods, ["vm.list", "vm.secrets_status"], statusLog.methods.description)
        XCTAssertEqual(statusLog.params(ofFirst: "vm.secrets_status")?["id"] as? String, "vm-1")

        // A slug works the same way for link.
        let (link, linkLog) = try runVMSecretsAgainstMock("secrets-link", arguments: ["vm", "secrets", "link", "calm-fox", "--project", "github.com/o/r", "--no-sync"])
        XCTAssertEqual(link.status, 0, "stdout=\(link.stdout) stderr=\(link.stderr)")
        XCTAssertEqual(linkLog.params(ofFirst: "vm.secrets_link")?["id"] as? String, "vm-2")
        XCTAssertTrue(link.stdout.contains("OK linked calm-fox to github.com/o/r"), link.stdout)

        // An unknown machine is an error, not every secret "missing".
        let (unknown, unknownLog) = try runVMSecretsAgainstMock("secrets-unknown", arguments: ["vm", "secrets", "status", "no-such-machine"])
        XCTAssertEqual(unknown.status, 1, "stdout=\(unknown.stdout) stderr=\(unknown.stderr)")
        XCTAssertTrue(unknown.stderr.contains("no machine named no-such-machine"), unknown.stderr)
        XCTAssertFalse(unknownLog.methods.contains("vm.secrets_status"), unknownLog.methods.description)
        XCTAssertFalse(unknown.stdout.contains("missing"), unknown.stdout)
    }

    func testVMSecretsSyncPrintsOnlyWhatChanged() throws {
        let (result, log) = try runVMSecretsAgainstMock("secrets-sync", arguments: ["vm", "secrets", "sync", "brave-otter"])
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.list", "vm.secrets_status", "vm.secrets_sync"], log.methods.description)
        XCTAssertEqual(log.params(ofFirst: "vm.secrets_sync")?["id"] as? String, "vm-1")
        // ANTHROPIC_API_KEY was already current, so it is not listed.
        XCTAssertTrue(
            result.stdout.contains("Synced 3 changes to brave-otter: OPENAI_API_KEY updated, GH_TOKEN added, OLD_KEY removed"),
            result.stdout
        )
        XCTAssertFalse(result.stdout.contains("ANTHROPIC_API_KEY"), result.stdout)
        XCTAssertFalse(result.stdout.contains("delivered"), result.stdout)
    }

    func testVMSecretsRemoveOfAnUnstoredNameExitsNonZero() throws {
        let (result, _) = try runVMSecretsAgainstMock("secrets-rm", arguments: ["vm", "secrets", "rm", "NOT_STORED", "ANTHROPIC_API_KEY"])
        XCTAssertEqual(result.status, 1, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("OK removed ANTHROPIC_API_KEY"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Synced 1 change to brave-otter: ANTHROPIC_API_KEY removed"), result.stdout)
        XCTAssertTrue(result.stderr.contains("No secret named NOT_STORED for all machines."), result.stderr)
    }

    func testVMSecretsListShowsRelativeAgesAndJSONKeepsTimestamps() throws {
        let (text, _) = try runVMSecretsAgainstMock("secrets-ls", arguments: ["vm", "secrets", "ls"])
        XCTAssertEqual(text.status, 0, "stdout=\(text.stdout) stderr=\(text.stderr)")
        XCTAssertTrue(text.stdout.contains("VALUE ID"), text.stdout)
        XCTAssertTrue(text.stdout.contains("\u{2022}\u{2022}\u{2022}\u{2022}3f9a1c2e"), text.stdout)
        XCTAssertFalse(text.stdout.contains("2025-01-01T00:00:00Z"), text.stdout)
        XCTAssertTrue(text.stdout.contains("ago"), text.stdout)

        let (json, _) = try runVMSecretsAgainstMock("secrets-ls-json", arguments: ["vm", "secrets", "ls", "--json"])
        XCTAssertEqual(json.status, 0, "stdout=\(json.stdout) stderr=\(json.stderr)")
        XCTAssertTrue(json.stdout.contains("2025-01-01T00:00:00Z"), json.stdout)
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
            (["vm", "secrets", "--help"], ["cmux vm secrets set ANTHROPIC_API_KEY", "is refused", "machine:<m>", "a machine id or label"]),
            (["secrets", "--help"], ["cmux secrets set ANTHROPIC_API_KEY", "cmux secrets import"]),
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
