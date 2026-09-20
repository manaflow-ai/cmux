import AppKit
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every machine create shows a workspace with a loading pane at once and
/// the CLI is pointed at that workspace; failures, retries, and cancels act
/// on that same workspace.
@MainActor
final class CloudMachineCreatePlaceholderTests: XCTestCase {
    private final class LaunchRecorder {
        var calls: [(workspace: Workspace, arguments: [String])] = []
        var completions: [@MainActor (CloudVMActionLauncher.Completion) -> Void] = []
        var refuse = false
    }

    private var recorder = LaunchRecorder()
    private var closedWorkspaces: [UUID] = []

    override func setUp() {
        super.setUp()
        recorder = LaunchRecorder()
        closedWorkspaces = []
        let recorder = self.recorder
        AppDelegate.cloudMachineCreateLaunchOverride = { workspace, arguments, _, cancellationReady, completion in
            if recorder.refuse { return false }
            recorder.calls.append((workspace, arguments))
            recorder.completions.append(completion)
            cancellationReady(CloudVMActionLauncher.CancellationHandle {})
            return true
        }
    }

    override func tearDown() {
        AppDelegate.cloudMachineCreateLaunchOverride = nil
        super.tearDown()
    }

    private func makeCoordinator(tabManager: TabManager) -> MachineCreateCoordinator {
        MachineCreateCoordinator(
            notifier: { _ in },
            notificationCenter: NotificationCenter(),
            cancelOperation: { [weak self] operation in
                guard let workspaceID = operation.request.placeholderWorkspaceID,
                      let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else { return }
                self?.closedWorkspaces.append(workspaceID)
                tabManager.closeWorkspace(workspace, recordHistory: false)
            }
        )
    }

