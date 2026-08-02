import AppKit
import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import CmuxSimulatorUIAutomation
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Simulator panel integration", .serialized)
struct SimulatorPanelIntegrationTests {
    @Test("Control API accepts Simulator panel type spellings")
    func panelTypeParsing() {
        #expect(PanelType(rawValue: "simulator") == .simulator)

        for spelling in ["simulator", "iOSSimulator", "ios-simulator", "ios_simulator", "ios simulator"] {
            #expect(TerminalController.shared.v2PanelType(["type": spelling], "type") == .simulator)
        }
    }

    @Test("Creating a Simulator surface focuses it and publishes its kind")
    func surfaceCreationAndFocus() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(workspace.newSimulatorSurface(inPane: paneID, focus: true))
        defer { panel.close() }

        #expect(panel.panelType == .simulator)
        #expect(workspace.focusedPanelId == panel.id)
        let surfaceID = try #require(workspace.surfaceIdFromPanelId(panel.id))
        #expect(workspace.bonsplitController.selectedTab(inPane: paneID)?.id == surfaceID)
        #expect(workspace.bonsplitController.tab(surfaceID)?.kind == SurfaceKind.simulator.rawValue)
    }

    @Test("Creating an unfocused Simulator split preserves the source focus")
    func splitCreationPreservesFocus() throws {
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let sourcePaneID = try #require(workspace.paneId(forPanelId: sourcePanelID))

        let panel = try #require(
            workspace.newSimulatorSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                focus: false
            )
        )
        defer { panel.close() }

        let simulatorPaneID = try #require(workspace.paneId(forPanelId: panel.id))
        #expect(simulatorPaneID != sourcePaneID)
        #expect(workspace.focusedPanelId == sourcePanelID)
        #expect(workspace.bonsplitController.focusedPaneId == sourcePaneID)
    }

    @Test("Canvas creates a Simulator as its own focused pane")
    func canvasPaneCreation() throws {
        let workspace = Workspace()
        workspace.setLayoutMode(.canvas)

        let panelID = try #require(workspace.openNewCanvasPane(type: .simulator, focus: true))
        let panel = try #require(workspace.panels[panelID] as? SimulatorPanel)
        defer { panel.close() }

        #expect(workspace.focusedPanelId == panelID)
        #expect(workspace.canvasModel.frame(of: panelID) != nil)
        #expect(workspace.canvasModel.layout.panes.contains { pane in
            pane.panelIds.contains { $0.rawValue == panelID }
        })
    }

    @Test("Session restore preserves preferred Simulator identity")
    func sessionPersistence() throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }
        let preferredDeviceID = "00000000-0000-0000-0000-000000000001"
        let preferredRuntimeID = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
        let preferredDeviceTypeID = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5"
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(
            workspace.newSimulatorSurface(
                inPane: paneID,
                preferredDeviceID: preferredDeviceID,
                preferredRuntimeIdentifier: preferredRuntimeID,
                preferredDeviceTypeIdentifier: preferredDeviceTypeID,
                focus: true
            )
        )
        defer { panel.close() }

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        #expect(panelSnapshot.type == .simulator)
        #expect(panelSnapshot.simulator?.deviceUDID == preferredDeviceID)
        #expect(panelSnapshot.simulator?.runtimeIdentifier == preferredRuntimeID)
        #expect(panelSnapshot.simulator?.deviceTypeIdentifier == preferredDeviceTypeID)

        flags.setOverride(false, for: simulatorFlag)
        let restoredWorkspace = Workspace()
        restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredPanel = try #require(
            restoredWorkspace.panels.values.compactMap { $0 as? SimulatorPanel }.first
        )
        defer { restoredPanel.close() }

        #expect(restoredPanel.selectedDeviceID == preferredDeviceID)
        #expect(restoredPanel.selectedRuntimeIdentifier == preferredRuntimeID)
        #expect(restoredPanel.selectedDeviceTypeIdentifier == preferredDeviceTypeID)
        let restoredSurfaceID = try #require(restoredWorkspace.surfaceIdFromPanelId(restoredPanel.id))
        #expect(restoredWorkspace.bonsplitController.tab(restoredSurfaceID)?.kind == SurfaceKind.simulator.rawValue)
        flags.setOverride(true, for: simulatorFlag)
    }

    @Test("Selecting another Simulator invalidates the session autosave fingerprint")
    func selectedDeviceInvalidatesSessionAutosaveFingerprint() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        let first = SimulatorDevice(
            id: "first-simulator",
            name: "First Simulator",
            runtimeIdentifier: "first-runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "first-type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let second = SimulatorDevice(
            id: "second-simulator",
            name: "Second Simulator",
            runtimeIdentifier: "second-runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "second-type",
            family: .iPad,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let panel = SimulatorPanel(
            preferredDeviceID: first.id,
            preferredRuntimeIdentifier: first.runtimeIdentifier,
            preferredDeviceTypeIdentifier: first.deviceTypeIdentifier,
            client: SimulatorFeatureFlagPaneClient(devices: [first, second])
        )
        workspace.panels[panel.id] = panel
        defer { workspace.teardownAllPanels() }

        try await panel.coordinator.selectDeviceAndWait(id: first.id)
        let initialFingerprint = manager.sessionAutosaveFingerprint()
        #expect(manager.sessionAutosaveFingerprint() == initialFingerprint)

        try await panel.coordinator.selectDeviceAndWait(id: second.id)

        #expect(panel.selectedDeviceID == second.id)
        #expect(manager.sessionAutosaveFingerprint() != initialFingerprint)
    }

    @Test("Remote tmux mirror workspaces reject local Simulator surfaces")
    func remoteMirrorRejection() throws {
        let workspace = Workspace()
        let sourcePanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: sourcePanelID))
        let originalPanelIDs = Set(workspace.panels.keys)
        workspace.isRemoteTmuxMirror = true

        #expect(workspace.newSimulatorSurface(inPane: paneID, focus: true) == nil)
        #expect(
            workspace.newSimulatorSplit(
                from: sourcePanelID,
                orientation: .vertical,
                focus: true
            ) == nil
        )
        #expect(Set(workspace.panels.keys) == originalPanelIDs)
    }

    @Test("Simulator responder ownership is panel-specific and yields cleanly")
    func responderOwnership() throws {
        let first = SimulatorPanel()
        let second = SimulatorPanel()
        defer { first.close(); second.close() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [], backing: .buffered, defer: false)
        let view = TestSimulatorResponder(owner: ObjectIdentifier(first.coordinator))
        window.contentView = view
        #expect(window.makeFirstResponder(view))

        #expect(first.ownedFocusIntent(for: view, in: window) == .panel)
        #expect(second.ownedFocusIntent(for: view, in: window) == nil)
        #expect(!second.yieldFocusIntent(.panel, in: window))
        #expect(window.firstResponder === view)
        #expect(first.yieldFocusIntent(.panel, in: window))
        #expect(window.firstResponder !== view)
    }

    @Test("Remote disable closes the worker and re-enable replaces it")
    func remoteFeatureFlagLifecycle() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }
        let firstClient = SimulatorFeatureFlagPaneClient(blockStop: true)
        let secondClient = SimulatorFeatureFlagPaneClient()
        var clients: [SimulatorFeatureFlagPaneClient] = [firstClient, secondClient]
        let panel = SimulatorPanel(clientFactory: { clients.removeFirst() })
        defer { panel.close() }
        let firstCoordinator = panel.coordinator

        flags.setOverride(false, for: simulatorFlag)
        for _ in 0..<100 {
            if await firstClient.stopCount != 0 { break }
            await Task.yield()
        }

        #expect(await firstClient.stopCount == 1)
        flags.setOverride(true, for: simulatorFlag)
        panel.setVisibleInUI(true)
        for _ in 0..<100 { await Task.yield() }
        #expect(panel.coordinator === firstCoordinator)
        #expect(!panel.isFeatureReady)
        #expect(await secondClient.discoveryCount == 0)

        await firstClient.releaseStop()
        for _ in 0..<100 {
            if await secondClient.discoveryCount != 0 { break }
            await Task.yield()
        }
        #expect(panel.coordinator !== firstCoordinator)
        #expect(panel.isFeatureReady)
        #expect(await secondClient.discoveryCount == 1)
    }

    @Test("Awaitable close does not finish before worker rollback")
    func awaitableCloseWaitsForWorkerRollback() async {
        let client = SimulatorFeatureFlagPaneClient(blockStop: true)
        let panel = SimulatorPanel(client: client)
        let completion = SimulatorCloseCompletionProbe()
        let closeTask = Task { @MainActor in
            await panel.closeAndWait()
            await completion.markCompleted()
        }

        for _ in 0..<100 {
            if await client.stopCount != 0 { break }
            await Task.yield()
        }

        #expect(await client.stopCount == 1)
        #expect(!(await completion.isCompleted))

        await client.releaseStop()
        await closeTask.value
        #expect(await completion.isCompleted)
    }

    @Test("Application termination retains cleanup after a closed panel deallocates")
    func applicationTerminationRetainsOrphanedClose() async {
        let client = SimulatorFeatureFlagPaneClient(blockStop: true)
        weak var releasedPanel: SimulatorPanel?
        do {
            let panel = SimulatorPanel(client: client)
            releasedPanel = panel
            panel.close()
        }
        for _ in 0..<100 {
            if await client.stopCount != 0 { break }
            await Task.yield()
        }

        #expect(await client.stopCount == 1)
        #expect(releasedPanel == nil)
        let cleanupTasks = SimulatorPanel.beginApplicationTerminationCleanup()
        let completion = SimulatorCloseCompletionProbe()
        let terminationWait = Task {
            for cleanupTask in cleanupTasks {
                await cleanupTask.value
            }
            await completion.markCompleted()
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!(await completion.isCompleted))

        await client.releaseStop()
        await terminationWait.value
        #expect(await completion.isCompleted)
    }

    @Test("Cancelling application termination restores the live Simulator panel")
    func cancelledApplicationTerminationRestoresPanel() async {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let firstClient = SimulatorFeatureFlagPaneClient(blockStop: true)
        let secondClient = SimulatorFeatureFlagPaneClient()
        var clients = [firstClient, secondClient]
        let panel = SimulatorPanel(clientFactory: { clients.removeFirst() })
        defer { panel.close() }
        panel.setVisibleInUI(true)
        for _ in 0..<100 {
            if await firstClient.discoveryCount != 0 { break }
            await Task.yield()
        }
        let firstCoordinator = panel.coordinator

        let cleanupTasks = SimulatorPanel.beginApplicationTerminationCleanup()
        for _ in 0..<100 {
            if await firstClient.stopCount != 0 { break }
            await Task.yield()
        }
        #expect(await firstClient.stopCount == 1)

        SimulatorPanel.cancelApplicationTerminationCleanup()
        await firstClient.releaseStop()
        for task in cleanupTasks {
            await task.value
        }
        for _ in 0..<100 {
            let replacementStarted = await secondClient.discoveryCount == 1
            if panel.isFeatureReady,
               panel.coordinator !== firstCoordinator,
               replacementStarted {
                break
            }
            await Task.yield()
        }

        #expect(panel.isFeatureReady)
        #expect(panel.coordinator !== firstCoordinator)
        #expect(await secondClient.discoveryCount == 1)
    }

    @Test("External file drops target Simulator import instead of file previews")
    func externalFileDropRouting() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }
        let workspace = Workspace()
        let terminalPanelID = try #require(workspace.focusedPanelId)
        let client = SimulatorFeatureFlagPaneClient(devices: [SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )])
        let panel = SimulatorPanel(client: client)
        defer { panel.close() }
        workspace.panels[panel.id] = panel
        let originalPanelCount = workspace.panels.count
        let applicationURL = URL(fileURLWithPath: "/tmp/Fixture.app")
        let unsupportedURL = URL(fileURLWithPath: "/tmp/Fixture.txt")

        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [applicationURL], panelId: panel.id
        ) == false)
        #expect(TerminalPaneDropTargetView.simulatorFileDropOperation(
            urls: [applicationURL],
            workspace: workspace,
            panelId: panel.id
        ) == [])
        await panel.coordinator.start()
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [applicationURL], panelId: panel.id
        ) == true)
        #expect(TerminalPaneDropTargetView.simulatorFileDropOperation(
            urls: [applicationURL],
            workspace: workspace,
            panelId: panel.id
        ) == .copy)
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [unsupportedURL], panelId: panel.id
        ) == false)
        #expect(TerminalPaneDropTargetView.simulatorFileDropOperation(
            urls: [unsupportedURL],
            workspace: workspace,
            panelId: panel.id
        ) == [])
        #expect(TerminalPaneDropTargetView.simulatorFileDropOperation(
            urls: [],
            workspace: workspace,
            panelId: panel.id
        ) == [])
        #expect(workspace.panels.count == originalPanelCount)
        #expect(workspace.handleSimulatorExternalFileDrop(urls: [], panelId: panel.id) == false)

        panel.suspendForRemoteDisable()
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.app")], panelId: panel.id
        ) == false)

        flags.setOverride(false, for: simulatorFlag)
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.txt")],
            panelId: terminalPanelID
        ) == nil)
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.app")],
            panelId: panel.id
        ) == false)
    }

    @Test("Control routing selects focused or sole Simulator and rejects ambiguous targets")
    func controlRouting() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let terminalID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: terminalID))
        let first = try #require(workspace.newSimulatorSurface(inPane: paneID, focus: false))
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: nil,
            paneID: nil
        )

        guard case .unsupportedCharacter = TerminalController.shared.controlSimulatorBeginType(
            routing: routing,
            text: "🙂"
        ) else {
            Issue.record("The sole Simulator should be selected")
            return
        }

        let terminalRouting = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: terminalID,
            paneID: nil
        )
        guard case let .failed(.surfaceNotSimulator(rejectedID)) =
                TerminalController.shared.controlSimulatorBeginType(
                    routing: terminalRouting,
                    text: "x"
                ) else {
            Issue.record("An explicit terminal must not receive Simulator input")
            return
        }
        #expect(rejectedID == terminalID)

        let second = try #require(workspace.newSimulatorSurface(inPane: paneID, focus: false))
        guard case .failed(.ambiguousSimulatorSurfaces(2)) =
                TerminalController.shared.controlSimulatorBeginType(routing: routing, text: "x") else {
            Issue.record("Two unfocused Simulators should require --surface")
            return
        }

        workspace.focusPanel(first.id)
        guard case .unsupportedCharacter = TerminalController.shared.controlSimulatorBeginType(
            routing: routing,
            text: "🙂"
        ) else {
            Issue.record("The focused Simulator should win over ambiguity")
            return
        }

        workspace.isRemoteTmuxMirror = true
        guard case .failed(.remoteWorkspace) = TerminalController.shared.controlSimulatorBeginType(
            routing: routing,
            text: "x"
        ) else {
            Issue.record("Remote workspaces must reject local Simulator control")
            return
        }
        first.close()
        second.close()
    }

    @Test("Control routing honors an explicit pane over workspace focus")
    func controlRoutingHonorsPane() throws {
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let terminalID = try #require(workspace.focusedPanelId)
        let firstPane = try #require(workspace.paneId(forPanelId: terminalID))
        let first = try #require(workspace.newSimulatorSurface(inPane: firstPane, focus: true))
        let second = try #require(workspace.newSimulatorSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))
        let secondPane = try #require(workspace.paneId(forPanelId: second.id))
        workspace.focusPanel(first.id)
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: nil,
            paneID: secondPane.id
        )

        guard case let .panel(resolved) = TerminalController.shared.resolveSimulatorPanel(
            routing: routing
        ) else {
            Issue.record("The explicit pane should resolve its selected Simulator")
            return
        }
        #expect(resolved === second)

        second.suspendForRemoteDisable()
        guard case .unavailable = TerminalController.shared.resolveSimulatorPanel(
            routing: routing
        ) else {
            Issue.record("A transitioning Simulator should resolve as unavailable")
            return
        }
    }

    @Test("Context discovers the default device before returning identity")
    func contextDiscoversDefaultDevice() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let device = SimulatorDevice(
            id: "fresh-default",
            name: "Fresh iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPad,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorFeatureFlagPaneClient(devices: [device])
        let panel = SimulatorPanel(client: client)
        workspace.panels[panel.id] = panel

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panel.id,
            paneID: nil
        )
        guard case let .started(_, _, receipt) = TerminalController.shared.controlSimulatorBeginOperation(
            routing: routing,
            operation: .context
        ) else {
            Issue.record("Expected context operation to start")
            return
        }

        let completion = await Task.detached {
            receipt.wait(timeout: 2)
        }.value
        guard case let .success(.object(payload)) = completion else {
            Issue.record("Expected context to return the discovered device")
            return
        }
        #expect(payload["simulator_id"] == JSONValue.string(device.id))
        #expect(payload["device_name"] == JSONValue.string(device.name))
        #expect(await client.discoveryCount == 1)
    }

    @Test("Context reads persisted identity without starting a stopped Simulator")
    func contextReadsPersistedIdentityWithoutStartingDevice() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let device = SimulatorDevice(
            id: "persisted-ipad",
            name: "Persisted iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPad,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorFeatureFlagPaneClient(devices: [device])
        let panel = SimulatorPanel(
            preferredDeviceID: device.id,
            preferredRuntimeIdentifier: device.runtimeIdentifier,
            preferredDeviceTypeIdentifier: device.deviceTypeIdentifier,
            client: client
        )
        workspace.panels[panel.id] = panel

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panel.id,
            paneID: nil
        )
        guard case let .started(_, _, receipt) = TerminalController.shared.controlSimulatorBeginOperation(
            routing: routing,
            operation: .context
        ) else {
            Issue.record("Expected context operation to start")
            return
        }

        let completion = await Task.detached {
            receipt.wait(timeout: 2)
        }.value
        guard case let .success(.object(payload)) = completion else {
            Issue.record("Expected context to return persisted identity")
            return
        }
        #expect(payload["simulator_id"] == .string(device.id))
        #expect(payload["runtime_id"] == .string(device.runtimeIdentifier))
        #expect(payload["device_type_id"] == .string(device.deviceTypeIdentifier))
        #expect(await client.discoveryCount == 0)
        #expect(await client.activationCount == 0)
    }

    @Test("Event log reads cached history without starting a stopped Simulator")
    func eventLogReadsCachedHistoryWithoutStartingDevice() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let device = SimulatorDevice(
            id: "stopped-event-log-ipad",
            name: "Stopped Event Log iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPad,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorFeatureFlagPaneClient(devices: [device])
        let panel = SimulatorPanel(
            preferredDeviceID: device.id,
            preferredRuntimeIdentifier: device.runtimeIdentifier,
            preferredDeviceTypeIdentifier: device.deviceTypeIdentifier,
            client: client
        )
        workspace.panels[panel.id] = panel

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panel.id,
            paneID: nil
        )
        guard case let .started(_, _, receipt) = TerminalController.shared.controlSimulatorBeginOperation(
            routing: routing,
            operation: .eventLog(limit: 10)
        ) else {
            Issue.record("Expected event-log operation to start")
            return
        }

        let completion = await Task.detached {
            receipt.wait(timeout: 2)
        }.value
        guard case let .success(.object(payload)) = completion else {
            Issue.record("Expected cached event-log payload")
            return
        }
        #expect(payload["events"] == .array([]))
        #expect(await client.discoveryCount == 0)
        #expect(await client.activationCount == 0)
    }

    @Test("Screenshot preparation starts a restored shutdown Simulator")
    func screenshotPreparationStartsRestoredShutdownDevice() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let device = SimulatorDevice(
            id: "restored-screenshot-ipad",
            name: "Restored Screenshot iPad",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPad,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorFeatureFlagPaneClient(devices: [device])
        let panel = SimulatorPanel(
            preferredDeviceID: device.id,
            preferredRuntimeIdentifier: device.runtimeIdentifier,
            preferredDeviceTypeIdentifier: device.deviceTypeIdentifier,
            client: client
        )
        workspace.panels[panel.id] = panel

        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panel.id,
            paneID: nil
        )
        guard case let .started(_, _, receipt) = TerminalController.shared.controlSimulatorBeginOperation(
            routing: routing,
            operation: .prepareScreenshot
        ) else {
            Issue.record("Expected screenshot preparation to start")
            return
        }

        let completion = await Task.detached {
            receipt.wait(timeout: 2)
        }.value
        guard case let .success(.object(payload)) = completion else {
            Issue.record("Expected capture-ready Simulator context")
            return
        }
        #expect(payload["simulator_id"] == .string(device.id))
        #expect(payload["state"] == .string(SimulatorDeviceState.booted.rawValue))
        #expect(await client.discoveryCount == 1)
        #expect(await client.activationCount == 1)
    }

    @Test("Control gestures map logical touches and edges through every orientation")
    func controlGestureOrientationMapping() throws {
        let touch = ControlSimulatorTouch(
            phase: "moved", x: 0.2, y: 0.3,
            secondX: 0.7, secondY: 0.8, edge: "left"
        )
        let cases: [(SimulatorOrientation, SimulatorPoint, SimulatorPoint, SimulatorEdge)] = [
            (.portrait, SimulatorPoint(x: 0.2, y: 0.3), SimulatorPoint(x: 0.7, y: 0.8), .left),
            (.portraitUpsideDown, SimulatorPoint(x: 0.8, y: 0.7),
             SimulatorPoint(x: 0.3, y: 0.2), .right),
            (.landscapeLeft, SimulatorPoint(x: 0.3, y: 0.8),
             SimulatorPoint(x: 0.8, y: 0.3), .bottom),
            (.landscapeRight, SimulatorPoint(x: 0.7, y: 0.2),
             SimulatorPoint(x: 0.2, y: 0.7), .top),
        ]

        for (orientation, primary, secondary, edge) in cases {
            let geometry = SimulatorOrientationGeometry(
                rawWidth: 100, rawHeight: 200, requestedOrientation: orientation
            )
            let event = try controlSimulatorPointerEvent(touch, geometry: geometry)
            #expect(event.phase == .moved)
            #expect(event.primary == primary)
            #expect(event.secondary == secondary)
            #expect(event.edge == edge)
        }
    }

    @Test("Semantic taps recapture after the accessibility display changes")
    func semanticTapRecapturesAfterDisplayChange() async throws {
        let flags = CmuxFeatureFlags.shared
        let simulatorFlag = CmuxFeatureFlags.allFlags[5]
        let previousOverride = flags.overrideValue(for: simulatorFlag)
        flags.setOverride(true, for: simulatorFlag)
        defer { flags.setOverride(previousOverride, for: simulatorFlag) }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true, eagerLoadTerminal: false)
        TerminalController.shared.setActiveTabManager(manager)
        defer {
            workspace.teardownAllPanels()
            TerminalController.shared.setActiveTabManager(nil)
        }
        let device = SimulatorDevice(
            id: "rotating-semantic-tap",
            name: "Rotating iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorRotatingAccessibilityPaneClient(device: device)
        let panel = SimulatorPanel(client: client)
        workspace.panels[panel.id] = panel
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panel.id,
            paneID: nil
        )

        guard case let .started(_, _, receipt) =
            TerminalController.shared.controlSimulatorBeginOperation(
                routing: routing,
                operation: .accessibilityTap(
                    label: "Continue",
                    identifier: "continue",
                    role: "button"
                )
            ) else {
            Issue.record("Expected semantic tap operation to start")
            return
        }

        let completion = await Task.detached {
            receipt.wait(timeout: 3)
        }.value
        guard case .success = completion else {
            Issue.record("Expected semantic tap to recover from the display change")
            return
        }

        #expect(await client.accessibilityReadCount >= 2)
        let gestures = await client.gestureEvents()
        #expect(gestures.count == 1)
        let gesture = try #require(gestures.first)
        let expectedPoint = SimulatorOrientationGeometry(
            display: SimulatorRotatingAccessibilityPaneClient.landscapeDisplay
        ).rawPointerEvent(SimulatorPointerEvent(
            phase: .began,
            primary: SimulatorPoint(x: 0.8, y: 0.3)
        )).primary
        #expect(gesture.map { $0.primary } == [expectedPoint, expectedPoint])
    }

    @Test("Ref actions revalidate after their pre-action delay")
    func refActionRevalidatesAfterPreDelay() async throws {
        let device = SimulatorDevice(
            id: "delayed-semantic-tap",
            name: "Delayed iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorDelayedAccessibilityPaneClient(device: device)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: device.id)
        let timing = SimulatorPreActionMutationTiming(client: client)
        let executor = SimulatorUIAutomationExecutor(scheduler: timing)
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        guard case let .object(payload) = snapshot,
              case let .array(elements)? = payload["elements"] else {
            Issue.record("Expected a semantic snapshot")
            await coordinator.close()
            return
        }
        let elementRefs = elements.compactMap { value -> String? in
            guard case let .object(fields) = value,
                  fields["identifier"] == .string("continue"),
                  case let .string(ref)? = fields["ref"] else {
                return nil
            }
            return ref
        }
        let elementRef = try #require(elementRefs.first)

        do {
            _ = try await executor.perform(
                .uiAction(.tap(
                    elementRef: elementRef,
                    preDelayMilliseconds: 100,
                    postDelayMilliseconds: 0
                )),
                coordinator: coordinator
            )
            Issue.record("Expected the delayed action to reject changed UI")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "ui_state_changed")
        }

        #expect(await client.gestureCount == 0)
        await coordinator.close()
    }

    @Test("A zero-timeout UI wait still inspects the current screen")
    func zeroTimeoutUIWaitSamplesImmediately() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let timing = InstantSimulatorUIAutomationTiming()
        let executor = SimulatorUIAutomationExecutor(scheduler: timing)

        let result = try await executor.perform(
            .uiWait(ControlSimulatorUIWait(
                predicate: "exists",
                elementRef: nil,
                identifier: "continue",
                label: nil,
                role: nil,
                value: nil,
                text: nil,
                timeoutMilliseconds: 0,
                pollIntervalMilliseconds: 100,
                settledDurationMilliseconds: 0
            )),
            coordinator: coordinator
        )

        guard case let .object(payload) = result else {
            Issue.record("Expected a completed UI wait payload")
            await coordinator.close()
            return
        }
        #expect(payload["completed"] == .bool(true))
        #expect(timing.monotonicNowMilliseconds() == 1_000)
        await coordinator.close()
    }

    @Test("UI waits retry captures invalidated by concurrent input")
    func uiWaitRetriesConcurrentMutation() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let timing = InstantSimulatorUIAutomationTiming()
        let executor = SimulatorUIAutomationExecutor(scheduler: timing)
        await client.mutateOnNextAccessibilityRead {
            coordinator.clearUIAutomationSnapshot()
        }

        let result = try await executor.perform(
            .uiWait(ControlSimulatorUIWait(
                predicate: "exists",
                elementRef: nil,
                identifier: "continue",
                label: nil,
                role: nil,
                value: nil,
                text: nil,
                timeoutMilliseconds: 1_000,
                pollIntervalMilliseconds: 100,
                settledDurationMilliseconds: 0
            )),
            coordinator: coordinator
        )

        guard case let .object(payload) = result else {
            Issue.record("Expected a completed UI wait payload")
            await coordinator.close()
            return
        }
        #expect(payload["completed"] == .bool(true))
        #expect(await client.accessibilityReads() == 2)
        await coordinator.close()
    }

    @Test("Split semantic touch releases with its original snapshot ref")
    func splitSemanticTouchRetainsItsTarget() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let executor = SimulatorUIAutomationExecutor(
            scheduler: InstantSimulatorUIAutomationTiming()
        )
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: snapshot,
            identifier: "continue"
        )

        _ = try await executor.perform(
            .uiAction(.touch(
                elementRef: elementRef,
                down: true,
                up: false,
                delayMilliseconds: 0
            )),
            coordinator: coordinator
        )
        _ = try await executor.perform(
            .uiAction(.touch(
                elementRef: elementRef,
                down: false,
                up: true,
                delayMilliseconds: 0
            )),
            coordinator: coordinator
        )

        #expect(await client.touchPhases() == [["began"], ["ended"]])
        await coordinator.close()
    }

    @Test("A balanced semantic touch settles before its refreshed capture")
    func balancedSemanticTouchWaitsForQuiescence() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let timing = InstantSimulatorUIAutomationTiming()
        let executor = SimulatorUIAutomationExecutor(scheduler: timing)
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: snapshot,
            identifier: "continue"
        )
        let startedAt = timing.monotonicNowMilliseconds()

        _ = try await executor.perform(
            .uiAction(.touch(
                elementRef: elementRef,
                down: true,
                up: true,
                delayMilliseconds: 0
            )),
            coordinator: coordinator
        )

        #expect(await client.touchPhases() == [["began", "ended"]])
        #expect(
            timing.monotonicNowMilliseconds() - startedAt
                >= SimulatorUIAutomationExecutor
                    .postMutationAccessibilityQuiescenceMilliseconds + 100
        )
        await coordinator.close()
    }

    @Test("A second down-only semantic touch is rejected before worker input")
    func overlappingSemanticTouchIsRejected() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let executor = SimulatorUIAutomationExecutor(
            scheduler: InstantSimulatorUIAutomationTiming()
        )
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: snapshot,
            identifier: "continue"
        )
        let down = ControlSimulatorUIAction.touch(
            elementRef: elementRef,
            down: true,
            up: false,
            delayMilliseconds: 0
        )

        _ = try await executor.perform(.uiAction(down), coordinator: coordinator)
        do {
            _ = try await executor.perform(.uiAction(down), coordinator: coordinator)
            Issue.record("Expected an overlapping touch-down to be rejected")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "touch_already_held")
        }

        #expect(await client.touchPhases() == [["began"]])
        await coordinator.close()
    }

    @Test("A display change releases a held semantic touch")
    func splitSemanticTouchReleasesAfterDisplayChange() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let executor = SimulatorUIAutomationExecutor(
            scheduler: InstantSimulatorUIAutomationTiming()
        )
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: snapshot,
            identifier: "continue"
        )
        _ = try await executor.perform(
            .uiAction(.touch(
                elementRef: elementRef,
                down: true,
                up: false,
                delayMilliseconds: 0
            )),
            coordinator: coordinator
        )
        await client.emitDisplay(.init(
            width: 2_532,
            height: 1_170,
            orientation: .landscapeLeft,
            scale: 3
        ))

        do {
            _ = try await executor.perform(
                .uiAction(.touch(
                    elementRef: elementRef,
                    down: false,
                    up: true,
                    delayMilliseconds: 0
                )),
                coordinator: coordinator
            )
            Issue.record("Expected stale held-touch geometry to fail")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "ui_state_changed")
        }

        #expect(await client.sentMessages().contains(.releaseInputs))
        #expect(coordinator.heldUIAutomationTouch(elementRef: elementRef) == nil)
        await coordinator.close()
    }

    @Test("An unchanged snapshot preserves the refs it omits")
    func unchangedSnapshotPreservesExistingRefs() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let timing = InstantSimulatorUIAutomationTiming()
        let executor = SimulatorUIAutomationExecutor(scheduler: timing)
        let first = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: first,
            identifier: "continue"
        )
        let screenHash = try simulatorScreenHash(in: first)
        let refreshedDisplay = SimulatorDisplayMetadata(
            width: 1_200,
            height: 2_600,
            orientation: .portrait,
            scale: 3
        )
        await client.emitDisplay(refreshedDisplay)
        for _ in 0..<100 where coordinator.display != refreshedDisplay {
            await Task.yield()
        }
        #expect(coordinator.display == refreshedDisplay)

        let unchanged = try await executor.perform(
            .uiSnapshot(sinceScreenHash: screenHash),
            coordinator: coordinator
        )
        guard case let .object(payload) = unchanged else {
            Issue.record("Expected an unchanged snapshot payload")
            await coordinator.close()
            return
        }
        #expect(payload["type"] == .string("runtime-snapshot-unchanged"))
        let preserved = try coordinator.currentUIAutomationSnapshot(
            nowMilliseconds: timing.wallTimeNowMilliseconds()
        )
        #expect(preserved.display == refreshedDisplay)
        #expect(preserved.element(ref: elementRef) != nil)

        _ = try await executor.perform(
            .uiAction(.tap(
                elementRef: elementRef,
                preDelayMilliseconds: 0,
                postDelayMilliseconds: 0
            )),
            coordinator: coordinator
        )
        #expect(await client.gestureCount() == 1)
        await coordinator.close()
    }

    @Test("Semantic revalidation rejects input that lands during capture")
    func semanticRevalidationTracksConcurrentMutation() async throws {
        let client = SimulatorSemanticAutomationPaneClient(behavior: .staticTree)
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let executor = SimulatorUIAutomationExecutor(
            scheduler: InstantSimulatorUIAutomationTiming()
        )
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: snapshot,
            identifier: "continue"
        )
        await client.mutateOnNextAccessibilityRead {
            coordinator.clearUIAutomationSnapshot()
        }

        do {
            _ = try await executor.perform(
                .uiAction(.tap(
                    elementRef: elementRef,
                    preDelayMilliseconds: 0,
                    postDelayMilliseconds: 0
                )),
                coordinator: coordinator
            )
            Issue.record("Expected concurrent input to invalidate revalidation")
        } catch let failure as SimulatorUIAutomationFailure {
            #expect(failure.code == "ui_state_changed")
        }

        #expect(await client.gestureCount() == 0)
        await coordinator.close()
    }

    @Test("Semantic typing waits until the tapped field reports focus")
    func semanticTypingWaitsForFocus() async throws {
        let timing = InstantSimulatorUIAutomationTiming()
        let client = SimulatorSemanticAutomationPaneClient(
            behavior: .focusAfterSecondPostTapRead,
            timing: timing
        )
        let coordinator = SimulatorPaneCoordinator(client: client)
        try await coordinator.selectDeviceAndWait(id: client.deviceID)
        let executor = SimulatorUIAutomationExecutor(scheduler: timing)
        let snapshot = try await executor.perform(
            .uiSnapshot(sinceScreenHash: nil),
            coordinator: coordinator
        )
        let elementRef = try simulatorElementRef(
            in: snapshot,
            identifier: "search"
        )

        _ = try await executor.perform(
            .uiAction(.typeText(
                elementRef: elementRef,
                text: "settings",
                replaceExisting: true
            )),
            coordinator: coordinator
        )

        let timeline = await client.timeline()
        let tapIndex = try #require(timeline.firstIndex(of: "tap"))
        let unfocusedIndex = try #require(
            timeline[tapIndex...].firstIndex(of: "read:unfocused")
        )
        let focusedIndex = try #require(
            timeline[unfocusedIndex...].firstIndex(of: "read:focused")
        )
        let typeIndex = try #require(timeline.firstIndex(of: "type"))
        #expect(tapIndex < unfocusedIndex)
        #expect(unfocusedIndex < focusedIndex)
        #expect(focusedIndex < typeIndex)
        #expect(!(await client.readAccessibilityTooSoonAfterType()))
        await coordinator.close()
    }

    @Test("Simulator accessibility socket payload preserves axe fields and bounds metadata")
    func accessibilitySocketPayload() throws {
        let node = SimulatorAccessibilityNode(
            id: "continue-button",
            role: "Button",
            label: "Continue",
            value: "Ready",
            roleDescription: "button",
            frame: SimulatorRect(x: 10, y: 20, width: 80, height: 40),
            isEnabled: true,
            children: []
        )
        let snapshot = SimulatorAccessibilitySnapshot(
            roots: [node],
            display: SimulatorDisplayMetadata(
                width: 1_200, height: 2_400, orientation: .portrait, scale: 3
            ),
            nodeCount: 500,
            isTruncated: true
        )

        guard case let .object(payload) = try simulatorAccessibilityResultPayload(
            .accessibility(snapshot)
        ), case let .array(roots)? = payload["roots"],
        case let .object(encoded)? = roots.first else {
            Issue.record("Expected an accessibility payload")
            return
        }
        #expect(payload["node_count"] == .int(500))
        #expect(payload["truncated"] == .bool(true))
        #expect(encoded["AXLabel"] == .string("Continue"))
        #expect(encoded["AXUniqueId"] == .string("continue-button"))
        #expect(encoded["role_description"] == .string("button"))
        #expect(encoded["type"] == .string("Button"))

        #expect(try simulatorForegroundApplicationResultPayload(
            .foregroundApplication(nil)
        ) == .object(["application": .null]))
    }
}

