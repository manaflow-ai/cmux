import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// #13141 repro:
/// 1. Create a new Cloud machine from the Cloud sidebar.
/// 2. Before provider/daemon creation completes, observe a local workspace titled
///    `Cloud VM`, with `New Machine` / `Creating…` and `Cancel Create`.
/// 3. After the machine connects, observe the machine's first remote workspace
///    (`workspace-1`) in the Cloud tree.
///
/// The native creation boundary must adopt the daemon's name. A warm template
/// can authoritatively name its first workspace `Cloud` (#14125); neither that
/// name nor an existing remote name is evidence of a local placeholder.
@MainActor
@Suite(.serialized)
struct CloudWorkspaceCreationNamingTests {
    @Test("The daemon receipt replaces only the provisional title and keeps early input",
          arguments: ["workspace-1", "Cloud", "Cloud VM", "Existing project"])
    func receiptAdoptsNameWithoutReplacingWorkspace(remoteName: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            fixture.provider.usesReceipt = true
            fixture.provider.defaultWorkspaceName = remoteName
            var pending: CloudTerminalPaneReservation?
            var stableID: UUID?
            fixture.provider.beforeCreate = {
                let operation = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.operations.values.first)
                let reservation = try #require(operation.reservation)
                let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
                pending = reservation
                stableID = workspace.stableId
                #expect(workspace.title == String(localized: "workspace.cloudVM.defaultTitle", defaultValue: "Cloud VM"))
                #expect(workspace.effectiveCustomTitleSource != .user)
                #expect(workspace.cloudVMBinding?.remoteWorkspaceID == nil)
                #expect(workspace.panels.count == 1)
                #expect(workspace.terminalPanel(for: reservation.panelID)?.surface.initialCommand == nil)
                reservation.inputRelay.send(.bytes(Data("echo first command\n".utf8)))
            }
            fixture.provider.beforeMaterialize = { resource, reservation in
                let reservation = try #require(reservation)
                let workspace = try #require(fixture.manager.workspacesById[reservation.workspaceID])
                #expect(reservation === pending)
                #expect(workspace.title == remoteName)
                #expect(workspace.effectiveCustomTitleSource == .remote)
                #expect(workspace.cloudVMBinding?.remoteWorkspaceID == resource.remoteWorkspace?.id)
                #expect(fixture.workspaceRows().map(\.searchableTitle) == [remoteName])
            }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: false
            )
            let reservation = try #require(pending)
            let opened = try #require(result.opened)
            let workspace = try #require(fixture.manager.workspacesById[opened.workspaceID])
            #expect(opened.workspaceID == reservation.workspaceID)
            #expect(opened.projections.map(\.panelID) == [reservation.panelID])
            #expect(workspace.stableId == stableID)
            #expect(workspace.title == result.workspace.name && workspace.title == remoteName)
            #expect(workspace.panels.count == 1 && fixture.manager.tabs.count == 2)
            #expect(fixture.provider.requestedWorkspaceNames.count == 1)
            #expect(fixture.provider.requestedWorkspaceNames.allSatisfy { $0 == nil })
            #expect(fixture.provider.terminalCreates == 0 && fixture.provider.refreshes == 0)
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)

            let connection = try CloudManualMirrorSocketFixture()
            defer { connection.close() }
            let transport = CloudTuiManualIOConnection(socketPath: connection.socketPath)
            defer { transport.close() }
            try await transport.start()
            let router = CloudTuiManualIOInputRouter(surfaceID: 17)
            router.setConnection(transport)
            reservation.inputRelay.attach(router)
            let command = await connection.nextCommand(timeout: .seconds(2))
            #expect(command?.inputBytes == Data("echo first command\n".utf8))
            #expect(command?.surface == 17)

            fixture.provider.beforeCreate = nil
            fixture.provider.beforeMaterialize = nil
            fixture.provider.defaultWorkspaceName = "workspace-2"
            let later = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: false
            )
            #expect(later.opened?.workspaceID != opened.workspaceID)
            #expect(later.workspace.id != result.workspace.id)
            #expect(later.workspace.name == "workspace-2")
            #expect(workspace.title == remoteName && workspace.panels.count == 1)
            #expect(fixture.workspaceRows().map(\.searchableTitle) == [remoteName, "workspace-2"])
            #expect(fixture.manager.tabs.count == 3 && fixture.catalog.projections.count == 2)
        }
    }
}
