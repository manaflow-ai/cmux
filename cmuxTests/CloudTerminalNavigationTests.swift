import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudTerminalNavigationTests {
    @Test("Invalid owner coordinates never submit a navigation operation", arguments: 0..<4)
    func rejectsInvalidOwner(variant: Int) async {
        let machine = SurfaceMachineID.cloud("navigation")
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term-1")
        let workspace = SurfaceRemoteWorkspace(id: "ws-1", name: "Workspace", index: 0, focused: false)
        let view = SurfaceRemoteView(tabID: "tab-1", workspace: workspace)
        let controller = CloudWorkspaceOperationController(isAvailable: { true }, notificationCenter: NotificationCenter())
        var submissions = 0
        let navigation = CloudTreeTerminalNavigationCoordinator(
            machineName: { _ in "Machine" },
            run: { _, _ in submissions += 1; return Task {} },
            host: AppDelegate.makeCloudTerminalNavigationHost(),
            operationController: controller
        )
        let group = SurfaceResourceGroup(
            title: "Workspace", resources: [resource],
            remoteWorkspaceID: variant == 1 ? "ws-other" : variant == 2 ? "" : nil
        )
        navigation.open(
            machine: variant == 0 ? .cloud("other") : machine,
            group: group, resource: resource, view: variant < 2 ? view : nil, openIn: nil
        )
        await controller.waitForPendingOperations()
        #expect(submissions == 0)
    }

    @Test("Duplicate valid activations submit one operation with the machine's display name")
    func deduplicatesActivations() async {
        let machine = SurfaceMachineID.cloud("navigation")
        let resource = SurfaceResourceID(machine: machine, kind: .terminal, key: "term-1")
        let workspace = SurfaceRemoteWorkspace(id: "ws-1", name: "Workspace", index: 0, focused: false)
        let view = SurfaceRemoteView(tabID: "tab-1", workspace: workspace)
        let group = SurfaceResourceGroup(title: "Workspace", resources: [resource], remoteWorkspaceID: workspace.id)
        let controller = CloudWorkspaceOperationController(isAvailable: { true }, notificationCenter: NotificationCenter())
        var labels: [String] = []
        let navigation = CloudTreeTerminalNavigationCoordinator(
            machineName: { _ in "Friendly machine" },
            run: { label, _ in labels.append(label); return Task {} },
            host: AppDelegate.makeCloudTerminalNavigationHost(),
            operationController: controller
        )
        for _ in 0..<2 {
            navigation.open(machine: machine, group: group, resource: resource, view: view, openIn: nil)
        }
        await controller.waitForPendingOperations()
        #expect(labels.count == 1)
        #expect(labels.first?.contains("Friendly machine") == true)
    }

    @Test("Navigation reuses the exact daemon-tab projection through the real catalog")
    func reusesProjection() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let workspace = try await fixture.provider.createRemoteWorkspace(name: "Navigation")
            let resource = try #require(fixture.catalog.snapshot.resources.first { $0.id.machine == fixture.provider.machine })
            let view = try #require(resource.remoteViews?.first)
            let initial = try await fixture.catalog.project(
                resource.id, into: .workspace(id: fixture.originalWorkspaceID, placement: .tab),
                focus: false, reuseExisting: true, reuseInWorkspace: fixture.originalWorkspaceID, remoteView: view
            )
            let group = SurfaceResourceGroup(
                title: workspace.name, placements: [SurfaceResourcePlacement(resource: resource.id, remoteView: view)],
                remoteWorkspaceID: workspace.id
            )
            let controller = CloudWorkspaceOperationController(isAvailable: { true }, notificationCenter: NotificationCenter())
            var failures: [any Error] = []
            let navigation = CloudTreeTerminalNavigationCoordinator(
                machineName: { _ in "Machine" },
                run: { _, operation in
                    Task { @MainActor in
                        do { try await operation(fixture.catalog) }
                        catch { failures.append(error) }
                    }
                },
                host: AppDelegate.makeCloudTerminalNavigationHost(),
                operationController: controller
            )
            navigation.open(machine: fixture.provider.machine, group: group, resource: resource.id, view: view, openIn: nil)
            await controller.waitForPendingOperations()
            #expect(failures.isEmpty)
            let projections = fixture.catalog.projections.filter { $0.resource == resource.id }
            #expect(projections.count == 1)
            #expect(projections.first?.panelID == initial.projection.panelID)
            #expect(projections.first?.remoteTabID == view.tabID)
            #expect(fixture.manager.tabs.count == 1)
            #expect(fixture.manager.selectedTabId == initial.projection.workspaceID)
        }
    }
}
