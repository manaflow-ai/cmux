import Testing

@Suite
struct CLIRemotesArgumentValidationTests {
    @Test func listAcceptsOnlyEmptyOrJsonArguments() throws {
        try RemotesArgumentParser.validateList([])
        try RemotesArgumentParser.validateList(["--json"])

        try expectRemotesError(.unknownFlag("--typo")) {
            try RemotesArgumentParser.validateList(["--typo"])
        }
        try expectRemotesError(.unexpectedArgument("unexpected")) {
            try RemotesArgumentParser.validateList(["unexpected"])
        }
    }

    @Test func removeAcceptsOneTargetAndJsonOnly() throws {
        #expect(try RemotesArgumentParser.removeTarget(["studio"]) == "studio")
        #expect(try RemotesArgumentParser.removeTarget(["studio", "--json"]) == "studio")
        #expect(try RemotesArgumentParser.removeTarget(["--json", "studio"]) == "studio")
        #expect(try RemotesArgumentParser.removeTarget(["--json"]) == nil)

        try expectRemotesError(.unknownFlag("--typo")) {
            _ = try RemotesArgumentParser.removeTarget(["studio", "--typo"])
        }
        try expectRemotesError(.unexpectedArgument("unexpected")) {
            _ = try RemotesArgumentParser.removeTarget(["studio", "unexpected"])
        }
    }

    private func expectRemotesError(
        _ expected: RemotesArgumentError,
        operation: () throws -> Void
    ) throws {
        do {
            try operation()
            Issue.record("Expected remotes argument validation to fail with \(expected)")
        } catch let error as RemotesArgumentError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
