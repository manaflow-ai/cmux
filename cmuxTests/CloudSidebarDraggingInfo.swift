import AppKit

/// Native destination input; all access stays on the AppKit test thread.
@MainActor
final class CloudSidebarDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation: NSPoint
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    // NSDraggingInfo declares these getters nonisolated; the fixture is immutable.
    nonisolated(unsafe) let draggingPasteboard: NSPasteboard
    nonisolated(unsafe) let draggingSource: Any?
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(source: NSOutlineView, pasteboard: NSPasteboard, location: NSPoint, sequenceNumber: Int = 1) {
        draggingSource = source
        draggingDestinationWindow = source.window
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingSequenceNumber = sequenceNumber
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
}
