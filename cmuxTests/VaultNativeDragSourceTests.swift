import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Vault native drag source", .serialized)
struct VaultNativeDragSourceTests {
    @Test("Each rendered duplicate row owns its current native drag source")
    func renderedDuplicateRowsOwnCurrentNativeDragSources() throws {
        let first = Self.makeEntry(title: "First rendered occurrence")
        let second = Self.makeEntry(title: "Second rendered occurrence")
        var startedEntries: [SessionEntry] = []
        let source = SessionDragSourceView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 28),
            entry: first,
            beginDrag: { entry, _, _, _, _ in
                startedEntries.append(entry)
                return true
            },
            onDoubleClick: {}
        )
        let window = NSWindow(
            contentRect: source.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = source
        defer { window.orderOut(nil) }

        try Self.drag(source, in: window, from: NSPoint(x: 1, y: 1))
        source.update(entry: second, beginDrag: source.beginDrag, onDoubleClick: {})
        try Self.drag(source, in: window, from: NSPoint(x: 239, y: 27))

        #expect(startedEntries.map(\.title) == [first.title, second.title])
    }

    @Test("Dragging a row never also performs its double-click action")
    func rowDragDoesNotActivateDoubleClick() throws {
        let entry = Self.makeEntry(title: "Drag instead of activate")
        var dragCount = 0
        var activationCount = 0
        let source = SessionDragSourceView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 28),
            entry: entry,
            beginDrag: { _, _, _, _, _ in
                dragCount += 1
                return true
            },
            onDoubleClick: { activationCount += 1 }
        )
        let window = NSWindow(
            contentRect: source.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = source
        defer { window.orderOut(nil) }

        let start = NSPoint(x: 40, y: 14)
        source.mouseDown(with: try Self.mouseEvent(
            type: .leftMouseDown,
            location: source.convert(start, to: nil),
            window: window,
            clickCount: 2
        ))
        source.mouseDragged(with: try Self.mouseEvent(
            type: .leftMouseDragged,
            location: source.convert(NSPoint(x: start.x + 8, y: start.y), to: nil),
            window: window,
            clickCount: 2
        ))
        source.mouseUp(with: try Self.mouseEvent(
            type: .leftMouseUp,
            location: source.convert(NSPoint(x: start.x + 8, y: start.y), to: nil),
            window: window,
            clickCount: 2
        ))

        #expect(dragCount == 1)
        #expect(activationCount == 0)
    }

    @Test("Repeated click sequences can still initiate a native drag", arguments: [1, 2, 3])
    func repeatedClickSequenceCanInitiateNativeDrag(clickCount: Int) throws {
        let entry = Self.makeEntry(title: "Repeated click \(clickCount)")
        var startedEntry: SessionEntry?
        let source = SessionDragSourceView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 40),
            entry: entry,
            beginDrag: { candidate, _, _, _, _ in
                startedEntry = candidate
                return true
            },
            onDoubleClick: {}
        )
        let window = NSWindow(
            contentRect: source.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = source
        defer { window.orderOut(nil) }

        let start = NSPoint(x: 40, y: 14)
        source.mouseDown(with: try Self.mouseEvent(
            type: .leftMouseDown,
            location: source.convert(start, to: nil),
            window: window,
            clickCount: clickCount
        ))
        source.mouseDragged(with: try Self.mouseEvent(
            type: .leftMouseDragged,
            location: source.convert(NSPoint(x: start.x + 8, y: start.y), to: nil),
            window: window,
            clickCount: clickCount
        ))

        #expect(startedEntry == entry)
    }

    @Test("A completed native drag releases ownership before the next duplicate drag")
    func completedDragReleasesOwnershipForNextDuplicate() throws {
        let registry = SessionDragRegistry()
        var startedSources: [SessionDragSessionSource] = []
        let coordinator = SessionDragCoordinator(
            registry: registry,
            startDraggingSession: { _, _, _, source in
                startedSources.append(source)
            }
        )
        let sourceView = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        let event = try Self.mouseEvent(
            type: .leftMouseDown,
            location: NSPoint(x: 20, y: 14),
            windowNumber: 0
        )
        let entry = Self.makeEntry(title: "Repeated duplicate")
        let frame = sourceView.bounds
        let image = NSImage(size: frame.size)

        for expectedStartCount in 1...3 {
            #expect(coordinator.beginSessionDrag(
                entry,
                from: sourceView,
                event: event,
                frame: frame,
                image: image
            ))
            #expect(startedSources.count == expectedStartCount)

            let source = startedSources[expectedStartCount - 1]
            let dragID = source.dragID
            #expect(registry.entry(id: dragID) == entry)
            #expect(source.dragID == dragID)
            #expect(!coordinator.beginSessionDrag(
                entry,
                from: sourceView,
                event: event,
                frame: frame,
                image: image
            ))

            source.finishDrag()
            #expect(registry.entry(id: dragID) == nil)
        }
    }

    private static func makeEntry(title: String) -> SessionEntry {
        SessionEntry(
            id: "codex:/tmp/vault-native-drag/duplicate.jsonl",
            agent: .codex,
            sessionId: "vault-native-drag-duplicate",
            title: title,
            cwd: "/tmp/vault-native-drag",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_000),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try mouseEvent(
            type: type,
            location: location,
            windowNumber: window.windowNumber,
            clickCount: clickCount
        )
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        windowNumber: Int,
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private static func drag(
        _ source: SessionDragSourceView,
        in window: NSWindow,
        from start: NSPoint
    ) throws {
        source.mouseDown(with: try mouseEvent(
            type: .leftMouseDown,
            location: source.convert(start, to: nil),
            window: window
        ))
        source.mouseDragged(with: try mouseEvent(
            type: .leftMouseDragged,
            location: source.convert(
                NSPoint(
                    x: start.x + 8 < source.bounds.maxX ? start.x + 8 : start.x - 8,
                    y: start.y
                ),
                to: nil
            ),
            window: window
        ))
    }
}
