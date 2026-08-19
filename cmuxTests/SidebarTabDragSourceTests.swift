import AppKit
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// In-memory fake of the cross-window registry seam, mirroring the fake used by
/// `SidebarDragStateTests` in the CmuxSidebar package.
@MainActor
private final class FakeWorkspaceDragRegistry: SidebarWorkspaceDragRegistering {
    var current: UUID?
    private(set) var beginCalls: [UUID] = []
    private(set) var endCalls: [UUID] = []

    var currentWorkspaceId: UUID? { current }

    func begin(workspaceId: UUID) {
        beginCalls.append(workspaceId)
        current = workspaceId
    }

    func end(workspaceId: UUID) {
        endCalls.append(workspaceId)
        if current == workspaceId { current = nil }
    }
}

@MainActor
@Suite("Sidebar native tab drag source", .serialized)
struct SidebarTabDragSourceTests {
    /// Regression — the exact repro path for the system-wide gesture deadlock:
    /// a sidebar drag that never concludes leaves drag state (and the WindowServer's
    /// "drag in progress") stuck, suspending four-finger Mission Control until the
    /// process exits. An AppKit-owned source must clear drag state when its session
    /// ends so a fresh drag can begin and system gestures are restored.
    ///
    /// The lifecycle is wired symmetrically, exactly as ContentView wires it:
    /// `onDragBegin` arms drag state and `onDragEnd` clears it through the same
    /// injected closure path — the coordinator holds no notification side
    /// channel into drag state.
    @Test("Concluded drag clears drag state and allows a new drag")
    func concludedDragClearsStateAndAllowsNewDrag() throws {
        let registry = FakeWorkspaceDragRegistry()
        let dragState = SidebarDragState(workspaceDragRegistry: registry)
        let workspaceId = UUID()
        var startedSources: [SidebarTabDragSessionSource] = []
        let coordinator = SidebarTabDragSourceCoordinator(
            onDragBegin: { dragState.beginDragging(tabId: $0) },
            onDragEnd: { _ in
                guard dragState.draggedTabId != nil || dragState.dropIndicator != nil else { return }
                dragState.clearDrag()
            },
            startDraggingSession: { _, _, _, source in
                startedSources.append(source)
            }
        )
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let window = NSWindow(
            contentRect: anchor.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = anchor
        defer { window.orderOut(nil) }
        coordinator.registerAnchor(anchor, for: workspaceId)
        let event = try Self.mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 14))

        #expect(coordinator.beginDrag(workspaceId: workspaceId, event: event, makeImage: { _, _ in nil }))
        #expect(startedSources.count == 1)
        #expect(dragState.draggedTabId == workspaceId)
        #expect(registry.beginCalls == [workspaceId])

        // A second begin while a session is active must not start a second session.
        #expect(!coordinator.beginDrag(workspaceId: workspaceId, event: event, makeImage: { _, _ in nil }))
        #expect(startedSources.count == 1)

        // Conclude the native session through the same delegate path AppKit
        // uses. The injected onDragEnd must clear drag state synchronously —
        // a drag whose session never concludes leaves it stuck.
        try #require(startedSources.first).finish()
        #expect(dragState.draggedTabId == nil)
        #expect(registry.endCalls == [workspaceId])

