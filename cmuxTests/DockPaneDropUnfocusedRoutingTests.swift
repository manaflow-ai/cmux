import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class DockPaneDropMockDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    let draggedImageLocation: NSPoint
    let draggedImage: NSImage?
    // NSDraggingInfo exposes the pasteboard nonisolated; tests mutate it only before construction.
    nonisolated(unsafe) let draggingPasteboard: NSPasteboard
    // AppKit exposes the dragging source as an untyped object and this test never mutates it.
    nonisolated(unsafe) let draggingSource: Any?
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(
        window: NSWindow,
        location: NSPoint,
        pasteboard: NSPasteboard,
        sourceOperationMask: NSDragOperation = .move,
        draggingSource: Any? = nil,
        sequenceNumber: Int = 1
    ) {
        self.draggingDestinationWindow = window
        self.draggingSourceOperationMask = sourceOperationMask
        self.draggingLocation = location
        self.draggedImageLocation = location
        self.draggedImage = nil
        self.draggingPasteboard = pasteboard
        self.draggingSource = draggingSource
        self.draggingSequenceNumber = sequenceNumber
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? {
        nil
    }

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}

@Suite("Dock pane drop routing when unfocused", .serialized)
struct DockPaneDropUnfocusedRoutingTests {
    @Test("Drop mouse-up uses the same terminal portal route as hover")
    @MainActor
    func dropMouseUpUsesSameTerminalPortalRouteAsHover() throws {
        let tabId = UUID()
        let sourcePaneId = UUID()
        let payload = try Self.makePaneDragPayload(tabId: tabId, sourcePaneId: sourcePaneId)
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        dragPasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        defer { dragPasteboard.clearContents() }

        let pasteboardTypes = dragPasteboard.types
        #expect(TerminalPaneDropTargetView.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseDragged
        ))
        #expect(TerminalPaneDropTargetView.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseUp
        ))
        #expect(WindowInputRoutingContext(eventType: .leftMouseDragged).allowsTerminalPortalDragRouting)
        #expect(WindowInputRoutingContext(eventType: .leftMouseUp).allowsTerminalPortalDragRouting)
        #expect(DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseDragged
        ))
        #expect(DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseUp
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let contentView = try #require(window.contentView)
        let host = WindowTerminalHostView(frame: contentView.bounds)
        host.autoresizingMask = [.width, .height]
        let target = TerminalPaneDropTargetView(frame: host.bounds)
        target.autoresizingMask = [.width, .height]
        target.dropContext = PaneDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: PaneID(id: UUID())
        )
        host.addSubview(target)
        contentView.addSubview(host)

        #expect(!window.isKeyWindow)
        let pointInWindow = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        let dragEvent = try Self.makeMouseEvent(type: .leftMouseDragged, at: pointInWindow, window: window)
        let dropEvent = try Self.makeMouseEvent(type: .leftMouseUp, at: pointInWindow, window: window)

        let dragHit = host.performHitTest(
            at: NSPoint(x: host.bounds.midX, y: host.bounds.midY),
            currentEvent: dragEvent
        )
        let dropHit = host.performHitTest(
            at: NSPoint(x: host.bounds.midX, y: host.bounds.midY),
            currentEvent: dropEvent
        )
        #expect(dragHit === target)
        #expect(dropHit === target)
    }

    @Test("Drop mouse-up uses the same browser portal route as hover")
    @MainActor
    func dropMouseUpUsesSameBrowserPortalRouteAsHover() throws {
        let tabId = UUID()
        let sourcePaneId = UUID()
        let payload = try Self.makePaneDragPayload(tabId: tabId, sourcePaneId: sourcePaneId)
        let dragPasteboard = NSPasteboard(name: .drag)
        dragPasteboard.clearContents()
        dragPasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
        defer { dragPasteboard.clearContents() }

        let pasteboardTypes = dragPasteboard.types
        #expect(BrowserPaneDropTargetView.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseDragged
        ))
        #expect(BrowserPaneDropTargetView.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseUp
        ))
        #expect(WindowInputRoutingContext(eventType: .leftMouseDragged).allowsBrowserPortalDragRouting)
        #expect(!WindowInputRoutingContext(eventType: .leftMouseUp).allowsBrowserPortalDragRouting)
        #expect(WindowInputRoutingContext(eventType: .leftMouseUp).allowsPortalPointerHitTesting)
        #expect(WindowInputRoutingContext(eventType: .leftMouseUp).allowsPaneDropHitTesting)
        #expect(WindowBrowserHostView.shouldPassThroughToDragTargets(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseDragged
        ))
        #expect(!WindowBrowserHostView.shouldPassThroughToDragTargets(
            pasteboardTypes: pasteboardTypes,
            eventType: .leftMouseUp
        ))
        #expect(!WindowBrowserHostView.shouldPassThroughToDragTargets(
            pasteboardTypes: [.fileURL],
            eventType: .leftMouseUp
        ))
    }

    @Test("Accepted unfocused Dock pane drop moves a main surface into the Dock")
    @MainActor
    func acceptedUnfocusedDockPaneDropMovesMainSurfaceIntoDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let sourcePane = try #require(workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first)
            let sourcePanel = try #require(workspace.newTerminalSurface(inPane: sourcePane, focus: true))
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(sourcePanel.id))
            let dock = workspace.dockSplit
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let existingDockPanelId = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, focus: false))

            let payload = try Self.makePaneDragPayload(tabId: sourceTabId.uuid, sourcePaneId: sourcePane.id)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7529.\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
            defer { pasteboard.clearContents() }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView)
            let target = TerminalPaneDropTargetView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
            target.dropContext = PaneDropContext(
                workspaceId: workspace.id,
                panelId: existingDockPanelId,
                paneId: dockPane
            )
            contentView.addSubview(target)

            #expect(!window.isKeyWindow)
            #expect(AppDelegate.shared?.dockForPane(dockPane) === dock)
            #expect(AppDelegate.shared?.locateContainerSurface(tabId: sourceTabId.uuid) != nil)
            let dropPoint = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            let draggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: dropPoint,
                pasteboard: pasteboard
            )

            #expect(target.draggingEntered(draggingInfo) == .move)
            #expect(target.performDragOperation(draggingInfo))
            #expect(dock.containsPanel(sourcePanel.id))
            #expect(!workspace.panels.keys.contains(sourcePanel.id))
        }
    }

    @Test("Accepted unfocused main pane drop moves a Dock surface out of the Dock")
    @MainActor
    func acceptedUnfocusedMainPaneDropMovesDockSurfaceOutOfDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let targetPanel = try #require(workspace.panels.values.first)
            let targetPane = try #require(workspace.paneId(forPanelId: targetPanel.id))
            let dock = workspace.dockSplit
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let dockPanelId = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, focus: false))
            let dockTabId = try #require(dock.surfaceId(forPanelId: dockPanelId))
            let dockSourcePane = try #require(dock.paneId(forPanelId: dockPanelId) ?? dockPane)

            let payload = try Self.makePaneDragPayload(tabId: dockTabId.uuid, sourcePaneId: dockSourcePane.id)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7529.\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
            defer { pasteboard.clearContents() }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView)
            let target = TerminalPaneDropTargetView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
            target.dropContext = PaneDropContext(
                workspaceId: workspace.id,
                panelId: targetPanel.id,
                paneId: targetPane
            )
            contentView.addSubview(target)

            #expect(!window.isKeyWindow)
            #expect(AppDelegate.shared?.dockForPane(targetPane) == nil)
            #expect(AppDelegate.shared?.locateDockSurface(tabId: dockTabId.uuid)?.dock === dock)
            let dropPoint = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            let draggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: dropPoint,
                pasteboard: pasteboard
            )

            #expect(target.draggingEntered(draggingInfo) == .move)
            #expect(target.performDragOperation(draggingInfo))
            #expect(workspace.panels.keys.contains(dockPanelId))
            #expect(!dock.containsPanel(dockPanelId))
        }
    }

    private static func makePaneDragPayload(tabId: UUID, sourcePaneId: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tab": ["id": tabId.uuidString, "kind": SurfaceKind.terminal.rawValue],
            "sourcePaneId": sourcePaneId.uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier),
        ])
    }

    private static func makeMouseEvent(
        type: NSEvent.EventType,
        at locationInWindow: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
