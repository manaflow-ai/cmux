import CmuxSwiftRender
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CmuxSidebarActionDispatchTests {
    @Test func logActionReachesWorkspaceLogCommand() async {
        let commands = AsyncStream<String>.makeStream()
        let dispatch = makeCmuxSidebarActionDispatch { line in
            commands.continuation.yield(line)
            return "OK"
        }

        dispatch.run(ButtonAction(commands: [.log("row \"tapped\"\nnext")]))
        let command = await commands.stream.first

        #expect(command == "log --source=custom-sidebar -- \"row \\\"tapped\\\"\\nnext\"")
    }
}
