import AppKit
import CmuxCloud
import CmuxCloudBannerCore
import CmuxComputerUse
import CmuxSurfaceCatalogModel
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud VPN setup", .serialized, .timeLimit(.minutes(1)))
struct CloudVPNSetupTests {
    private let backend = CloudTunnelBackend.networkExtension(extensionBundleIdentifier: "test.cloud.vpn")

    @Test("Opening and observing setup never enrolls or activates the VPN")
    func openingIsPassive() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller)
        let panel = CloudVPNSetupPanel(coordinator: coordinator)
        #expect(panel.panelType == .cloudVPNSetup && panel.model.isAttached)
        let observation = Task { await panel.model.observe() }
        await panel.model.refresh()
        #expect(panel.model.state == .off && panel.model.canConnect)
        observation.cancel()
        #expect(controller.calls.isEmpty && enroller.enrollCount == 0)
        #expect(await coordinator.state == .off)
    }

    @Test("Unsupported builds explain the missing capability and never offer a working connect action")
    func unsupportedBuild() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = CloudTunnelCoordinator(backend: .unavailable(.entitlementMissing),
            controller: controller, enroller: enroller, consumers: FakeTunnelConsumers())
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        #expect(!model.canConnect && !model.canDisconnect)
        #expect(model.unavailableMessage?.contains("signed VPN extension") == true)
        #expect(model.unavailableMessage?.contains("Ports") == true)
        #expect(controller.calls.isEmpty && enroller.enrollCount == 0)
    }

    @Test("Setup waits for status and accepts a late coordinator once")
    func lateCoordinator() async {
        let controller = FakeTunnelController()
        let model = CloudVPNSetupModel(coordinator: nil)
        #expect(!model.canConnect)
        let coordinator = makeCoordinator(controller: controller)
        #expect(model.attachIfNeeded(coordinator))
        #expect(!model.attachIfNeeded(makeCoordinator()))
        #expect(model.isCheckingStatus && !model.canConnect)
        await model.refresh()
        #expect(!model.isCheckingStatus && model.canConnect)
        #expect(controller.calls.isEmpty)
    }

    @Test("Only explicit Connect enrolls, and closing setup leaves the chosen VPN running")
    func explicitConnectAndDisconnect() async {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller)
        let panel = CloudVPNSetupPanel(coordinator: coordinator)
        await panel.model.refresh()
        await panel.model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await panel.model.refresh()
        #expect(panel.model.canDisconnect && !panel.model.canConnect)
        #expect(controller.calls == ["install", "start"] && enroller.enrollCount == 1)
        panel.close()
        #expect(await coordinator.state == .up)
        let reopened = CloudVPNSetupPanel(coordinator: coordinator)
        await reopened.model.refresh()
        #expect(reopened.model.state == .up)
        await reopened.model.disconnect()
        #expect(reopened.model.state == .off && reopened.model.canConnect)
    }

    @Test("Approval wait shows its explanation and remains cancellable")
    func approvalCanBeCancelled() async {
        let controller = FakeTunnelController()
        controller.holdInstallForApproval = true
        let coordinator = makeCoordinator(controller: controller)
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .awaitingApproval } == .awaitingApproval)
        await model.refresh()
        #expect(model.statusTitle == String(localized: "cloud.vpn.setup.waiting", defaultValue: "Waiting"))
        #expect(model.statusMessage?.contains("System Settings") == true)
        #expect(model.canDisconnect && !model.canConnect)
        await model.disconnect()
        #expect(model.state == .off && !controller.calls.contains("start"))
        controller.approve(with: CancellationError())
    }

    @Test("Admission refusal is visible and does not touch the system VPN")
    func refusalIsExplained() async {
        let controller = FakeTunnelController()
        let coordinator = CloudTunnelCoordinator(backend: backend, controller: controller,
            enroller: FakeTunnelEnroller(), consumers: FakeTunnelConsumers(),
            admission: .constant { .noCloudMachine })
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        #expect(model.errorMessage == CloudTunnelStartRefusal.noCloudMachine.error.description)
        #expect(model.state == .off && model.canConnect && controller.calls.isEmpty)
    }

    @Test("A failed start stays actionable and an explicit retry can connect")
    func failedStartCanRetry() async {
        let controller = FakeTunnelController()
        controller.startError = FakeTunnelController.Failure.refused
        let coordinator = makeCoordinator(controller: controller)
        let model = CloudVPNSetupModel(coordinator: coordinator)
        await model.refresh()
        await model.connect()
        let failed = await coordinator.waitForState(timeout: .seconds(5)) { if case .failed = $0 { true } else { false } }
        if case .failed = failed {} else { Issue.record("Expected an explicit failure") }
        await model.refresh()
        #expect(model.statusMessage != nil && model.canConnect)
        controller.startError = nil
        await model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await model.refresh()
        #expect(model.state == .up && model.errorMessage == nil)
        await model.disconnect()
    }

    /// Ports and Settings both open setup as one cmux pane in a "Cloud VPN"
    /// workspace, never a separate window, and a repeat click focuses it.
    @Test("Ports and Settings open one Cloud VPN pane instead of a window")
    func entryPointsOpenOnePane() throws {
        let previous = AppDelegate.shared
        let app = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            NSApp.windows.filter { $0.identifier?.rawValue == "cmux.cloudVPNSetup" }.forEach { $0.close() }
            manager.tabs.forEach { $0.teardownAllPanels() }
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            AppDelegate.shared = previous
            try? FileManager.default.removeItem(at: root)
        }
        AppDelegate.shared = app
        app.cloudTunnelCoordinator = makeCoordinator()
        let original = try #require(manager.selectedWorkspace)
        let ports = CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, resizeCPU: { _, _ in },
                resizeMemory: { _, _ in }, promptUpgrade: {}),
            nodeActions: CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
                projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
                newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
                newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
                renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in },
                copyPortLink: { _ in }, refresh: {}),
            expansionStore: CloudTreeExpansionStore(
                defaults: try #require(UserDefaults(suiteName: "vpn-setup-\(UUID())"))),
            tabDragTransferRegistry: { nil })
        let settings = HostSettingsActions(
            configFileURL: root.appendingPathComponent("cmux.json"),
            computerUseRuntimeService: ComputerUseRuntimeService(),
            browserDataImportCoordinator: BrowserDataImportCoordinator(),
            runComputerUseOnboardingAction: { _ in })
        func setupPanes() -> [(workspace: Workspace, panel: any Panel)] {
            manager.tabs.flatMap { workspace in
                workspace.panels.values.filter { $0.panelType.rawValue == "cloudVPNSetup" }.map { (workspace, $0) }
            }
        }

        ports.performPortAction(.setupVPN, machineID: .cloud("vpn-setup-vm"))
        let opened = try #require(setupPanes().first, "Set Up VPN in Ports must open a Cloud VPN pane")
        #expect(setupPanes().count == 1)
        #expect(manager.selectedTabId == opened.workspace.id && opened.workspace.id != original.id)
        #expect(opened.workspace.panels.count == 1, "The placeholder terminal must be replaced by the pane")
        #expect(opened.workspace.focusedPanelId == opened.panel.id)

        manager.selectedTabId = original.id
        settings.openCloudVPNSetup()
        #expect(setupPanes().map(\.panel.id) == [opened.panel.id], "Settings must focus the existing pane")
        #expect(manager.selectedTabId == opened.workspace.id)
        ports.performPortAction(.setupVPN, machineID: .cloud("vpn-setup-vm"))
        #expect(setupPanes().count == 1)
        #expect(!NSApp.windows.contains { $0.identifier?.rawValue == "cmux.cloudVPNSetup" },
            "Setup must not open a separate window")
    }

    private func makeCoordinator(
        controller: FakeTunnelController = FakeTunnelController(),
        enroller: FakeTunnelEnroller = FakeTunnelEnroller()
    ) -> CloudTunnelCoordinator {
        CloudTunnelCoordinator(backend: backend, controller: controller,
            enroller: enroller, consumers: FakeTunnelConsumers())
    }
}
