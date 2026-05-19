import XCTest
import CMUXWorkstream

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class EventScopeWorkspaceIds: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>

    init(_ ids: Set<String>) {
        self.ids = ids
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func update(_ ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        self.ids = ids
    }
}

final class CmuxEventBusTests: XCTestCase {
    func testSubscribeReplaysEventsAfterSequenceAndReportsAck() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        bus.publish(
            name: "workspace.created",
            category: "workspace",
            source: "test",
            workspaceId: "w1",
            payload: ["value": "one"]
        )
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "w1",
            payload: ["title": "Done"]
        )

        let snapshot = bus.subscribe(afterSequence: 1, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.count, 1)
        XCTAssertEqual(snapshot.replay.first?["name"] as? String, "notification.created")
        XCTAssertEqual(snapshot.ack["type"] as? String, "ack")
        XCTAssertEqual(snapshot.ack["replay_count"] as? Int, 1)

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual((resume["latest_seq"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(resume["gap"] as? Bool, false)
    }

    func testSubscribeReportsGapWhenCursorFallsOutOfRetention() throws {
        let bus = CmuxEventBus(retainedEventLimit: 2)
        bus.publish(name: "a", category: "test", source: "test")
        bus.publish(name: "b", category: "test", source: "test")
        bus.publish(name: "c", category: "test", source: "test")

        let snapshot = bus.subscribe(afterSequence: 0, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual(resume["gap"] as? Bool, true)
        XCTAssertEqual(snapshot.replay.compactMap { $0["name"] as? String }, ["b", "c"])
    }

    func testSubscribeReportsGapWhenCursorIsNewerThanProcess() throws {
        let bus = CmuxEventBus(retainedEventLimit: 2)
        let snapshot = bus.subscribe(afterSequence: 42, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        let resume = try XCTUnwrap(snapshot.ack["resume"] as? [String: Any])
        XCTAssertEqual(resume["gap"] as? Bool, true)
        XCTAssertEqual((resume["latest_seq"] as? NSNumber)?.int64Value, 0)
        XCTAssertNotNil(snapshot.ack["boot_id"] as? String)
    }

    func testSubscriptionFiltersLiveEventsByCategory() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: ["notification"])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "notification.created", category: "notification", source: "test")

        let event = snapshot.subscription.next(timeout: 0.2)
        XCTAssertEqual(event?["name"] as? String, "notification.created")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testSubscriptionFiltersReplayAndLiveEventsByWindowScope() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        bus.publish(
            name: "workspace.created",
            category: "workspace",
            source: "test",
            workspaceId: "workspace-a",
            windowId: "window-a"
        )
        bus.publish(
            name: "workspace.created",
            category: "workspace",
            source: "test",
            workspaceId: "workspace-b",
            windowId: "window-b"
        )

        let snapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .window, windowId: "window-a")
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.compactMap { $0["workspace_id"] as? String }, ["workspace-a"])
        let filters = try XCTUnwrap(snapshot.ack["filters"] as? [String: Any])
        let scope = try XCTUnwrap(filters["scope"] as? [String: Any])
        XCTAssertEqual(scope["kind"] as? String, "window")
        XCTAssertEqual(scope["window_id"] as? String, "window-a")

        bus.publish(
            name: "surface.created",
            category: "surface",
            source: "test",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            windowId: "window-a"
        )
        bus.publish(
            name: "surface.created",
            category: "surface",
            source: "test",
            workspaceId: "workspace-b",
            surfaceId: "surface-b",
            windowId: "window-b"
        )

        let event = snapshot.subscription.next(timeout: 0.2)
        XCTAssertEqual(event?["surface_id"] as? String, "surface-a")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testWindowScopeCanFallbackToKnownWorkspaceIds() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "workspace-a"
        )
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "workspace-b"
        )

        let snapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: "window-a",
                windowWorkspaceIds: ["workspace-a"]
            )
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.compactMap { $0["workspace_id"] as? String }, ["workspace-a"])
    }

    func testWindowScopeUsesDynamicWorkspaceMembershipForLiveWorkspaceOnlyEvents() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let workspaceIds = EventScopeWorkspaceIds(["workspace-a"])
        let snapshot = bus.subscribe(
            afterSequence: nil,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: "window-a",
                windowWorkspaceIds: ["workspace-a"],
                currentWindowWorkspaceIdsProvider: { workspaceIds.snapshot() }
            )
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "workspace-a"
        )
        workspaceIds.update(["workspace-c"])
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "workspace-a"
        )
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "workspace-c"
        )

        XCTAssertEqual(snapshot.subscription.next(timeout: 0.2)?["workspace_id"] as? String, "workspace-a")
        XCTAssertEqual(snapshot.subscription.next(timeout: 0.2)?["workspace_id"] as? String, "workspace-c")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testWindowScopeDoesNotUseWorkspaceFallbackForExplicitMismatchedWindow() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        bus.publish(
            name: "notification.created",
            category: "notification",
            source: "test",
            workspaceId: "workspace-a",
            windowId: "window-b"
        )

        let snapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: "window-a",
                windowWorkspaceIds: ["workspace-a"]
            )
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.compactMap { $0["name"] as? String }, [])
    }

    func testWindowScopeUsesWorkspaceFallbackForWindowRefPayload() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let windowId = UUID()
        let workspaceId = UUID()
        bus.publish(
            name: "browser.action",
            category: "browser",
            source: "socket.v2",
            workspaceId: workspaceId.uuidString,
            payload: [
                "method": "browser.click",
                "params": [
                    "window_id": "window:1",
                    "workspace_id": workspaceId.uuidString
                ],
                "result": [
                    "surface_id": UUID().uuidString
                ]
            ]
        )

        let snapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: windowId.uuidString,
                windowWorkspaceIds: [workspaceId.uuidString]
            )
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.compactMap { $0["name"] as? String }, ["browser.action"])
    }

    func testWindowScopeMatchesSourceWindowPayloadWhenWorkspaceLeavesWindow() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let workspaceIds = EventScopeWorkspaceIds(["workspace-c"])
        let snapshot = bus.subscribe(
            afterSequence: nil,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: "window-a",
                windowWorkspaceIds: ["workspace-a"],
                currentWindowWorkspaceIdsProvider: { workspaceIds.snapshot() }
            )
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(
            name: "workspace.moved",
            category: "workspace",
            source: "socket.v2",
            workspaceId: "workspace-b",
            windowId: "window-b",
            payload: [
                "method": "workspace.move_to_window",
                "result": [
                    "source_window_id": "window-a",
                    "source_workspace_id": "workspace-a",
                    "window_id": "window-b",
                    "workspace_id": "workspace-b"
                ]
            ]
        )

        XCTAssertEqual(snapshot.subscription.next(timeout: 0.2)?["name"] as? String, "workspace.moved")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testWindowScopeMatchesSourceWindowPayloadWhenSurfaceLeavesWindow() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let workspaceIds = EventScopeWorkspaceIds(["workspace-c"])
        let snapshot = bus.subscribe(
            afterSequence: nil,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: "window-a",
                windowWorkspaceIds: ["workspace-a"],
                currentWindowWorkspaceIdsProvider: { workspaceIds.snapshot() }
            )
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(
            name: "surface.moved",
            category: "surface",
            source: "socket.v2",
            workspaceId: "workspace-b",
            surfaceId: "surface-a",
            paneId: "pane-b",
            windowId: "window-b",
            payload: [
                "method": "surface.move",
                "result": [
                    "source_window_id": "window-a",
                    "source_workspace_id": "workspace-a",
                    "source_pane_id": "pane-a",
                    "window_id": "window-b",
                    "workspace_id": "workspace-b",
                    "pane_id": "pane-b",
                    "surface_id": "surface-a"
                ]
            ]
        )

        XCTAssertEqual(snapshot.subscription.next(timeout: 0.2)?["name"] as? String, "surface.moved")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testWindowScopeReplayUsesEventTimeWindowForWorkspaceOnlyEvents() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let sourceWindowId = UUID().uuidString
        let destinationWindowId = UUID().uuidString
        let workspaceId = UUID().uuidString

        CmuxEventWindowWorkspaceIndex.shared.replace(
            windowId: sourceWindowId,
            workspaceIds: [workspaceId]
        )
        bus.publish(
            name: "feed.item.received",
            category: "feed",
            source: "socket-worker",
            workspaceId: workspaceId,
            payload: ["workspace_id": workspaceId]
        )
        CmuxEventWindowWorkspaceIndex.shared.replace(windowId: sourceWindowId, workspaceIds: [])
        CmuxEventWindowWorkspaceIndex.shared.replace(
            windowId: destinationWindowId,
            workspaceIds: [workspaceId]
        )

        let sourceReplay = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .window, windowId: sourceWindowId)
        )
        defer { bus.unsubscribe(sourceReplay.subscription) }
        XCTAssertEqual(sourceReplay.replay.compactMap { $0["name"] as? String }, ["feed.item.received"])
        XCTAssertEqual(sourceReplay.replay.first?["window_id"] as? String, sourceWindowId)

        let destinationReplay = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(
                kind: .window,
                windowId: destinationWindowId,
                windowWorkspaceIds: [workspaceId]
            )
        )
        defer { bus.unsubscribe(destinationReplay.subscription) }
        XCTAssertTrue(destinationReplay.replay.isEmpty)
    }

    func testSurfaceOnlyEventsUseIndexedOwnershipForBroaderScopes() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let windowId = UUID().uuidString
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let surfaceId = UUID().uuidString
        CmuxEventWindowWorkspaceIndex.shared.replace(windowId: windowId, workspaceIds: [workspaceId])
        CmuxEventWindowWorkspaceIndex.shared.rememberSurface(
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            windowId: windowId,
            paneId: paneId
        )

        bus.publish(
            name: "notification.requested",
            category: "notification",
            source: "socket.v1",
            surfaceId: surfaceId,
            payload: ["surface_id": surfaceId]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().last)
        XCTAssertEqual(event["window_id"] as? String, windowId)
        XCTAssertEqual(event["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(event["pane_id"] as? String, paneId)

        let workspaceReplay = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .workspace, workspaceId: workspaceId)
        )
        defer { bus.unsubscribe(workspaceReplay.subscription) }
        XCTAssertEqual(workspaceReplay.replay.compactMap { $0["name"] as? String }, ["notification.requested"])

        let windowReplay = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .window, windowId: windowId)
        )
        defer { bus.unsubscribe(windowReplay.subscription) }
        XCTAssertEqual(windowReplay.replay.compactMap { $0["name"] as? String }, ["notification.requested"])
    }

    @MainActor
    func testEventScopeResolverPrefersExplicitWorkspaceOverCallerSurface() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let callerWindowId = UUID()
        let targetWindowId = UUID()
        let callerManager = TabManager()
        let targetManager = TabManager()
        app.registerMainWindowContextForTesting(windowId: callerWindowId, tabManager: callerManager)
        app.registerMainWindowContextForTesting(windowId: targetWindowId, tabManager: targetManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: callerWindowId)
            app.unregisterMainWindowContextForTesting(windowId: targetWindowId)
        }

        let callerWorkspace = try XCTUnwrap(callerManager.selectedWorkspace)
        let callerSurfaceId = try XCTUnwrap(callerWorkspace.focusedPanelId)
        let callerPaneId = try XCTUnwrap(callerWorkspace.paneId(forPanelId: callerSurfaceId)?.id)
        let targetWorkspace = try XCTUnwrap(targetManager.selectedWorkspace)
        let targetSurfaceId = try XCTUnwrap(targetWorkspace.focusedPanelId)

        let scope = try TerminalController.shared.resolveEventsScopeForTesting(params: [
            "scope": "surface",
            "workspace_id": targetWorkspace.id.uuidString,
            "caller": [
                "workspace_id": callerWorkspace.id.uuidString,
                "surface_id": callerSurfaceId.uuidString,
                "pane_id": callerPaneId.uuidString
            ]
        ])

        XCTAssertEqual(scope.kind, .surface)
        XCTAssertEqual(scope.surfaceId, targetSurfaceId.uuidString)
    }

    @MainActor
    func testEventScopeResolverPrefersExplicitPaneOverCallerSurface() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let callerWindowId = UUID()
        let targetWindowId = UUID()
        let callerManager = TabManager()
        let targetManager = TabManager()
        app.registerMainWindowContextForTesting(windowId: callerWindowId, tabManager: callerManager)
        app.registerMainWindowContextForTesting(windowId: targetWindowId, tabManager: targetManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: callerWindowId)
            app.unregisterMainWindowContextForTesting(windowId: targetWindowId)
        }

        let callerWorkspace = try XCTUnwrap(callerManager.selectedWorkspace)
        let callerSurfaceId = try XCTUnwrap(callerWorkspace.focusedPanelId)
        let callerPaneId = try XCTUnwrap(callerWorkspace.paneId(forPanelId: callerSurfaceId)?.id)
        let targetWorkspace = try XCTUnwrap(targetManager.selectedWorkspace)
        let targetPaneId = try XCTUnwrap(targetWorkspace.bonsplitController.allPaneIds.first?.id)

        let scope = try TerminalController.shared.resolveEventsScopeForTesting(params: [
            "scope": "window",
            "pane_id": targetPaneId.uuidString,
            "caller": [
                "workspace_id": callerWorkspace.id.uuidString,
                "surface_id": callerSurfaceId.uuidString,
                "pane_id": callerPaneId.uuidString
            ]
        ])

        XCTAssertEqual(scope.kind, .window)
        XCTAssertEqual(scope.windowId, targetWindowId.uuidString)
    }

    @MainActor
    func testEventScopeResolverUsesMovedCallerSurfaceBeforeStaleCallerContext() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let sourceWindowId = UUID()
        let targetWindowId = UUID()
        let sourceManager = TabManager()
        let targetManager = TabManager()
        app.registerMainWindowContextForTesting(windowId: sourceWindowId, tabManager: sourceManager)
        app.registerMainWindowContextForTesting(windowId: targetWindowId, tabManager: targetManager)
        defer {
            app.unregisterMainWindowContextForTesting(windowId: sourceWindowId)
            app.unregisterMainWindowContextForTesting(windowId: targetWindowId)
        }

        let sourceWorkspace = try XCTUnwrap(sourceManager.selectedWorkspace)
        let sourcePaneId = try XCTUnwrap(sourceWorkspace.bonsplitController.allPaneIds.first)
        let remainingSurfaceId = try XCTUnwrap(sourceWorkspace.focusedPanelId)
        let movedSurface = try XCTUnwrap(sourceWorkspace.newTerminalSurface(inPane: sourcePaneId, focus: false))
        let staleCallerPaneId = try XCTUnwrap(sourceWorkspace.paneId(forPanelId: movedSurface.id)?.id)
        let targetWorkspace = try XCTUnwrap(targetManager.selectedWorkspace)

        XCTAssertTrue(app.moveSurface(
            panelId: movedSurface.id,
            toWorkspace: targetWorkspace.id,
            focus: false,
            focusWindow: false
        ))
        XCTAssertNotNil(sourceWorkspace.panels[remainingSurfaceId])
        XCTAssertNil(sourceWorkspace.panels[movedSurface.id])
        XCTAssertNotNil(targetWorkspace.panels[movedSurface.id])

        let caller: [String: Any] = [
            "workspace_id": sourceWorkspace.id.uuidString,
            "surface_id": movedSurface.id.uuidString,
            "pane_id": staleCallerPaneId.uuidString
        ]

        let windowScope = try TerminalController.shared.resolveEventsScopeForTesting(params: [
            "scope": "window",
            "caller": caller
        ])
        XCTAssertEqual(windowScope.kind, .window)
        XCTAssertEqual(windowScope.windowId, targetWindowId.uuidString)

        let workspaceScope = try TerminalController.shared.resolveEventsScopeForTesting(params: [
            "scope": "workspace",
            "caller": caller
        ])
        XCTAssertEqual(workspaceScope.kind, .workspace)
        XCTAssertEqual(workspaceScope.workspaceId, targetWorkspace.id.uuidString)

        let currentPaneId = try XCTUnwrap(targetWorkspace.paneId(forPanelId: movedSurface.id)?.id)
        let paneScope = try TerminalController.shared.resolveEventsScopeForTesting(params: [
            "scope": "pane",
            "caller": caller
        ])
        XCTAssertEqual(paneScope.kind, .pane)
        XCTAssertEqual(paneScope.paneId, currentPaneId.uuidString)
    }

    func testSubscriptionFiltersByWorkspaceSurfaceAndPaneScopes() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        bus.publish(
            name: "pane.focused",
            category: "pane",
            source: "test",
            workspaceId: "workspace-a",
            surfaceId: "surface-a",
            paneId: "pane-a"
        )
        bus.publish(
            name: "pane.focused",
            category: "pane",
            source: "test",
            workspaceId: "workspace-b",
            surfaceId: "surface-b",
            paneId: "pane-b"
        )

        let workspaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .workspace, workspaceId: "workspace-a")
        )
        defer { bus.unsubscribe(workspaceSnapshot.subscription) }
        XCTAssertEqual(workspaceSnapshot.replay.compactMap { $0["workspace_id"] as? String }, ["workspace-a"])

        let surfaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: "surface-a")
        )
        defer { bus.unsubscribe(surfaceSnapshot.subscription) }
        XCTAssertEqual(surfaceSnapshot.replay.compactMap { $0["surface_id"] as? String }, ["surface-a"])

        let paneSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .pane, paneId: "pane-a")
        )
        defer { bus.unsubscribe(paneSnapshot.subscription) }
        XCTAssertEqual(paneSnapshot.replay.compactMap { $0["pane_id"] as? String }, ["pane-a"])
    }

    func testScopeFiltersCanonicalizeUUIDCase() {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let surfaceId = UUID()
        bus.publish(
            name: "surface.key_sent",
            category: "surface",
            source: "socket.v1",
            surfaceId: surfaceId.uuidString.lowercased(),
            payload: [
                "surface_id": surfaceId.uuidString.lowercased()
            ]
        )

        let snapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: surfaceId.uuidString)
        )
        defer { bus.unsubscribe(snapshot.subscription) }

        XCTAssertEqual(snapshot.replay.compactMap { $0["name"] as? String }, ["surface.key_sent"])
    }

    func testScopeFiltersMatchNestedV2PayloadIds() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        bus.publish(
            name: "pane.swapped",
            category: "pane",
            source: "socket.v2",
            payload: [
                "method": "pane.swap",
                "params": [
                    "pane_id": "pane-a"
                ],
                "result": [
                    "target_pane_id": "pane-b"
                ]
            ]
        )
        bus.publish(
            name: "surface.closed",
            category: "surface",
            source: "socket.v2",
            payload: [
                "method": "surface.close",
                "result": [
                    "closed_surface_ids": ["surface-b"]
                ]
            ]
        )
        bus.publish(
            name: "pane.swapped",
            category: "pane",
            source: "socket.v2",
            payload: [
                "method": "pane.swap",
                "result": [
                    "source_surface_id": "surface-a",
                    "target_surface_id": "surface-c"
                ]
            ]
        )
        bus.publish(
            name: "surface.action",
            category: "surface",
            source: "socket.v2",
            payload: [
                "method": "tab.action",
                "params": [
                    "tab_id": "surface-d"
                ],
                "result": [
                    "created_surface_id": "surface-e",
                    "created_tab_id": "surface-f"
                ]
            ]
        )

        let paneSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .pane, paneId: "pane-b")
        )
        defer { bus.unsubscribe(paneSnapshot.subscription) }
        XCTAssertEqual(paneSnapshot.replay.compactMap { $0["name"] as? String }, ["pane.swapped"])

        let surfaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: "surface-b")
        )
        defer { bus.unsubscribe(surfaceSnapshot.subscription) }
        XCTAssertEqual(surfaceSnapshot.replay.compactMap { $0["name"] as? String }, ["surface.closed"])

        let targetSurfaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: "surface-c")
        )
        defer { bus.unsubscribe(targetSurfaceSnapshot.subscription) }
        XCTAssertEqual(targetSurfaceSnapshot.replay.compactMap { $0["name"] as? String }, ["pane.swapped"])

        let tabAliasSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: "surface-d")
        )
        defer { bus.unsubscribe(tabAliasSnapshot.subscription) }
        XCTAssertEqual(tabAliasSnapshot.replay.compactMap { $0["name"] as? String }, ["surface.action"])

        let createdSurfaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: "surface-e")
        )
        defer { bus.unsubscribe(createdSurfaceSnapshot.subscription) }
        XCTAssertEqual(createdSurfaceSnapshot.replay.compactMap { $0["name"] as? String }, ["surface.action"])

        let createdTabSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .surface, surfaceId: "surface-f")
        )
        defer { bus.unsubscribe(createdTabSnapshot.subscription) }
        XCTAssertEqual(createdTabSnapshot.replay.compactMap { $0["name"] as? String }, ["surface.action"])
    }

    func testScopeFiltersMatchParamsAndResultIdsWithSameKey() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        bus.publish(
            name: "pane.joined",
            category: "pane",
            source: "socket.v2",
            payload: [
                "method": "pane.join",
                "params": [
                    "pane_id": "pane-source",
                    "workspace_id": "workspace-source"
                ],
                "result": [
                    "pane_id": "pane-destination",
                    "workspace_id": "workspace-destination"
                ]
            ]
        )

        let sourcePaneSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .pane, paneId: "pane-source")
        )
        defer { bus.unsubscribe(sourcePaneSnapshot.subscription) }
        XCTAssertEqual(sourcePaneSnapshot.replay.compactMap { $0["name"] as? String }, ["pane.joined"])

        let destinationPaneSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .pane, paneId: "pane-destination")
        )
        defer { bus.unsubscribe(destinationPaneSnapshot.subscription) }
        XCTAssertEqual(destinationPaneSnapshot.replay.compactMap { $0["name"] as? String }, ["pane.joined"])

        let sourceWorkspaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .workspace, workspaceId: "workspace-source")
        )
        defer { bus.unsubscribe(sourceWorkspaceSnapshot.subscription) }
        XCTAssertEqual(sourceWorkspaceSnapshot.replay.compactMap { $0["name"] as? String }, ["pane.joined"])

        let destinationWorkspaceSnapshot = bus.subscribe(
            afterSequence: 0,
            names: [],
            categories: [],
            scope: CmuxEventScope(kind: .workspace, workspaceId: "workspace-destination")
        )
        defer { bus.unsubscribe(destinationWorkspaceSnapshot.subscription) }
        XCTAssertEqual(destinationWorkspaceSnapshot.replay.compactMap { $0["name"] as? String }, ["pane.joined"])
    }

    func testSlowSubscriptionClosesWhenPendingQueueIsFull() {
        let bus = CmuxEventBus(retainedEventLimit: 8, maxPendingEventsPerSubscription: 2)
        let snapshot = bus.subscribe(afterSequence: nil, names: [], categories: [])
        defer { bus.unsubscribe(snapshot.subscription) }

        bus.publish(name: "one", category: "test", source: "test")
        bus.publish(name: "two", category: "test", source: "test")
        bus.publish(name: "three", category: "test", source: "test")

        XCTAssertTrue(snapshot.subscription.isClosed)
        XCTAssertEqual(snapshot.subscription.closeReason, "pending event buffer exceeded 2 events")
        XCTAssertNil(snapshot.subscription.next(timeout: 0.05))
    }

    func testEventEncodingIsSingleLineJSON() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        bus.publish(
            name: "surface.input_sent",
            category: "surface",
            source: "test",
            payload: ["text": "hello\nworld"]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        let line = try XCTUnwrap(CmuxEventBus.encodeLine(event))
        XCTAssertFalse(line.contains("\n"))

        let data = try XCTUnwrap(line.data(using: .utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "event")
        XCTAssertNotNil(parsed["boot_id"] as? String)
    }

    func testEncodingPreservesZeroAndOneNumbers() throws {
        let line = try XCTUnwrap(CmuxEventBus.encodeLine([
            "zero": NSNumber(value: Int64(0)),
            "one": NSNumber(value: Int64(1)),
            "truth": true
        ]))

        XCTAssertTrue(line.contains("\"zero\":0"))
        XCTAssertTrue(line.contains("\"one\":1"))
        XCTAssertTrue(line.contains("\"truth\":true"))
    }

    func testStrictSequenceParsingRejectsBooleanAndFloatFrames() throws {
        XCTAssertEqual(CmuxEventBus.int64(NSNumber(value: Int64(42))), 42)
        XCTAssertEqual(CmuxEventBus.int64("42"), 42)
        XCTAssertNil(CmuxEventBus.int64(true))
        XCTAssertNil(CmuxEventBus.int64(NSNumber(value: 1.5)))
    }

    func testOversizedEventPayloadIsTruncatedBeforeRetention() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4, maxEventLineBytes: 1_024)

        bus.publish(
            name: "agent.log",
            category: "agent",
            source: "test",
            payload: ["message": String(repeating: "x", count: 20_000)]
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        XCTAssertEqual(event["payload_truncated"] as? Bool, true)

        let line = try XCTUnwrap(CmuxEventBus.encodeLine(event))
        XCTAssertLessThanOrEqual(line.utf8.count, 1_024)
    }

    func testWindowLifecyclePayloadIncludesFocusState() throws {
        let bus = CmuxEventBus(retainedEventLimit: 4)
        let windowId = UUID()
        let workspaceId = UUID()

        bus.publishWindowLifecycle(
            name: "window.keyed",
            windowId: windowId,
            workspaceId: workspaceId,
            workspaceCount: 2,
            selectedWorkspaceIndex: 1,
            isKeyWindow: true,
            isMainWindow: true,
            origin: "unit"
        )

        let event = try XCTUnwrap(bus.retainedSnapshot().first)
        XCTAssertEqual(event["name"] as? String, "window.keyed")
        XCTAssertEqual(event["source"] as? String, "window.lifecycle")
        XCTAssertEqual(event["window_id"] as? String, windowId.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["workspace_id"] as? String, workspaceId.uuidString)
        XCTAssertEqual((payload["workspace_count"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(payload["is_key_window"] as? Bool, true)
        XCTAssertEqual(payload["is_main_window"] as? Bool, true)
    }

    func testNotificationReplacementPublishesRemovedThenCreatedWithReplacedIds() throws {
        let bus = CmuxEventBus(retainedEventLimit: 8)
        let workspaceId = UUID()
        let surfaceId = UUID()
        let oldNotification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Old",
            subtitle: "",
            body: "Done",
            createdAt: Date(),
            isRead: false
        )
        let newNotification = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "New",
            subtitle: "",
            body: "Done",
            createdAt: Date(),
            isRead: false
        )

        bus.publishNotificationChanges(oldValue: [oldNotification], newValue: [newNotification])

        let events = bus.retainedSnapshot()
        XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["notification.removed", "notification.created"])
        let removedPayload = try XCTUnwrap(events.first?["payload"] as? [String: Any])
        XCTAssertTrue(removedPayload["title"] is NSNull)
        XCTAssertTrue(removedPayload["subtitle"] is NSNull)
        XCTAssertTrue(removedPayload["body"] is NSNull)
        XCTAssertEqual(removedPayload["title_length"] as? Int, 3)
        XCTAssertEqual(removedPayload["body_length"] as? Int, 4)
        XCTAssertEqual(removedPayload["redacted_fields"] as? [String], ["title", "subtitle", "body"])
        let createdPayload = try XCTUnwrap(events.last?["payload"] as? [String: Any])
        XCTAssertTrue(createdPayload["title"] is NSNull)
        XCTAssertTrue(createdPayload["subtitle"] is NSNull)
        XCTAssertTrue(createdPayload["body"] is NSNull)
        XCTAssertEqual(createdPayload["title_length"] as? Int, 3)
        XCTAssertEqual(createdPayload["body_length"] as? Int, 4)
        XCTAssertEqual(createdPayload["redacted_fields"] as? [String], ["title", "subtitle", "body"])
        let replacedIds = try XCTUnwrap(createdPayload["replaced_notification_ids"] as? [String])
        XCTAssertEqual(replacedIds, [oldNotification.id.uuidString])
    }

    @MainActor
    func testBulkNotificationClearPublishesClearedWithoutRemovedDuplicates() throws {
        let store = TerminalNotificationStore.shared
        let workspaceId = UUID()
        let notifications = [
            TerminalNotification(
                id: UUID(),
                tabId: workspaceId,
                surfaceId: nil,
                title: "First",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            ),
            TerminalNotification(
                id: UUID(),
                tabId: workspaceId,
                surfaceId: nil,
                title: "Second",
                subtitle: "",
                body: "",
                createdAt: Date(),
                isRead: false
            )
        ]
        defer {
            store.replaceNotificationsForTesting([])
            CmuxEventBus.shared.resetForTesting()
        }

        store.replaceNotificationsForTesting(notifications)
        CmuxEventBus.shared.resetForTesting()

        store.clearNotifications(forTabId: workspaceId, discardQueuedNotifications: false)

        let events = CmuxEventBus.shared.retainedSnapshot()
        XCTAssertEqual(events.compactMap { $0["name"] as? String }, ["notification.cleared"])
        let payload = try XCTUnwrap(events.first?["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload["notification_ids"] as? [String] ?? []), Set(notifications.map { $0.id.uuidString }))
        XCTAssertEqual(payload["count"] as? Int, 2)
    }

    func testNotificationSocketParamsRedactTextFields() throws {
        let redacted = CmuxSocketEventMapper.redactedNotificationParams([
            "title": "Secret title",
            "subtitle": "Private subtitle",
            "body": "Sensitive body",
            "redacted_fields": ["existing"],
            "workspace_id": "workspace"
        ])

        XCTAssertTrue(redacted["title"] is NSNull)
        XCTAssertTrue(redacted["subtitle"] is NSNull)
        XCTAssertTrue(redacted["body"] is NSNull)
        XCTAssertEqual(redacted["title_length"] as? Int, 12)
        XCTAssertEqual(redacted["subtitle_length"] as? Int, 16)
        XCTAssertEqual(redacted["body_length"] as? Int, 14)
        XCTAssertEqual(redacted["redacted_fields"] as? [String], ["existing", "title", "subtitle", "body"])
        XCTAssertEqual(redacted["workspace_id"] as? String, "workspace")
    }

    func testV1NotifySurfacePublishesSurfaceIdWithoutWorkspaceId() throws {
        let surfaceId = UUID()
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: "notify_surface \(surfaceId.uuidString) done", response: "OK")

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "notification.requested")
        XCTAssertTrue(event["workspace_id"] is NSNull)
        XCTAssertEqual(event["surface_id"] as? String, surfaceId.uuidString)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["surface_id"] as? String, surfaceId.uuidString)
    }

    func testV1SendSurfacePublishesExplicitSurfaceId() throws {
        let windowId = UUID().uuidString
        let workspaceId = UUID().uuidString
        let paneId = UUID().uuidString
        let surfaceId = UUID().uuidString
        CmuxEventWindowWorkspaceIndex.shared.replace(windowId: windowId, workspaceIds: [workspaceId])
        CmuxEventWindowWorkspaceIndex.shared.rememberSurface(
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            windowId: windowId,
            paneId: paneId
        )
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: "send_surface \(surfaceId) secret", response: "OK")

        let event = try XCTUnwrap(CmuxEventBus.shared.retainedSnapshot().last)
        XCTAssertEqual(event["name"] as? String, "surface.input_sent")
        XCTAssertEqual(event["window_id"] as? String, windowId)
        XCTAssertEqual(event["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(event["surface_id"] as? String, surfaceId)
        XCTAssertEqual(event["pane_id"] as? String, paneId)
        let payload = try XCTUnwrap(event["payload"] as? [String: Any])
        XCTAssertEqual(payload["surface_id"] as? String, surfaceId)
        XCTAssertEqual(payload["args"] as? String, "<redacted>")
    }

    func testV1MapperIgnoresNonSuccessResponses() throws {
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }

        CmuxSocketEventMapper.publish(command: "notify title", response: "OKAY")
        CmuxSocketEventMapper.publish(command: "notify title", response: "queued")
        CmuxSocketEventMapper.publish(command: "notify title", response: "ERROR: failed")

        XCTAssertTrue(CmuxEventBus.shared.retainedSnapshot().isEmpty)
    }

    func testWorkstreamPayloadRedactsSensitiveFields() throws {
        let event = WorkstreamEvent(
            sessionId: "session",
            hookEventName: .preToolUse,
            source: "claude",
            workspaceId: "workspace",
            cwd: "/tmp/workspace",
            toolName: "Bash",
            toolInputJSON: #"{"command":"echo secret"}"#,
            context: WorkstreamContext(
                lastUserMessage: "secret prompt",
                assistantPreamble: "secret answer"
            ),
            requestId: "request",
            ppid: 42,
            receivedAt: Date(timeIntervalSince1970: 0),
            extraFieldsJSON: #"{"message":"secret extra","result":"secret output"}"#
        )

        let payload = CmuxEventBus.workstreamPayload(event)

        XCTAssertEqual(payload["session_id"] as? String, "session")
        XCTAssertEqual(payload["hook_event_name"] as? String, "PreToolUse")
        XCTAssertEqual(payload["tool_name"] as? String, "Bash")
        XCTAssertTrue(payload["tool_input"] is NSNull)
        XCTAssertTrue(payload["context"] is NSNull)
        XCTAssertTrue(payload["extra_fields"] is NSNull)
        XCTAssertEqual(payload["tool_input_length"] as? Int, 25)
        XCTAssertNotNil(payload["context_length"] as? Int)
        XCTAssertEqual(payload["extra_fields_length"] as? Int, 51)
        XCTAssertEqual(payload["redacted_fields"] as? [String], ["tool_input", "context", "extra_fields"])

        let line = try XCTUnwrap(CmuxEventBus.encodeLine(["payload": payload]))
        XCTAssertFalse(line.contains("secret"))
    }

    func testPublishAppendsDurableEventLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(retainedEventLimit: 4, eventLogURL: logURL)

        bus.publish(name: "workspace.created", category: "workspace", source: "test")
        bus.publish(name: "surface.created", category: "surface", source: "test")
        bus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.count, 2)

        let secondData = try XCTUnwrap(lines.last?.data(using: .utf8))
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        XCTAssertEqual(second["name"] as? String, "surface.created")
    }

    func testDurableEventLogDropsOldestPendingLinesUnderBackpressure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-backpressure-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(
            retainedEventLimit: 8,
            eventLogURL: logURL,
            maxPendingEventLogLines: 2
        )

        bus.setEventLogFlushSuspendedForTesting(true)
        defer {
            bus.setEventLogFlushSuspendedForTesting(false)
            bus.flushEventLogForTesting()
        }

        for index in 0..<5 {
            bus.publish(
                name: "agent.log",
                category: "agent",
                source: "test",
                payload: ["index": index]
            )
        }

        let backlog = bus.eventLogBacklogSnapshotForTesting()
        XCTAssertEqual(backlog.pending, 2)
        XCTAssertEqual(backlog.dropped, 3)

        bus.setEventLogFlushSuspendedForTesting(false)
        bus.flushEventLogForTesting()

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let indexes = try lines.map { line in
            let data = try XCTUnwrap(line.data(using: .utf8))
            let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(event["payload"] as? [String: Any])
            return try XCTUnwrap(payload["index"] as? Int)
        }
        XCTAssertEqual(indexes, [3, 4])
    }

    func testDurableEventLogRotatesAtByteLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-rotation-\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("events.jsonl")
        let bus = CmuxEventBus(
            retainedEventLimit: 32,
            eventLogURL: logURL,
            maxEventLogBytes: 1_500,
            maxEventLineBytes: 1_024
        )

        for index in 0..<20 {
            bus.publish(
                name: "agent.log",
                category: "agent",
                source: "test",
                payload: ["index": index, "message": String(repeating: "x", count: 120)]
            )
        }
        bus.flushEventLogForTesting()

        let rotatedURL = logURL.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertLessThanOrEqual(try fileSize(logURL), 1_500)
        XCTAssertLessThanOrEqual(try fileSize(rotatedURL), 1_500)
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return try XCTUnwrap(size).uint64Value
    }
}