private actor SimulatorSemanticAutomationPaneClient: SimulatorPaneClient {
    enum Behavior: Equatable, Sendable {
        case staticTree
        case focusAfterSecondPostTapRead
    }

    nonisolated let deviceID = "semantic-automation-device"
    private static let defaultDisplay = SimulatorDisplayMetadata(
        width: 1_170,
        height: 2_532,
        orientation: .portrait,
        scale: 3
    )

    private let events = SimulatorWorkerEventStreamSource(
        maximumBufferedBytes: 16 * 1_024,
        maximumBufferedEvents: 32,
        onTermination: {}
    )
    private let behavior: Behavior
    private let timing: (any SimulatorUIAutomationScheduling)?
    private var actions: [SimulatorControlAction] = []
    private var messages: [SimulatorWorkerInbound] = []
    private var recordedTimeline: [String] = []
    private var didTap = false
    private var postTapReadCount = 0
    private var typedAtMilliseconds: Int64?
    private var observedEarlyPostTypeRead = false
    private var mutationHook: (@MainActor @Sendable () -> Void)?
    private var accessibilityReadCount = 0
    private var currentDisplay =
        SimulatorSemanticAutomationPaneClient.defaultDisplay

    init(
        behavior: Behavior,
        timing: (any SimulatorUIAutomationScheduling)? = nil
    ) {
        self.behavior = behavior
        self.timing = timing
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        [SimulatorDevice(
            id: deviceID,
            name: "Semantic iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )]
    }

    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? {
        currentDisplay
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        let capabilities: Set<SimulatorCapability> = [
            .accessibility,
            .keyboard,
            .touch,
        ]
        _ = await events.continuation.yield(.message(.display(currentDisplay)))
        _ = await events.continuation.yield(.message(.capabilities(capabilities)))
        _ = await events.continuation.yield(.message(.capabilitiesHydrated(capabilities)))
    }

    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { events.stream }
    func send(_ message: SimulatorWorkerInbound) async {
        messages.append(message)
    }

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        switch action {
        case .readAccessibility:
            accessibilityReadCount += 1
            if let typedAtMilliseconds, let timing,
               timing.monotonicNowMilliseconds() - typedAtMilliseconds < 500 {
                observedEarlyPostTypeRead = true
            }
            if didTap { postTapReadCount += 1 }
            let focused = behavior == .focusAfterSecondPostTapRead
                && didTap
                && postTapReadCount >= 2
            recordedTimeline.append(focused ? "read:focused" : "read:unfocused")
            let snapshot = Self.snapshot(
                searchFocused: focused,
                display: currentDisplay
            )
            if let mutationHook {
                self.mutationHook = nil
                await mutationHook()
            }
            return .accessibility(snapshot)
        case .interactive(.gesture):
            didTap = true
            recordedTimeline.append("tap")
            return .none
        case let .interactive(.touch(events, _)):
            recordedTimeline.append(contentsOf: events.map { $0.phase.rawValue })
            return .none
        case .interactive(.typeText):
            typedAtMilliseconds = timing?.monotonicNowMilliseconds()
            recordedTimeline.append("type")
            return .none
        case .interactive(.keyChord):
            recordedTimeline.append("select-all")
            return .none
        default:
            return .none
        }
    }

    func invalidateWorker() async {}
    func stop() async {}

    func mutateOnNextAccessibilityRead(
        _ hook: @escaping @MainActor @Sendable () -> Void
    ) {
        mutationHook = hook
    }

    func emitDisplay(_ display: SimulatorDisplayMetadata) async {
        currentDisplay = display
        _ = await events.continuation.yield(.message(.display(display)))
    }

    func sentMessages() -> [SimulatorWorkerInbound] {
        messages
    }

    func readAccessibilityTooSoonAfterType() -> Bool {
        observedEarlyPostTypeRead
    }

    func accessibilityReads() -> Int {
        accessibilityReadCount
    }

    func gestureCount() -> Int {
        actions.filter {
            guard case .interactive(.gesture) = $0 else { return false }
            return true
        }.count
    }

    func touchPhases() -> [[String]] {
        actions.compactMap {
            guard case let .interactive(.touch(events, _)) = $0 else { return nil }
            return events.map(\.phase.rawValue)
        }
    }

    func timeline() -> [String] {
        recordedTimeline
    }

    private static func snapshot(
        searchFocused: Bool,
        display: SimulatorDisplayMetadata
    ) -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "application",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(x: 0, y: 0, width: 390, height: 844),
                    isEnabled: true,
                    children: [
                        SimulatorAccessibilityNode(
                            id: "button",
                            identifier: "continue",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            frame: SimulatorRect(x: 20, y: 100, width: 120, height: 44),
                            isEnabled: true,
                            children: []
                        ),
                        SimulatorAccessibilityNode(
                            id: "search-field",
                            identifier: "search",
                            role: "TextField",
                            label: "Search",
                            value: nil,
                            frame: SimulatorRect(x: 20, y: 180, width: 300, height: 44),
                            isEnabled: true,
                            isFocused: searchFocused,
                            children: []
                        ),
                    ]
                ),
            ],
            display: display
        )
    }
}

