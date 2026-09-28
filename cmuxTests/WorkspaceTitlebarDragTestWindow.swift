import AppKit

/// Records the AppKit drag handoff without moving a CI window or taking focus.
final class WorkspaceTitlebarDragTestWindow: NSWindow {
    private(set) var dragCount = 0
    private(set) var wasMovableDuringDrag = false

    override func performDrag(with event: NSEvent) {
        dragCount += 1
        wasMovableDuringDrag = isMovable
    }
}
