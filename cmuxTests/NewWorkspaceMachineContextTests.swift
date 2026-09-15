import AppKit
import CmuxCloudMachines
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct NewWorkspaceMachineContextTests {
    @Test func focusedMachinesSelectionWinsAndLocalSelectionStaysLocal() {
        #expect(
            NewWorkspaceMachineContext(
                selection: .cloud("machine-b"),
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .cloud("machine-b")
        )
        #expect(
            NewWorkspaceMachineContext(
                selection: .local,
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .local
        )
        #expect(
            NewWorkspaceMachineContext(
                selection: .pending,
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: true
            ).target == .unavailable
        )
    }

    @Test func workspaceBindingWinsWhenMachinesPanelDoesNotOwnFocus() {
        #expect(
            NewWorkspaceMachineContext(
                selection: .cloud("machine-b"),
                selectedWorkspaceCloudMachineID: "machine-a",
                machinesPanelOwnsFocus: false
            ).target == .cloud("machine-a")
        )
        #expect(
            NewWorkspaceMachineContext(
                selection: .none,
                selectedWorkspaceCloudMachineID: nil,
                machinesPanelOwnsFocus: false
            ).target == .local
        )
    }

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
        appDelegate.setNewWorkspaceMachineSelection(.cloud("machine-b"), in: tabManager)
        context.keyboardFocusCoordinator.noteRightSidebarInteraction(mode: .machines)

        #expect(appDelegate.performNewWorkspaceAction(tabManager: tabManager, debugSource: "test.cmdN.machine"))
        appDelegate.setNewWorkspaceMachineSelection(.cloud("machine-a"), in: tabManager)
        await appDelegate.cloudWorkspaceOperationController?.waitForPendingOperations()
        #expect(createdMachine == "machine-b")
    }
}
