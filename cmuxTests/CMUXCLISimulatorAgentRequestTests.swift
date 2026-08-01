import CmuxSimulator
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("CMUXCLI Simulator agent requests")
struct CMUXCLISimulatorAgentRequestTests {
    @Test("Semantic UI actions cover the server receipt deadline")
    func semanticUIActionTimeouts() throws {
        let cli = CMUXCLI(args: [])
        let commands: [(subcommand: String, arguments: [String])] = [
            ("tap", ["--ref", "e1_1"]),
            ("tap", ["--label", "Continue"]),
            ("touch", ["--ref", "e1_1", "--down", "--up"]),
            ("drag", ["--ref", "e1_1", "right"]),
            ("swipe", ["--ref", "e1_1", "up"]),
            ("long-press", ["--ref", "e1_1", "750"]),
            ("key", ["40"]),
            ("button", ["home"]),
            ("gesture-preset", ["scroll-up"]),
        ]
        let expectedTimeout = simulatorOperationDeadlines.clientTimeout(for: 140)

        for command in commands {
            let arguments = try cli.parseSimulatorArguments(command.arguments)
            let request = try #require(cli.simulatorAgentRequest(
                subcommand: command.subcommand,
                arguments: arguments
            ))
            #expect(
                request.timeout == expectedTimeout,
                "\(command.subcommand) used \(String(describing: request.timeout))"
            )
            #expect(request.output == .uiAction)
        }
    }

    @Test("Partial semantic actions retain warning and completion details")
    func partialSemanticActionOutput() throws {
        let cli = CMUXCLI(args: [])
        let output = cli.simulatorUIActionOutput([
            "completed": true,
            "snapshot_warning": "The tap committed before snapshot refresh failed",
            "ui_error": [
                "code": "SNAPSHOT_CAPTURE_FAILED",
                "message": "Snapshot refresh failed",
            ],
            "action": [
                "type": "type-text",
                "text_committed": false,
            ],
        ])
        let data = try #require(output.data(using: .utf8))
        let payload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let action = try #require(payload["action"] as? [String: Any])
        let error = try #require(payload["ui_error"] as? [String: Any])

        #expect(payload["completed"] as? Bool == true)
        #expect(payload["snapshot_warning"] as? String
            == "The tap committed before snapshot refresh failed")
        #expect(action["text_committed"] as? Bool == false)
        #expect(error["code"] as? String == "SNAPSHOT_CAPTURE_FAILED")
    }
}
