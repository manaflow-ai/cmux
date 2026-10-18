import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Black-box coverage for `cmux vm doctor` and the readiness warning `cmux vm agent`
/// prints before it starts an agent. The real CLI binary runs against a mock control
/// socket that plays the app's `vm.agent_readiness`; CLI-target code is not linked
/// into this bundle (see CLIVMTransferTests), so behavior is observed through the
/// requests the mock receives and the CLI's output.
extension CLINotifyProcessIntegrationRegressionTests {
    private final class VMDoctorRequestLog: @unchecked Sendable {
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
            return requests.compactMap { $0["method"] as? String }.filter { !$0.hasPrefix("system.") }
        }

        func params(of method: String) -> [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return requests.filter { ($0["method"] as? String) == method }.compactMap { $0["params"] as? [String: Any] }
        }
    }

    /// The app's answer for a machine where Claude Code is ready and Codex has nothing.
    private static let vmDoctorReadiness: [String: Any] = [
        "machine": "vm-1",
        "supported": true,
        "probe": false,
        "fast": false,
        "checked_at": "2026-10-15T00:00:00Z",
        "agents": [
            [
                "agent": "claude", "name": "Claude Code", "installed": true, "source": "key",
                "key": "ANTHROPIC_API_KEY", "credential": "Cloud Secrets: ANTHROPIC_API_KEY",
                "endpoint": "api.anthropic.com", "endpoint_kind": "provider", "status": "ready",
                "status_label": "Ready", "detail": "Sends ANTHROPIC_API_KEY to Anthropic directly.",
                "fix": NSNull(), "warning": NSNull(),
            ],
            [
                "agent": "codex", "name": "Codex", "installed": true, "source": "none",
                "key": NSNull(), "credential": "None", "endpoint": "\u{2014}", "endpoint_kind": "none",
                "status": "problem", "status_label": "Needs a fix",
                "detail": "No API key or sign-in: it will stop at a sign-in prompt or an auth error.",
                "fix": "Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY",
                "warning": "Warning: Codex may not start: No API key or sign-in: it will stop at a sign-in prompt or an auth error. Fix: Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY",
            ],
        ],
        "problems": 1,
        "attention": 0,
    ]

    private func runVMDoctorCLI(
        _ name: String,
        arguments: [String],
        respond: @escaping @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]?
    ) throws -> (result: ProcessRunResult, log: VMDoctorRequestLog) {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let log = VMDoctorRequestLog()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-doctor-\(UUID().uuidString.prefix(8))", isDirectory: true)
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
            if let result = respond(method, params) {
                return self.v2Response(id: id, ok: true, result: result)
            }
            return self.v2Response(id: id, ok: false, error: ["code": "method_not_found", "message": "Unknown method"])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_DEBUG")
        let result = runProcess(executablePath: cliPath, arguments: arguments, environment: environment, timeout: 60)
        wait(for: [handled], timeout: 60)
        XCTAssertFalse(result.timedOut, "\(arguments) timed out: \(result.stderr)")
        return (result, log)
    }

    func testVMDoctorPrintsATableWithOneFixLinePerProblem() throws {
        let (result, log) = try runVMDoctorCLI("vm-doctor-table", arguments: ["vm", "doctor", "brave-otter"]) { method, _ in
            method == "vm.agent_readiness" ? Self.vmDoctorReadiness : nil
        }
        // A problem exits 1, after the report.
        XCTAssertEqual(result.status, 1, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertEqual(log.methods, ["vm.agent_readiness"], log.methods.description)
        let params = try XCTUnwrap(log.params(of: "vm.agent_readiness").first)
        XCTAssertEqual(params["id"] as? String, "brave-otter")
        XCTAssertEqual(params["probe"] as? Bool, false)
        XCTAssertNil(params["agent"])
        XCTAssertNil(params["fast"], "doctor is the full check")

        let lines = result.stdout.components(separatedBy: "\n")
        let header = try XCTUnwrap(lines.first)
        XCTAssertTrue(header.hasPrefix("AGENT"), result.stdout)
        for column in ["CREDENTIAL", "ENDPOINT", "STATUS"] {
            XCTAssertTrue(header.contains(column), header)
        }
        XCTAssertTrue(result.stdout.contains("Claude Code"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Cloud Secrets: ANTHROPIC_API_KEY"), result.stdout)
        XCTAssertTrue(result.stdout.contains("api.anthropic.com"), result.stdout)
        XCTAssertTrue(result.stdout.contains("Codex: No API key or sign-in"), result.stdout)
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("  Fix: ") },
            ["  Fix: Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY"],
            "one Fix: line per problem, none for a ready agent: \(result.stdout)"
        )
        XCTAssertTrue(result.stdout.contains("brave-otter: 1 of 2 ready."), result.stdout)
        XCTAssertTrue(result.stdout.contains("cmux vm doctor brave-otter --probe"), result.stdout)
        XCTAssertTrue(result.stderr.contains("1 agent on brave-otter needs a fix"), result.stderr)
    }

    func testVMDoctorPassesAgentAndProbeAndPrintsJSON() throws {
        let (result, log) = try runVMDoctorCLI(
            "vm-doctor-json",
            arguments: ["vm", "doctor", "brave-otter", "--agent", "git", "--probe", "--json"]
        ) { method, _ in
            guard method == "vm.agent_readiness" else { return nil }
            var ready = Self.vmDoctorReadiness
            ready["problems"] = 0
            ready["probe"] = true
            return ready
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let params = try XCTUnwrap(log.params(of: "vm.agent_readiness").first)
        XCTAssertEqual(params["agent"] as? String, "git")
        XCTAssertEqual(params["probe"] as? Bool, true)
        let payload = try XCTUnwrap(jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), result.stdout)
        XCTAssertEqual(payload["supported"] as? Bool, true)
        XCTAssertEqual((payload["agents"] as? [[String: Any]])?.count, 2)
    }

    func testVMDoctorRefusesAnUnknownAgentBeforeTheSocket() throws {
        let (result, log) = try runVMDoctorCLI("vm-doctor-agent", arguments: ["vm", "doctor", "brave-otter", "--agent", "vim"]) { _, _ in nil }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("--agent must be one of"), result.stderr)
        XCTAssertFalse(log.methods.contains("vm.agent_readiness"), log.methods.description)
    }

    func testVMDoctorOnAnOlderAppSaysToUpdate() throws {
        let (result, _) = try runVMDoctorCLI("vm-doctor-old", arguments: ["vm", "doctor", "vm-1"]) { _, _ in nil }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("cannot check agents yet"), result.stderr)
    }

    func testVMDoctorOnAMachineThatCannotAnswer() throws {
        let (result, _) = try runVMDoctorCLI("vm-doctor-unsupported", arguments: ["vm", "doctor", "vm-1"]) { method, _ in
            method == "vm.agent_readiness" ? ["machine": "vm-1", "supported": false, "agents": [], "problems": 0] : nil
        }
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("did not answer the check"), result.stderr)
        XCTAssertTrue(result.stderr.contains("cmux vm wait vm-1 --wake"), result.stderr)
    }

    func testVMAgentWarnsOnceBeforeLaunchAndStillStarts() throws {
        let (result, log) = try runVMDoctorCLI(
            "vm-agent-readiness",
            arguments: ["vm", "agent", "--agent", "codex", "--machine", "vivid-newt", "--no-open", "--json", "--", "hi"]
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return [:]
            case "vm.agent_readiness": return Self.vmDoctorReadiness
            case "surface.new_terminal": return ["terminal_id": "term_a1", "remote_workspace_id": "ws_1", "surface_id": ""]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        let readiness = try XCTUnwrap(log.params(of: "vm.agent_readiness").first, log.methods.description)
        XCTAssertEqual(readiness["id"] as? String, "vivid-newt")
        XCTAssertEqual(readiness["agent"] as? String, "codex")
        XCTAssertEqual(readiness["fast"] as? Bool, true, "the pre-launch check never reaches the network")
        let methods = log.methods
        let check = try XCTUnwrap(methods.firstIndex(of: "vm.agent_readiness"), methods.description)
        let start = try XCTUnwrap(methods.firstIndex(of: "surface.new_terminal"), methods.description)
        XCTAssertLessThan(check, start, "checked before the agent starts")
        // Only the chosen agent's line, exactly once, on stderr.
        let warnings = result.stderr.components(separatedBy: "\n").filter { $0.hasPrefix("Warning: ") && $0.contains("may not start") }
        XCTAssertEqual(warnings, [
            "Warning: Codex may not start: No API key or sign-in: it will stop at a sign-in prompt or an auth error. Fix: Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY",
        ], result.stderr)
        XCTAssertFalse(result.stdout.contains("may not start"), "stdout stays the JSON payload")
    }

    func testVMAgentIsSilentWhenTheAppCannotCheck() throws {
        let (result, log) = try runVMDoctorCLI(
            "vm-agent-readiness-old",
            arguments: ["vm", "agent", "--agent", "claude", "--machine", "vivid-newt", "--no-open", "--json", "--", "hi"]
        ) { method, _ in
            switch method {
            case "vm.secrets_sync": return [:]
            case "surface.new_terminal": return ["terminal_id": "term_a1", "remote_workspace_id": "ws_1", "surface_id": ""]
            default: return nil
            }
        }
        XCTAssertEqual(result.status, 0, "stdout=\(result.stdout) stderr=\(result.stderr)")
        XCTAssertTrue(log.methods.contains("surface.new_terminal"), log.methods.description)
        XCTAssertFalse(result.stderr.contains("may not start"), result.stderr)
    }
}
