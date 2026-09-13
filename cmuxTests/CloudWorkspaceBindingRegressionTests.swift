import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct CloudWorkspaceBindingRegressionTests {
    private static let machine = SurfaceMachineID.cloud("vivid-newt")
    private static let workspace = SurfaceRemoteWorkspace(id: "ws_api", name: "api", index: 0, focused: true)

    @Test func aDeletedBoundWorkspaceCannotRouteCreationBackToItsStaleID() {
        let bound = UUID()
        let coordinator = CloudPlacementCoordinator(binding: { id in
            id == bound
                ? WorkspaceCloudVMBinding(vmID: "vivid-newt", isBase: false, remoteWorkspaceID: "ws_deleted")
                : nil
        })
        let resource = SurfaceResource(
            id: SurfaceResourceID(machine: Self.machine, kind: .terminal, key: "term_1"),
            title: "term_1", detail: "/root", lifecycle: .running, agent: nil,
            remoteWorkspace: Self.workspace,
            remoteViews: [SurfaceRemoteView(tabID: "tab_1", workspace: Self.workspace)],
            port: nil, url: nil
        )

        #expect(coordinator.creationWorkspaceID(in: bound, near: resource) == "ws_api")
    }
}
