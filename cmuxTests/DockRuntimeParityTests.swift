import Bonsplit
import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class DockRuntimeParityPanel: Panel, ObservableObject {
    let id = UUID()
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle: String
    let displayIcon: String? = "terminal.fill"
    var isDirty = false

    private(set) var flashReasons: [WorkspaceAttentionFlashReason] = []

    init(title: String) {
        displayTitle = title
    }

    func close() {}
    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        flashReasons.append(reason)
    }
}

@MainActor
private extension DockSplitStore {
    @discardableResult
    func seedRuntimeParityPanel(_ panel: any Panel) throws -> PaneID {
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabID = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        surfaceIdToPanelId[tabID] = panel.id
        return pane
    }
}

@MainActor
@Suite("Dock runtime parity", .serialized)
struct DockRuntimeParityTests {
    private static let socketWorker = DispatchQueue(label: "DockRuntimeParityTests.socketWorker")

    private func socketEnvelope(
        method: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(line)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func socketEnvelopeOnWorker(
        method: String,
        params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorker.async {
                continuation.resume(returning: controller.handleSocketLine(line))
            }
        }
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func socketResult(
        method: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let envelope = try socketEnvelope(method: method, params: params)
        #expect(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func withAppContext(
        _ body: (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(appDelegate, manager, workspace, windowID)
        }
    }

    @Test("Notification attention routes to both Dock scopes")
    func notificationAttentionRoutesToBothDockScopes() async throws {
        try await withAppContext { appDelegate, manager, workspace, windowID in
            let workspaceDock = workspace.dockSplit
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspacePanel = DockRuntimeParityPanel(title: "Workspace Dock")
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            try workspaceDock.seedRuntimeParityPanel(workspacePanel)
            try globalDock.seedRuntimeParityPanel(globalPanel)

            workspace.triggerNotificationFocusFlash(
                panelId: workspacePanel.id,
                requiresSplit: false,
                shouldFocus: false
            )
            workspace.triggerNotificationFocusFlash(
                panelId: globalPanel.id,
                requiresSplit: false,
                shouldFocus: false
            )
            manager.workspaceTriggerNotificationDismissFlash(
                workspaceId: workspace.id,
                panelId: workspacePanel.id
            )
            manager.workspaceTriggerNotificationDismissFlash(
                workspaceId: globalDock.workspaceId,
                panelId: globalPanel.id
            )
            manager.workspaceTriggerUnreadIndicatorDismissFlash(
                workspaceId: workspace.id,
                panelId: workspacePanel.id
            )
            manager.workspaceTriggerUnreadIndicatorDismissFlash(
                workspaceId: globalDock.workspaceId,
                panelId: globalPanel.id
            )

            let expected: [WorkspaceAttentionFlashReason] = [
                .notificationArrival,
                .notificationDismiss,
                .unreadIndicatorDismiss,
            ]
            #expect(workspacePanel.flashReasons == expected)
            #expect(globalPanel.flashReasons == expected)
        }
    }

    @Test("Dock surfaces are discoverable and workspace Dock terminals resolve by bare ID")
    func topologyAndBareIDRoutingIncludeBothDockScopes() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let workspaceDock = workspace.dockSplit
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspaceTerminal = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .deferredUntilVisible
            )
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            let workspacePane = try workspaceDock.seedRuntimeParityPanel(workspaceTerminal)
            let globalPane = try globalDock.seedRuntimeParityPanel(globalPanel)
            let params = ["workspace_id": workspace.id.uuidString]

            let surfaceList = try socketResult(method: "surface.list", params: params)
            let surfaces = try #require(surfaceList["surfaces"] as? [[String: Any]])
            let workspaceSurface = try #require(surfaces.first {
                $0["id"] as? String == workspaceTerminal.id.uuidString
            })
            let globalSurface = try #require(surfaces.first {
                $0["id"] as? String == globalPanel.id.uuidString
            })
            #expect(workspaceSurface["dock_scope"] as? String == "workspace")
            #expect(globalSurface["dock_scope"] as? String == "global")

            let paneList = try socketResult(method: "pane.list", params: params)
            let panes = try #require(paneList["panes"] as? [[String: Any]])
            let workspacePaneRow = try #require(panes.first {
                $0["id"] as? String == workspacePane.id.uuidString
            })
            let globalPaneRow = try #require(panes.first {
                $0["id"] as? String == globalPane.id.uuidString
            })
            #expect(workspacePaneRow["dock_scope"] as? String == "workspace")
            #expect(globalPaneRow["dock_scope"] as? String == "global")

            for (paneID, surfaceID, scope) in [
                (workspacePane.id, workspaceTerminal.id, "workspace"),
                (globalPane.id, globalPanel.id, "global"),
            ] {
                let result = try socketResult(
                    method: "pane.surfaces",
                    params: ["pane_id": paneID.uuidString]
                )
                #expect(result["dock_scope"] as? String == scope)
                let paneSurfaces = try #require(result["surfaces"] as? [[String: Any]])
                #expect(paneSurfaces.contains { $0["id"] as? String == surfaceID.uuidString })
            }

            let tree = try socketResult(method: "system.tree")
            let windows = try #require(tree["windows"] as? [[String: Any]])
            let treeWorkspaces = windows.flatMap { $0["workspaces"] as? [[String: Any]] ?? [] }
            let treePanes = treeWorkspaces.flatMap { $0["panes"] as? [[String: Any]] ?? [] }
            #expect(treePanes.contains {
                $0["id"] as? String == workspacePane.id.uuidString &&
                    $0["dock_scope"] as? String == "workspace"
            })
            #expect(treePanes.contains {
                $0["id"] as? String == globalPane.id.uuidString &&
                    $0["dock_scope"] as? String == "global"
            })

            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: workspace.id,
                surfaceID: workspaceTerminal.id,
                paneID: nil
            )
            let send = TerminalController.shared.controlSurfaceSendText(
                routing: routing,
                surfaceID: workspaceTerminal.id,
                hasSurfaceIDParam: true,
                text: "dock input"
            )
            switch send {
            case .sent(_, _, let surfaceID, _),
                 .surfaceUnavailable(let surfaceID),
                 .processExited(let surfaceID),
                 .inputQueueFull(let surfaceID):
                #expect(surfaceID == workspaceTerminal.id)
            default:
                Issue.record("Workspace Dock send did not resolve its terminal: \(send)")
            }

            let readEnvelope = try await socketEnvelopeOnWorker(
                method: "surface.read_text",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": workspaceTerminal.id.uuidString,
                ]
            )
            if readEnvelope["ok"] as? Bool != true {
                let error = try #require(readEnvelope["error"] as? [String: Any])
                #expect(error["message"] as? String != "Surface is not a terminal")
            }
        }
    }
}