// The lock serializes every read and mutation of the timing fixture's state.
private final class InstantSimulatorUIAutomationTiming:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var currentMilliseconds: Int64 = 1_000

    func monotonicNowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        lock.withLock {
            currentMilliseconds += max(1, milliseconds)
        }
    }
}

private func simulatorElementRef(
    in snapshot: JSONValue,
    identifier: String
) throws -> String {
    guard case let .object(payload) = snapshot,
          case let .array(elements)? = payload["elements"] else {
        Issue.record("Expected a semantic snapshot")
        throw CancellationError()
    }
    let elementRefs = elements.compactMap { value -> String? in
        guard case let .object(fields) = value,
              fields["identifier"] == .string(identifier),
              case let .string(ref)? = fields["ref"] else {
            return nil
        }
        return ref
    }
    return try #require(elementRefs.first)
}

private func simulatorScreenHash(in snapshot: JSONValue) throws -> String {
    guard case let .object(payload) = snapshot,
          case let .string(screenHash)? = payload["screen_hash"] else {
        Issue.record("Expected a semantic snapshot screen hash")
        throw CancellationError()
    }
    return screenHash
}

private actor SimulatorFeatureFlagPaneClient: SimulatorPaneClient {
    private let events = SimulatorWorkerEventStreamSource(
        maximumBufferedBytes: 1_024,
        maximumBufferedEvents: 4,
        onTermination: {}
    )
    private(set) var discoveryCount = 0
    private(set) var activationCount = 0
    private(set) var stopCount = 0
    private let blockStop: Bool
    private let devices: [SimulatorDevice]
    private var stopContinuation: CheckedContinuation<Void, Never>?

    init(blockStop: Bool = false, devices: [SimulatorDevice] = []) {
        self.blockStop = blockStop
        self.devices = devices
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        discoveryCount += 1
        return devices
    }

    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? { nil }
    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        activationCount += 1
    }
    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { events.stream }
    func send(_ message: SimulatorWorkerInbound) async {}
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult { .none }
    func invalidateWorker() async {}
    func stop() async {
        stopCount += 1
        guard blockStop else { return }
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }
}

