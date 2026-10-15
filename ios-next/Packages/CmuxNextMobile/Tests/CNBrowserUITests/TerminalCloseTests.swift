@testable import CNBrowserUI
import CNCore
import Testing

struct TerminalCloseTests {
    @Test func endedOrUnknownTerminalsCloseLocally() {
        #expect(TerminalClose.isGone(RPCError(code: .notFound, message: "no such terminal")))
        #expect(TerminalClose.isGone(RPCError(code: .unavailable, message: "terminal s7 ended on the Mac")))
        #expect(!TerminalClose.isGone(RPCError(code: .unsupported, message: "This Mac kept the tab open")))
        #expect(!TerminalClose.isGone(HostClientErrorStub()))
    }
}

private struct HostClientErrorStub: Error {}
