import XCTest
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
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
        if waitForSocket {
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

    private static func subscription(id: String, provider: String, label: String, sessions: Int = 0, usedPercent: Int? = nil) -> [String: Any] {
        var account: [String: Any] = [
            "id": id,
            "provider": provider,
            "providerAccountId": "acct-\(label)",
            "label": label,
            "state": "active",
            "credentialExpiresAt": NSNull(),
            "lastFailureCode": NSNull(),
            "cooldownUntil": NSNull(),
            "activeSessions": sessions,
        ]
        if let usedPercent {
            account["usage"] = ["rate_limit": ["primary_window": ["used_percent": usedPercent], "secondary_window": ["used_percent": 12]]]
        }
        return account
    }

    func testCoderouterSubscriptionsListPrintsUsageAndSessions() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "subscriptions", "list"],
            socketName: "coderouter-subs-list"
        ) { method, _ in
            guard method == "coderouter.accounts.list" else { return nil }
            return self.okResponse([
                "teamId": "team_local",
                "accounts": [
                    Self.subscription(id: Self.accountA, provider: "codex", label: "a@x.dev", sessions: 2, usedPercent: 40),
                    Self.subscription(id: Self.accountB, provider: "opencode-go", label: "b@x.dev"),
                ],
            ])
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            """
            Subscription accounts (2):
              \(Self.accountA)  codex a@x.dev  active  sessions=2  used 5h 40% / week 12%
              \(Self.accountB)  opencode-go b@x.dev  active  sessions=0

            """
        )
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"coderouter.accounts.list""#) })
    }

    func testCoderouterSubscriptionsRemoveResolvesALabel() throws {
        nonisolated(unsafe) var removedIDs: [String] = []
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "subs", "remove", "b@x.dev"],
            socketName: "coderouter-subs-remove"
        ) { method, params in
            switch method {
            case "coderouter.accounts.list":
                return self.okResponse(["teamId": "team_local", "accounts": [
                    Self.subscription(id: Self.accountA, provider: "codex", label: "a@x.dev"),
                    Self.subscription(id: Self.accountB, provider: "codex", label: "b@x.dev"),
                ]])
            case "coderouter.accounts.remove":
                removedIDs.append((params["accountId"] as? String) ?? "")
                return self.okResponse(["removed": true, "lastAccount": false, "legacyCleanupPending": false])
            default:
                return nil
            }
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(removedIDs, [Self.accountB])
        XCTAssertEqual(result.stdout, "OK removed codex b@x.dev\n")
    }

    func testCoderouterSubscriptionsAddWithoutTheCodeRouterCLIPrintsTheNpxCommand() throws {
        let emptyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-empty-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyPath) }
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "subscriptions", "add", "codex"],
            socketName: "coderouter-subs-add",
            extraEnvironment: ["PATH": emptyPath.path],
            waitForSocket: false
        ) { _, _ in nil }
        XCTAssertEqual(result.status, 127, result.stderr)
        XCTAssertTrue(result.stderr.contains("npx coderouter@latest add codex"), result.stderr)
        XCTAssertFalse(state.commands.contains { $0.contains("coderouter.accounts") })
    }

    func testCoderouterAccountsListsEveryKindInOneTable() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "accounts"],
            socketName: "coderouter-accounts-list"
        ) { method, _ in
            switch method {
            case "coderouter.claude_upstream.get":
                return self.okResponse(Self.listPayload([
                    Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work"),
                ]))
            case "coderouter.accounts.list":
                return self.okResponse(["teamId": "team_local", "accounts": [
                    Self.subscription(id: Self.accountB, provider: "codex", label: "a@x.dev", sessions: 2, usedPercent: 40),
                ]])
            default:
                return nil
            }
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, result.stdout)
        XCTAssertTrue(lines[0].hasPrefix("KIND"), lines[0])
        for column in ["ACCOUNT", "STATE", "USAGE", "ID"] { XCTAssertTrue(lines[0].contains(column), lines[0]) }
        let codexLine = try XCTUnwrap(lines.first { $0.hasPrefix("codex") })
        for cell in ["a@x.dev", "active", "2 sessions, 5h 40%, week 12%", "66666666"] { XCTAssertTrue(codexLine.contains(cell), codexLine) }
        let claudeLine = try XCTUnwrap(lines.first { $0.hasPrefix("claude") })
        for cell in ["sk-ant-oat01-...HIJ (work)", "active", "11111111"] { XCTAssertTrue(claudeLine.contains(cell), claudeLine) }
        XCTAssertFalse(result.stdout.contains(Self.accountB), "the table shows id prefixes, not full ids")
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"coderouter.accounts.list""#) })
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"coderouter.claude_upstream.get""#) })
    }

    func testCoderouterAccountsAddInfersClaudeFromTheEnvironment() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "accounts", "add", "--label", "work"],
            socketName: "coderouter-accounts-add-env",
            extraEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": Self.sampleOAuthToken]
        ) { method, params in
            guard method == "coderouter.claude_upstream.add" else { return nil }
            receivedParams = params
            return self.okResponse(["teamId": "team_local", "account": Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work"), "accountsTotal": 1])
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "anthropic_oauth")
        XCTAssertEqual(receivedParams["token"] as? String, Self.sampleOAuthToken)
        XCTAssertEqual(receivedParams["label"] as? String, "work")
        XCTAssertTrue(result.stdout.hasPrefix("OK added Claude upstream account: anthropic_oauth sk-ant-oat01-...HIJ (work)"), result.stdout)
    }

    func testCoderouterAccountsAddInfersTheKindFromAPastedSecret() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let apiKey = "sk-ant-api03-0123456789abcdefghijklmnopqrstuvwxyz"
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "accounts", "add", "--stdin"],
            socketName: "coderouter-accounts-add-stdin",
            standardInput: "\(apiKey)\n"
        ) { method, params in
            guard method == "coderouter.claude_upstream.add" else { return nil }
            receivedParams = params
            return self.okResponse(["teamId": "team_local", "account": Self.account(id: Self.accountB, kind: "anthropic_api_key", identifier: "sk-ant-...wxyz"), "accountsTotal": 2])
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "anthropic_api_key")
        XCTAssertEqual(receivedParams["apiKey"] as? String, apiKey)
    }

    func testCoderouterAccountsRemoveRoutesToTheOwningStore() throws {
        nonisolated(unsafe) var methods: [String] = []
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "accounts", "remove", "6666"],
            socketName: "coderouter-accounts-remove"
        ) { method, _ in
            methods.append(method)
            switch method {
            case "coderouter.claude_upstream.get":
                return self.okResponse(Self.listPayload([Self.account(id: Self.accountA, kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", label: "work")]))
            case "coderouter.accounts.list":
                return self.okResponse(["teamId": "team_local", "accounts": [Self.subscription(id: Self.accountB, provider: "codex", label: "a@x.dev")]])
            case "coderouter.accounts.remove":
                return self.okResponse(["removed": true, "lastAccount": false, "legacyCleanupPending": false])
            default:
                return nil
            }
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK removed codex a@x.dev\n")
        XCTAssertTrue(methods.contains("coderouter.accounts.remove"))
        XCTAssertFalse(methods.contains("coderouter.claude_upstream.remove"))
    }

    func testCoderouterAccountsPauseRefusesASubscription() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "accounts", "pause", "a@x.dev"],
            socketName: "coderouter-accounts-pause"
        ) { method, _ in
            switch method {
            case "coderouter.claude_upstream.get":
                return self.okResponse(Self.listPayload([]))
            case "coderouter.accounts.list":
                return self.okResponse(["teamId": "team_local", "accounts": [Self.subscription(id: Self.accountB, provider: "codex", label: "a@x.dev")]])
            default:
                return nil
            }
        }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("subscriptions cannot be paused"), result.stderr)
        XCTAssertFalse(state.commands.contains { $0.contains("claude_upstream.update") })
    }

    func testCoderouterUnknownVerbStillPassesThroughToTheInstalledCLI() throws {
        // With an empty PATH the passthrough cannot find `coderouter`/`cr`; the
        // point is that the socket is never consulted for a non-cmux verb.
        let emptyPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-empty-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyPath) }

        let (result, state) = try runCoderouterCLI(
            ["coderouter", "accounts"],
            socketName: "coderouter-passthrough",
            extraEnvironment: ["PATH": emptyPath.path],
            waitForSocket: false
        ) { _, _ in nil }

        XCTAssertEqual(result.status, 127, result.stderr)
        XCTAssertTrue(state.commands.isEmpty, "passthrough verbs must not touch the cmux socket: \(state.commands)")
    }
}
