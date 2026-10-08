import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct InProcessMachineCreateLauncherTests {
    @Test func parsesTheAuthenticatedNewMachineSubset() throws {
        let workspace = UUID()
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "new", "--desktop", "--size", "8192", "--network-policy",
            #"{"mode":"full"}"#, "--agent-updates", "latest", "--focus", "false",
            "--workspace", workspace.uuidString
        ]))

        #expect(invocation.kind == .desktop)
        #expect(invocation.memoryMb == 8192)
        #expect(invocation.networkPolicy?.mode == .full)
        #expect(invocation.agentUpdates == .latest)
        #expect(invocation.workspaceID == workspace)
        #expect(invocation.focus == false)
    }

    @Test func rejectsPathsThatMustRemainOnTheCli() {
        #expect(InProcessMachineCreateLauncher.parse(arguments: ["vm", "base", "open"]) == nil)
        #expect(InProcessMachineCreateLauncher.parse(arguments: ["vm", "fork", "vm-1"]) == nil)
        #expect(InProcessMachineCreateLauncher.parse(arguments: ["vm", "new", "--image", "legacy"]) == nil)
    }

    @Test func retryOpenKeepsTheReservedWorkspaceAndUsesTheInProcessParser() throws {
        let workspace = UUID()
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "open", "vm-1", "--workspace", workspace.uuidString, "--focus", "false"
        ]))
        #expect(invocation.machineID == "vm-1")
        #expect(invocation.workspaceID == workspace)
        #expect(invocation.focus == false)
    }

    @Test func oneOperationKeepsOneIdempotencyKeyAcrossRetries() {
        let operationID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID) == "app-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID) == InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID))
    }
}