private actor SimulatorRotatingAccessibilityPaneClient: SimulatorPaneClient {
    static let portraitDisplay = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .portrait,
        scale: 3
    )
    static let landscapeDisplay = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .landscapeLeft,
        scale: 3
    )

    private let events = SimulatorWorkerEventStreamSource(
        maximumBufferedBytes: 16 * 1_024,
        maximumBufferedEvents: 16,
        onTermination: {}
    )
    private let device: SimulatorDevice
    private var actions: [SimulatorControlAction] = []
    private(set) var accessibilityReadCount = 0

    init(device: SimulatorDevice) {
        self.device = device
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        [device]
    }

    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? {
        Self.portraitDisplay
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        let capabilities: Set<SimulatorCapability> = [.accessibility, .touch]
        _ = await events.continuation.yield(.message(.capabilities(capabilities)))
        _ = await events.continuation.yield(.message(.capabilitiesHydrated(capabilities)))
    }

    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { events.stream }
    func send(_ message: SimulatorWorkerInbound) async {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        guard case .readAccessibility = action else { return .none }
        accessibilityReadCount += 1
        if accessibilityReadCount == 1 {
            _ = await events.continuation.yield(.message(.display(Self.landscapeDisplay)))
            try await Task.sleep(for: .milliseconds(25))
            return .accessibility(Self.snapshot(
                display: Self.portraitDisplay,
                buttonFrame: SimulatorRect(x: 60, y: 160, width: 80, height: 80)
            ))
        }
        return .accessibility(Self.snapshot(
            display: Self.landscapeDisplay,
            buttonFrame: SimulatorRect(x: 280, y: 200, width: 80, height: 80)
        ))
    }

    func invalidateWorker() async {}
    func stop() async {}

    func gestureEvents() -> [[SimulatorPointerEvent]] {
        actions.compactMap { action in
            guard case let .interactive(.gesture(events)) = action else { return nil }
            return events
        }
    }

    private static func snapshot(
        display: SimulatorDisplayMetadata,
        buttonFrame: SimulatorRect
    ) -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "application",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(x: 0, y: 0, width: 400, height: 800),
                    isEnabled: true,
                    children: [
                        SimulatorAccessibilityNode(
                            id: "button",
                            identifier: "continue",
                            role: "Button",
                            label: "Continue",
                            value: nil,
                            frame: buttonFrame,
                            isEnabled: true,
                            children: []
                        ),
                    ]
                ),
            ],
            display: display
        )
    }
}