        // No lingering session: a fresh drag can begin and conclude.
        #expect(coordinator.beginDrag(workspaceId: workspaceId, event: event, makeImage: { _, _ in nil }))
        #expect(startedSources.count == 2)
        try #require(startedSources.last).finish()
        #expect(dragState.draggedTabId == nil)
        #expect(registry.endCalls == [workspaceId, workspaceId])
    }

    @Test("Session conclusion is idempotent")
    func sessionConclusionIsIdempotent() {
        var finishCount = 0
        let source = SidebarTabDragSessionSource(onFinish: { finishCount += 1 })
        source.finish()
        source.finish()
        #expect(finishCount == 1)
    }

    @Test("Internal-only drags expose no operation outside the app")
    func internalOnlyDragsExposeNoOperationOutsideApp() {
        #expect(SidebarTabDragSessionSource.operationMask(for: .withinApplication) == .move)
        #expect(SidebarTabDragSessionSource.operationMask(for: .outsideApplication) == [])
    }

    @Test("Begin drag requires a registered anchor")
    func beginDragRequiresRegisteredAnchor() throws {
        let coordinator = SidebarTabDragSourceCoordinator()
        let workspaceId = UUID()
        let event = try Self.mouseEvent(type: .leftMouseDragged, location: NSPoint(x: 20, y: 14))

        // No anchor registered yet.
        #expect(!coordinator.beginDrag(workspaceId: workspaceId, event: event, makeImage: { _, _ in nil }))

        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        coordinator.registerAnchor(anchor, for: workspaceId)
        #expect(coordinator.anchor(for: workspaceId) === anchor)
    }

    /// Regression — the exact repro path after the first drag: a SwiftUI
    /// re-render (the row's drag-state opacity flip) detaches the `.overlay`-
    /// hosted anchor from its window, and a second drag must still start. The
    /// session is driven from the window's live content view using the frame
    /// captured while the anchor was attached.
    @Test("Detached anchor falls back to the event's window")
    func detachedAnchorFallsBackToEventWindow() throws {
        struct Start {
            let sourceView: NSView
        }
        var starts: [Start] = []
        let coordinator = SidebarTabDragSourceCoordinator(
            startDraggingSession: { sourceView, _, _, _ in
                starts.append(Start(sourceView: sourceView))
            }
        )
        let workspaceId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let anchor = NSView(frame: NSRect(x: 10, y: 300, width: 240, height: 28))
        window.contentView = contentView
        contentView.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        coordinator.registerAnchor(anchor, for: workspaceId)
        // The frame is captured while attached; now simulate the re-render detach.
        #expect(anchor.window === window)
        anchor.removeFromSuperview()
        #expect(anchor.window == nil)

        // A mouse event bound to the still-live window.
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 130, y: 314),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        #expect(event.window === window)

        #expect(coordinator.beginDrag(workspaceId: workspaceId, event: event, makeImage: { _, _ in nil }))
        #expect(starts.count == 1)
        // The session is driven from the live content view, not the detached anchor.
        #expect(starts[0].sourceView === contentView)
    }

    /// Regression — closed workspaces must stop accumulating anchor entries:
    /// the coordinator retains anchors strongly, so a row that is dismantled
    /// (workspace closed, group collapsed) without unregistering leaks its
    /// `NSView` and cached window frame for the lifetime of the sidebar.
    /// Dismantle is the one teardown signal that does NOT fire on the
    /// re-render window detaches the detached-drag fallback depends on.
    @Test("Dismantled anchor unregisters; detached anchor stays registered")
    func dismantledAnchorUnregistersDetachedStaysRegistered() {
        let coordinator = SidebarTabDragSourceCoordinator()
        let closedId = UUID()
        let detachedId = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = contentView
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        // Two rows, both mounted through the representable exactly as the
        // sidebar mounts them (dismantle callbacks carry the view, not a
        // captured id — the coordinator resolves ids through its index).
        let closedAnchor = SidebarTabDragAnchorNSView(frame: NSRect(x: 10, y: 300, width: 240, height: 28))
        closedAnchor.onDismantle = { [weak closedAnchor] in
            guard let closedAnchor else { return }
            coordinator.unregisterAnchor(closedAnchor)
        }
        contentView.addSubview(closedAnchor)
        coordinator.registerAnchor(closedAnchor, for: closedId)

        let detachedAnchor = SidebarTabDragAnchorNSView(frame: NSRect(x: 10, y: 260, width: 240, height: 28))
        // The window-move callback mirrors the representable's wiring so the
        // detach below runs the production viewDidMoveToWindow path (and the
        // coordinator's window cache tracks it), not just a bare removal.
        detachedAnchor.onMoveToWindow = { [weak coordinator] window in
            coordinator?.anchorDidMove(toWindow: window, for: detachedId)
        }
        detachedAnchor.onDismantle = { [weak detachedAnchor] in
            guard let detachedAnchor else { return }
            coordinator.unregisterAnchor(detachedAnchor)
        }
        contentView.addSubview(detachedAnchor)
        coordinator.registerAnchor(detachedAnchor, for: detachedId)

        #expect(coordinator.anchor(for: closedId) === closedAnchor)
        #expect(coordinator.anchor(for: detachedId) === detachedAnchor)
        // Precondition for the teardown assertions below: both rows' frames
        // were captured while attached, so a nil frame after dismantle proves
        // removal rather than a frame that was never cached.
        #expect(coordinator.windowFrame(for: closedId) != nil)
        #expect(coordinator.windowFrame(for: detachedId) != nil)

        // A re-render detaches one row's overlay from its window (the exact
        // detach the fallback needs): the anchor must stay registered with its
        // cached window frame and cached window.
        detachedAnchor.removeFromSuperview()
        #expect(detachedAnchor.window == nil)
        #expect(coordinator.anchor(for: detachedId) === detachedAnchor)
        #expect(coordinator.windowFrame(for: detachedId) != nil)
        #expect(coordinator.cachedWindow(for: detachedId) === window)

        // The other row's workspace is closed — SwiftUI dismantles the row.
        // The anchor and its cached frame must be gone so churn cannot grow
        // the maps.
        SidebarTabDragAnchorView.dismantleNSView(closedAnchor, coordinator: ())
        #expect(coordinator.anchor(for: closedId) == nil)
        #expect(coordinator.windowFrame(for: closedId) == nil)

        // A recycled anchor view re-registered under a new id must not leave
        // the old id's entry behind.
        let recycledId = UUID()
        coordinator.registerAnchor(detachedAnchor, for: recycledId)
        #expect(coordinator.anchor(for: detachedId) == nil)
        #expect(coordinator.anchor(for: recycledId) === detachedAnchor)
    }

    /// Regression — SwiftUI can replace a row's anchor view and register the
    /// replacement *before* the old view's `dismantleNSView` runs. Removing by
    /// workspace id alone would delete the live replacement's registration and
    /// leave the next drag without an anchor; teardown must be scoped to the
    /// retired view. A replacement registering while detached must also not
    /// inherit the old view's cached frame.
    @Test("Replacing an anchor view keeps the replacement registered through the old view's dismantle")
    func replacementAnchorSurvivesOldViewDismantle() {
        let coordinator = SidebarTabDragSourceCoordinator()
        let workspaceId = UUID()

        let oldAnchor = SidebarTabDragAnchorNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        oldAnchor.onDismantle = { [weak oldAnchor] in
            guard let oldAnchor else { return }
            coordinator.unregisterAnchor(oldAnchor)
        }
        coordinator.registerAnchor(oldAnchor, for: workspaceId)

        // SwiftUI replaces the row's anchor; the replacement registers while
        // detached (no window yet, so no fresh frame is cached).
        let replacementAnchor = SidebarTabDragAnchorNSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        replacementAnchor.onDismantle = { [weak replacementAnchor] in
            guard let replacementAnchor else { return }
            coordinator.unregisterAnchor(replacementAnchor)
        }
        coordinator.registerAnchor(replacementAnchor, for: workspaceId)
        #expect(coordinator.anchor(for: workspaceId) === replacementAnchor)

        // The old view's dismantle arrives late. It must not remove the live
        // replacement's registration.
        SidebarTabDragAnchorView.dismantleNSView(oldAnchor, coordinator: ())
        #expect(coordinator.anchor(for: workspaceId) === replacementAnchor)

        // The replacement's own dismantle still unregisters normally.
        SidebarTabDragAnchorView.dismantleNSView(replacementAnchor, coordinator: ())
        #expect(coordinator.anchor(for: workspaceId) == nil)
        #expect(coordinator.windowFrame(for: workspaceId) == nil)
    }

    // The event-builder tests exercise the *synthetic* path: unit tests dispatch
    // no live mouse event, so `NSApp.currentEvent` is nil and `dragEvent`
    // cannot take the live-event fast path. The anchor's own window (or the
    // cached window its frame was captured in) drives the synthesis.
    @Test("Synthetic drag event lands in the anchor's window")
    func dragEventSynthesizesWindowEvent() throws {
        let coordinator = SidebarTabDragSourceCoordinator()
        let workspaceId = UUID()
        // Borderless window: content view occupies the frame at window-base
        // origin (0,0), so local coords == window base coords and the exact
        // location assertion is titlebar-independent.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        // The anchor IS the content view: local coords == window base coords,
        // so the conversion is exact and easy to assert.
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = anchor
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        coordinator.registerAnchor(anchor, for: workspaceId)
        #expect(anchor.window === window)

        let location = NSPoint(x: 120, y: 60)
        let event = try #require(coordinator.dragEvent(for: workspaceId, location: location))
        #expect(event.windowNumber == window.windowNumber)
        #expect(event.locationInWindow == location)
    }

    @Test("Detached anchor resolves the drag event through the cached window")
    func dragEventDetachedAnchorResolvesCachedWindow() throws {
        let coordinator = SidebarTabDragSourceCoordinator()
        let workspaceId = UUID()
        // Borderless window keeps the cached frame exactly at (10, 260, 240, 28)
        // in window base coords, so the detached-mapping assertion is exact.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        window.contentView = contentView
        let anchor = NSView(frame: NSRect(x: 10, y: 260, width: 240, height: 28))
        contentView.addSubview(anchor)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        coordinator.registerAnchor(anchor, for: workspaceId)
        #expect(anchor.window === window)

        // Re-render detaches the overlay; the frame + window caches survive.
        anchor.removeFromSuperview()
        #expect(anchor.window == nil)

        let event = try #require(coordinator.dragEvent(for: workspaceId, location: NSPoint(x: 20, y: 14)))
        #expect(event.windowNumber == window.windowNumber)
        // Detached: the row-local (top-left origin) gesture offset is mapped
        // over the cached window-base frame — (10 + 20, 260 + 28 - 14).
        #expect(event.locationInWindow == NSPoint(x: 30, y: 274))
    }

    @Test("No reliable window fails closed")
    func dragEventFailsClosedWithoutReliableWindow() {
        let coordinator = SidebarTabDragSourceCoordinator()
        let workspaceId = UUID()
        // Registered but never attached: no anchor window, no cached window or
        // frame. The event builder must return nil instead of guessing.
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        coordinator.registerAnchor(anchor, for: workspaceId)
        #expect(coordinator.dragEvent(for: workspaceId, location: .zero) == nil)

        // An id with no registered anchor also fails closed.
        #expect(coordinator.dragEvent(for: UUID(), location: .zero) == nil)
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
