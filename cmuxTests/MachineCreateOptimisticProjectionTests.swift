import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for optimistic projection identity and retry fencing.
@MainActor
@Suite(.serialized)
struct MachineCreateOptimisticProjectionTests {
    private func makeCoordinator() -> (MachineCreateCoordinator, MachineCreateCoordinatorTests.LaunchRecorder) {
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let coordinator = MachineCreateCoordinator(
            notifier: { _ in },
            notificationCenter: NotificationCenter()
        )
        return (coordinator, launches)
    }

    @Test func staleCompletionFromAnEarlierRetryCannotFinishTheCurrentOperation() {
        let (coordinator, launches) = makeCoordinator()
        coordinator.start(MachineCreateCoordinatorTests.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id
        let staleCompletion = launches.completions[0]

        launches.complete(status: 1, output: "Error: transient")
        #expect(coordinator.retry(id))
        #expect(coordinator.operation(id: id)?.isRunning == true)

        staleCompletion(CloudVMActionLauncher.Completion(
            terminationStatus: 0,
            output: "OK machine=stale",
            workspaceId: nil,
            machineId: "stale"
        ))
        #expect(coordinator.operation(id: id)?.isRunning == true)
        #expect(coordinator.operation(id: id)?.createdMachineID == nil)

        launches.complete(status: 0, output: "OK machine=current", machineID: "current")
        #expect(coordinator.operations.isEmpty)
    }

    @Test func committedProjectionKeepsThePendingNodeIdentityUntilFleetAdoptsIt() {
        let workspaceID = UUID()
        let operation = MachineCreateOperation(
            id: UUID(),
            request: MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspaceID),
            startedAt: Date(timeIntervalSince1970: 1_787_400_000),
            createdMachineID: "current",
            phase: .reconciling(machineID: "current")
        )
        let machine = MachineSnapshot(
            id: "current", provider: "freestyle", image: "image", isDesktop: true,
            activity: .ready, createdAt: nil, label: nil
        )
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machine], pendingCreates: [operation], snapshot: .empty, localWorkspaces: []
        )
        #expect(nodes.first?.id == "pending-machine:\(operation.id.uuidString)")
        if case .machine(let snapshot, _) = nodes.first?.kind {
            #expect(snapshot.id == "current")
        } else {
            Issue.record("expected the pending node to adopt the authoritative machine")
        }
    }
}
