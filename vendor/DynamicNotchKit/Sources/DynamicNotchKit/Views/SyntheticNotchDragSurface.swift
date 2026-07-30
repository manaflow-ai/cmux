import AppKit
import SwiftUI

/// AppKit pointer surface for dragging only the synthetic menu-bar pill.
struct SyntheticNotchDragSurface: NSViewRepresentable {
    let begin: () -> Bool
    let drag: (CGFloat) -> Void
    let end: (CGFloat) -> Void

    func makeNSView(context: Context) -> SyntheticNotchDragView {
        let view = SyntheticNotchDragView()
        update(view)
        return view
    }

    func updateNSView(
        _ nsView: SyntheticNotchDragView,
        context: Context
    ) {
        update(nsView)
    }

    private func update(_ view: SyntheticNotchDragView) {
        view.begin = begin
        view.drag = drag
        view.end = end
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class SyntheticNotchDragView: NSView {
    var begin: (() -> Bool)?
    var drag: ((CGFloat) -> Void)?
    var end: ((CGFloat) -> Void)?

    private var isDragging = false
    private var trackingAreaReference: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
            ],
            owner: self
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDragging else { return }
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard begin?() == true else { return }
        isDragging = true
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        drag?(NSEvent.mouseLocation.x)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        end?(NSEvent.mouseLocation.x)
        finishDragging()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isDragging {
            end?(NSEvent.mouseLocation.x)
            finishDragging()
        }
    }

    private func finishDragging() {
        guard isDragging else { return }
        isDragging = false
        NSCursor.pop()
        let isPointerInside: Bool
        if let window {
            let windowPoint = window.convertPoint(
                fromScreen: NSEvent.mouseLocation
            )
            isPointerInside = bounds.contains(
                convert(windowPoint, from: nil)
            )
        } else {
            isPointerInside = false
        }
        if isPointerInside {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}
