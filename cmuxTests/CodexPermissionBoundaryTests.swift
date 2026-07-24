import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Codex permission ordering boundaries")
struct CodexPermissionBoundaryTests {
    private let machine = CodexPermissionTransitionMachine()
    private let runtime = CodexPermissionRuntimeGeneration(
        pid: 4_242,
        pidStartSeconds: 10,
        pidStartMicroseconds: 20
    )

    @Test func boundaryRetiresOldStartsBeforeUnscopedApproval() throws {
        let oldTool = CodexPermissionSignalIdentity(
            turnID: "turn-old",
            requestID: "call-old"
        )
        let oldStart = machine.reduce(
            current: nil,
            event: .toolStarted,
            identity: oldTool,
            runtime: runtime
        )
        let boundary = try #require(machine.crossOrderingBoundary(
            current: oldStart.state,
            runtime: runtime,
            revision: oldStart.state.revision + 1
        ))
        let delayedOldRequest = machine.reduce(
            current: boundary,
            event: .permissionRequested,
            identity: oldTool,
            runtime: runtime
        )
        let newTool = CodexPermissionSignalIdentity(
            turnID: "turn-new",
            requestID: "call-new"
        )
        let newStart = machine.reduce(
            current: boundary,
            event: .toolStarted,
            identity: newTool,
            runtime: runtime
        )
        let unscopedNewRequest = machine.reduce(
            current: newStart.state,
            event: .permissionRequested,
            identity: .init(turnID: nil, requestID: nil),
            runtime: runtime
        )

        #expect(delayedOldRequest.accepted == false)
        #expect(unscopedNewRequest.accepted)
        #expect(unscopedNewRequest.state.identity == newTool)
    }
}
