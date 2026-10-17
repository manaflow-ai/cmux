import CmuxCloud
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Agents section and `vm.agent_readiness` read one service: the section's
/// model and the socket payload must agree on status, fix, and the key a button
/// sets, and neither may carry anything but names and fixed words.
@MainActor
final class CloudAgentReadinessModelTests: XCTestCase {
    private static let output = """
    cmux-agent-readiness v1 plane=1 auth=1
    agent=claude installed=1 version=2.1.300 source=key key=ANTHROPIC_API_KEY mode=team reason=team-account endpoint=provider host=api.anthropic.com probe=401 helper=-
    agent=codex installed=1 version=0.162.1 source=none key=- mode=own reason=no-team-account endpoint=none host=- probe=- helper=-
    agent=opencode installed=1 version=- source=routing key=- mode=team reason=team-account endpoint=cmux host=coderouter.cmux.internal probe=- helper=-
    cmux-agent-readiness end
    """

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [(machine: String, command: String, timeoutMs: Int)] = []
        func append(_ machine: String, _ command: String, _ timeoutMs: Int) {
            lock.lock(); commands.append((machine, command, timeoutMs)); lock.unlock()
        }
        var all: [(machine: String, command: String, timeoutMs: Int)] {
            lock.lock(); defer { lock.unlock() }; return commands
        }
    }

    private func service(
        calls: Calls,
        result: @escaping @Sendable () throws -> VMExecResult
    ) -> CloudAgentReadinessService {
        CloudAgentReadinessService(
            exec: { machine, command, timeoutMs in
                calls.append(machine, command, timeoutMs)
                return try result()
            },
            vaultNames: { _ in ["ANTHROPIC_API_KEY"] },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func waitUntilSettled(_ model: CloudAgentReadinessModel) async {
        await model.settle()
    }

    func testCheckNowProbesAndRowsCarryFixes() async {
        let calls = Calls()
        let model = CloudAgentReadinessModel(
            machineID: "vm-1",
            machineLabel: "brave-otter",
            service: service(calls: calls) { VMExecResult(exitCode: 0, stdout: Self.output, stderr: "") }
        )
        model.checkIfNeeded()
        await waitUntilSettled(model)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertFalse(model.probed, "the first look sends no key anywhere")
        XCTAssertTrue(calls.all.first?.command.hasSuffix(" cmux-agent-readiness all 0 0") == true)

        model.check(probe: true)
        await waitUntilSettled(model)
        XCTAssertTrue(model.probed)
        XCTAssertTrue(calls.all.last?.command.hasSuffix(" cmux-agent-readiness all 1 0") == true)
        XCTAssertEqual(calls.all.last?.timeoutMs, 60_000)

        XCTAssertEqual(model.assessments.map(\.entry.agent), [.claude, .codex, .opencode])
        XCTAssertEqual(model.issues.map(\.entry.agent), [.claude, .codex], "problems first; ready rows are not issues")
        let claude = model.assessments[0]
        XCTAssertEqual(claude.credential, "Cloud Secrets: ANTHROPIC_API_KEY")
        XCTAssertEqual(CloudAgentReadinessModel.keyToSet(for: claude), "ANTHROPIC_API_KEY", "a rejected key is replaced")
        XCTAssertEqual(CloudAgentReadinessModel.keyToSet(for: model.assessments[1]), "OPENAI_API_KEY", "a missing key is added")
        XCTAssertNil(CloudAgentReadinessModel.keyToSet(for: model.assessments[2]))
        XCTAssertEqual(model.assessments[1].fix, "Add OPENAI_API_KEY: cmux vm secrets set OPENAI_API_KEY")
        XCTAssertEqual(model.checkedLabel(now: Date(timeIntervalSince1970: 1_030)), "Checked just now")
    }

    func testAMachineThatCannotRunTheCheckIsUnavailable() async {
        let model = CloudAgentReadinessModel(
            machineID: "vm-1",
            machineLabel: nil,
            service: service(calls: Calls()) { VMExecResult(exitCode: 127, stdout: "", stderr: "sh: not found") }
        )
        model.check(probe: false)
        await waitUntilSettled(model)
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertTrue(model.assessments.isEmpty)
    }

    /// `probed` describes the rows shown; an unavailable answer shows none.
    func testAnUnavailableCheckAfterAProbeClearsProbed() async {
        final class Answer: @unchecked Sendable {
            var supported = true
        }
        let answer = Answer()
        let model = CloudAgentReadinessModel(
            machineID: "vm-1",
            machineLabel: nil,
            service: service(calls: Calls()) {
                answer.supported
                    ? VMExecResult(exitCode: 0, stdout: Self.output, stderr: "")
                    : VMExecResult(exitCode: 127, stdout: "", stderr: "sh: not found")
            }
        )
        model.check(probe: true)
        await waitUntilSettled(model)
        XCTAssertTrue(model.probed)

        answer.supported = false
        model.check(probe: false)
        await waitUntilSettled(model)
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertFalse(model.probed)
    }

    func testAFailedCheckShowsFixedCopy() async {
        struct Boom: Error {}
        let model = CloudAgentReadinessModel(
            machineID: "vm-1",
            machineLabel: nil,
            service: service(calls: Calls()) { throw Boom() }
        )
        model.check(probe: true)
        await waitUntilSettled(model)
        guard case .failed(let message) = model.phase else {
            return XCTFail("expected a failure, got \(model.phase)")
        }
        XCTAssertTrue(message.contains("could not be checked"), message)
    }

    func testSocketPayloadIsNamesAndWordsOnly() async throws {
        let calls = Calls()
        let result = try await service(calls: calls) { VMExecResult(exitCode: 0, stdout: Self.output, stderr: "") }
            .check(machineID: "vm-1", request: CloudAgentReadinessRequest(agent: nil, probe: true))
        let payload = TerminalController.agentReadinessPayload(result, address: "brave-otter")
        XCTAssertEqual(payload["supported"] as? Bool, true)
        XCTAssertEqual(payload["probe"] as? Bool, true)
        XCTAssertEqual(payload["problems"] as? Int, 2)
        let agents = try XCTUnwrap(payload["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.map { $0["agent"] as? String }, ["claude", "codex", "opencode"])
        XCTAssertEqual(agents[0]["status"] as? String, "problem")
        XCTAssertEqual(agents[0]["detail"] as? String, "Key rejected by Anthropic (401).")
        XCTAssertEqual((agents[0]["probe"] as? [String: Any])?["status"] as? Int, 401)
        XCTAssertEqual(agents[2]["endpoint"] as? String, "cmux model routing")
        XCTAssertNotNil(agents[1]["warning"] as? String)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("value"), "no field carries a value: \(text)")
    }
}
