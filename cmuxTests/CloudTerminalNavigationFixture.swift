import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Executes the production navigation policy without an app, window, or catalog.
@MainActor
final class CloudTerminalNavigationFixture: CloudTerminalNavigationCatalog, CloudTerminalNavigationScheduling {
    let machine = SurfaceMachineID.cloud("navigation-fixture")
    let remoteWorkspace = SurfaceRemoteWorkspace(id: "ws-1", name: "Project", index: 0, focused: false)
    let workspaceID = UUID()
    let panelID = UUID()
    var existingWorkspaceID: UUID?
    var available = true
    var checkFailureAt: Int?
    var failure: (any Error)?
    var cancelAfterOpen = false
    var delayLayout = false
    let layoutStarted = AsyncStream<Void>.makeStream()
    private var layoutWaiter: CheckedContinuation<Void, Never>?
    var restoredProjections: [SurfaceProjection]?
    var events: [String] = []
    var failures: [any Error] = []
    var focused: [(UUID, UUID)] = []
    var closed: [UUID] = []
    var projectedWorkspaceID: UUID?
    var projectedView: SurfaceRemoteView?
    var openedTitle: String?
    var boundTitle: String?
    var receivedLayout: SurfaceProjectionLayout?
    var receivedGroup: SurfaceResourceGroup?
    private var checks = 0
    private var tasks: [Task<Void, Never>] = []

    var resource: SurfaceResourceID { SurfaceResourceID(machine: machine, kind: .terminal, key: "term-1") }
    var view: SurfaceRemoteView { SurfaceRemoteView(tabID: "tab-clicked", workspace: remoteWorkspace) }
    var group: SurfaceResourceGroup {
        SurfaceResourceGroup(title: " Project ", placements: [SurfaceResourcePlacement(resource: resource, remoteView: view)],
                             remoteWorkspaceID: remoteWorkspace.id)
    }
    var projection: SurfaceProjection {
        SurfaceProjection(resource: resource, workspaceID: workspaceID, panelID: panelID,
                          remoteWorkspaceID: remoteWorkspace.id, remoteTabID: view.tabID)
    }
    var layout: SurfaceProjectionLayout { .leaf(placements: group.placements) }

    func makeNavigation() -> CloudTreeTerminalNavigationCoordinator {
        CloudTreeTerminalNavigationCoordinator(
            machineName: { _ in "Friendly machine" },
            run: { [unowned self] _, operation in
                Task { @MainActor in
                    do { try await operation(self) }
                    catch { failures.append(error) }
                }
            },
            host: CloudTerminalNavigationHost(
                focus: { [unowned self] panel, workspace in
                    events.append("focus"); focused.append((panel, workspace))
                },
                closeWorkspace: { [unowned self] workspace in
                    events.append("close"); closed.append(workspace)
                }
            ),
            operationController: self
        )
    }

    func start(key: String, _ operation: @escaping @MainActor () async throws -> Void) -> Bool {
        guard available else { return false }
        tasks.append(Task { @MainActor in
            do { try await operation() }
            catch { failures.append(error) }
        })
        return true
    }

    func wait() async { for task in tasks { await task.value } }

    func releaseLayout() {
        layoutWaiter?.resume()
        layoutWaiter = nil
    }

    func checkCloudWorkspaceNavigation(machine: SurfaceMachineID, workspaceID: String) throws {
        events.append("check")
        checks += 1
        if checks == checkFailureAt { throw CancellationError() }
    }

    func localWorkspaceShowing(remoteWorkspaceID: String, placements: [SurfaceResourcePlacement]) -> UUID? {
        events.append("lookup")
        return existingWorkspaceID
    }

    func projectTerminal(_ resource: SurfaceResourceID, in workspaceID: UUID, view: SurfaceRemoteView?) async throws -> SurfaceProjection {
        events.append("project")
        projectedWorkspaceID = workspaceID
        projectedView = view
        if let failure { throw failure }
        return projection
    }

    func terminalWorkspaceLayout(machine: SurfaceMachineID, workspaceID: String) async -> SurfaceProjectionLayout? {
        events.append("layout")
        if delayLayout {
            await withCheckedContinuation { continuation in
                layoutWaiter = continuation
                layoutStarted.continuation.yield(())
            }
        }
        return layout
    }

    func openTerminalWorkspace(_ group: SurfaceResourceGroup, title: String, layout: SurfaceProjectionLayout?) async throws
        -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        events.append("open")
        openedTitle = title
        receivedLayout = layout
        receivedGroup = group
        if let failure { throw failure }
        if cancelAfterOpen { withUnsafeCurrentTask { $0?.cancel() } }
        return (workspaceID, restoredProjections ?? [projection])
    }

    func bindTerminalWorkspace(localWorkspaceID: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String, generatedTitle: String) {
        events.append("bind")
        boundTitle = generatedTitle
    }
}
