import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct FileDropOverlayHitTestPerformanceTests {
    private final class CountingContentView: NSView {
        var hitTestCallCount = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            hitTestCallCount += 1
            return super.hitTest(point)
        }
    }

    private final class MockDraggingInfo: NSObject, NSDraggingInfo {
        let draggingDestinationWindow: NSWindow?
        let draggingSourceOperationMask: NSDragOperation = .copy
        var draggingLocation: NSPoint
        let draggedImageLocation: NSPoint
        let draggedImage: NSImage? = nil
        nonisolated(unsafe) let draggingPasteboard: NSPasteboard
        nonisolated(unsafe) let draggingSource: Any? = nil
        let draggingSequenceNumber = 7811
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        let springLoadingHighlight: NSSpringLoadingHighlight = .none

        init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
            draggingDestinationWindow = window
            draggingLocation = location
            draggedImageLocation = location
            draggingPasteboard = pasteboard
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

    @Test("Each drag update reuses one underlying window hit test")
    func eightyDragUpdatesPerformOneUnderlyingHitTestEach() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let savedBehavior = defaults.object(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
        defaults.set(FileDropDefaultBehavior.text.rawValue, forKey: FileDropBehaviorSettings.defaultBehaviorKey)
        defer {
            if let savedBehavior {
                defaults.set(savedBehavior, forKey: FileDropBehaviorSettings.defaultBehaviorKey)
            } else {
                defaults.removeObject(forKey: FileDropBehaviorSettings.defaultBehaviorKey)
            }
        }

        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let textView = NSTextView(frame: NSRect(x: 80, y: 70, width: 260, height: 170))
        textView.isEditable = true
        contentView.addSubview(textView)

        let themeFrame = try #require(contentView.superview)
        let overlay = FileDropOverlayView(frame: contentView.frame)
        themeFrame.addSubview(overlay, positioned: .above, relativeTo: contentView)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux.test.drag.hit-test.\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(
            pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/issue-7811.txt") as NSURL]),
            "Expected a file URL drag payload"
        )
        let dragInfo = MockDraggingInfo(
            window: window,
            location: textView.convert(NSPoint(x: 10, y: textView.bounds.midY), to: nil),
            pasteboard: pasteboard
        )

        contentView.hitTestCallCount = 0
        for index in 0..<80 {
            let progress = CGFloat(index) / 79
            dragInfo.draggingLocation = textView.convert(
                NSPoint(x: 10 + progress * (textView.bounds.width - 20), y: textView.bounds.midY),
                to: nil
            )
            let operation = index == 0
                ? overlay.draggingEntered(dragInfo)
                : overlay.draggingUpdated(dragInfo)
            #expect(operation == .copy)
        }

        #expect(
            contentView.hitTestCallCount == 80,
            "The 80-event issue repro should walk the underlying AppKit hierarchy no more than once per event"
        )
    }
}
