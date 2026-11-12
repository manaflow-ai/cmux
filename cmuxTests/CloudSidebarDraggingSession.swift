import AppKit

@MainActor
final class CloudSidebarDraggingSession: NSDraggingSession {
    // AppKit's getter is nonisolated; this immutable fixture stays on the test UI thread.
    nonisolated(unsafe) let board: NSPasteboard

    init(pasteboard: NSPasteboard) {
        board = pasteboard
        super.init()
    }

    override var draggingSequenceNumber: Int { 12574 }
    override var draggingPasteboard: NSPasteboard { board }
}
