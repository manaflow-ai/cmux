import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the production panel's mixed observation boundary in a real
/// SwiftUI host, without its sign-in gate or network polling. StateObject is
/// intentional here: it matches MachinesPanelView's existing adapter.
@MainActor
struct CloudMachineOrderingTestPanel: View {
    @StateObject private var model: MachinesPanelViewModel
    let machineActions: MachineRowActions
    let nodeActions: CloudTreeNodeActions
    let expansionStore: CloudTreeExpansionStore

    init(model: MachinesPanelViewModel, fixture: CloudMachineOrderingFixture) {
        _model = StateObject(wrappedValue: model)
        machineActions = fixture.coordinator.machineActions
        nodeActions = fixture.coordinator.nodeActions
        expansionStore = CloudTreeExpansionStore(defaults: fixture.base.defaults)
    }

    var body: some View {
        CloudTreeOutlineView(
            machines: model.sidebarMachines, snapshot: model.catalog, localWorkspaces: [],
            machineActions: machineActions, nodeActions: nodeActions, expansionStore: expansionStore
        )
    }
}
