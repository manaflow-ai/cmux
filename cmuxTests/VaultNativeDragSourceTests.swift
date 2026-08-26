import AppKit
import Bonsplit
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
    @Test("Hosted duplicate rows remain draggable after their AppKit cell recycles")
    func hostedDuplicateRowsRemainDraggableAfterCellReuse() async throws {
        let duplicate = Self.makeEntry(title: "Repeated hosted duplicate")
        let distinct = Self.makeEntry(
            title: "Distinct hosted row",
            identifier: "distinct"
        )
        var startedEntries: [SessionEntry] = []
        let actions = IndexSectionActions(
            onBeginDrag: {},
            beginSessionDrag: { entry, _, _, _, _ in
                startedEntries.append(entry)
                return true
            },
            onPreviewEntry: { _ in },
            onDismissPreview: { _ in },
            onResume: nil,
            search: { _, _, _, _ in .init(entries: [], errors: []) },
            loadSnapshot: { cwd in
                .init(cwd: cwd ?? "", entries: [], errors: [])
            }
        )
        let duplicateSection = IndexSection(
            key: .directory("/tmp/vault-native-drag/duplicate-section"),
            title: "duplicate-section",
            icon: .folder,
            entries: [duplicate, duplicate, distinct]
        )
        var tableRows = [Self.tableRow(section: duplicateSection, actions: actions)]
        for index in 0..<12 {
            let entry = Self.makeEntry(
                title: "Recycling filler \(index)",
                identifier: "filler-\(index)"
            )
            tableRows.append(Self.tableRow(
                section: IndexSection(
                    key: .directory("/tmp/vault-native-drag/filler-\(index)"),
                    title: "filler-\(index)",
                    icon: .folder,
                    entries: [entry]
                ),
                actions: actions
            ))
        }

        let controller = SessionIndexTableController()
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            controller.dismantle()
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)

        controller.apply(
            rows: tableRows,
            environment: .init(
                colorScheme: .light,
                globalFontMagnificationPercent: 100
            )
        )
        await Self.flushStagedTableMutations()
        Self.layout(window: window, container: container)

        let table = container.tableView
        try Self.dragHostedSources(
            in: table,
            row: 0,
            window: window,
            expectedEntries: [duplicate, duplicate, distinct]
        )
        #expect(
            startedEntries.sorted(by: Self.entryTitleAscending)
                == [duplicate, duplicate, distinct].sorted(by: Self.entryTitleAscending)
        )

        table.scrollRowToVisible(tableRows.count - 1)
        Self.layout(window: window, container: container)
        #expect(table.view(atColumn: 0, row: 0, makeIfNecessary: false) == nil)

        startedEntries.removeAll()
        table.scrollRowToVisible(0)
        Self.layout(window: window, container: container)
        try Self.dragHostedSources(
            in: table,
            row: 0,
            window: window,
            expectedEntries: [duplicate, duplicate, distinct]
        )
        #expect(
            startedEntries.sorted(by: Self.entryTitleAscending)
                == [duplicate, duplicate, distinct].sorted(by: Self.entryTitleAscending)
        )
    }

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
        let tabDragTransferRegistry = TabDragTransferRegistry()
        var startedSources: [SessionDragSessionSource] = []
        let coordinator = SessionDragCoordinator(
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
                registry: registry,
                tabDragTransferRegistry: tabDragTransferRegistry,
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
                registry: registry,
                tabDragTransferRegistry: tabDragTransferRegistry,
                from: sourceView,
                event: event,
                frame: frame,
                image: image
            ))

            source.finishDrag()
            #expect(registry.entry(id: dragID) == nil)
        }
    }

    private static func makeEntry(
        title: String,
        identifier: String = "duplicate"
    ) -> SessionEntry {
        SessionEntry(
            id: "codex:/tmp/vault-native-drag/\(identifier).jsonl",
            agent: .codex,
            sessionId: "vault-native-drag-\(identifier)",
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

    private static func tableRow(
        section: IndexSection,
        actions: IndexSectionActions
    ) -> SessionIndexTableRow {
        .section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            popoverIdentity: nil,
            isCollapsed: false,
            actions: actions,
            setCollapsed: { _ in },
            setPopoverOpen: { _ in }
        )
    }

    private static func dragHostedSources(
        in table: NSTableView,
        row: Int,
        window: NSWindow,
        expectedEntries: [SessionEntry]
    ) throws {
        let cell = try #require(table.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false
        ) as? SessionIndexTableCellView)
        let sources = cell.descendants(of: SessionDragSourceView.self).sorted {
            $0.convert(.zero, to: cell).y < $1.convert(.zero, to: cell).y
        }
        #expect(
            sources.map(\.entry).sorted(by: entryTitleAscending)
                == expectedEntries.sorted(by: entryTitleAscending)
        )
        #expect(Set(sources.map { ObjectIdentifier($0) }).count == expectedEntries.count)
        for source in sources {
            #expect(source.bounds.width > 8)
            #expect(source.bounds.height > 0)
            try drag(
                source,
                in: window,
                from: NSPoint(x: 4, y: source.bounds.midY)
            )
        }
    }

    private static func layout(
        window: NSWindow,
        container: SessionIndexTableContainerView
    ) {
        container.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private static func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private static func entryTitleAscending(_ lhs: SessionEntry, _ rhs: SessionEntry) -> Bool {
        lhs.title < rhs.title
    }
}

private extension NSView {
    func descendants<ViewType: NSView>(of type: ViewType.Type) -> [ViewType] {
        var matches: [ViewType] = []
        if let match = self as? ViewType {
            matches.append(match)
        }
        for subview in subviews {
            matches.append(contentsOf: subview.descendants(of: type))
        }
        return matches
    }
}
