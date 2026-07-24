import AppKit
import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
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

        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.app")], panelId: panel.id
        ) == false)
        await panel.coordinator.start()
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.app")], panelId: panel.id
        ) == true)
        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.txt")], panelId: panel.id
        ) == false)
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

private final class TestSimulatorResponder: NSView, SimulatorInputResponder {
    let simulatorOwnerID: ObjectIdentifier?
    init(owner: ObjectIdentifier) { simulatorOwnerID = owner; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
}
