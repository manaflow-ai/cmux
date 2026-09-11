import XCTest
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// The CLI executable's CMUXCLI type is not part of the app test target. The
// provider-first alias is a pure routing helper shared with the app instead.
typealias CMUXCLI = CmuxTuiRemoteRouting

@Suite struct AgentAliasArgumentTests {
    final class BundleProbe {}

    @Test(arguments: ["claude", "codex", "opencode", "pi"], ["--help", "-h"])
    func helpKeepsTheProviderArgumentBoundary(agent: String, help: String) {
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, help]) == ["--agent", agent, help])
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "--", help]) == ["--agent", agent, "--", help])
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "prompt", help]) == ["--agent", agent, "--", "prompt", help])
        #expect(CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, help]))
        #expect(!CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, "--", help]))
        #expect(!CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, "prompt", help]))
        #expect(!CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, "--name", help]))
        #expect(!CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, "--machine", "--", help]))
    }

    @Test func agentSubcommandMatchingIgnoresCase() {
        #expect(CmuxTuiRemoteRouting.isAgentSubcommand("agent"))
        #expect(CmuxTuiRemoteRouting.isAgentSubcommand("Agent"))
        #expect(CmuxTuiRemoteRouting.isAgentSubcommand("AGENT"))
        #expect(!CmuxTuiRemoteRouting.isAgentSubcommand("agents"))
    }

    @Test(arguments: ["claude", "codex", "opencode", "pi"], ["--help", "-h"])
    func providerHelpDoesNotBypassWrapperValidation(agent: String, help: String) throws {
        for command in [["vm", "agent", "--agent", agent], ["agent", agent], ["coderouter", "agent", agent]] {
            let result = try runWithoutMutationRequests(command + ["--machine", "--", help])
            #expect(result.status != 0, "\(command): \(result.text)")
            #expect(result.text.contains("--machine requires a value"), "\(command): \(result.text)")
        }
    }

    @Test(arguments: ["open", "project"], ["--left", "--right", "--up", "--down"])
    func surfaceOpenRejectsTabAndSideBeforeMutation(subcommand: String, side: String) throws {
        let result = try runWithoutMutationRequests(["surface", subcommand, "vm/terminal/test", "--pane", "pane:1", "--tab", side])
        #expect(result.status != 0, "\(result.text)")
        #expect(result.text.contains("--tab and a pane side"), "\(result.text)")
    }

    @Test func browserLayoutRequiresURLBeforeMutation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-layout-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let surfaces: [[String: Any]] = [["type": "browser"], ["type": "browser", "url": ""], ["type": "browser", "url": NSNull()]]
        for surface in surfaces {
            try JSONSerialization.data(withJSONObject: ["pane": ["surfaces": [surface]]]).write(to: file)
            let result = try runWithoutMutationRequests(["vm", "layout", "apply", "test-machine", file.path])
            #expect(result.status != 0, "\(result.text)")
            #expect(result.text.contains(".pane.surfaces[0].url"), "\(result.text)")
            #expect(result.text.contains("browser surface needs url"), "\(result.text)")
        }
    }

    @Test(arguments: [["--json"], ["--sync"], ["--no-open"], ["--wait"], ["--output"], ["--timeout", "30"], ["--machine", "vm-agent-test"]])
    func aliasesAcceptLeadingCanonicalOptions(options: [String]) throws {
        for command in [["vm", "agent"], ["agent"], ["coderouter", "agent"]] {
            let result = try runWithoutMutationRequests(command + options + ["--agent", "claude", "--size", "1", "--", "reply pong"])
            #expect(result.status != 0, "\(command): \(result.text)")
            #expect(result.text.contains("vm agent: unknown size '1'"), "\(command): \(result.text)")
        }
    }

    @Test
    func topLevelAgentAliasReachesCanonicalValidation() throws {
        let result = try runWithoutMutationRequests(["agent", "claude", "--size", "1", "reply pong"])
        #expect(result.status != 0, "\(result.text)")
        #expect(result.text.contains("vm agent: unknown size '1'"), "\(result.text)")
    }

    @Test(arguments: ["--help", "-h"])
    func topLevelAgentHelpDoesNotConnect(help: String) throws {
        for command in [["agent", help], ["agent", "claude", help], ["agent", "--agent", "claude", help]] {
            let result = try runWithoutMutationRequests(command)
            #expect(result.status == 0, "\(result.text)")
            #expect(result.text.contains("Usage:") && result.text.contains("cmux agent"), "\(result.text)")
            #expect(!result.connected, "Help unexpectedly connected to the app socket")
        }
    }

    private func runWithoutMutationRequests(_ arguments: [String]) throws -> (status: Int32, text: String, connected: Bool) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-agent-help-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try BundledCLITestSupport.bundledCLIURL(for: BundleProbe.self)
        let socketPath = "/tmp/cmux-args-\(UUID().uuidString).sock"
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        defer { Darwin.close(listener); unlink(socketPath) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: socketPath.utf8CString.map { UInt8(bitPattern: $0) })
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(Darwin.listen(listener, 1) == 0)
        try #require(fcntl(listener, F_SETFL, O_NONBLOCK) == 0)
        do {
            let output = directory.appendingPathComponent("output")
            try Data().write(to: output)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = binary
            process.arguments = ["--socket", socketPath] + arguments
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
            environment["HOME"] = directory.path
            environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            let finished = ended.wait(timeout: .now() + 10) == .success
            if !finished { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let text = try String(contentsOf: output, encoding: .utf8)
            #expect(finished, "\(arguments): \(text)")
            let connection = Darwin.accept(listener, nil, nil)
            if connection >= 0 {
                defer { Darwin.close(connection) }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let received = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.recv(connection, bytes.baseAddress, bytes.count, MSG_DONTWAIT)
                }
                #expect(received == 0, "Unexpected socket request: \(String(decoding: buffer.prefix(max(received, 0)), as: UTF8.self))")
            }
            return (process.terminationStatus, text, connection >= 0)
        }
    }

    @Test(arguments: ["claude", "codex", "opencode", "pi"], ["--machine", "--size", "--cwd", "--name", "--remote-workspace", "--timeout"])
    func incompleteVMOptionRemainsAnOption(agent: String, option: String) {
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, option]) == ["--agent", agent, option])
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "--no-open", option]) == ["--agent", agent, "--no-open", option])
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "--", option]) == ["--agent", agent, "--", option])
        #expect(CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "prompt", option]) == ["--agent", agent, "--", "prompt", option])
    }

    /// The until-done flags belong to `cmux vm agent`, not to the agent: the
    /// short forms must keep them in front of `--`, and a `--timeout` value
    /// must not hide a later `--help`.
    @Test(arguments: ["claude", "codex", "opencode", "pi"])
    func untilDoneOptionsStayVMOptions(agent: String) {
        #expect(
            CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "--wait", "--output", "--timeout", "30", "fix the tests"])
                == ["--agent", agent, "--wait", "--output", "--timeout", "30", "--", "fix the tests"]
        )
        #expect(
            CmuxTuiRemoteRouting.vmAgentAliasArgs([agent, "--timeout", "30", "--", "--wait"])
                == ["--agent", agent, "--timeout", "30", "--", "--wait"]
        )
        #expect(CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, "--timeout", "30", "--help"]))
        #expect(CmuxTuiRemoteRouting.vmAgentRequestsHelp([agent, "--wait", "-h"]))
    }
}

