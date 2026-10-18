import Foundation

@_silgen_name("task_local_test_legacy_checks")
private func legacyCheckCount() -> UInt32

// Binds the app's real Cloud pane reservations the way their production callers
// do: across actor hops, nested clearing scopes, failures and cancellation.
@main
struct SurfaceTaskLocalProbe {
    static func main() async throws {
        try await loadingReservationCrossesActorHops()
        try await failureRestoresParentScope()
        try await cancellationRestoresParentScope()
        try await displayReservationCrossesActorHops()
        if ProcessInfo.processInfo.environment["CMUX_TEST_LEGACY_TASK_LOCAL"] != nil {
            precondition(legacyCheckCount() > 0, "The regression must execute the legacy branch")
        }
        print("PASS: 4 surface task-local reservation scenarios")
    }

    @MainActor
    private static func loadingReservation() throws -> (CloudMachineLoadingReservation, SurfaceDestination) {
        let workspace = Workspace(machineID: "vm-1")
        let destination = SurfaceDestination(workspaceID: workspace.id)
        let resource = SurfaceResourceID(kind: .terminal, machine: SurfaceMachine(cloudMachineID: "vm-1"), name: "shell")
        let view = SurfaceRemoteView(workspace: SurfaceRemoteWorkspace(id: "remote-ws"), tabID: "tab-1")
        guard let reservation = CloudMachineLoadingReservation(resource, at: destination, remoteView: view) else {
            throw CloudDiagnosticFailure.placement
        }
        return (reservation, destination)
    }

    @MainActor
    private static func loadingReservationCrossesActorHops() async throws {
        let (reservation, destination) = try loadingReservation()
        precondition(CloudMachineLoadingReservation.current == nil)
        let panelID = try await CloudMachineLoadingReservation.withCurrent(reservation) {
            // Resume on another actor, then return to the main actor that owns
            // the workspace, as provider materialization does.
            let seen = await ReservationReader().loadingPanelID()
            precondition(seen == reservation.panelID)
            let cleared = await CloudMachineLoadingReservation.withCurrent(nil) {
                await ReservationReader().loadingPanelID() == nil
            }
            precondition(cleared)
            let panel = try CloudMachineLoadingReservation.current?.loadingPanel(at: destination, machineID: "vm-1")
            try CloudMachineLoadingReservation.current?.validate(
                materializedPlacement: SurfaceRemotePlacement(workspaceID: "remote-ws", tabID: "tab-1")
            )
            return panel?.id
        }
        precondition(panelID == reservation.panelID)
        precondition(CloudMachineLoadingReservation.current == nil)
    }

    @MainActor
    private static func failureRestoresParentScope() async throws {
        let (outer, _) = try loadingReservation()
        let (inner, _) = try loadingReservation()
        try await CloudMachineLoadingReservation.withCurrent(outer) {
            do {
                try await CloudMachineLoadingReservation.withCurrent(inner) {
                    _ = await ReservationReader().loadingPanelID()
                    try CloudMachineLoadingReservation.current?.validate(
                        materializedPlacement: SurfaceRemotePlacement(workspaceID: "other", tabID: "tab-1")
                    )
                }
                preconditionFailure("A mismatched placement must throw")
            } catch CloudDiagnosticFailure.placement {}
            precondition(CloudMachineLoadingReservation.current?.panelID == outer.panelID)
        }
        precondition(CloudMachineLoadingReservation.current == nil)
    }

    @MainActor
    private static func cancellationRestoresParentScope() async throws {
        let (reservation, _) = try loadingReservation()
        let entered = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            defer { precondition(CloudMachineLoadingReservation.current == nil) }
            try await CloudMachineLoadingReservation.withCurrent(reservation) {
                entered.continuation.yield(())
                for await _ in resume.stream {}
                let seen = await ReservationReader().loadingPanelID()
                precondition(seen == reservation.panelID)
                try Task.checkCancellation()
            }
        }
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        resume.continuation.finish()
        entered.continuation.finish()
        do {
            try await task.value
            preconditionFailure("Cancellation must reach the reserved scope")
        } catch is CancellationError {}
        precondition(CloudMachineLoadingReservation.current == nil)
    }

    @MainActor
    private static func displayReservationCrossesActorHops() async throws {
        let workspace = Workspace(machineID: "vm-2")
        let panelID = UUID()
        SurfacePaneFactory.browserPanels.insert(panelID)
        let display = SurfaceResource(id: SurfaceResourceID(kind: .display, machine: SurfaceMachine(cloudMachineID: "vm-2"), name: "display-1"))
        let other = SurfaceResource(id: SurfaceResourceID(kind: .display, machine: SurfaceMachine(cloudMachineID: "vm-2"), name: "display-2"))
        let reservation = CloudDisplayPaneReservation(resource: display.id, workspaceID: workspace.id, panelID: panelID)
        precondition(CloudDisplayPaneReservation.current == nil)
        try await CloudDisplayPaneReservation.withCurrent(reservation) {
            let seen = await ReservationReader().displayPanelID()
            precondition(seen == panelID)
            let reserved = try CloudDisplayPaneReservation.current?.pane(for: display)
            precondition(reserved?.panelID == panelID)
            let unrelated = try CloudDisplayPaneReservation.current?.pane(for: other)
            precondition(unrelated == nil)
        }
        precondition(CloudDisplayPaneReservation.current == nil)
    }
}

private actor ReservationReader {
    func loadingPanelID() -> UUID? { CloudMachineLoadingReservation.current?.panelID }
    func displayPanelID() -> UUID? { CloudDisplayPaneReservation.current?.panelID }
}
