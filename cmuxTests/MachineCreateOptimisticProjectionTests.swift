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

    @Test func fleetArrivalBeforeAttachCompletionKeepsTheSelectedPendingIdentity() throws {
        let (coordinator, launches) = makeCoordinator()
        coordinator.start(
            MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(UUID()),
            launch: launches.launch
        )
        let pending = CloudTreeNodeBuilder.nodes(
            machines: [], pendingCreates: coordinator.operations, snapshot: .empty, localWorkspaces: []
        )
        let selectedID = try #require(pending.first?.id)
        launches.progressHandlers[0]("OK machine=early\n")
        let machine = MachineSnapshot(
            id: "early", provider: "freestyle", image: "image", isDesktop: true,
            activity: .ready, createdAt: nil, label: nil
        )
        let refreshed = CloudTreeNodeBuilder.nodes(
            machines: [machine], pendingCreates: coordinator.operations, snapshot: .empty, localWorkspaces: []
        )
        #expect(refreshed.count == 1)
        #expect(refreshed.first?.id == selectedID)
        #expect(coordinator.hasRunningOperations)
    }

    @Test(arguments: [false, true])
    func workspaceOwnedCloseDoesNotRequestAnotherPresentationClose(failed: Bool) throws {
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        var presentationCloses = 0
        var destroyed: [String] = []
        let coordinator = MachineCreateCoordinator(
            notifier: { _ in }, notificationCenter: NotificationCenter(),
            cancelCreatedMachine: { destroyed.append($0) },
            cancelOperation: { _ in presentationCloses += 1 }
        )
        let workspaceID = UUID()
        coordinator.start(
            MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspaceID),
            cancellableLaunch: launches.cancellableLaunch
        )
        if failed { launches.complete(status: 1, output: "Error: unavailable") }

        coordinator.cancelOperations(forPresentationWorkspace: workspaceID)

        #expect(coordinator.operations.isEmpty)
        #expect(presentationCloses == 0, "TabManager already owns this close; reentry double-finalizes the workspace")
        if !failed {
            #expect(launches.cancellations == 1)
            launches.complete(status: 0, output: "OK machine=late\n", machineID: "late")
            #expect(destroyed == ["late"])
        }
    }

    @Test(arguments: [false, true])
    func separatePanelsPreserveAdoptedSelectionAcrossCoalescedRefreshes(renderBeforeReconcile: Bool) throws {
        let (coordinator, launches) = makeCoordinator()
        let firstPanel = MachinesPanelViewModel(createCoordinator: coordinator)
        let secondPanel = MachinesPanelViewModel(createCoordinator: coordinator)
        coordinator.start(
            MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(UUID()),
            launch: launches.launch
        )
        let selectedID = try #require(CloudTreeNodeBuilder.nodes(
            machines: [], pendingCreates: firstPanel.pendingCreates, snapshot: .empty, localWorkspaces: []
        ).first?.id)
        let machine = MachineSnapshot(
            id: "adopted", provider: "freestyle", image: "image", isDesktop: true,
            activity: .ready, createdAt: nil, label: nil
        )
        launches.complete(status: 0, output: "OK machine=adopted", machineID: "adopted")
        if renderBeforeReconcile {
            #expect(CloudTreeNodeBuilder.nodes(
                machines: [machine], pendingCreates: firstPanel.pendingCreates,
                adoptedOperationIDs: firstPanel.adoptedOperationIDs, snapshot: .empty, localWorkspaces: []
            ).first?.id == selectedID)
        }
        coordinator.reconcileAuthoritativeState(machineIDs: ["adopted"], catalogMachineIDs: [])
        #expect(coordinator.operations.isEmpty)
        for panel in [secondPanel, firstPanel, secondPanel] {
            #expect(CloudTreeNodeBuilder.nodes(
                machines: [machine], pendingCreates: panel.pendingCreates,
                adoptedOperationIDs: panel.adoptedOperationIDs, snapshot: .empty, localWorkspaces: []
            ).first?.id == selectedID)
        }
    }

    @Test func retryAfterAttachFailureOpensTheExactVMWithoutSelectingIt() throws {
        let (coordinator, launches) = makeCoordinator()
        let workspaceID = UUID()
        coordinator.start(
            MachineCreateCoordinatorTests.newMachineRequest().targetingReservedWorkspace(workspaceID),
            launch: launches.launch
        )
        let id = try #require(coordinator.operations.first?.id)
        launches.complete(status: 1, output: "Error: attach failed", machineID: "already-created")
        #expect(coordinator.operation(id: id)?.failureOutput == "Error: attach failed")
        #expect(coordinator.retry(id))
        #expect(launches.arguments.last == ["vm", "open", "already-created", "--workspace", workspaceID.uuidString, "--focus", "false"])
        #expect(coordinator.operation(id: id)?.createdMachineID == "already-created")
        launches.complete(status: 0, output: "", workspaceID: workspaceID)
        #expect(coordinator.operation(id: id)?.isReconciling == true)
        #expect(coordinator.lastFinished?.outcome == .created(machineID: "already-created", workspaceID: workspaceID))
    }

}
