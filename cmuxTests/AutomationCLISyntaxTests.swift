import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Automation CLI syntax")
struct AutomationCLISyntaxTests {
    @Test("accepts the documented automation command shapes")
    func acceptsDocumentedShapes() {
        #expect(throws: Never.self) {
            try CMUXCLI.validateAutomationArguments(subcommand: "list", arguments: [])
            try CMUXCLI.validateAutomationArguments(subcommand: "show", arguments: ["rule"])
            try CMUXCLI.validateAutomationArguments(subcommand: "enable", arguments: ["rule"])
            try CMUXCLI.validateAutomationArguments(subcommand: "logs", arguments: ["--limit", "20"])
            try CMUXCLI.validateAutomationArguments(
                subcommand: "test",
                arguments: ["rule", "--event", #"{"name":"agent.needs_input"}"#]
            )
            try CMUXCLI.validateAutomationArguments(
                subcommand: "test",
                arguments: ["rule", #"--event={"name":"agent.needs_input"}"#]
            )
        }
    }

    @Test("rejects malformed automation commands")
    func rejectsMalformedCommands() {
        let malformed: [(String, [String])] = [
            ("list", ["--typo"]),
            ("show", ["rule", "extra"]),
            ("enable", ["rule", "--typo"]),
            ("disable", ["rule", "unexpected"]),
            ("logs", ["--limit", "20", "extra"]),
            ("logs", ["--unknown"]),
            ("test", ["rule", "--event"]),
            ("test", ["rule", "--event", #"{"name":"agent.needs_input"}"#, "extra"]),
            ("test", ["rule", "extra", "--event", #"{"name":"agent.needs_input"}"#]),
            ("test", ["rule", "--typo", #"{"name":"agent.needs_input"}"#])
        ]
        for (subcommand, arguments) in malformed {
            #expect(throws: (any Error).self) {
                try CMUXCLI.validateAutomationArguments(subcommand: subcommand, arguments: arguments)
            }
        }
    }
}