private actor SimulatorDelayedAccessibilityPaneClient: SimulatorPaneClient {
    static let display = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .portrait,
        scale: 3
    )

    private let events = SimulatorWorkerEventStreamSource(
        maximumBufferedBytes: 16 * 1_024,
        maximumBufferedEvents: 16,
        onTermination: {}
    )
    private let device: SimulatorDevice
    private var showsChangedUI = false
    private(set) var gestureCount = 0

    init(device: SimulatorDevice) {
        self.device = device
    }

    func discoverDevices() async throws -> [SimulatorDevice] {
        [device]
    }

    func synchronizeOrientation(
        _ orientation: SimulatorOrientation
    ) async throws -> SimulatorDisplayMetadata? {
        Self.display
    }

    func activateDevice(id: String, geometry: SimulatorSurfaceGeometry?) async throws {
        let capabilities: Set<SimulatorCapability> = [.accessibility, .touch]
        _ = await events.continuation.yield(.message(.display(Self.display)))
        _ = await events.continuation.yield(.message(.capabilities(capabilities)))
        _ = await events.continuation.yield(.message(.capabilitiesHydrated(capabilities)))
    }

    func shutdownDevice(id: String) async throws {}
    func subscribe() async -> SimulatorWorkerEventStream { events.stream }
    func send(_ message: SimulatorWorkerInbound) async {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        switch action {
        case .readAccessibility:
            return .accessibility(Self.snapshot(changed: showsChangedUI))
        case .interactive(.gesture):
            gestureCount += 1
            return .none
        default:
            return .none
        }
    }

    func invalidateWorker() async {}
    func stop() async {}

    func showChangedUI() {
        showsChangedUI = true
    }

    private static func snapshot(changed: Bool) -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "application",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(x: 0, y: 0, width: 400, height: 800),
                    isEnabled: true,
                    children: [
                        SimulatorAccessibilityNode(
                            id: "button",
                            identifier: "continue",
                            role: "Button",
                            label: changed ? "Changed" : "Continue",
                            value: nil,
                            frame: changed
                                ? SimulatorRect(x: 240, y: 500, width: 80, height: 80)
                                : SimulatorRect(x: 40, y: 100, width: 80, height: 80),
                            isEnabled: true,
                            children: []
                        ),
                    ]
                ),
            ],
            display: display
        )
    }
}

// The lock serializes timing state; the client is an actor-safe immutable reference.
private final class SimulatorPreActionMutationTiming:
    SimulatorUIAutomationScheduling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let client: SimulatorDelayedAccessibilityPaneClient
    private var currentMilliseconds: Int64 = 1_000
    private var hasMutated = false

    init(client: SimulatorDelayedAccessibilityPaneClient) {
        self.client = client
    }

    func monotonicNowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func wallTimeNowMilliseconds() -> Int64 {
        lock.withLock { currentMilliseconds }
    }

    func nextEvent(after duration: Duration) async throws {
        let components = duration.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        let shouldMutate = lock.withLock {
            currentMilliseconds += milliseconds
            guard !hasMutated else { return false }
            hasMutated = true
            return true
        }
        if shouldMutate {
            await client.showChangedUI()
        }
    }
}

private actor SimulatorCloseCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private final class TestSimulatorResponder: NSView, SimulatorInputResponder {
    let simulatorOwnerID: ObjectIdentifier?
    init(owner: ObjectIdentifier) { simulatorOwnerID = owner; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
}