    private func withContext(_ body: (AppDelegate, TabManager) throws -> Void) throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        try body(appDelegate, tabManager)
    }

    private func loadingWorkspace(in tabManager: TabManager) -> (Workspace, CloudVMLoadingPanel)? {
        for workspace in tabManager.tabs {
            if let panel = workspace.panels.values.first(where: { $0.panelType == .cloudVMLoading }) as? CloudVMLoadingPanel {
                return (workspace, panel)
            }
        }
        return nil
    }

    func testNewMachineCreateShowsAnUnpinnedLoadingWorkspaceAndTargetsIt() throws {
        try withContext { appDelegate, tabManager in
            let coordinator = makeCoordinator(tabManager: tabManager)
            let request = MachineCreateCoordinatorTests.newMachineRequest(kind: .base)
            let before = tabManager.tabs.count
            XCTAssertTrue(appDelegate.startCloudMachineCreate(request, tabManager: tabManager, preferredWindow: nil, coordinator: coordinator))
            XCTAssertEqual(tabManager.tabs.count, before + 1)
            let (workspace, panel) = try XCTUnwrap(loadingWorkspace(in: tabManager))
            XCTAssertEqual(panel.flow, .newMachine)
            XCTAssertTrue(panel.isLoading)
            XCTAssertFalse(workspace.isPinned, "only Base pins its placeholder")
            XCTAssertEqual(tabManager.selectedTabId, workspace.id)
            XCTAssertEqual(recorder.calls.count, 1)
            XCTAssertEqual(recorder.calls[0].workspace.id, workspace.id)
            XCTAssertEqual(Array(recorder.calls[0].arguments.suffix(2)), ["--workspace", workspace.id.uuidString])
            XCTAssertEqual(coordinator.operations.count, 1)
            XCTAssertEqual(coordinator.operations[0].request.placeholderWorkspaceID, workspace.id)
        }
    }

    func testForkCreateCarriesTheSourceNameIntoThePane() throws {
        try withContext { appDelegate, tabManager in
            let coordinator = makeCoordinator(tabManager: tabManager)
            let request = MachineCreateRequest(
                mode: .newMachine, kind: .base, name: nil,
                arguments: ["vm", "fork", "vm-kind-otter", "--focus", "false"],
                source: .fork(vmID: "vm-kind-otter", name: "kind-otter")
            )
            XCTAssertTrue(appDelegate.startCloudMachineCreate(request, tabManager: tabManager, preferredWindow: nil, coordinator: coordinator))
            let (workspace, panel) = try XCTUnwrap(loadingWorkspace(in: tabManager))
            XCTAssertEqual(panel.flow, .fork(sourceName: "kind-otter"))
            XCTAssertEqual(workspace.title, "Fork of kind-otter")
            XCTAssertEqual(recorder.calls[0].arguments, ["vm", "fork", "vm-kind-otter", "--focus", "false", "--workspace", workspace.id.uuidString])
        }
    }

    func testRefusedLaunchTakesThePlaceholderDown() throws {
        try withContext { appDelegate, tabManager in
            recorder.refuse = true
            let coordinator = makeCoordinator(tabManager: tabManager)
            let before = tabManager.tabs.count
            XCTAssertFalse(appDelegate.startCloudMachineCreate(
                MachineCreateCoordinatorTests.newMachineRequest(kind: .base),
                tabManager: tabManager, preferredWindow: nil, coordinator: coordinator
            ))
            XCTAssertEqual(tabManager.tabs.count, before)
            XCTAssertNil(loadingWorkspace(in: tabManager))
            XCTAssertTrue(coordinator.operations.isEmpty)
        }
    }

    func testCancelFromThePendingRowClosesThePlaceholder() throws {
        try withContext { appDelegate, tabManager in
            let coordinator = makeCoordinator(tabManager: tabManager)
            XCTAssertTrue(appDelegate.startCloudMachineCreate(
                MachineCreateCoordinatorTests.newMachineRequest(kind: .base),
                tabManager: tabManager, preferredWindow: nil, coordinator: coordinator
            ))
            let (workspace, _) = try XCTUnwrap(loadingWorkspace(in: tabManager))
            coordinator.cancel(try XCTUnwrap(coordinator.operations.first).id)
            XCTAssertEqual(closedWorkspaces, [workspace.id])
            XCTAssertNil(loadingWorkspace(in: tabManager))
        }
    }

    func testRetryFromThePaneRelaunchesTheSameCreate() throws {
        try withContext { appDelegate, tabManager in
            let coordinator = makeCoordinator(tabManager: tabManager)
            XCTAssertTrue(appDelegate.startCloudMachineCreate(
                MachineCreateCoordinatorTests.newMachineRequest(kind: .base),
                tabManager: tabManager, preferredWindow: nil, coordinator: coordinator
            ))
            let (workspace, panel) = try XCTUnwrap(loadingWorkspace(in: tabManager))
            let firstArguments = recorder.calls[0].arguments
            recorder.completions[0](CloudVMActionLauncher.Completion(terminationStatus: 1, output: "Error: vm_cloud_service_unavailable", workspaceId: nil))
            XCTAssertEqual(coordinator.operations.first?.isRunning, false)
            XCTAssertTrue(panel.canRetry)
            let retry = try XCTUnwrap(panel.retryHandler)
            retry()
            XCTAssertEqual(recorder.calls.count, 2)
            XCTAssertEqual(recorder.calls[1].workspace.id, workspace.id)
            XCTAssertEqual(recorder.calls[1].arguments, firstArguments)
            XCTAssertEqual(coordinator.operations.first?.isRunning, true)
        }
    }

    func testMintedButUnopenedMachineDisablesRetry() throws {
        try withContext { appDelegate, tabManager in
            let coordinator = makeCoordinator(tabManager: tabManager)
            XCTAssertTrue(appDelegate.startCloudMachineCreate(
                MachineCreateCoordinatorTests.newMachineRequest(kind: .base),
                tabManager: tabManager, preferredWindow: nil, coordinator: coordinator
            ))
            let (_, panel) = try XCTUnwrap(loadingWorkspace(in: tabManager))
            recorder.completions[0](CloudVMActionLauncher.Completion(
                terminationStatus: 1,
                output: "Created Cloud VM vm-1\nOK machine=vm-1\nError: attach timed out",
                workspaceId: nil
            ))
            XCTAssertFalse(panel.canRetry)
            XCTAssertNil(panel.retryHandler)
            XCTAssertTrue(panel.hasFailed)
            XCTAssertTrue(coordinator.operations.isEmpty, "the machine exists; the fleet row takes over")
        }
    }

    func testBaseOpenIgnoresANewMachinePlaceholder() throws {
        try withContext { appDelegate, tabManager in
            let coordinator = makeCoordinator(tabManager: tabManager)
            XCTAssertTrue(appDelegate.startCloudMachineCreate(
                MachineCreateCoordinatorTests.newMachineRequest(kind: .base),
                tabManager: tabManager, preferredWindow: nil, coordinator: coordinator
            ))
            let (newMachineWorkspace, _) = try XCTUnwrap(loadingWorkspace(in: tabManager))
            let base = try XCTUnwrap(appDelegate.makeCloudVMPlaceholderWorkspace(in: tabManager, title: "Cloud VM", flow: .base, pinned: true))
            XCTAssertNotEqual(base.id, newMachineWorkspace.id)
            XCTAssertTrue(base.isPinned)
            XCTAssertEqual(appDelegate.cloudVMLoadingPanel(in: base)?.flow, .base)
            XCTAssertEqual(appDelegate.cloudVMLoadingPanel(in: newMachineWorkspace)?.flow, .newMachine)
        }
    }
}
