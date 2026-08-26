import AppKit
import Bonsplit
import CmuxTerminal
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
    func dropMouseUpUsesSameTerminalPortalRouteAsHover() async throws {
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
            let sourcePanel = try #require(workspace.newTerminalSurface(inPane: targetPane, focus: true))
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(sourcePanel.id))
            let payload = try Self.makePaneDragPayload(tabId: sourceTabId.uuid, sourcePaneId: targetPane.id)
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
            #expect(!DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
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
                workspaceId: workspace.id,
                panelId: targetPanel.id,
                paneId: targetPane
            )
            host.addSubview(target)
            contentView.addSubview(host)

            #expect(!window.isKeyWindow)
            let pointInWindow = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
            let dragEvent = try Self.makeMouseEvent(type: .leftMouseDragged, at: pointInWindow, window: window)
            let dropEvent = try Self.makeMouseEvent(type: .leftMouseUp, at: pointInWindow, window: window)
            let draggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: pointInWindow,
                pasteboard: dragPasteboard
            )

            #expect(target.draggingEntered(draggingInfo) == .move)
            #expect(DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: pasteboardTypes,
                eventType: .leftMouseUp,
                hasActiveDropDrag: host.hasActivePaneDropDrag
            ))
            target.draggingExited(draggingInfo)
            let filePasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7529.file.\(UUID().uuidString)"))
            filePasteboard.clearContents()
            filePasteboard.declareTypes([.fileURL], owner: nil)
            defer { filePasteboard.clearContents() }
            let fileDraggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: pointInWindow,
                pasteboard: filePasteboard,
                sequenceNumber: 2
            )
            #expect(target.draggingEntered(fileDraggingInfo) == .copy)
            #expect(!DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: filePasteboard.types,
                eventType: .leftMouseUp,
                hasActiveDropDrag: host.hasActivePaneDropDrag
            ))
            target.draggingExited(fileDraggingInfo)
            #expect(target.draggingEntered(draggingInfo) == .move)
            let pointInTarget = target.convert(pointInWindow, from: nil)
            let dragHit = target.performHitTest(
                at: pointInTarget,
                currentEvent: dragEvent
            )
            let dropHit = target.performHitTest(
                at: pointInTarget,
                currentEvent: dropEvent
            )
            #expect(dragHit === target)
            #expect(dropHit === target)
            target.draggingEnded(draggingInfo)
            #expect(!host.hasActivePaneDropDrag)
        }
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

    @Test("Sidebar reorder never authorizes terminal mouse-up routing")
    @MainActor
    func sidebarReorderNeverAuthorizesTerminalMouseUpRouting() async throws {
        await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            defer { AppDelegate.shared = previousAppDelegate }

            let pasteboardTypes = [DragOverlayRoutingPolicy.sidebarTabReorderType]
            #expect(!DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: pasteboardTypes,
                eventType: .leftMouseUp,
                hasActiveDropDrag: appDelegate.sidebarWorkspaceDragRegistry.currentWorkspaceId != nil
            ))

            let workspaceId = UUID()
            appDelegate.sidebarWorkspaceDragRegistry.begin(workspaceId: workspaceId)
            defer { appDelegate.sidebarWorkspaceDragRegistry.end(workspaceId: workspaceId) }
            #expect(!DragOverlayRoutingPolicy.shouldPassThroughTerminalPortalHitTesting(
                pasteboardTypes: pasteboardTypes,
                eventType: .leftMouseUp,
                hasActiveDropDrag: appDelegate.sidebarWorkspaceDragRegistry.currentWorkspaceId != nil
            ))
        }
    }

    @Test("Nil exit clears only the target view active drag sequence")
    @MainActor
    func nilExitClearsOnlyTargetViewActiveDragSequence() async throws {
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
            let sourcePanel = try #require(workspace.newTerminalSurface(inPane: targetPane, focus: true))
            let sourceTabId = try #require(workspace.surfaceIdFromPanelId(sourcePanel.id))
            let payload = try Self.makePaneDragPayload(tabId: sourceTabId.uuid, sourcePaneId: targetPane.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView)
            let host = WindowTerminalHostView(frame: contentView.bounds)
            contentView.addSubview(host)
            let firstTarget = TerminalPaneDropTargetView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            let secondTarget = TerminalPaneDropTargetView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            let dropContext = PaneDropContext(workspaceId: workspace.id, panelId: targetPanel.id, paneId: targetPane)
            firstTarget.dropContext = dropContext
            secondTarget.dropContext = dropContext
            host.addSubview(firstTarget)
            host.addSubview(secondTarget)

            let firstPasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7529.first.\(UUID().uuidString)"))
            let secondPasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.issue-7529.second.\(UUID().uuidString)"))
            firstPasteboard.clearContents()
            secondPasteboard.clearContents()
            firstPasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
            secondPasteboard.setData(payload, forType: DragOverlayRoutingPolicy.bonsplitTabTransferType)
            defer {
                firstPasteboard.clearContents()
                secondPasteboard.clearContents()
            }

            let firstDraggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: NSPoint(x: 10, y: 10),
                pasteboard: firstPasteboard,
                sequenceNumber: 11
            )
            let secondDraggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: NSPoint(x: 20, y: 20),
                pasteboard: secondPasteboard,
                sequenceNumber: 22
            )

            #expect(firstTarget.draggingEntered(firstDraggingInfo) == .move)
            #expect(secondTarget.draggingEntered(secondDraggingInfo) == .move)
            firstTarget.draggingExited(nil)
            #expect(host.hasActivePaneDropDrag)
            secondTarget.draggingExited(nil)
            #expect(!host.hasActivePaneDropDrag)
        }
    }

    @Test("Plain Finder file drop into a global Dock terminal inserts the path")
    @MainActor
    func plainFinderFileDropIntoGlobalDockTerminalInsertsPath() async throws {
        try await withGlobalDockTerminalFileDrop(defaultBehavior: .text) {
            target, draggingInfo, dock, terminalPanel, _, terminalInputs, terminalInputContinuation in
            #expect(target.draggingEntered(draggingInfo) == .copy)
            #expect(target.performDragOperation(draggingInfo))
            terminalInputContinuation.finish()

            var inputIterator = terminalInputs.makeAsyncIterator()
            let nextInput = await inputIterator.next()
            let input = try #require(nextInput)
            let inputText: String
            switch input {
            case .bytes(let data):
                inputText = String(decoding: data, as: UTF8.self)
            case .namedKey(let name):
                inputText = name
            }
            #expect(inputText == "/tmp/cmux\\ issue\\ 9747/dragged\\ image.png")
            #expect(dock.panels.count == 1)
            #expect(dock.panels[terminalPanel.id] === terminalPanel)
            #expect(dock.focusedPanelId == terminalPanel.id)
        }
    }

    @Test("Shift-preview Finder file drop creates its split in the global Dock")
    @MainActor
    func shiftPreviewFinderFileDropCreatesSplitInGlobalDock() async throws {
        // NSDraggingInfo does not expose modifier flags. Verify Shift resolves to
        // preview, then exercise that resolved branch through the real AppKit entry point.
        #expect(DragOverlayRoutingPolicy.resolvedFileDropBehavior(
            pasteboardTypes: [.fileURL],
            modifierFlags: [.shift],
            defaultBehavior: .text
        ) == .preview)

        try await withGlobalDockTerminalFileDrop(defaultBehavior: .preview) {
            target, draggingInfo, dock, terminalPanel, fileURL, _, _ in
            #expect(target.draggingEntered(draggingInfo) == .copy)
            #expect(target.performDragOperation(draggingInfo))
            #expect(dock.bonsplitController.allPaneIds.count == 2)

            let previewPanels = dock.panels.values.compactMap { $0 as? FilePreviewPanel }
            let previewPanel = try #require(previewPanels.first)
            #expect(previewPanels.count == 1)
            #expect(previewPanel.filePath == fileURL.path)
            #expect(dock.containsPanel(terminalPanel.id))
            #expect(dock.paneId(forPanelId: previewPanel.id) != nil)
        }
    }

    @Test("Overlay late target discovery resolves its Dock before performing the drop")
    @MainActor
    func overlayLateTargetDiscoveryResolvesDockBeforePerformingDrop() async throws {
        try await withGlobalDockTerminalFileDrop(defaultBehavior: .preview) {
            target, draggingInfo, dock, terminalPanel, fileURL, _, _ in
            let contentView = try #require(target.window?.contentView)
            let overlay = FileDropOverlayView(frame: contentView.bounds)
            contentView.addSubview(overlay, positioned: .above, relativeTo: target)
            defer { overlay.removeFromSuperview() }

            #expect(overlay.activePaneDropTarget == nil)
            #expect(overlay.prepareForDragOperation(draggingInfo))
            #expect((overlay.preparedPaneDropTarget as AnyObject?) === target)
            #expect(overlay.performDragOperation(draggingInfo))

            let previewPanels = dock.panels.values.compactMap { $0 as? FilePreviewPanel }
            let previewPanel = try #require(previewPanels.first)
            #expect(previewPanels.count == 1)
            #expect(previewPanel.filePath == fileURL.path)
            #expect(dock.containsPanel(terminalPanel.id))
            #expect(dock.paneId(forPanelId: previewPanel.id) != nil)
        }
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
            let dock = workspace.requiredDockSplitForTesting
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
            let dock = workspace.requiredDockSplitForTesting
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let dockPanelId = try #require(dock.newSurface(kind: .terminal, inPane: dockPane, focus: false))
            let dockTabId = try #require(dock.surfaceId(forPanelId: dockPanelId))
            let dockSourcePane = try #require(dock.paneId(forPanelId: dockPanelId))

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
            "tab": ["id": tabId.uuidString, "kind": "terminal"],
            "sourcePaneId": sourcePaneId.uuidString,
            "sourceProcessId": Int(ProcessInfo.processInfo.processIdentifier),
        ])
    }

    @MainActor
    private func withGlobalDockTerminalFileDrop(
        defaultBehavior: FileDropDefaultBehavior,
        assertions: @MainActor (
            TerminalPaneDropTargetView,
            DockPaneDropMockDraggingInfo,
            DockSplitStore,
            TerminalPanel,
            URL,
            AsyncStream<TerminalManualInput>,
            AsyncStream<TerminalManualInput>.Continuation
        ) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let defaults = UserDefaults.standard
            let previousDefaultBehavior = defaults.object(
                forKey: FileDropBehaviorSettings.defaultBehaviorKey
            )
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            defaults.set(
                defaultBehavior.rawValue,
                forKey: FileDropBehaviorSettings.defaultBehaviorKey
            )
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            defer {
                if let previousDefaultBehavior {
                    defaults.set(
                        previousDefaultBehavior,
                        forKey: FileDropBehaviorSettings.defaultBehaviorKey
                    )
                } else {
                    defaults.removeObject(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
                }
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let dock = appDelegate.windowDock(forWindowId: windowId)
            let dockPane = try #require(dock.bonsplitController.allPaneIds.first)
            let (terminalInputs, terminalInputContinuation) =
                AsyncStream<TerminalManualInput>.makeStream()
            defer { terminalInputContinuation.finish() }
            let terminalSurface = TerminalSurface(
                tabId: dock.workspaceId,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                focusPlacement: .rightSidebarDock,
                ioMode: .manualMirror,
                manualInputHandler: { input in
                    _ = terminalInputContinuation.yield(input)
                }
            )
            let terminalPanel = TerminalPanel(
                workspaceId: dock.workspaceId,
                surface: terminalSurface
            )
            dock.panels[terminalPanel.id] = terminalPanel
            let terminalTab = try #require(dock.bonsplitController.createTab(
                title: terminalPanel.displayTitle,
                icon: terminalPanel.displayIcon,
                kind: terminalPanel.panelType.rawValue,
                isDirty: false,
                inPane: dockPane
            ))
            dock.bindSurface(terminalTab, toPanelId: terminalPanel.id)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer { window.orderOut(nil) }
            let contentView = try #require(window.contentView)
            let target = TerminalPaneDropTargetView(
                frame: NSRect(x: 20, y: 20, width: 260, height: 160)
            )
            target.hostedView = terminalPanel.hostedView
            target.dropContext = PaneDropContext(
                workspaceId: dock.workspaceId,
                panelId: terminalPanel.id,
                paneId: dockPane
            )
            contentView.addSubview(target)

            let fileURL = URL(
                fileURLWithPath: "/tmp/cmux issue 9747/dragged image.png"
            )
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("cmux.test.issue-9747.file.\(UUID().uuidString)")
            )
            pasteboard.clearContents()
            pasteboard.writeObjects([fileURL as NSURL])
            defer { pasteboard.clearContents() }

            let dropPoint = target.convert(
                NSPoint(x: 10, y: target.bounds.midY),
                to: nil
            )
            let draggingInfo = DockPaneDropMockDraggingInfo(
                window: window,
                location: dropPoint,
                pasteboard: pasteboard
            )

            #expect(dock.scope == .global)
            #expect(dock.workspaceId == windowId)
            #expect(appDelegate.workspaceFor(tabId: dock.workspaceId) == nil)
            try await assertions(
                target,
                draggingInfo,
                dock,
                terminalPanel,
                fileURL,
                terminalInputs,
                terminalInputContinuation
            )
        }
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
