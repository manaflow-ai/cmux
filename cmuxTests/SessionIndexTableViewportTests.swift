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
            previewEntryId: nil,
            isCollapsed: false,
            isPopoverOpen: false,
            actions: IndexSectionActions(
                onBeginDrag: {},
                onPreviewEntry: { _ in },
                onDismissPreview: { _ in },
                onResume: nil,
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
    func unrelatedPreviewDoesNotInvalidateASectionRow() {
        let section = IndexSection(
            key: .directory("/tmp/vault-scale"),
            title: "vault-scale",
            icon: .folder,
            entries: [Self.makeEntry(index: 0)]
        )
        let actions = IndexSectionActions(
            onBeginDrag: {},
            onPreviewEntry: { _ in },
            onDismissPreview: { _ in },
            onResume: nil,
            search: { _, _, _, _ in .init(entries: [], errors: []) },
            loadSnapshot: { cwd in .init(cwd: cwd ?? "", entries: [], errors: []) }
        )
        let withoutPreview = SessionIndexTableRow.section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            previewEntryId: nil,
            isCollapsed: false,
            isPopoverOpen: false,
            actions: actions,
            setCollapsed: { _ in },
            setPopoverOpen: { _ in }
        )
        let unrelatedPreview = SessionIndexTableRow.section(
            section: section,
            rowLimit: 5,
            isDragged: false,
            previewEntryId: "claude:/tmp/another-section/session.jsonl",
            isCollapsed: false,
            isPopoverOpen: false,
            actions: actions,
            setCollapsed: { _ in },
            setPopoverOpen: { _ in }
        )

        #expect(withoutPreview.hasEquivalentContent(to: unrelatedPreview))
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
            rootView: SessionIndexView(store: store, onResume: nil)
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
