import CmuxSimulator
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
        }
    }
}
