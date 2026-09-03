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

    private static func upstreamPayload(kind: String, identifier: String, created: Bool? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "teamId": "team_local",
            "upstream": [
                "kind": kind,
                "identifier": identifier,
                "region": NSNull(),
                "modelIds": [String: Any](),
                "updatedAt": "2026-09-02T10:00:00.000Z",
            ] as [String: Any],
        ]
        if let created { payload["created"] = created }
        return payload
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

    func testCoderouterClaudeShowPrintsMaskedUpstream() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "show"],
            socketName: "coderouter-show"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.get" else { return nil }
            return self.okResponse(Self.upstreamPayload(kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ"))
        }

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "Claude upstream: anthropic_oauth sk-ant-oat01-...HIJ\n  updated: 2026-09-02T10:00:00.000Z\n"
        )
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"coderouter.claude_upstream.get""#) },
            "Expected claude show to call coderouter.claude_upstream.get, saw \(state.commands)"
        )
    }

    func testCoderouterClaudeShowWithoutUpstreamExplainsSetup() throws {
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "show"],
            socketName: "coderouter-show-none"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.get" else { return nil }
            return self.okResponse(["teamId": "team_local", "upstream": NSNull()])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("Claude upstream: none."), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux coderouter claude set oauth-token"), result.stdout)
    }

    func testCoderouterClaudeSetOAuthTokenReadsStdinAndNeverEchoesIt() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "set", "oauth-token", "--stdin", "--team", "team_explicit"],
            socketName: "coderouter-set-oauth",
            standardInput: "\(Self.sampleOAuthToken)\n"
        ) { method, params in
            guard method == "coderouter.claude_upstream.set" else { return nil }
            receivedParams = params
            return self.okResponse(Self.upstreamPayload(kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", created: true))
        }

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "anthropic_oauth")
        XCTAssertEqual(receivedParams["token"] as? String, Self.sampleOAuthToken)
        XCTAssertEqual(receivedParams["teamId"] as? String, "team_explicit")
        XCTAssertEqual(
            result.stdout,
            "OK Claude upstream set: anthropic_oauth sk-ant-oat01-...HIJ\n  team: team_local\nCloud machines route `claude` through this upstream now.\n"
        )
        XCTAssertFalse(result.stdout.contains(Self.sampleOAuthToken), "the secret must never be printed")
        XCTAssertFalse(result.stderr.contains(Self.sampleOAuthToken), "the secret must never be printed")
        XCTAssertEqual(state.commands.filter { $0.contains(#""method":"coderouter.claude_upstream.set""#) }.count, 1)
    }

    func testCoderouterClaudeSetOAuthTokenReadsEnvironmentVariable() throws {
        nonisolated(unsafe) var receivedToken: String?
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "set", "oauth-token", "--json"],
            socketName: "coderouter-set-oauth-env",
            extraEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": Self.sampleOAuthToken]
        ) { method, params in
            guard method == "coderouter.claude_upstream.set" else { return nil }
            receivedToken = params["token"] as? String
            return self.okResponse(Self.upstreamPayload(kind: "anthropic_oauth", identifier: "sk-ant-oat01-...HIJ", created: false))
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedToken, Self.sampleOAuthToken)
        let printed = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(printed["created"] as? Bool, false)
        XCTAssertEqual((printed["upstream"] as? [String: Any])?["kind"] as? String, "anthropic_oauth")
    }

    func testCoderouterClaudeSetOAuthTokenRejectsAPIKeyShapeBeforeTheSocket() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "set", "oauth-token"],
            socketName: "coderouter-set-oauth-bad",
            extraEnvironment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-api03-not-an-oauth-token-0123456789"],
            waitForSocket: false
        ) { _, _ in nil }

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not a Claude Code OAuth token"), result.stderr)
        XCTAssertFalse(
            state.commands.contains { $0.contains("coderouter.claude_upstream.set") },
            "a malformed token must not be sent to the app: \(state.commands)"
        )
    }

    func testCoderouterClaudeSetAPIKeyReadsEnvironment() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let apiKey = "sk-ant-api03-0123456789abcdefghijklmnopqrstuvwxyz"
        let (result, _) = try runCoderouterCLI(
            ["coderouter", "claude", "set", "api-key"],
            socketName: "coderouter-set-api-key",
            extraEnvironment: ["ANTHROPIC_API_KEY": apiKey]
        ) { method, params in
            guard method == "coderouter.claude_upstream.set" else { return nil }
            receivedParams = params
            return self.okResponse(Self.upstreamPayload(kind: "anthropic_api_key", identifier: "sk-ant-...wxyz", created: true))
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(receivedParams["kind"] as? String, "anthropic_api_key")
        XCTAssertEqual(receivedParams["apiKey"] as? String, apiKey)
        XCTAssertTrue(result.stdout.hasPrefix("OK Claude upstream set: anthropic_api_key sk-ant-...wxyz\n"), result.stdout)
    }

    func testCoderouterClaudeSetBedrockReadsAWSEnvironmentAndModelMap() throws {
        nonisolated(unsafe) var receivedParams: [String: Any] = [:]
        let (result, _) = try runCoderouterCLI(
            [
                "coderouter", "claude", "set", "bedrock",
                "--region", "us-west-2",
                "--model", "claude-sonnet-4-5=us.anthropic.claude-sonnet-4-5-20250929-v1:0",
            ],
            socketName: "coderouter-set-bedrock",
            extraEnvironment: [
                "AWS_ACCESS_KEY_ID": "TESTKEYIDNOTREAL0001",
                "AWS_SECRET_ACCESS_KEY": "0123456789abcdefghijklmnopqrstuvwxyzABCD",
                "AWS_SESSION_TOKEN": "session-token-value",
            ]
        ) { method, params in
            guard method == "coderouter.claude_upstream.set" else { return nil }
            receivedParams = params
            var payload = Self.upstreamPayload(kind: "bedrock", identifier: "TEST...0001", created: true)
            var upstream = payload["upstream"] as? [String: Any]
            upstream?["region"] = "us-west-2"
            payload["upstream"] = upstream
            return self.okResponse(payload)
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
    }

    func testCoderouterClaudeClearIsIdempotent() throws {
        let (result, state) = try runCoderouterCLI(
            ["coderouter", "claude", "clear"],
            socketName: "coderouter-clear"
        ) { method, _ in
            guard method == "coderouter.claude_upstream.clear" else { return nil }
            return self.okResponse(["removed": false])
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "No Claude upstream was set.\n")
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

    func testCoderouterStatusCombinesAuthAndUpstream() throws {
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
                return self.okResponse(Self.upstreamPayload(kind: "anthropic_api_key", identifier: "sk-ant-...wxyz"))
            default:
                return nil
            }
        }

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout,
            "Signed in as dev@example.com\nTeam: team_local\nClaude upstream: anthropic_api_key sk-ant-...wxyz\n  updated: 2026-09-02T10:00:00.000Z\n"
        )
        XCTAssertTrue(state.commands.contains { $0.contains(#""method":"auth.status""#) })
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
