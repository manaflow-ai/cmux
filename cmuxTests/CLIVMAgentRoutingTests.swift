import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for the `cmux vm` first-run fixes: `codex exec` outside a git
/// work tree, `vm agent --remote-cwd`, machine labels accepted wherever an id is,
/// `vm terminal read` on an exited terminal, and the `cmux vm --help` quick start.
/// The real CLI binary runs against a mock control socket; CLI-target code is not
/// linked into this bundle (see CLIVMTransferTests), so behavior is observed through
/// the requests the mock receives and the CLI's output.
extension CLINotifyProcessIntegrationRegressionTests {
    private final class VMAgentRoutingRequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [[String: Any]] = []

        func append(_ request: [String: Any]) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func snapshot() -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        /// Cloud requests only; the CLI may also resolve its caller with `system.*`.
        var vmMethods: [String] {
            snapshot().compactMap { $0["method"] as? String }.filter { !$0.hasPrefix("system.") }
        }

        func params(of method: String) -> [[String: Any]] {
            snapshot().filter { ($0["method"] as? String) == method }.compactMap { $0["params"] as? [String: Any] }
        }
    }

    /// What the mock answers: a result, or an error (`code`, `message`, optional `data`).
    private enum VMAgentRoutingReply {
        case result([String: Any])
        case error([String: Any])
    }

    private func runVMAgentRoutingCLI(
        _ name: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> VMAgentRoutingReply?
    ) throws -> (result: ProcessRunResult, log: VMAgentRoutingRequestLog) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMAgentRoutingRequestLog()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-agent-routing-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: home)
        }
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            if line.hasPrefix("auth ") { return "OK" }
            guard let request = self.jsonObject(line),
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            log.append(request)
            let params = (request["params"] as? [String: Any]) ?? [:]
            switch respond(method, params) {
            case .result(let result):
                return self.v2Response(id: id, ok: true, result: result)
            case .error(let error):
                return self.v2Response(id: id, ok: false, error: error)
            case nil:
                return self.v2Response(id: id, ok: false, error: ["code": "method_not_found", "message": "Unknown method"])
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_DEBUG")
        environment.merge(extraEnvironment) { _, override in override }
        let result = runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 60)
        wait(for: [handled], timeout: 60)
        XCTAssertFalse(result.timedOut, "\(arguments) timed out: \(result.stderr)")
        return (result, log)
    }

    private static let vmAgentRoutingNewTerminal: [String: Any] = [
        "terminal_id": "term_a1", "remote_workspace_id": "ws_1", "surface_id": "",
    ]

    /// The `bash -lc` script `surface.new_terminal` was asked to run.
    private func vmAgentRoutingScript(_ log: VMAgentRoutingRequestLog) -> String {
        let command = log.params(of: "surface.new_terminal").first?["command"] as? [String]
        return command?.last ?? ""
    }

    // MARK: - codex exec outside a git work tree

    func testVMAgentCodexPromptSkipsTheGitRepoCheck() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vac",
            arguments: ["vm", "agent", "--agent", "codex", "--machine", "vivid-newt", "--no-open", "--json", "--", "summarize the repo"]
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return .result([:])
            case "surface.new_terminal": return .result(Self.vmAgentRoutingNewTerminal)
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let payload = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(payload["command"] as? [String], ["codex", "exec", "--skip-git-repo-check", "summarize the repo"])
        XCTAssertTrue(vmAgentRoutingScript(log).contains("--skip-git-repo-check"), vmAgentRoutingScript(log))
    }

    func testVMAgentCodexExecPassthroughGetsTheFlagOnce() throws {
        let cases: [(args: [String], expected: [String])] = [
            (["exec", "fix it"], ["codex", "exec", "--skip-git-repo-check", "fix it"]),
            (["e", "fix it"], ["codex", "e", "--skip-git-repo-check", "fix it"]),
            (["exec", "--skip-git-repo-check", "fix it"], ["codex", "exec", "--skip-git-repo-check", "fix it"]),
            // Interactive codex asks about trust instead of exiting; it is left alone.
            (["--model", "o3"], ["codex", "--model", "o3"]),
        ]
        for testCase in cases {
            let (result, _) = try runVMAgentRoutingCLI(
                "vap",
                arguments: ["vm", "agent", "--agent", "codex", "--machine", "vivid-newt", "--no-open", "--json", "--"] + testCase.args
            ) { method, _ in
                switch method {
                case "vm.secrets_sync": return .result([:])
                case "surface.new_terminal": return .result(Self.vmAgentRoutingNewTerminal)
                default: return nil
                }
            }
            XCTAssertEqual(result.status, 0, "\(testCase.args): stdout=\(result.stdout) stderr=\(result.stderr)")
            let payload = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(payload["command"] as? [String], testCase.expected, "\(testCase.args)")
        }
    }

    // MARK: - --remote-cwd

    func testVMAgentRemoteCwdStartsTheAgentInThatDirectory() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vrc",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--remote-cwd", "~/work/app/", "--no-open", "--json", "--", "run the tests"]
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return .result([:])
            case "surface.new_terminal": return .result(Self.vmAgentRoutingNewTerminal)
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let payload = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(payload["cwd"] as? String, "~/work/app")
        XCTAssertNil(payload["synced_to"], "--remote-cwd alone pushes nothing")
        let script = vmAgentRoutingScript(log)
        // Home first, then the remote directory; a missing directory fails the launch.
        XCTAssertTrue(script.hasPrefix("cd \"$HOME\"; cd work/app || exit 1; "), script)
        XCTAssertFalse(log.vmMethods.contains("vm.file_put"), log.vmMethods.description)
    }

    func testVMAgentRemoteCwdRejectsAnEmptyValueBeforeTheSocket() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vre",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--remote-cwd", " ", "--", "hi"]
        ) { _, _ in nil }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("--remote-cwd needs a directory"), result.stderr)
        XCTAssertTrue(log.vmMethods.isEmpty, log.vmMethods.description)
    }

    // MARK: - Missing-secret preflight

    func testVMAgentWarnsAboutDeclaredSecretsTheMachineLacks() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vsp",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--no-open", "--json", "--", "hi"]
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return .result([:])
            case "vm.secrets_check":
                return .result([
                    "declared": [["name": "OPENAI_API_KEY", "stored": false, "source": ".cmux/cloud.json"]],
                    "missing": ["OPENAI_API_KEY"],
                ])
            case "surface.new_terminal": return .result(Self.vmAgentRoutingNewTerminal)
            default: return nil
            }
        }
        // A warning, not a blocker: the agent still starts.
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("OPENAI_API_KEY"), result.stderr)
        XCTAssertFalse(result.stdout.contains("OPENAI_API_KEY"), "stdout stays the JSON payload")
        let methods = log.vmMethods
        let check = try XCTUnwrap(methods.firstIndex(of: "vm.secrets_check"), methods.description)
        let start = try XCTUnwrap(methods.firstIndex(of: "surface.new_terminal"), methods.description)
        XCTAssertLessThan(check, start, "the warning prints before the agent starts")
        XCTAssertEqual(log.params(of: "vm.secrets_check").first?["id"] as? String, "vivid-newt")
    }

    // MARK: - Machine labels

    private static let vmLabelList: [String: Any] = [
        "vms": [
            ["id": "vivid-newt", "displayName": "cgc-eval-r0", "slug": "vivid-newt", "status": "running"],
            ["id": "brave-otter", "displayName": "", "slug": "brave-otter", "status": "running"],
        ],
    ]

    private static let vmNotFound: VMAgentRoutingReply = .error([
        "code": "vm_error",
        "message": "The Cloud VM request failed.",
        "data": ["http_status": 404, "backend_code": "vm_not_found"],
    ])

    func testVMExecAcceptsAMachineLabel() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vel",
            arguments: ["vm", "exec", "cgc-eval-r0", "--", "uname", "-a"]
        ) { method, params in
            switch method {
            case "vm.exec":
                guard params["id"] as? String == "vivid-newt" else { return Self.vmNotFound }
                return .result(["exit_code": 0, "stdout": "Linux\n", "stderr": ""])
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, "Linux\n")
        XCTAssertEqual(log.vmMethods, ["vm.exec", "vm.list", "vm.exec"], log.vmMethods.description)
        XCTAssertEqual(log.params(of: "vm.exec").map { $0["id"] as? String }, ["cgc-eval-r0", "vivid-newt"])
        // A label that resolves is silent: no "is the label of" line on every command.
        XCTAssertEqual(result.stderr, "", result.stderr)
    }

    func testVMMachineLabelResolutionIsTracedOnlyUnderCMUXDebug() throws {
        let (result, _) = try runVMAgentRoutingCLI(
            "veld",
            arguments: ["vm", "exec", "cgc-eval-r0", "--", "true"],
            extraEnvironment: ["CMUX_DEBUG": "1"]
        ) { method, params in
            switch method {
            case "vm.exec":
                guard params["id"] as? String == "vivid-newt" else { return Self.vmNotFound }
                return .result(["exit_code": 0, "stdout": "", "stderr": ""])
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(result.stderr.contains("cgc-eval-r0 is the label of vivid-newt"), result.stderr)
    }

    func testVMPortsNamesALabeledMachineByItsLabel() throws {
        // `vm ports <label>` with nothing listening: the empty-state line names the
        // machine the way it was typed, not by the id the label resolved to.
        let (result, log) = try runVMAgentRoutingCLI(
            "vpl",
            arguments: ["vm", "ports", "cgc-eval-r0"]
        ) { method, params in
            switch method {
            case "vm.exec":
                guard params["id"] as? String == "vivid-newt" else { return Self.vmNotFound }
                return .result(["exit_code": 0, "stdout": "", "stderr": ""])
            case "vm.list": return .result(Self.vmLabelList)
            case "vm.status": return .result(["id": "vivid-newt"])
            case "vm.publication_list": return .result(["publications": []])
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.params(of: "vm.exec").map { $0["id"] as? String }, ["cgc-eval-r0", "vivid-newt"])
        XCTAssertTrue(result.stdout.contains("listening inside cgc-eval-r0 yet"), result.stdout)
        XCTAssertFalse(result.stdout.contains("vivid-newt"), result.stdout)
        XCTAssertFalse(result.stderr.contains("is the label of"), result.stderr)
    }

    func testVMMachineIdsCostNoListRead() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vid",
            arguments: ["vm", "exec", "vivid-newt", "--", "true"]
        ) { method, _ in
            method == "vm.exec" ? .result(["exit_code": 0, "stdout": "", "stderr": ""]) : nil
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(log.vmMethods, ["vm.exec"], log.vmMethods.description)
    }

    func testVMMachineLabelResolvesInTargetsAndMachineFlags() throws {
        // `vm open <label>/<ws>/<term>` rewrites only the machine part of the target;
        // `vm terminal read <label> <term>` resolves the positional machine.
        let (readResult, readLog) = try runVMAgentRoutingCLI(
            "vtl",
            arguments: ["vm", "terminal", "read", "cgc-eval-r0", "term_7"]
        ) { method, params in
            switch method {
            case "vm.terminal_read":
                guard params["id"] as? String == "vivid-newt" else { return Self.vmNotFound }
                return .result(["text": "$ ls\n"])
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertEqual(readResult.status, 0, "stdout=\(readResult.stdout) stderr=\(readResult.stderr)")
        XCTAssertEqual(readLog.params(of: "vm.terminal_read").last?["terminal_id"] as? String, "term_7")
        XCTAssertEqual(readLog.params(of: "vm.terminal_read").last?["id"] as? String, "vivid-newt")

        let (agentResult, agentLog) = try runVMAgentRoutingCLI(
            "vml",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "cgc-eval-r0", "--no-open", "--json", "--", "hi"]
        ) { method, params in
            switch method {
            case "vm.secrets_sync": return .result([:])
            case "surface.new_terminal":
                guard params["machine"] as? String == "vivid-newt" else { return Self.vmNotFound }
                return .result(Self.vmAgentRoutingNewTerminal)
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertEqual(agentResult.status, 0, "stdout=\(agentResult.stdout) stderr=\(agentResult.stderr)")
        XCTAssertEqual(agentLog.params(of: "surface.new_terminal").map { $0["machine"] as? String }, ["cgc-eval-r0", "vivid-newt"])
        let payload = try XCTUnwrap(jsonObject(agentResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(payload["machine"] as? String, "vivid-newt")
    }

    func testVMAmbiguousMachineLabelListsTheMatches() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vam",
            arguments: ["vm", "exec", "eval", "--", "true"]
        ) { method, _ in
            switch method {
            case "vm.exec": return Self.vmNotFound
            case "vm.list":
                return .result(["vms": [
                    ["id": "vivid-newt", "displayName": "eval"],
                    ["id": "brave-otter", "displayName": "eval"],
                ]])
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("eval is the label of more than one machine"), result.stderr)
        XCTAssertTrue(result.stderr.contains("vivid-newt"), result.stderr)
        XCTAssertTrue(result.stderr.contains("brave-otter"), result.stderr)
        XCTAssertEqual(log.vmMethods, ["vm.exec", "vm.list"], "an ambiguous label never reruns the verb")
    }

    func testVMUnknownMachineKeepsTheOriginalError() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vun",
            arguments: ["vm", "pause", "ghost"]
        ) { method, _ in
            switch method {
            case "vm.pause": return Self.vmNotFound
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertEqual(log.vmMethods, ["vm.pause", "vm.list"], log.vmMethods.description)
        XCTAssertFalse(result.stderr.contains("is the label of"), result.stderr)
    }

    func testVMDestructiveVerbsNeedTheExactLabel() throws {
        // A case-folded label is a near miss on `vm rm`: refused, naming the machine.
        let (folded, foldedLog) = try runVMAgentRoutingCLI(
            "vrmf",
            arguments: ["vm", "rm", "CGC-EVAL-R0"]
        ) { method, params in
            switch method {
            case "vm.destroy":
                return params["id"] as? String == "vivid-newt" ? .result(["ok": true]) : Self.vmNotFound
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertNotEqual(folded.status, 0, folded.stdout)
        XCTAssertEqual(foldedLog.vmMethods, ["vm.destroy", "vm.list"], "nothing is destroyed on a near miss")
        XCTAssertTrue(folded.stderr.contains("Did you mean cgc-eval-r0 (vivid-newt)?"), folded.stderr)

        // The slug is not an alias for a destructive verb once the machine has a label.
        let (slug, slugLog) = try runVMAgentRoutingCLI(
            "vrms",
            arguments: ["vm", "pause", "proud-white-sloth"]
        ) { method, params in
            switch method {
            case "vm.pause":
                return params["id"] as? String == "vm-f944" ? .result(["ok": true]) : Self.vmNotFound
            case "vm.list":
                return .result(["vms": [["id": "vm-f944", "displayName": "my box", "slug": "proud-white-sloth", "status": "running"]]])
            default: return nil
            }
        }
        XCTAssertNotEqual(slug.status, 0, slug.stdout)
        XCTAssertEqual(slugLog.vmMethods, ["vm.pause", "vm.list"], slugLog.vmMethods.description)
        XCTAssertTrue(slug.stderr.contains("Did you mean my box (vm-f944)?"), slug.stderr)

        // The exact label still works.
        let (exact, exactLog) = try runVMAgentRoutingCLI(
            "vrme",
            arguments: ["vm", "rm", "cgc-eval-r0"]
        ) { method, params in
            switch method {
            case "vm.destroy":
                return params["id"] as? String == "vivid-newt" ? .result(["ok": true]) : Self.vmNotFound
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertEqual(exact.status, 0, "stdout=\(exact.stdout) stderr=\(exact.stderr)")
        XCTAssertEqual(exactLog.params(of: "vm.destroy").map { $0["id"] as? String }, ["cgc-eval-r0", "vivid-newt"])
    }

    func testVMNeverRerunsACommandThatRanOnTheMachine() throws {
        // The app accepted the label (as the backend accepts slugs) and the command ran
        // and failed with "not found" on its stderr: that is the command's own failure,
        // never a machine lookup, so it is not run a second time.
        let (result, log) = try runVMAgentRoutingCLI(
            "vrr",
            arguments: ["vm", "exec", "cgc-eval-r0", "--", "missing-tool"]
        ) { method, _ in
            switch method {
            case "vm.exec": return .result(["exit_code": 127, "stdout": "", "stderr": "bash: missing-tool: command not found\n"])
            case "vm.list": return .result(Self.vmLabelList)
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertEqual(log.vmMethods, ["vm.exec"], log.vmMethods.description)
    }

    // MARK: - vm terminal read on an exited terminal

    func testVMTerminalReadReportsAnExitedTerminalOnStderr() throws {
        let (result, _) = try runVMAgentRoutingCLI(
            "vtx",
            arguments: ["vm", "terminal", "read", "vivid-newt", "term_7"]
        ) { method, _ in
            guard method == "vm.terminal_read" else { return nil }
            return .result([
                "text": "done\n",
                "exited": true,
                "exit_code": 2,
                "message": "Terminal term_7 has exited (code 2); this is its last screen.",
            ])
        }
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "done\n\n", "stdout stays the screen")
        XCTAssertTrue(result.stderr.contains("Terminal term_7 has exited (code 2)"), result.stderr)
    }

    // MARK: - cmux vm --help

    func testVMHelpOpensWithAQuickStart() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("vhq")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(executablePath: cliPath, arguments: ["vm", "--help"], environment: environment, timeout: 30)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = result.stdout.components(separatedBy: "\n")
        let usage = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("Usage: cmux vm <") }, result.stdout)
        let quickStart = try XCTUnwrap(lines.firstIndex { $0 == "Quick start:" }, result.stdout)
        // The verbs follow in short groups, the rarely used ones below a "More:" fold.
        let groups = ["Machines:", "Work on a machine:", "Workspaces and terminals:", "More:"]
        let groupLines = try groups.map { heading in
            try XCTUnwrap(lines.firstIndex { $0 == heading }, "\(heading) missing from:\n\(result.stdout)")
        }
        XCTAssertEqual(groupLines, groupLines.sorted(), "groups out of order: \(groupLines)")
        XCTAssertLessThan(usage, quickStart)
        XCTAssertLessThan(quickStart, groupLines[0])
        XCTAssertLessThan(lines.count, 120, "the overview stays short; flags live in `cmux vm <verb> --help`")
        XCTAssertLessThan(quickStart, 8, "the quick start is on the first screen")
        let block = lines[quickStart..<min(quickStart + 7, lines.count)].joined(separator: "\n")
        for command in [
            "cmux vm secrets import --from-shell",
            "cmux vm clone owner/repo --agent claude",
            "cmux vm ls",
            "cmux vm open <machine>",
            "cmux vm agent --agent codex -- \"<task>\"",
        ] {
            XCTAssertTrue(block.contains(command), "\(command) missing from:\n\(block)")
        }
        // A verb folded to one overview line still prints its full flags on its own.
        let fork = runProcess(executablePath: cliPath, arguments: ["vm", "fork", "--help"], environment: environment, timeout: 30)
        XCTAssertEqual(fork.status, 0, fork.stderr)
        XCTAssertTrue(fork.stdout.contains("Usage: cmux vm fork <id> [--name <name>]"), fork.stdout)
        XCTAssertFalse(fork.stdout.contains("Usage: cmux vm <"), fork.stdout)
    }

    // MARK: - Waking a paused machine

    func testVMAgentAndOpenWakeAPausedMachineWithOneLine() throws {
        let (agent, agentLog) = try runVMAgentRoutingCLI(
            "vwk1",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--no-open", "--json", "--", "hi"]
        ) { method, _ in
            switch method {
            case "vm.status": return .result(["id": "vivid-newt", "status": "paused"])
            case "vm.resume": return .result(["id": "vivid-newt", "status": "running"])
            case "vm.secrets_sync": return .result([:])
            case "surface.new_terminal": return .result(Self.vmAgentRoutingNewTerminal)
            default: return nil
            }
        }
        XCTAssertEqual(agent.status, 0, "stdout=\(agent.stdout) stderr=\(agent.stderr)")
        let methods = agentLog.vmMethods
        let resume = try XCTUnwrap(methods.firstIndex(of: "vm.resume"), methods.description)
        XCTAssertLessThan(resume, try XCTUnwrap(methods.firstIndex(of: "vm.secrets_sync"), methods.description))
        XCTAssertLessThan(resume, try XCTUnwrap(methods.firstIndex(of: "surface.new_terminal"), methods.description))
        XCTAssertTrue(agent.stderr.contains("Waking vivid-newt\u{2026} "), agent.stderr)
        XCTAssertEqual(agent.stderr.components(separatedBy: "Waking").count, 2, "one line: \(agent.stderr)")

        // A running machine costs one status read and no resume.
        let (awake, awakeLog) = try runVMAgentRoutingCLI(
            "vwk2",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--no-open", "--json", "--", "hi"]
        ) { method, _ in
            switch method {
            case "vm.status": return .result(["id": "vivid-newt", "status": "running"])
            case "vm.secrets_sync": return .result([:])
            case "surface.new_terminal": return .result(Self.vmAgentRoutingNewTerminal)
            default: return nil
            }
        }
        XCTAssertEqual(awake.status, 0, "stdout=\(awake.stdout) stderr=\(awake.stderr)")
        XCTAssertFalse(awakeLog.vmMethods.contains("vm.resume"), awakeLog.vmMethods.description)
        XCTAssertFalse(awake.stderr.contains("Waking"), awake.stderr)

        // `vm open <machine>/<ws>` wakes the machine before it reads the machine's catalog.
        let (_, openLog) = try runVMAgentRoutingCLI(
            "vwk3",
            arguments: ["vm", "open", "vivid-newt/ws_1"]
        ) { method, _ in
            switch method {
            case "vm.status": return .result(["id": "vivid-newt", "status": "paused"])
            case "vm.resume": return .result(["id": "vivid-newt", "status": "running"])
            default: return nil
            }
        }
        let openMethods = openLog.vmMethods
        XCTAssertEqual(Array(openMethods.prefix(2)), ["vm.status", "vm.resume"], openMethods.description)
    }

    func testVMWakeFailureNamesTheMachineAndStops() throws {
        let (result, log) = try runVMAgentRoutingCLI(
            "vwk4",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--no-open", "--", "hi"]
        ) { method, _ in
            switch method {
            case "vm.status": return .result(["id": "vivid-newt", "status": "paused"])
            case "vm.resume":
                return .error([
                    "code": "vm_error",
                    "message": "Your plan's machine limit is reached.",
                    "data": ["http_status": 409, "backend_code": "vm_active_limit_exceeded"],
                ])
            default: return nil
            }
        }
        XCTAssertNotEqual(result.status, 0, result.stdout)
        XCTAssertTrue(result.stderr.contains("Could not wake vivid-newt: Your plan's machine limit is reached."), result.stderr)
        XCTAssertFalse(log.vmMethods.contains("surface.new_terminal"), log.vmMethods.description)
    }
}
