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
    @Test(arguments: [false, true])
    func upstreamFailureNeverReachesCreatePresentation(created: Bool) async throws {
        let workspace = UUID()
        let invocation = try #require(InProcessMachineCreateLauncher.parse(arguments: [
            "vm", "new", "--workspace", workspace.uuidString, "--focus", "false"
        ]))
        let upstreamMessage = "upstream-diagnostic-fixture-7b912"
        let dependencies = InProcessMachineCreateLauncher.Dependencies(
            create: { _, _ in
                if !created { throw VMClientError.httpStatus(503, "{\"message\":\"\(upstreamMessage)\"}") }
                return VMSummary(id: "created-machine", provider: "freestyle", status: "running", image: "snapshot", createdAt: 1)
            },
            record: { _, _ in nil },
            provider: { _ in nil },
            open: { _, _ in throw VMClientError.httpStatus(503, "{\"message\":\"\(upstreamMessage)\"}") }
        )
        let completion = await InProcessMachineCreateLauncher.run(
            invocation, operationID: UUID(), dependencies: dependencies, onOutput: { _ in }
        )
        #expect(!completion.succeeded)
        #expect(!completion.output.contains(upstreamMessage))
        let coordinator = MachineCreateCoordinator(notifier: { notice in
            #expect(!notice.body.contains(upstreamMessage))
        })
        coordinator.start(MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspace)) { _, _, finish in
            finish(completion)
            return true
        }
        let finished = try #require(coordinator.lastFinished)
        switch finished.outcome {
        case .failed(let output), .createdButOpenFailed(_, let output):
            #expect(!output.contains(upstreamMessage))
        case .created:
            Issue.record("A failed create or attach must not be reported as ready")
        }
    }

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
        #expect(InProcessMachineCreateLauncher.idempotencyKey(operationID: operationID) != InProcessMachineCreateLauncher.idempotencyKey(operationID: UUID()))
    }
}
