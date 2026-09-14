import AppKit

@MainActor
final class CloudSidebarDraggingSession: NSDraggingSession {
    let board: NSPasteboard

    init(pasteboard: NSPasteboard) {
        board = pasteboard
        super.init()
    }

    override var draggingSequenceNumber: Int { 12574 }
    override var draggingPasteboard: NSPasteboard { board }
}
