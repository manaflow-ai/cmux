import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focused coverage for the `ssh-tmux` list/attach argument contract.
@Suite struct RemoteTmuxInvocationTests {
    @Test func defaultsToTheExistingBulkMirror() throws {
        let invocation = try RemoteTmuxInvocation.parse(["dev@host", "--no-focus"])
        #expect(invocation.action == .mirror)
        #expect(invocation.destination == "dev@host")
        #expect(invocation.focus == false)
    }

    @Test(arguments: ["list", "ls"])
    func listAliasesDoNotSelectOrOpenAWorkspace(_ verb: String) throws {
        let invocation = try RemoteTmuxInvocation.parse(["dev@host", verb, "--port", "2222"])
        #expect(invocation.action == .list)
        #expect(invocation.port == 2222)
        #expect(invocation.workspaceName == nil)
        #expect(!invocation.newWindow)
    }

    @Test func attachAcceptsPositionalAndLongFormSelectors() throws {
        let positional = try RemoteTmuxInvocation.parse(["dev@host", "attach", "work"])
        #expect(positional.action == .attach(session: "work"))

        let longForm = try RemoteTmuxInvocation.parse(["dev@host", "--session", "work"])
        #expect(longForm.action == .attach(session: "work"))
    }

    @Test(arguments: [
        ["dev@host", "attach"],
        ["dev@host", "list", "--session", "work"],
        ["dev@host", "attach", "work", "extra"],
        ["dev@host", "attach", "work", "--session", "other"],
    ])
    func rejectsAmbiguousSelectors(_ arguments: [String]) {
        #expect(throws: CLIError.self) {
            try RemoteTmuxInvocation.parse(arguments)
        }
    }
}
