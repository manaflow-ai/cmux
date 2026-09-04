import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SessionIndexTableViewportTests {
    @MainActor
    @Test
    func tableHeightsTrackFontMagnificationWithoutMeasuringOffscreenViews() {
        let section = IndexSection(
            key: .directory("/tmp/vault-scale"),
            title: "vault-scale",
            icon: .folder,
            entries: [Self.makeEntry(index: 0)]
        )
        let row = SessionIndexTableRow.section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            popoverIdentity: nil,
            isCollapsed: false,
            actions: IndexSectionActions(
                onBeginDrag: {},
                beginSessionDrag: { _, _, _, _, _ in false },
                onPreviewEntry: { _ in },
                onDismissPreview: { _ in },
                onResume: nil,
                onOpen: nil,
                search: { _, _, _, _ in .init(entries: [], errors: []) },
                loadSnapshot: { cwd in .init(cwd: cwd ?? "", entries: [], errors: []) }
            ),
            setCollapsed: { _ in },
            setPopoverOpen: { _ in }
        )
        let calculator = SessionIndexTableRowHeightCalculator()
        let standardHeight = calculator.height(
            for: row,
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 100)
        )
        let magnifiedHeight = calculator.height(
            for: row,
            environment: .init(colorScheme: .light, globalFontMagnificationPercent: 200)
        )

        #expect(magnifiedHeight > standardHeight)
    }

    @MainActor
    @Test
    func tableApplyDefersAndCoalescesUntilAfterTheCurrentCallback() async {
        let controller = SessionIndexTableController()
        let container = controller.makeContainerView()
        let actions = SectionGapActions(
            currentDraggedKey: { nil },
            moveSection: { _, _ in },
            clearDraggedKey: {}
        )
        let environment = SessionIndexTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
        let first = SessionIndexTableRow.gap(
            beforeKey: .directory("/tmp/first"),
            isValidDrop: true,
            actions: actions
        )
        let second = SessionIndexTableRow.gap(
            beforeKey: .directory("/tmp/second"),
            isValidDrop: true,
            actions: actions
        )

        controller.apply(rows: [first], environment: environment)
        controller.apply(rows: [first, second], environment: environment)

        #expect(container.tableView.numberOfRows == 0)
        await flushStagedTableMutations()
        #expect(container.tableView.numberOfRows == 2)
    }

    @MainActor
    @Test
    func tableDocumentViewTracksSidebarViewportWidth() throws {
        let controller = SessionIndexTableController()
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        container.layoutSubtreeIfNeeded()

        let table = container.tableView
        let clipView = try #require(table.superview as? NSClipView)
        let column = try #require(table.tableColumns.first)
        #expect(abs(table.frame.width - clipView.bounds.width) < 0.5)

        container.frame.size.width = 480
        container.layoutSubtreeIfNeeded()
        #expect(abs(table.frame.width - clipView.bounds.width) < 0.5)
        #expect(abs(column.width - table.bounds.width) < 0.5)
    }

    @MainActor
    @Test
    func unrelatedPreviewDoesNotInvalidateASectionRow() {
        let section = IndexSection(
            key: .directory("/tmp/vault-scale"),
            title: "vault-scale",
            icon: .folder,
            entries: [Self.makeEntry(index: 0)]
        )
        let actions = IndexSectionActions(
            onBeginDrag: {},
            beginSessionDrag: { _, _, _, _, _ in false },
            onPreviewEntry: { _ in },
            onDismissPreview: { _ in },
            onResume: nil,
            onOpen: nil,
            search: { _, _, _, _ in .init(entries: [], errors: []) },
            loadSnapshot: { cwd in .init(cwd: cwd ?? "", entries: [], errors: []) }
        )
        let withoutPreview = SessionIndexTableRow.section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            popoverIdentity: nil,
            isCollapsed: false,
            actions: actions,
            setCollapsed: { _ in },
            setPopoverOpen: { _ in }
        )
        let unrelatedPreview = SessionIndexTableRow.section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            popoverIdentity: .transcript(
                section: .directory("/tmp/another-section"),
                entry: "claude:/tmp/another-section/session.jsonl"
            ),
            isCollapsed: false,
            actions: actions,
            setCollapsed: { _ in },
            setPopoverOpen: { _ in }
        )

        #expect(withoutPreview.hasEquivalentContent(to: unrelatedPreview))
    }

    @MainActor
    @Test
    func sectionPopoverPresentationDoesNotInvalidateHostedRow() {
        let section = Self.makeSection()
        let closed = Self.makeSectionRow(section: section)
        let open = Self.makeSectionRow(
            section: section,
            popoverIdentity: .section(section.key)
        )

        #expect(closed.hasEquivalentContent(to: open))
    }

    @MainActor
    @Test
    func transcriptPresentationDoesNotInvalidateHostedRow() throws {
        let section = Self.makeSection()
        let entry = try #require(section.entries.first)
        let closed = Self.makeSectionRow(section: section)
        let open = Self.makeSectionRow(
            section: section,
            popoverIdentity: .transcript(section: section.key, entry: entry.id)
        )

        #expect(closed.hasEquivalentContent(to: open))
    }

    @MainActor
    @Test
    func presentationForAnotherSectionIsIgnored() {
        let section = Self.makeSection()
        let row = Self.makeSectionRow(
            section: section,
            popoverIdentity: .section(.directory("/tmp/another-section"))
        )

        #expect(row.popoverPresentation == nil)
        #expect(row.containedPreviewEntryID == nil)
    }

    @MainActor
    @Test
    func tablePopoverUsesControlAnchorAndClosesWhenAnchorRowRecycles() async throws {
        var dismissalCount = 0
        let presenter = SessionIndexTablePopoverPresenter()
        let controller = SessionIndexTableController(popoverPresenter: presenter)
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 180)

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)

        let targetSection = Self.makeSection()
        let targetIdentity = SessionIndexTablePopoverIdentity.section(targetSection.key)
        let openTargetRow = Self.makeSectionRow(
            section: targetSection,
            popoverIdentity: targetIdentity,
            onSetPopoverOpen: { isOpen in
                if !isOpen {
                    dismissalCount += 1
                }
            }
        )
        let closedTargetRow = Self.makeSectionRow(
            section: targetSection,
            onSetPopoverOpen: { _ in }
        )
        let gapActions = SectionGapActions(
            currentDraggedKey: { nil },
            moveSection: { _, _ in },
            clearDraggedKey: {}
        )
        var openRows: [SessionIndexTableRow] = [
            .gap(beforeKey: targetSection.key, isValidDrop: true, actions: gapActions),
            openTargetRow,
        ]
        for index in 1..<12 {
            let section = IndexSection(
                key: .directory("/tmp/vault-presentation-\(index)"),
                title: "vault-presentation-\(index)",
                icon: .folder,
                entries: [Self.makeEntry(index: index)]
            )
            openRows.append(.gap(
                beforeKey: section.key,
                isValidDrop: true,
                actions: gapActions
            ))
            openRows.append(Self.makeSectionRow(section: section))
        }
        openRows.append(.gap(beforeKey: nil, isValidDrop: true, actions: gapActions))

        let environment = SessionIndexTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )
        controller.apply(rows: openRows, environment: environment)
        await flushStagedTableMutations()
        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        await flushStagedTableMutations()

        let table = container.tableView
        let targetRowIndex = 1
        let targetCell = try #require(table.view(
            atColumn: 0,
            row: targetRowIndex,
            makeIfNecessary: false
        ) as? SessionIndexTableCellView)
        let anchorRect = try #require(targetCell.popoverAnchorRect(for: targetIdentity))
        #expect(anchorRect.height > 0)
        #expect(anchorRect.height < targetCell.bounds.height)
        #expect(anchorRect.minY >= targetCell.bounds.minY - 0.5)
        #expect(anchorRect.maxY <= targetCell.bounds.maxY + 0.5)
        #expect(presenter.isPopoverShown)

        table.scrollRowToVisible(openRows.count - 1)
        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        await flushStagedTableMutations()

        #expect(table.view(
            atColumn: 0,
            row: targetRowIndex,
            makeIfNecessary: false
        ) == nil)
        #expect(dismissalCount == 1)
        #expect(!presenter.isPopoverShown)

        var closedRows = openRows
        closedRows[targetRowIndex] = closedTargetRow
        controller.apply(rows: closedRows, environment: environment)
        await flushStagedTableMutations()
        table.scrollRowToVisible(targetRowIndex)
        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        await flushStagedTableMutations()

        #expect(!presenter.isPopoverShown)
    }

    @MainActor
    @Test
    func transcriptPopoverStoresTheClickedSessionRowAnchor() async throws {
        let presenter = SessionIndexTablePopoverPresenter()
        let controller = SessionIndexTableController(popoverPresenter: presenter)
        let container = controller.makeContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 320, height: 220)

        let window = NSWindow(
            contentRect: container.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            presenter.dismiss()
            window.orderOut(nil)
        }
        window.makeKeyAndOrderFront(nil)

        let entries = (0..<3).map(Self.makeEntry)
        let section = IndexSection(
            key: .directory("/tmp/vault-transcript-anchor"),
            title: "vault-transcript-anchor",
            icon: .folder,
            entries: entries
        )
        let selectedIdentity = SessionIndexTablePopoverIdentity.transcript(
            section: section.key,
            entry: entries[2].id
        )
        let row = Self.makeSectionRow(
            section: section,
            popoverIdentity: selectedIdentity
        )
        let gapActions = SectionGapActions(
            currentDraggedKey: { nil },
            moveSection: { _, _ in },
            clearDraggedKey: {}
        )
        let rows: [SessionIndexTableRow] = [
            .gap(beforeKey: section.key, isValidDrop: true, actions: gapActions),
            row,
            .gap(beforeKey: nil, isValidDrop: true, actions: gapActions),
        ]
        let environment = SessionIndexTableEnvironmentSnapshot(
            colorScheme: .light,
            globalFontMagnificationPercent: 100
        )

        controller.apply(rows: rows, environment: environment)
        await flushStagedTableMutations()
        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()
        await flushStagedTableMutations()

        let table = container.tableView
        let cell = try #require(table.view(
            atColumn: 0,
            row: 1,
            makeIfNecessary: false
        ) as? SessionIndexTableCellView)
        let firstRect = try #require(cell.popoverAnchorRect(for: .transcript(
            section: section.key,
            entry: entries[0].id
        )))
        let selectedRect = try #require(cell.popoverAnchorRect(for: selectedIdentity))
        let selectedAnchorView = try #require(
            cell.popoverAnchorView(for: selectedIdentity)
        )
        let nativeAnchorRect = selectedAnchorView.convert(
            selectedAnchorView.bounds,
            to: cell
        )

        // The cell is unflipped, so a lower visual row has a smaller AppKit
        // y-coordinate even though SwiftUI's top-left coordinate increases.
        #expect(selectedRect.midY < firstRect.midY)
        #expect(selectedRect.maxY <= cell.bounds.maxY + 0.5)
        #expect(selectedRect.minY >= cell.bounds.minY - 0.5)
        #expect(selectedAnchorView.bounds.height > 0)
        #expect(selectedAnchorView.isDescendant(of: cell))
        #expect(abs(nativeAnchorRect.midY - selectedRect.midY) < 0.5)
        #expect(presenter.isAnchored(in: selectedAnchorView))
        #expect(presenter.isPopoverShown)
    }

    @MainActor
    @Test
    func vaultUsesViewportBoundedAppKitRowsAtScale() async throws {
        let defaults = SessionIndexDefaultsSnapshot()
        defer { defaults.restore() }

        let store = SessionIndexStore()
        store.grouping = .directory
        store.directoryOrder = []
        store.replaceEntriesForTesting(
            (0..<46).map(Self.makeEntry)
        )

        let host = NSHostingView(
            rootView: SessionIndexView(
                store: store,
                onResume: nil,
                onOpen: nil
            )
                .frame(width: 320, height: 300)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        await flushStagedTableMutations()
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        let table = try #require(host.firstDescendant(of: NSTableView.self))
        let visibleRows = table.rows(in: table.visibleRect)
        let realizedRows = (0..<table.numberOfRows).filter { row in
            table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil
        }

        #expect(table.numberOfRows >= 46)
        #expect(visibleRows.length > 0)
        #expect(table.numberOfRows > visibleRows.length)
        #expect(realizedRows.count <= visibleRows.length + 2)
    }

    @MainActor
    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private static func makeEntry(index: Int) -> SessionEntry {
        SessionEntry(
            id: "claude:/tmp/vault-scale/session-\(index).jsonl",
            agent: .claude,
            sessionId: "session-\(index)",
            title: "Synthetic session \(index)",
            cwd: "/tmp/vault-scale/project-\(index)",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
    }

    private static func makeSection() -> IndexSection {
        IndexSection(
            key: .directory("/tmp/vault-presentation"),
            title: "vault-presentation",
            icon: .folder,
            entries: [makeEntry(index: 0)]
        )
    }

    @MainActor
    private static func makeSectionRow(
        section: IndexSection,
        popoverIdentity: SessionIndexTablePopoverIdentity? = nil,
        onSetPopoverOpen: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> SessionIndexTableRow {
        SessionIndexTableRow.section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            popoverIdentity: popoverIdentity,
            isCollapsed: false,
            actions: IndexSectionActions(
                onBeginDrag: {},
                beginSessionDrag: { _, _, _, _, _ in false },
                onPreviewEntry: { _ in },
                onDismissPreview: { _ in },
                onResume: nil,
                onOpen: nil,
                search: { _, _, _, _ in .init(entries: [], errors: []) },
                loadSnapshot: { cwd in .init(cwd: cwd ?? "", entries: [], errors: []) }
            ),
            setCollapsed: { _ in },
            setPopoverOpen: onSetPopoverOpen
        )
    }
}

private struct SessionIndexDefaultsSnapshot {
    private let values: [(key: String, value: Any?)]

    init(defaults: UserDefaults = .standard) {
        values = Self.keys.map { key in (key, defaults.object(forKey: key)) }
    }

    func restore(defaults: UserDefaults = .standard) {
        for item in values {
            if let value = item.value {
                defaults.set(value, forKey: item.key)
            } else {
                defaults.removeObject(forKey: item.key)
            }
        }
    }

    private static let keys = [
        "sessionIndex.agentOrder",
        "sessionIndex.directoryOrder",
        "sessionIndex.grouping",
    ]
}

private extension NSView {
    func firstDescendant<ViewType: NSView>(of type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
