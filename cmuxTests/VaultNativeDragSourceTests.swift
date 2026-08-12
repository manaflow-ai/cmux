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
    @Test("Every duplicate row can repeatedly initiate a native drag")
    func duplicateRowsCanRepeatedlyInitiateNativeDrags() throws {
        let first = Self.makeEntry(title: "First rendered occurrence")
        let second = Self.makeEntry(title: "Second rendered occurrence")
        let rows = SessionIndexRowSnapshot.rows(for: [first, second])
        let regions = SessionDragRegionStore()
        regions.update(rows[0], frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        regions.update(rows[1], frame: NSRect(x: 0, y: 28, width: 240, height: 28))

        var startedEntries: [SessionEntry] = []
        let monitor = SessionDragMonitorView(
            frame: NSRect(x: 0, y: 0, width: 240, height: 80),
            regions: regions
        ) { entry, _, _, _, _ in
            startedEntries.append(entry)
            return true
        }
        let window = NSWindow(
            contentRect: monitor.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = monitor
        defer { window.orderOut(nil) }

        for point in [NSPoint(x: 40, y: 14), NSPoint(x: 40, y: 42)] {
            let mouseDown = try Self.mouseEvent(
                type: .leftMouseDown,
                location: monitor.convert(point, to: nil),
                window: window
            )
            let mouseDragged = try Self.mouseEvent(
                type: .leftMouseDragged,
                location: monitor.convert(
                    NSPoint(x: point.x + 8, y: point.y),
                    to: nil
                ),
                window: window
            )

            _ = monitor.handleEvent(mouseDown)
            _ = monitor.handleEvent(mouseDragged)
        }

        #expect(startedEntries.map(\.title) == [first.title, second.title])
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
            #expect(coordinator.hasActiveSession)
            #expect(startedSources.count == expectedStartCount)

            let dragID = try #require(registry.activeDragID)
            #expect(registry.entry(id: dragID) == entry)
            let source = startedSources[expectedStartCount - 1]
            #expect(source.dragID == dragID)

            source.finishDrag()
            #expect(!coordinator.hasActiveSession)
            #expect(registry.activeDragID == nil)
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
        window: NSWindow
    ) throws -> NSEvent {
        try mouseEvent(
            type: type,
            location: location,
            windowNumber: window.windowNumber
        )
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        windowNumber: Int
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