// `cmux coderouter <status|machines|claude>` drives the app's `coderouter.*`
// socket methods; every other `cmux coderouter` verb still execs the installed
// CodeRouter CLI. These run the bundled CLI against a mock socket server and
// assert the wire method, the params, and the printed result.
extension CLINotifyProcessIntegrationRegressionTests {
    private static let sampleOAuthToken = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ"
    private static let accountA = "11111111-2222-4333-8444-555555555555"
    private static let accountB = "66666666-7777-4888-9999-000000000000"

    private static func account(
        id: String,
        kind: String,
        identifier: String,
        label: String = "",
        state: String = "active",
        cooldownUntil: Any = NSNull(),
        lastFailureCode: Any = NSNull()
    ) -> [String: Any] {
        [
            "id": id,
            "kind": kind,
            "label": label,
            "identifier": identifier,
            "region": NSNull(),
            "modelIds": [String: Any](),
            "state": state,
            "cooldownUntil": cooldownUntil,
            "lastFailureCode": lastFailureCode,
            "lastUsedAt": NSNull(),
            "createdAt": "2026-09-02T10:00:00.000Z",
            "updatedAt": "2026-09-02T10:00:00.000Z",
        ]
    }

    private static func listPayload(_ accounts: [[String: Any]]) -> [String: Any] {
        ["teamId": "team_local", "accounts": accounts, "upstream": accounts.first ?? NSNull()]
    }

