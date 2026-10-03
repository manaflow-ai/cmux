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
@Suite("Cloud VPN setup", .serialized, .exclusiveAppContext, .timeLimit(.minutes(1)))
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
    func explicitConnectAndDisconnect() async throws {
        let controller = FakeTunnelController()
        let enroller = FakeTunnelEnroller()
        let coordinator = makeCoordinator(controller: controller, enroller: enroller)
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let paneID = try #require(workspace.focusedPanelId.flatMap { workspace.paneId(forPanelId: $0) })
        let panel = try #require(workspace.newCloudVPNSetupSurface(inPane: paneID, coordinator: coordinator))
        await panel.model.refresh()
        await panel.model.connect()
        #expect(await coordinator.waitForState(timeout: .seconds(5)) { $0 == .up } == .up)
        await panel.model.refresh()
        #expect(panel.model.canDisconnect && !panel.model.canConnect)
        #expect(controller.calls == ["install", "start"] && enroller.enrollCount == 1)
        #expect(workspace.closePanel(panel.id, force: true) && workspace.panels[panel.id] == nil)
        #expect(await coordinator.state == .up && controller.calls == ["install", "start"])
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
    /// Settings is its own window, so it also brings the main window forward;
    /// Ports is already inside it.
    @Test("Ports and Settings open one Cloud VPN pane instead of a window")
    func entryPointsOpenOnePane() throws {
        let cloudMarkerKey = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
        let previousCloudMarker = UserDefaults.standard.object(forKey: cloudMarkerKey)
        UserDefaults.standard.set(true, forKey: cloudMarkerKey)
        let cloudFlag = CmuxFeatureFlags.cloudMachinesFlag
        let previousCloudOverride = CmuxFeatureFlags.shared.overrideValue(for: cloudFlag)
        CmuxFeatureFlags.shared.setOverride(true, for: cloudFlag)
        defer {
            if let previousCloudMarker { UserDefaults.standard.set(previousCloudMarker, forKey: cloudMarkerKey) }
            else { UserDefaults.standard.removeObject(forKey: cloudMarkerKey) }
            CmuxFeatureFlags.shared.setOverride(previousCloudOverride, for: cloudFlag)
        }
        let previous = AppDelegate.shared
        let previousActive = TerminalController.shared.activeTabManagerForCallerNotification()
        let app = AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = app.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            manager.tabs.forEach { $0.teardownAllPanels() }
            app.unregisterMainWindowContextForTesting(windowId: windowID)
            app.forgetRecoverableMainWindowRoute(windowId: windowID)
            AppDelegate.shared = previous
            TerminalController.shared.setActiveTabManager(previousActive)
            try? FileManager.default.removeItem(at: root)
        }
        AppDelegate.shared = app
        app.cloudTunnelCoordinator = makeCoordinator()
        try #require(app.mainWindowContexts.values.first { $0.windowId == windowID }).window = window
        // Record window ordering instead of moving a real window on the test host.
        var broughtForward: [NSWindow] = []
        app.mainWindowVisibilityController = MainWindowVisibilityController(dependencies: .init(
            isActivationSuppressed: { false },
            setActiveMainWindow: { [weak app] in app?.setActiveMainWindow($0) },
            isApplicationHidden: { false },
            activateRunningApplication: { _ in },
            windowOperations: .init(isVisible: { _ in true }, isMiniaturized: { _ in false },
                isKeyWindow: { _ in false }, canBecomeMain: { _ in true }, canBecomeKey: { _ in true },
                deminiaturize: { _ in }, makeKeyAndOrderFront: { broughtForward.append($0) }, makeKey: { _ in },
                orderFront: { _ in }, orderFrontRegardless: { _ in }, orderOut: { _ in },
                softHide: { _ in }, softShow: { _ in })))
        let original = try #require(manager.selectedWorkspace)
        let ports = CloudTreeOutlineView.Coordinator(
            machineActions: MachineRowActions(openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, resizeCPU: { _, _ in },
                resizeMemory: { _, _ in }, promptUpgrade: {}),
            nodeActions: CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
                projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
                newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
                newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
                renameTerminal: { _, _ in }, renameRemoteView: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in },
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
        #expect(broughtForward.isEmpty, "Ports is already inside the main window")

        manager.selectedTabId = original.id
        settings.openCloudVPNSetup()
        #expect(setupPanes().map(\.panel.id) == [opened.panel.id], "Settings must focus the existing pane")
        #expect(manager.selectedTabId == opened.workspace.id)
        #expect(broughtForward.count == 1 && broughtForward.first === window,
            "Settings must bring the main window with the pane forward")
        ports.performPortAction(.setupVPN, machineID: .cloud("vpn-setup-vm"))
        #expect(setupPanes().count == 1 && broughtForward.count == 1)

        manager.closeWorkspace(opened.workspace, recordHistory: false)
        #expect(setupPanes().isEmpty)
        settings.openCloudVPNSetup()
        #expect(setupPanes().count == 1 && broughtForward.count == 2,
            "Settings must open a new pane and bring the main window forward")
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
