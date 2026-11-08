import Foundation
import Testing

// RemoteTmuxInvocation.swift compiles into this target, so it needs no app import. An app
// import here makes cmuxCLITests resolve the app's modules (Sparkle, Iroh, ...), which it
// does not link, and the target fails to build.

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

/// `--socket-name <name>` selects a tmux server (`tmux -L <name>`) so one host can mirror
/// separate servers into separate windows (#15022).
@Suite struct RemoteTmuxInvocationSocketNameTests {
    @Test func socketNameIsAcceptedAsAConnectionOption() throws {
        let invocation = try RemoteTmuxInvocation.parse(["dev@host", "--socket-name", "alpha"])
        #expect(invocation.action == .mirror)
        #expect(invocation.destination == "dev@host")
    }

    @Test func socketNameIsRecorded() throws {
        let invocation = try RemoteTmuxInvocation.parse(["dev@host", "--socket-name", "alpha"])
        #expect(invocation.socketName == "alpha")
    }

    @Test func socketNameDefaultsToTheServerDefault() throws {
        let invocation = try RemoteTmuxInvocation.parse(["dev@host"])
        #expect(invocation.socketName == nil)
    }

    @Test func socketNameWorksWithListAndAttach() throws {
        let list = try RemoteTmuxInvocation.parse(["dev@host", "list", "--socket-name", "alpha"])
        #expect(list.action == .list)
        #expect(list.socketName == "alpha")

        let attach = try RemoteTmuxInvocation.parse(["dev@host", "--socket-name", "beta", "attach", "work"])
        #expect(attach.action == .attach(session: "work"))
        #expect(attach.socketName == "beta")
    }

    @Test(arguments: ["alpha", "proj.v2", "team_a", "a-b-c", "A1"])
    func socketNameAcceptsLettersDigitsDotUnderscoreAndHyphen(_ name: String) throws {
        let invocation = try RemoteTmuxInvocation.parse(["dev@host", "--socket-name", name])
        #expect(invocation.socketName == name)
    }

    /// The value is interpolated into a remote shell command, so anything outside the strict
    /// character set is refused at the parser rather than relying on quoting.
    @Test(arguments: [
        ["dev@host", "--socket-name"],
        ["dev@host", "--socket-name", ""],
        ["dev@host", "--socket-name", "-x"],
        ["dev@host", "--socket-name", "a b"],
        ["dev@host", "--socket-name", "a/b"],
        ["dev@host", "--socket-name", "a;rm"],
        ["dev@host", "--socket-name", "a'b"],
        ["dev@host", "--socket-name", "a$b"],
        ["dev@host", "--socket-name", "名前"],
        ["dev@host", "--socket-name", String(repeating: "a", count: 65)],
    ])
    func rejectsMissingOrUnsafeSocketNames(_ arguments: [String]) {
        #expect(throws: CLIError.self) {
            try RemoteTmuxInvocation.parse(arguments)
        }
    }
}