    private func runCoderouterCLI(
        _ arguments: [String],
        socketName: String,
        standardInput: String? = nil,
        extraEnvironment: [String: String] = [:],
        waitForSocket: Bool = true,
        handler: @escaping (String, [String: Any]) -> String?
    ) throws -> (result: ProcessRunResult, state: MockSocketServerState) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(socketName)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandler: @Sendable (String) -> String = { [self] line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            let params = (payload["params"] as? [String: Any]) ?? [:]
            if let result = handler(method, params) {
                return result.replacingOccurrences(of: "__ID__", with: id)
            }
            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected", "message": "Unexpected method \(method)"]
            )
        }
        // A test that expects the CLI to stay off the socket must not hold a
        // case-bound expectation it never waits on: the detached accept loop
        // records any unexpected request without turning cleanup into a test
        // failure.
        let serverHandled: XCTestExpectation?
        if waitForSocket {
            serverHandled = startMockServer(
                listenerFD: listenerFD,
                state: state,
                handler: serverHandler
            )
        } else {
            startDetachedMockServer(
                listenerFD: listenerFD,
                state: state,
                handler: serverHandler
            )
            serverHandled = nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        for (key, value) in extraEnvironment {
            environment[key] = value
        }

        let result = runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            standardInput: standardInput,
            timeout: 5
        )
        if let serverHandled {
            wait(for: [serverHandled], timeout: 5)
        }
        return (result, state)
    }

    /// The mock responds with `__ID__` so the handler closure does not need the
    /// request id; `runCoderouterCLI` substitutes it.
    private func okResponse(_ result: [String: Any]) -> String {
        v2Response(id: "__ID__", ok: true, result: result)
    }

    func testCoderouterClaudeListPrintsEveryAccountWithHealth() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "list"],
            socketName: "coderouter-list"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.get" else { return nil }
            return self.okResponse(Self.listPayload([
                Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work"),
                Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz", state: "disabled"),
            ]))
        }

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            """
            Claude upstream accounts (2):
              \(Self.accountA)  anthropic_oauth sk-ant-oat01-...HIJ (work)  active
              \(Self.accountB)  anthropic_api_key sk-ant-...wxyz  disabled

            """
        )
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"coderouter.claude_upstream.get""#) },
            "Expected claude list to call coderouter.claude_upstream.get, saw \(state.commands)"
        )
    }

    func testCoderouterClaudeListWithoutAccountsExplainsSetup() throws {
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "show"],
            socketName: "coderouter-list-none"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.get" else { return nil }
            return self.okResponse(Self.listPayload([]))
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("Claude upstream accounts: none."), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux coderouter claude add oauth-token"), result.stdout)
    }

    func testCoderouterClaudeAddOAuthTokenReadsStdinAndNeverEchoesIt() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "add", "oauth-token", "--stdin", "--label", "work", "--team", "team_explicit"],
            socketName: "coderouter-add-oauth",
            standardInput: "\(Self.sampleOAuthToken)\n"
        ) { method, params in
            guard method == "coderouter.claude_upstream.add" else { return nil }
            receivedParams = params
            return self.okResponse([
                "teamId": "team_local",
                "account": Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work"),
                "accountsTotal": 2,
            ])
        }

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "anthropic_oauth")
        XCTAssertEqual(receivedParams["token"] as? String, Self.sampleOAuthToken)
        XCTAssertEqual(receivedParams["label"] as? String, "work")
        XCTAssertEqual(receivedParams["teamId"] as? String, "team_explicit")
        XCTAssertEqual(
            result.stdout,
            """
            OK added Claude upstream account: anthropic_oauth sk-ant-oat01-...HIJ (work)
              id: \(Self.accountA)
              team: team_local
            Cloud machines now route `claude` across 2 accounts.

            """
        )
        XCTAssertFalse(result.stdout.contains(Self.sampleOAuthToken), "the secret must never be printed")
        XCTAssertFalse(result.stderr.contains(Self.sampleOAuthToken), "the secret must never be printed")
        XCTAssertEqual(state.commands.filter { $0.contains(#""method":"coderouter.claude_upstream.add""#) }.count, 1)
    }

    func testCoderouterClaudeSetIsAnAliasForAddAndReadsTheEnvironment() throws {
        nonisolated(unsafe) var receivedToken: String?
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "set", "oauth-token", "--json"],
            socketName: "coderouter-set-oauth-env",
            extraEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": Self.sampleOAuthToken]
        ) { method, params in
            guard method == "coderouter.claude_upstream.add" else { return nil }
            receivedToken = params["token"] as? String
            return self.okResponse([
                "teamId": "team_local",
                "account": Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ"),
                "accountsTotal": 1,
            ])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedToken, Self.sampleOAuthToken)
        let printed = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(printed["accountsTotal"] as? Int, 1)
        XCTAssertEqual((printed["account"] as? [String: Any])?["kind"] as? String, "anthropic_oauth")
    }

    func testCoderouterClaudeAddOAuthTokenRejectsAPIKeyShapeBeforeTheSocket() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "add", "oauth-token"],
            socketName: "coderouter-add-oauth-bad",
            extraEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-api03-not-an-oauth-token-0123456789"],
            waitForSocket: false
        ) { _, _ in nil }

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not a Claude Code OAuth token"), result.stderr)
        XCTAssertFalse(
            state.commands.contains { $0.contains("coderouter.claude_upstream.add") },
            "a malformed token must not be sent to the app: \(state.commands)"
        )
    }

    func testCoderouterClaudeAddAPIKeyReadsEnvironment() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let apiKey = "sk-ant-api03-0123456789abcdefghijklmnopqrstuvwxyz"
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "add", "api-key"],
            socketName: "coderouter-add-api-key",
            extraEnvironment: ["ANTHROPIC_API_KEY": apiKey]
        ) { method, params in
            guard method == "coderouter.claude_upstream.add" else { return nil }
            receivedParams = params
            return self.okResponse([
                "teamId": "team_local",
                "account": Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz"),
                "accountsTotal": 1,
            ])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "anthropic_api_key")
        XCTAssertEqual(receivedParams["apiKey"] as? String, apiKey)
        XCTAssertNil(receivedParams["label"])
        XCTAssertTrue(result.stdout.hasPrefix("OK added Claude upstream account: anthropic_api_key sk-ant-...wxyz\n"), result.stdout)
    }

    func testCoderouterClaudeAddBedrockReadsAWSEnvironmentAndModelMap() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let (result, _) = try runCoderouterCLI(
            [
                "coderouter", "claude", "add", "bedrock",
                "--region", "us-west-2",
                "--model", "claude-sonnet-4-5=us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            ],
            socketName: "coderouter-add-bedrock",
            extraEnvironment: [
                "AWS_ACCESS_KEY_ID": "TESTKEYIDNOTREAL0001",
                "AWS_SECRET_ACCESS_KEY": "0123456789abcdefghijklmnopqrstuvwxyzABCD",
                "AWS_SESSION_TOKEN": "session-token-value",
            ]
        ) { method, params in
            guard method == "coderouter.claude_upstream.add" else { return nil }
            receivedParams = params
            var account = Self.account(id: Self.accountA, kind: "bedrock", identifier: "TEST...0001")
            account["region"] = "us-west-2"
            return self.okResponse(["teamId": "team_local", "account": account, "accountsTotal": 3])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "bedrock")
        XCTAssertEqual(receivedParams["region"] as? String, "us-west-2")
        XCTAssertEqual(receivedParams["accessKeyId"] as? String, "TESTKEYIDNOTREAL0001")
        XCTAssertEqual(receivedParams["secretAccessKey"] as? String, "0123456789abcdefghijklmnopqrstuvwxyzABCD")
        XCTAssertEqual(receivedParams["sessionToken"] as? String, "session-token-value")
        XCTAssertEqual(
            (receivedParams["modelIds"] as? [String: String])?["claude-sonnet-4-5"],
            "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
        )
        XCTAssertTrue(result.stdout.contains("  region: us-west-2\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("across 3 accounts."), result.stdout)
    }

    func testCoderouterClaudeRemoveByIdSkipsTheListAndRemoveByLabelResolvesIt() throws {
        nonisolated(unsafe) var removedIDs: [String] = []
        let (byID, byIDState) = try runCoderouterCLI(
            ["coderouter", "claude", "remove", Self.accountA],
            socketName: "coderouter-remove-id"
        ) { method, params in
            guard method == "coderouter.claude_upstream.remove" else { return nil }
            removedIDs.append((params["accountId"] as? String) ?? "")
            return self.okResponse(["removed": true, "count": 1])
        }
        XCTAssertEqual(byID.status, 0, byID.stderr)
        XCTAssertEqual(removedIDs, [Self.accountA])
        XCTAssertEqual(byID.stdout, "OK removed \(Self.accountA)\n")
        XCTAssertFalse(byIDState.commands.contains { $0.contains("coderouter.claude_upstream.get") })

        removedIDs = []
        let (byLabel, _) = try runCoderouterCLI(
            ["coderouter", "claude", "remove", "work"],
            socketName: "coderouter-remove-label"
        ) { method, params in
            switch method {
            case "coderouter.claude_upstream.get":
                return self.okResponse(Self.listPayload([
                    Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work"),
                    Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz"),
                ]))
            case "coderouter.claude_upstream.remove":
                removedIDs.append((params["accountId"] as? String) ?? "")
                return self.okResponse(["removed": true, "count": 1])
            default:
                return nil
            }
        }
        XCTAssertEqual(byLabel.status, 0, byLabel.stderr)
        XCTAssertEqual(removedIDs, [Self.accountA])
        XCTAssertEqual(byLabel.stdout, "OK removed anthropic_oauth sk-ant-oat01-...HIJ (work)\n")
    }

    func testCoderouterClaudeRemoveRefusesAnAmbiguousSelector() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "remove", "work"],
            socketName: "coderouter-remove-ambiguous"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.get" else { return nil }
            return self.okResponse(Self.listPayload([
                Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work"),
                Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz", label: "work"),
            ]))
        }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("matches 2 Claude upstream accounts"), result.stderr)
        XCTAssertFalse(state.commands.contains { $0.contains("coderouter.claude_upstream.remove") })
    }

    func testCoderouterClaudeDisableSendsAnUpdate() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "disable", Self.accountB],
            socketName: "coderouter-disable"
        ) { method, params in
            guard method == "coderouter.claude_upstream.update" else { return nil }
            receivedParams = params
            return self.okResponse(["teamId": "team_local", "account": Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz", state: "disabled")])
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["accountId"] as? String, Self.accountB)
        XCTAssertEqual(receivedParams["state"] as? String, "disabled")
        XCTAssertEqual(result.stdout, "OK disabled \(Self.accountB)\n")
    }

    func testCoderouterClaudeClearIsIdempotent() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "clear"],
            socketName: "coderouter-clear"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.clear" else { return nil }
            return self.okResponse(["removed": false, "count": 0])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "No Claude upstream accounts were set.\n")
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"coderouter.claude_upstream.clear""#) })
    }

    func testCoderouterMachinesPrintsPerMachineSpend() throws {
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "machines"],
            socketName: "coderouter-machines"
        ) { method, _ in
            guard method == "coderouter.machines" else { return nil }
            return self.okResponse([
                "teamId": "team_local",
                "periodDays": 30,
                "kind": "ready",
                "asOf": "2026-09-02T10:00:00.000Z",
                "machines": [
                    [
                        "vmId": "vm_a",
                        "providerVmId": "fs-1",
                        "displayName": "builder",
                        "totals": ["inputTokens": 1000, "cachedInputTokens": 0, "outputTokens": 234, "totalTokens": 1234, "apiEquivalentUsd": 0.5],
                    ] as [String: Any],
                ],
            ])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "vm_a  builder  tokens=1234  $0.50\nTotal (30d): 1 machine, tokens=1234, $0.50 API-equivalent\n"
        )
    }

    func testCoderouterAgentUsesTheSharedVMAgentPath() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-agent-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let (result, state) = try runCoderouterCLI(
            ["coderouter", "agent", "claude", "--machine", "vm-agent-test", "--no-open", "--json", "--", "reply exactly pong"],
            socketName: "coderouter-agent",
            extraEnvironment: ["HOME": home.path]
        ) { method, params in
            guard method == "surface.new_terminal" else { return nil }
            XCTAssertEqual(params["machine"] as? String, "vm-agent-test")
            let command = params["command"] as? [String] ?? []
            XCTAssertEqual(command.first, "bash")
            XCTAssertTrue(command.last?.contains("exec 'claude' '-p' 'reply exactly pong'") == true, command.description)
            return self.okResponse([
                "machine": "vm-agent-test",
                "terminal_id": "term_agent_test",
                "remote_workspace_id": "ws_agent_test",
            ])
        }

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let payload = try XCTUnwrap(jsonObject(result.stdout))
        XCTAssertEqual(payload["agent"] as? String, "claude")
        XCTAssertEqual(payload["terminal_id"] as? String, "term_agent_test")
        XCTAssertEqual(payload["workspace_id"] as? String, "ws_agent_test")
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"surface.new_terminal""#) })
    }

    func testProviderFirstAgentAliasAddsTheCanonicalSeparator() {
        XCTAssertEqual(
            CMUXCLI.vmAgentAliasArgs(["claude", "--machine", "vm-agent-test", "reply exactly pong"]),
            ["--agent", "claude", "--machine", "vm-agent-test", "--", "reply exactly pong"]
        )
        XCTAssertEqual(
            CMUXCLI.vmAgentAliasArgs(["codex", "--", "exec", "summarize"]),
            ["--agent", "codex", "--", "exec", "summarize"]
        )
    }

    func testCoderouterStatusCombinesAuthAndAccounts() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "status"],
            socketName: "coderouter-status"
        ) { method, _ in
            switch method {
            case "auth.status":
                return self.okResponse([
                    "signed_in": true,
                    "user": ["email": "dev@example.com"],
                    "selected_team_id": "team_local",
                ])
            case "coderouter.claude_upstream.get":
                return self.okResponse(Self.listPayload([
                    Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz"),
                ]))
            default:
                return nil
            }
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            """
            Signed in as dev@example.com
            Team: team_local
            Claude upstream accounts (1):
              \(Self.accountB)  anthropic_api_key sk-ant-...wxyz  active

            """
        )
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"auth.status""#) })
    }

    func testCoderouterUnknownVerbStillPassesThroughToTheInstalledCLI() throws {
        // With an empty PATH and an empty HOME (the passthrough also looks in
        // the installer's ~/.coderouter/bin) there is no `coderouter`/`cr` to
        // run; the point is that the socket is never consulted for a non-cmux
        // verb.
        let emptyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-empty-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyPath) }

        let (result, state) = try runCoderouterCLI(
            ["coderouter", "accounts"],
            socketName: "coderouter-passthrough",
            extraEnvironment: [
                "PATH": emptyPath.path,
                "HOME": emptyPath.path,
                "CFFIXED_USER_HOME": emptyPath.path,
            ],
            waitForSocket: false
        ) { _, _ in nil }

        XCTAssertEqual(result.status, 127, result.stderr)
        XCTAssertTrue(state.commands.isEmpty, "passthrough verbs must not touch the cmux socket: \(state.commands)")
    }
}
