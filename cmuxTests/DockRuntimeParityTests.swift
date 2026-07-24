import AppKit
import Bonsplit
import Combine
import CmuxControlSocket
import CmuxTerminal
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
        try #require(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
    }

    private func withAppContext(
        _ body: @MainActor (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowID = UUID()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
            appDelegate.registerMainWindow(
                window,
                windowId: windowID,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState()
            )
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                window.orderOut(nil)
                window.close()
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

            let workspaceDelivery = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: workspace.id,
                surfaceId: workspacePanel.id
            )
            #expect(workspaceDelivery?.tabId == workspace.id)
            #expect(workspaceDelivery?.surfaceId == workspacePanel.id)
            let globalDelivery = appDelegate.agentNotificationDeliveryTarget(
                claimedTabId: workspace.id,
                surfaceId: globalPanel.id
            )
            #expect(globalDelivery?.tabId == globalDock.workspaceId)
            #expect(globalDelivery?.surfaceId == globalPanel.id)

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

    @Test("Explicit socket flashes route as user initiated in both Dock scopes")
    func explicitSocketFlashesRouteAsUserInitiatedInBothDockScopes() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let workspaceDock = workspace.dockSplit
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspacePanel = DockRuntimeParityPanel(title: "Workspace Dock")
            let globalPanel = DockRuntimeParityPanel(title: "Global Dock")
            try workspaceDock.seedRuntimeParityPanel(workspacePanel)
            try globalDock.seedRuntimeParityPanel(globalPanel)

            let workspaceFlash = TerminalController.shared.controlSurfaceTriggerFlash(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: true,
                    windowID: windowID,
                    groupID: nil,
                    workspaceID: workspace.id,
                    surfaceID: workspacePanel.id,
                    paneID: nil
                ),
                surfaceID: workspacePanel.id
            )
            guard case .flashed(_, let workspaceID, let workspaceSurfaceID) = workspaceFlash else {
                Issue.record("Workspace Dock flash did not resolve: \(workspaceFlash)")
                return
            }
            #expect(workspaceID == workspace.id)
            #expect(workspaceSurfaceID == workspacePanel.id)

            let globalFlash = TerminalController.shared.controlSurfaceTriggerFlash(
                routing: ControlRoutingSelectors(
                    hasWindowIDParam: true,
                    windowID: windowID,
                    groupID: nil,
                    workspaceID: globalDock.workspaceId,
                    surfaceID: globalPanel.id,
                    paneID: nil
                ),
                surfaceID: globalPanel.id
            )
            guard case .flashed(_, let globalWorkspaceID, let globalSurfaceID) = globalFlash else {
                Issue.record("Global Dock flash did not resolve: \(globalFlash)")
                return
            }
            #expect(globalWorkspaceID == globalDock.workspaceId)
            #expect(globalSurfaceID == globalPanel.id)
            #expect(workspacePanel.flashReasons == [.userInitiated])
            #expect(globalPanel.flashReasons == [.userInitiated])
        }
    }

    @Test(
        "Dock surfaces are discoverable and workspace Dock terminals resolve by bare ID",
        .timeLimit(.minutes(1))
    )
    func topologyAndBareIDRoutingIncludeBothDockScopes() async throws {
        try await withAppContext { appDelegate, _, workspace, windowID in
            let workspaceDock = workspace.dockSplit
            let globalDock = appDelegate.windowDock(forWindowId: windowID)
            let workspaceTerminal = TerminalPanel(
                workspaceId: workspace.id,
                runtimeSpawnPolicy: .pacedSessionRestore
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
            #expect(workspacePaneRow["pixel_frame"] == nil)
            #expect(globalPaneRow["pixel_frame"] == nil)

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

            let tree = try socketResult(method: "system.tree", params: params)
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
            let treeSurfaces = treePanes.flatMap { $0["surfaces"] as? [[String: Any]] ?? [] }
            #expect(treeSurfaces.contains {
                $0["id"] as? String == workspaceTerminal.id.uuidString &&
                    $0["dock_scope"] as? String == "workspace"
            })
            #expect(treeSurfaces.contains {
                $0["id"] as? String == globalPanel.id.uuidString &&
                    $0["dock_scope"] as? String == "global"
            })

            let routing = ControlRoutingSelectors(
                hasWindowIDParam: false,
                windowID: nil,
                groupID: nil,
                workspaceID: nil,
                surfaceID: workspaceTerminal.id,
                paneID: nil
            )
            let send = TerminalController.shared.controlSurfaceSendText(
                routing: routing,
                surfaceID: workspaceTerminal.id,
                hasSurfaceIDParam: true,
                text: "dock input"
            )
            guard case .sent(_, _, let sentSurfaceID, _) = send else {
                Issue.record("Workspace Dock send did not resolve its terminal: \(send)")
                return
            }
            #expect(sentSurfaceID == workspaceTerminal.id)

            await waitForLiveSurface(workspaceTerminal.surface)
            try #require(workspaceTerminal.surface.hasLiveSurface)
            let readEnvelope = try await socketEnvelopeOnWorker(
                method: "surface.read_text",
                params: [
                    "surface_id": workspaceTerminal.id.uuidString,
                ]
            )
            try #require(readEnvelope["ok"] as? Bool == true, "\(readEnvelope)")
            let readResult = try #require(readEnvelope["result"] as? [String: Any])
            #expect(readResult["surface_id"] as? String == workspaceTerminal.id.uuidString)
        }
    }
}
