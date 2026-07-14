import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct PortalDividerDragTests {
    private static let contentBounds = NSRect(x: 0, y: 0, width: 800, height: 600)

    private func makeNestedSplits() -> (outer: NSSplitView, inner: NSSplitView) {
        let outer = NSSplitView(frame: Self.contentBounds)
        outer.isVertical = false
        let top = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let bottom = NSView(frame: NSRect(x: 0, y: 301, width: 800, height: 299))
        outer.addArrangedSubview(top)
        outer.addArrangedSubview(bottom)
        let inner = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        inner.isVertical = true
        top.addSubview(inner)
        return (outer, inner)
    }

    private func region(
        _ splitView: NSSplitView,
        rect: NSRect,
        isVertical: Bool
    ) -> PortalSplitDividerRegion {
        PortalSplitDividerRegion(
            splitView: splitView,
            dividerIndex: 0,
            rectInWindow: rect,
            boundsInWindow: Self.contentBounds,
            isVertical: isVertical
        )
    }

    private var verticalDividerRect: NSRect { NSRect(x: 400, y: 0, width: 1, height: 300) }
    private var horizontalDividerRect: NSRect { NSRect(x: 0, y: 300, width: 800, height: 1) }
    private var cornerPoint: NSPoint { NSPoint(x: 400, y: 300) }

    @Test func allAxesCursorResolvesWithoutPrivateSelectors() {
        let cursor = PortalDividerCursorKind.both.cursor
        #expect(cursor.image.size.width > 0)
        #expect(cursor.image.size.height > 0)
    }

    @Test func singleAxisDragConsumesEventsAndKeepsItsOrientation() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let (_, inner) = makeNestedSplits()
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        inner.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 300)))
        window.contentView?.addSubview(inner)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        let start = NSPoint(x: 400, y: 150)
        let controller = PortalDividerDragController()
        var releasedAt: NSPoint?

        #expect(PortalDividerDragController.drag(atWindowPoint: start, regions: [vertical])?.kind == .vertical)
        #expect(controller.begin(
            atWindowPoint: start,
            regions: [vertical],
            onRelease: { releasedAt = $0 }
        ))
        #expect(controller.cursorKind == .vertical)
        #expect(controller.hasCursorEventMonitorForTesting)

        let draggedPoint = NSPoint(x: 450, y: 280)
        guard let draggedEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: draggedPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else {
            Issue.record("Expected a synthetic drag event")
            return
        }
        #expect(controller.handleActiveSessionEvent(draggedEvent) == nil)
        #expect(abs(inner.arrangedSubviews[0].frame.width - 450) < 1)
        #expect(controller.cursorKind == .vertical)

        controller.end(atWindowPoint: draggedPoint)
        #expect(controller.cursorKind == nil)
        #expect(releasedAt == draggedPoint)
        #expect(!controller.hasCursorEventMonitorForTesting)
    }

    @Test func updateDoesNotPartiallyMoveWhenDividerIdentityGoesStale() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let (outer, inner) = makeNestedSplits()
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        inner.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 300)))
        window.contentView?.addSubview(outer)

        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        let controller = PortalDividerDragController()
        #expect(controller.begin(atWindowPoint: cornerPoint, regions: [horizontal, vertical]))

        let initialInnerPosition = inner.arrangedSubviews[0].frame.width
        let removed = outer.arrangedSubviews[1]
        outer.removeArrangedSubview(removed)
        removed.removeFromSuperview()
        controller.update(windowPoint: NSPoint(x: 420, y: 280))
        #expect(controller.isActive)
        #expect(abs(inner.arrangedSubviews[0].frame.width - initialInnerPosition) < 1)
        controller.end()
    }

    @Test func managedSplitRejectsStaleModelIdentityBeforeViewMoves() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let splitView = StubManagedSplitView(frame: Self.contentBounds)
        splitView.isVertical = true
        splitView.bonsplitController = BonsplitController()
        splitView.bonsplitSplitId = UUID()
        splitView.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600)))
        splitView.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 600)))
        window.contentView?.addSubview(splitView)
        let vertical = region(
            splitView,
            rect: NSRect(x: 400, y: 0, width: 1, height: 600),
            isVertical: true
        )
        let controller = PortalDividerDragController()
        let initialPosition = splitView.arrangedSubviews[0].frame.width

        #expect(controller.begin(atWindowPoint: NSPoint(x: 400, y: 300), regions: [vertical]))
        controller.update(windowPoint: NSPoint(x: 450, y: 300))

        #expect(controller.isActive)
        #expect(abs(splitView.arrangedSubviews[0].frame.width - initialPosition) < 1)
        controller.end()
    }

    @Test func zeroAlphaAncestorsAreNotInteractableForIntersection() {
        let window = NSWindow(
            contentRect: Self.contentBounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let (outer, inner) = makeNestedSplits()
        inner.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)))
        inner.addArrangedSubview(NSView(frame: NSRect(x: 401, y: 0, width: 399, height: 300)))
        window.contentView?.addSubview(outer)

        let horizontal = region(outer, rect: horizontalDividerRect, isVertical: false)
        let vertical = region(inner, rect: verticalDividerRect, isVertical: true)
        #expect(PortalSplitDividerRegion.dividerIntersection(at: cornerPoint, in: [horizontal, vertical]) != nil)

        inner.superview?.alphaValue = 0

        #expect(PortalSplitDividerRegion.dividerIntersection(at: cornerPoint, in: [horizontal, vertical]) == nil)
        #expect(vertical.isLive)
        let cursorPlan = PortalSplitDividerRegion.cursorRectPlan(for: [horizontal, vertical])
        #expect(cursorPlan.corners.isEmpty)
        #expect(cursorPlan.bands.allSatisfy { !$0.isVertical })
    }

    @Test func clampHonorsDelegateConstraints() {
        let splitView = NSSplitView(frame: Self.contentBounds)
        splitView.isVertical = true
        let delegate = StubSplitViewDelegate()
        splitView.delegate = delegate
        defer { splitView.delegate = nil }

        #expect(PortalDividerDragController.clampedPosition(-50, in: splitView, dividerIndex: 0) == 100)
        #expect(PortalDividerDragController.clampedPosition(750, in: splitView, dividerIndex: 0) == 700)
        #expect(PortalDividerDragController.clampedPosition(400, in: splitView, dividerIndex: 0) == 400)
    }
}

private final class StubSplitViewDelegate: NSObject, NSSplitViewDelegate {
    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, 100)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, 700)
    }
}

private final class StubManagedSplitView: NSSplitView, BonsplitManagedSplitView {
    var bonsplitController: BonsplitController?
    var bonsplitSplitId: UUID?
}
