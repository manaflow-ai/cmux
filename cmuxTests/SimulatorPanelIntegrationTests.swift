import CmuxControlSocket
import CmuxSimulator
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

    @Test("External file drops target Simulator import instead of file previews")
    func externalFileDropRouting() {
        let workspace = Workspace()
        let panel = SimulatorPanel()
        defer { panel.close() }
        workspace.panels[panel.id] = panel
        let originalPanelCount = workspace.panels.count

        #expect(workspace.handleSimulatorExternalFileDrop(
            urls: [URL(fileURLWithPath: "/tmp/Fixture.app")], panelId: panel.id
        ) == true)
        #expect(workspace.panels.count == originalPanelCount)
        #expect(workspace.handleSimulatorExternalFileDrop(urls: [], panelId: panel.id) == false)
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

    @Test("Simulator button CLI canonicalizes mixed-case native names")
    func buttonCLIParsing() {
        let cli = CMUXCLI(args: [])
        #expect(cli.simulatorButtonName("Home") == "home")
        #expect(cli.simulatorButtonName("SideButton") == "sideButton" && cli.simulatorCADiagnosticName("Blended") == "blended")
    }

    @Test("Simulator permission CLI normalizes the full serve-sim command shape")
    func permissionCLIParsing() throws {
        let cli = CMUXCLI(args: [])
        let limited = try #require(cli.simulatorAgentRequest(
            subcommand: "permissions",
            arguments: cli.parseSimulatorArguments([
                "grant", "photo", "com.example.App", "--value=limited",
                "--surface", "surface:2",
            ])
        ))
        #expect(limited.method == "simulator.permissions.set")
        #expect(limited.params["action"] as? String == "grant")
        #expect(limited.params["service"] as? String == "photos-limited")
        #expect(limited.params["bundle_id"] as? String == "com.example.App")
        #expect(limited.output == .permissionsUpdated(
            action: "grant",
            service: "photos-limited",
            bundleIdentifier: "com.example.App"
        ))

        let never = try #require(cli.simulatorAgentRequest(
            subcommand: "permissions",
            arguments: cli.parseSimulatorArguments([
                "grant", "location", "com.example.App", "never",
            ])
        ))
        #expect(never.params["action"] as? String == "revoke")
        #expect(never.params["service"] as? String == "location")

        let resetAll = try #require(cli.simulatorAgentRequest(
            subcommand: "permissions",
            arguments: cli.parseSimulatorArguments(["reset", "all", "com.example.App"])
        ))
        #expect(resetAll.params["service"] as? String == "all")

        let list = try #require(cli.simulatorAgentRequest(
            subcommand: "permissions",
            arguments: cli.parseSimulatorArguments(["list", "com.example.App"])
        ))
        #expect(list.method == "simulator.permissions.read")
        #expect(list.output == .permissionsList)

        let catalog: [(String, String)] = [
            ("calendar", "calendar"), ("contacts-limited", "contacts-limited"),
            ("contacts", "contacts"), ("location", "location"),
            ("photos-add", "photos-add"), ("photos", "photos"),
            ("photos-limited", "photos-limited"), ("media-library", "media-library"),
            ("microphone", "microphone"), ("motion", "motion"),
            ("reminders", "reminders"), ("siri", "siri"), ("camera", "camera"),
            ("notifications", "notifications"), ("notifications-critical", "notifications-critical"),
            ("speech", "speech"), ("faceid", "faceid"),
            ("user-tracking", "user-tracking"), ("homekit", "homekit"),
            ("push", "notifications"), ("notification", "notifications"),
            ("photo-library", "photos"), ("photo", "photos"),
            ("location-always", "location-always"),
            ("location-in-use", "location-inuse"), ("location-inuse", "location-inuse"),
            ("mic", "microphone"), ("critical-notifications", "notifications-critical"),
            ("face-id", "faceid"), ("home-kit", "homekit"),
        ]
        for (permission, service) in catalog {
            let normalized = try cli.normalizeSimulatorPermission(
                action: "grant",
                permission: permission,
                value: nil
            )
            #expect(normalized.action == "grant", "\(permission)")
            #expect(normalized.service == service, "\(permission)")
        }

        let aliasOverride = try cli.normalizeSimulatorPermission(
            action: "grant",
            permission: "location-always",
            value: "never"
        )
        #expect(aliasOverride.action == "revoke")
        #expect(aliasOverride.service == "location")

        #expect(throws: CLIError.self) {
            _ = try cli.simulatorPermissionsRequest(
                cli.parseSimulatorArguments(["grant", "camera", "bad id"])
            )
        }
        #expect(throws: CLIError.self) {
            _ = try cli.simulatorPermissionsRequest(
                cli.parseSimulatorArguments([
                    "grant", "microphone", "com.example.App", "limited",
                ])
            )
        }
    }

    @Test("Simulator interface CLI accepts aliases, explicit verbs, and relative text size")
    func interfaceCLIParsing() throws {
        let cli = CMUXCLI(args: [])

        let status = try #require(cli.simulatorAgentRequest(
            subcommand: "ui",
            arguments: cli.parseSimulatorArguments(["status"])
        ))
        #expect(status.method == "simulator.ui.status")
        #expect(status.output == .interfaceStatus)

        let get = try #require(cli.simulatorAgentRequest(
            subcommand: "ui",
            arguments: cli.parseSimulatorArguments(["get", "button-shapes"])
        ))
        #expect(get.method == "simulator.ui.status")
        #expect(get.output == .interfaceValue(option: "show-borders"))

        let color = try #require(cli.simulatorAgentRequest(
            subcommand: "ui",
            arguments: cli.parseSimulatorArguments(["color-filter", "protanopia"])
        ))
        #expect(color.params["option"] as? String == "color-filter")
        #expect(color.params["value"] as? String == "red-green")

        let toggle = try #require(cli.simulatorAgentRequest(
            subcommand: "ui",
            arguments: cli.parseSimulatorArguments(["set", "voice-over", "enabled"])
        ))
        #expect(toggle.params["option"] as? String == "voiceover")
        #expect(toggle.params["value"] as? String == "on")

        let increment = try #require(cli.simulatorAgentRequest(
            subcommand: "ui",
            arguments: cli.parseSimulatorArguments(["text-size", "increment"])
        ))
        #expect(increment.params["value"] as? String == "increment")

        for textSize in [
            "extra-small", "small", "medium", "large", "extra-large",
            "extra-extra-large", "extra-extra-extra-large", "accessibility-medium",
            "accessibility-large", "accessibility-extra-large",
            "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large",
            "increment", "decrement",
        ] {
            #expect(
                try cli.normalizeSimulatorInterfaceValue(textSize, option: "text-size")
                    == textSize
            )
        }

        #expect(throws: CLIError.self) {
            _ = try cli.simulatorInterfaceRequest(
                cli.parseSimulatorArguments(["appearance", "purple"])
            )
        }
    }

    @Test("Simulator accessibility CLI routes bounded correlated reads")
    func accessibilityCLIParsing() throws {
        let cli = CMUXCLI(args: [])
        let accessibility = try #require(cli.simulatorAgentRequest(
            subcommand: "accessibility",
            arguments: cli.parseSimulatorArguments(["--surface", "surface:2"])
        ))
        #expect(accessibility.method == "simulator.accessibility")
        #expect(accessibility.output == .accessibility)

        let foreground = try #require(cli.simulatorAgentRequest(
            subcommand: "foreground",
            arguments: cli.parseSimulatorArguments(["--surface", "surface:2"])
        ))
        #expect(foreground.method == "simulator.foreground")
        #expect(foreground.output == .foregroundApplication)

        #expect(throws: CLIError.self) {
            _ = try cli.simulatorAgentRequest(
                subcommand: "accessibility",
                arguments: cli.parseSimulatorArguments(["unexpected"])
            )
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

private final class TestSimulatorResponder: NSView, SimulatorInputResponder {
    let simulatorOwnerID: ObjectIdentifier?
    init(owner: ObjectIdentifier) { simulatorOwnerID = owner; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
}
