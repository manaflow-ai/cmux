import AppKit
import CmuxCloudMachines
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudWorkspaceMachineContextRoutingTests {
    @Test func cmdNUsesCapturedMachineAfterSelectionChanges() async throws {
        let appDelegate = AppDelegate()
        let store = DefaultCloudMachineStore(defaults: UserDefaults(suiteName: "CloudCmdNTargetTests.\(UUID().uuidString)")!)
        var createdMachine: String?
        appDelegate.cloudWorkspaceCoordinator = CloudWorkspaceCoordinator(
            defaultMachineStore: store,
            allowsOperation: { true },
            loadMachines: {
                [CloudMachineDescriptor(id: "machine-a", isDesktop: true), CloudMachineDescriptor(id: "machine-b", isDesktop: true)]
            },
            createWorkspace: { id, _ in
                createdMachine = id
                return UUID()
            }
        )
        appDelegate.cloudWorkspaceOperationController = CloudWorkspaceOperationController(isAvailable: { true })
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager, cmuxConfigStore: nil)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowID })
        appDelegate.setCloudTreeSelection(CloudTreeSelection(nodeID: "machine-b", machine: .cloud("machine-b")), in: tabManager)
        context.keyboardFocusCoordinator.noteRightSidebarInteraction(mode: .machines)

        #expect(appDelegate.performNewWorkspaceAction(tabManager: tabManager, debugSource: "test.cmdN.machine"))
        appDelegate.setCloudTreeSelection(CloudTreeSelection(nodeID: "machine-a", machine: .cloud("machine-a")), in: tabManager)
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(createdMachine == "machine-b")
    }
}
