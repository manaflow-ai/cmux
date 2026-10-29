import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceReorderDropOverlayHitTestingTests {
    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation
        let draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage?
        // NSPasteboard is AppKit-managed and read only by the main-actor drop view in these tests.
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        // NSDraggingInfo exposes an untyped AppKit source object; tests never mutate it.
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

    @Test @MainActor func dropViewUsesTopOriginCoordinates() {
        let view = SidebarWorkspaceReorderDropOverlay.DropView()
        #expect(view.isFlipped)
    }

    @Test func doesNotCaptureMouseDownBeforeDragStart() {
        #expect(!SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDown,
            pasteboardTypes: [NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)]
        ))
    }

    @Test func doesNotCapturePointerDragWithoutSidebarPasteboardType() {
        #expect(!SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDragged,
            pasteboardTypes: []
        ))
    }

    @Test func staleSidebarPasteboardTypeDoesNotCapturePointerDrag() {
        #expect(!SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDragged,
            pasteboardTypes: [NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)]
        ))
    }

    @Test func liveSidebarSessionMayCapturePointerDrag() {
        #expect(SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDragged,
            pasteboardTypes: [NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)],
            hasLiveWorkspaceDrag: true
        ))
    }

    /// AppKit routes a drag to the frontmost view registered for one of its
    /// types, ignoring `hitTest`. A sidebar row drag also carries the Bonsplit
    /// pane-merge type (#18837), so the Bonsplit overlay above the reorder
    /// view receives it and must hand the reorder on instead of rejecting it.
    @Test @MainActor func workspaceRowDragOverBonsplitOverlayStillReorders() {
        let container = SidebarWorkspaceTableContainerView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 160)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        let reorder = container.reorderDropView
        reorder.registerForDraggedTypes([SidebarWorkspaceReorderDropOverlay.pasteboardType])
        reorder.isValidDrag = { true }
        reorder.hasLiveWorkspaceDrag = { true }
        reorder.targets = [SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: UUID(),
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 240, height: 24)
        )]
        var updatedPoints: [CGPoint] = []
        var droppedPoints: [CGPoint] = []
        reorder.updateDrag = { point, _ in
            updatedPoints.append(point)
            return true
        }
        reorder.performDropAtPoint = { point, _ in
            droppedPoints.append(point)
            return true
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            UUID().uuidString,
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        pasteboard.setString(
            UUID().uuidString,
            forType: NSPasteboard.PasteboardType(BonsplitTabDragPayload.typeIdentifier)
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 100),
            pasteboard: pasteboard
        )

        // The Bonsplit overlay is the frontmost registered destination for this drag.
        let frontmost = container.subviews.last { view in
            view.registeredDraggedTypes.contains { pasteboard.types?.contains($0) == true }
        }
        #expect(frontmost === container.bonsplitDropView)

        let bonsplit = container.bonsplitDropView
        #expect(bonsplit.draggingEntered(sender) == .move)
        #expect(bonsplit.draggingUpdated(sender) == .move)
        #expect(bonsplit.prepareForDragOperation(sender))
        #expect(bonsplit.performDragOperation(sender))
        bonsplit.concludeDragOperation(sender)
        // AppKit sends this to the overlay, which responds to it; the reorder
        // view beneath does not, so it must not be forwarded there.
        bonsplit.draggingEnded(sender)

        #expect(updatedPoints.count == 2)
        #expect(droppedPoints.count == 1)
    }

    @Test @MainActor func targetBridgeUpdatesEveryAttachedDropView() {
        let bridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
        let firstView = SidebarWorkspaceReorderDropOverlay.DropView()
        let secondView = SidebarWorkspaceReorderDropOverlay.DropView()
        bridge.attach(firstView)
        bridge.attach(secondView)

        let target = SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: UUID(),
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 200, height: 24)
        )
        bridge.updateTargets([target])

        #expect(firstView.targets == [target])
        #expect(secondView.targets == [target])
    }

    @Test @MainActor func topStripOverlayOffsetsDropPointIntoContentCoordinates() {
        let view = SidebarWorkspaceReorderDropOverlay.DropView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 28)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 28),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            UUID().uuidString,
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 12),
            pasteboard: pasteboard
        )

        let rawPoint = view.convert(sender.draggingLocation, from: nil)
        view.pointOffset = CGSize(width: 0, height: -28)
        let dropPoint = view.dropPoint(from: sender)

        #expect(dropPoint.x == rawPoint.x)
        #expect(dropPoint.y == rawPoint.y - 28)
    }

    @Test @MainActor func fastReleaseQueuesDropUntilTargetsArrive() async {
        let bridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
        let view = SidebarWorkspaceReorderDropOverlay.DropView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 160)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        bridge.attach(view)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            UUID().uuidString,
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 48),
            pasteboard: pasteboard
        )
        let target = SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: UUID(),
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 200, height: 24)
        )

        var activeStates: [Bool] = []
        var updateCalls = 0
        var performedDrops: [(CGPoint, [SidebarWorkspaceReorderDropOverlay.Target])] = []
        view.isValidDrag = { true }
        view.hasLiveWorkspaceDrag = { true }
        view.setWorkspaceDropTargetCollectionActive = { activeStates.append($0) }
        view.clearDropIndicator = {}
        view.updateDrag = { _, _ in
            updateCalls += 1
            return true
        }
        view.performDropAtPoint = { point, targets in
            performedDrops.append((point, targets))
            return true
        }

        #expect(view.draggingEntered(sender) == .move)
        #expect(updateCalls == 0)
        let expectedDropPoint = view.convert(sender.draggingLocation, from: nil)
        #expect(view.performDragOperation(sender))
        #expect(performedDrops.isEmpty)

        bridge.updateTargets([target])
        await Task.yield()
        await Task.yield()

        #expect(performedDrops.count == 1)
        #expect(performedDrops.first?.0 == expectedDropPoint)
        #expect(performedDrops.first?.1 == [target])
        #expect(activeStates == [true, false])
    }

    @Test @MainActor func pendingFastReleaseSurvivesDragConclusionUntilTargetsArrive() async {
        let bridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
        let view = SidebarWorkspaceReorderDropOverlay.DropView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 160)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        bridge.attach(view)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            UUID().uuidString,
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 48),
            pasteboard: pasteboard
        )
        let target = SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: UUID(),
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 200, height: 24)
        )

        var activeStates: [Bool] = []
        var performedDrops: [(CGPoint, [SidebarWorkspaceReorderDropOverlay.Target])] = []
        view.isValidDrag = { true }
        view.hasLiveWorkspaceDrag = { true }
        view.setWorkspaceDropTargetCollectionActive = { activeStates.append($0) }
        view.clearDropIndicator = {}
        view.updateDrag = { _, _ in true }
        view.performDropAtPoint = { point, targets in
            performedDrops.append((point, targets))
            return true
        }

        #expect(view.draggingEntered(sender) == .move)
        let expectedDropPoint = view.convert(sender.draggingLocation, from: nil)
        #expect(view.performDragOperation(sender))
        view.concludeDragOperation(sender)

        bridge.updateTargets([target])

        #expect(performedDrops.count == 1)
        #expect(performedDrops.first?.0 == expectedDropPoint)
        #expect(performedDrops.first?.1 == [target])
        #expect(activeStates == [true, false])
    }

    @Test @MainActor func pendingDropKeepsSessionIdentityAfterNativeCompletion() {
        let bridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
        let view = SidebarWorkspaceReorderDropOverlay.DropView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 160)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        bridge.attach(view)

        let workspaceId = UUID()
        let sessionId = UUID()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            "\(SidebarTabDragPayload.prefix)\(workspaceId.uuidString)#\(sessionId.uuidString)",
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 48),
            pasteboard: pasteboard
        )
        let target = SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: UUID(),
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 200, height: 24)
        )

        var nativeSessionIsLive = true
        var regularCommitCount = 0
        var pendingCommitCount = 0
        view.isValidDrag = { nativeSessionIsLive }
        view.hasLiveWorkspaceDrag = { nativeSessionIsLive }
        view.updateDrag = { _, _ in true }
        view.performDropAtPoint = { _, _ in
            regularCommitCount += 1
            return nativeSessionIsLive
        }
        view.performPendingDropAtPoint = { pending, pendingTargets in
            pendingCommitCount += 1
            #expect(pending.workspaceId == workspaceId)
            #expect(pending.sessionId == sessionId)
            #expect(pendingTargets == [target])
            return true
        }

        #expect(view.draggingEntered(sender) == .move)
        #expect(view.performDragOperation(sender))
        view.concludeDragOperation(sender)
        nativeSessionIsLive = false

        bridge.updateTargets([target])

        #expect(regularCommitCount == 0)
        #expect(pendingCommitCount == 1)
    }

    @Test @MainActor func newDragInvalidatesOlderDeferredDropWithoutDisablingIt() {
        let bridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
        let view = SidebarWorkspaceReorderDropOverlay.DropView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 160)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        bridge.attach(view)

        let firstWorkspaceId = UUID()
        let firstSessionId = UUID()
        let secondWorkspaceId = UUID()
        let secondSessionId = UUID()
        let firstPasteboard = NSPasteboard(
            name: NSPasteboard.Name("workspace-reorder-first-\(UUID().uuidString)")
        )
        firstPasteboard.clearContents()
        firstPasteboard.setString(
            "\(SidebarTabDragPayload.prefix)\(firstWorkspaceId.uuidString)#\(firstSessionId.uuidString)",
            forType: SidebarWorkspaceReorderDropOverlay.pasteboardType
        )
        let secondPasteboard = NSPasteboard(
            name: NSPasteboard.Name("workspace-reorder-second-\(UUID().uuidString)")
        )
        secondPasteboard.clearContents()
        secondPasteboard.setString(
            "\(SidebarTabDragPayload.prefix)\(secondWorkspaceId.uuidString)#\(secondSessionId.uuidString)",
            forType: SidebarWorkspaceReorderDropOverlay.pasteboardType
        )
        defer {
            firstPasteboard.clearContents()
            secondPasteboard.clearContents()
            window.contentView = nil
            window.close()
        }

        var activeStates: [Bool] = []
        var pendingCommits: [(UUID?, UUID?)] = []
        view.isValidDrag = { true }
        view.hasLiveWorkspaceDrag = { true }
        view.updateDrag = { _, _ in true }
        view.performDropAtPoint = { _, _ in false }
        view.performPendingDropAtPoint = { pending, _ in
            pendingCommits.append((pending.workspaceId, pending.sessionId))
            return true
        }
        view.setWorkspaceDropTargetCollectionActive = { activeStates.append($0) }
        view.clearDropIndicator = {}

        let firstSender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 48),
            pasteboard: firstPasteboard,
            sequenceNumber: 1
        )
        #expect(view.draggingEntered(firstSender) == .move)
        #expect(view.performDragOperation(firstSender))
        view.concludeDragOperation(firstSender)

        let secondSender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 40, y: 52),
            pasteboard: secondPasteboard,
            sequenceNumber: 2
        )
        #expect(view.draggingEntered(secondSender) == .move)
        // A late exit from the superseded source must not retire the new one.
        view.draggingExited(firstSender)
        #expect(view.performDragOperation(secondSender))
        view.concludeDragOperation(secondSender)

        let target = SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: secondWorkspaceId,
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 200, height: 24)
        )
        bridge.updateTargets([target])

        #expect(pendingCommits.count == 1)
        #expect(pendingCommits.first?.0 == secondWorkspaceId)
        #expect(pendingCommits.first?.1 == secondSessionId)
        #expect(activeStates == [true, false])
    }

    @Test @MainActor func pendingFastReleaseClearsWhenTargetsNeverArrive() async {
        let bridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
        let view = SidebarWorkspaceReorderDropOverlay.DropView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 160)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        bridge.attach(view)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("workspace-reorder-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(
            UUID().uuidString,
            forType: NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        )
        let sender = MockDraggingInfo(
            window: window,
            location: NSPoint(x: 32, y: 48),
            pasteboard: pasteboard
        )
        let target = SidebarWorkspaceReorderDropOverlay.Target(
            workspaceId: UUID(),
            groupId: nil,
            isGroupHeader: false,
            frame: CGRect(x: 0, y: 40, width: 200, height: 24)
        )

        var activeStates: [Bool] = []
        var clearCount = 0
        var performedDrops: [(CGPoint, [SidebarWorkspaceReorderDropOverlay.Target])] = []
        view.isValidDrag = { true }
        view.hasLiveWorkspaceDrag = { true }
        view.setWorkspaceDropTargetCollectionActive = { activeStates.append($0) }
        view.clearDropIndicator = { clearCount += 1 }
        view.updateDrag = { _, _ in true }
        view.performDropAtPoint = { point, targets in
            performedDrops.append((point, targets))
            return true
        }

        #expect(view.draggingEntered(sender) == .move)
        #expect(view.performDragOperation(sender))
        view.concludeDragOperation(sender)
        bridge.updateTargets([])

        #expect(performedDrops.isEmpty)
        #expect(activeStates == [true, false])
        #expect(clearCount >= 1)

        bridge.updateTargets([target])

        #expect(performedDrops.isEmpty)
        #expect(activeStates == [true, false])
    }
}
