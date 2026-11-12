import AppKit
import CmuxWorkspaces
import Testing
@testable import cmux_DEV

#if DEBUG
@Suite(.serialized)
@MainActor
struct SidebarWorkspaceRowRetirementTests {
    @Test
    func tableRetirementInvalidatesDescriptionLinkAccessibility() async throws {
        let url = try #require(URL(string: "https://cmux.com"))
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: "[cmux](\(url.absoluteString))"
        )
        let mounted = try await mount(
            model: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model)
        )
        defer { mounted.window.close() }
        let textView = try #require(
            descendants(of: mounted.cell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { $0.attributedStringValue.string == "cmux" }
        )
        let accessibilityLink = try #require(
            (textView.accessibilityChildren() ?? [])
                .compactMap { $0 as? SidebarRowTextAccessibilityLink }
                .first { $0.accessibilityURL() == url }
        )
        #expect(accessibilityLink.accessibilityParent() != nil)
        #expect(!accessibilityLink.accessibilityFrameInParentSpace().isEmpty)

        await removeMountedRow(mounted)

        #expect(textView.attributedStringValue.length == 0)
        #expect(accessibilityLink.accessibilityParent() == nil)
        #expect(accessibilityLink.accessibilityFrameInParentSpace().isEmpty)
        #expect(!accessibilityLink.accessibilityPerformPress())
    }

    @Test
    func tableRetirementClosesStatusPopover() async throws {
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(manualTaskStatus: .working)
        let mounted = try await mount(
            model: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model)
        )
        defer { mounted.window.close() }
        let glyph = try #require(
            descendants(of: mounted.cell)
                .compactMap { $0 as? SidebarRowTaskStatusGlyphButton }
                .first { !$0.isHidden }
        )
        let existingWindowIds = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        #expect(glyph.accessibilityPerformPress())
        let popoverWindow = try #require(
            NSApplication.shared.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0)) && $0.isVisible
            }
        )

        let popoverCloseWaiter = SidebarPopoverCloseWaiter(window: popoverWindow)
        await removeMountedRow(mounted)
        await popoverCloseWaiter.wait()

        #expect(!popoverWindow.isVisible)
    }

    @Test
    func tableRetirementClosesChecklistPopover() async throws {
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(
            checklistItems: [WorkspaceChecklistItem(text: "Draft")],
            isChecklistPopoverPresented: true,
            checklistStyle: .popover
        )
        let existingWindowIds = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let mounted = try await mount(
            model: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model)
        )
        defer { mounted.window.close() }
        let popoverWindow = try #require(
            NSApplication.shared.windows.first {
                !existingWindowIds.contains(ObjectIdentifier($0))
                    && $0 !== mounted.window
                    && $0.isVisible
            }
        )

        let popoverCloseWaiter = SidebarPopoverCloseWaiter(window: popoverWindow)
        await removeMountedRow(mounted)
        await popoverCloseWaiter.wait()

        #expect(!popoverWindow.isVisible)
    }

    @Test
    func retiredTrackingMenuDoesNotBlockHoveringReplacementRow() async throws {
        let model = SidebarWorkspaceRowSuspensionTests.makeModel()
        let mounted = try await mount(
            model: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model)
        )
        defer { mounted.window.close() }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: mounted.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try #require(mounted.cell.menu(for: event) as? SidebarRowTrackedMenu)
        menu.menuWillOpen(menu)

        await removeMountedRow(mounted)
        menu.menuDidClose(menu)

        let replacement = SidebarWorkspaceRowSuspensionTests.makeModel()
        mounted.controller.apply(
            rows: [makeRowConfiguration(
                model: replacement,
                actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: replacement)
            )],
            actions: mounted.tableActions,
            workspaceIds: [replacement.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        mounted.container.layoutSubtreeIfNeeded()
        mounted.container.tableView.layoutSubtreeIfNeeded()

        let replacementCell = try #require(
            mounted.container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView
        )
        var applies = 0
        replacementCell.applyModelProbeForTesting = { _ in applies += 1 }
        let rowRect = mounted.container.tableView.rect(ofRow: 0)
        let windowPoint = mounted.container.tableView.convert(
            NSPoint(x: rowRect.midX, y: rowRect.midY),
            to: nil
        )
        mounted.container.tableView.setPointerWindowLocation(windowPoint)

        #expect(applies > 0, "A retired menu must not suppress hover on replacement rows.")
    }

    /// Closing one workspace must not rebuild the other rows: reloadData
    /// retired every visible cell, committing rename/checklist drafts and
    /// closing popovers on unrelated rows.
    @Test
    func closingOneWorkspaceKeepsSurvivingRowCells() async throws {
        let models = (0..<3).map { _ in SidebarWorkspaceRowSuspensionTests.makeModel() }
        let rows = models.map {
            makeRowConfiguration(model: $0, actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: $0))
        }
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let tableActions = makeTableActions()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFront(nil)
        defer { window.close() }

        func apply(_ rows: [SidebarWorkspaceTableRowConfiguration]) async {
            controller.apply(
                rows: rows,
                actions: tableActions,
                workspaceIds: rows.compactMap { $0.appKitWorkspaceRowModel?.workspaceId },
                selectedWorkspaceId: nil,
                selectedScrollTargetWorkspaceId: nil
            )
            await flushStagedTableMutations()
            container.layoutSubtreeIfNeeded()
            container.tableView.layoutSubtreeIfNeeded()
        }
        func cell(at row: Int) -> NSView? {
            container.tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
        }

        await apply(rows)
        let first = try #require(cell(at: 0))
        let third = try #require(cell(at: 2))

        await apply([rows[0], rows[2]])

        #expect(container.tableView.numberOfRows == 2)
        #expect(cell(at: 0) === first)
        #expect(cell(at: 1) === third)
    }

    @Test
    func rowEditClassifiesOnlyOrderPreservingDropsAndAdds() {
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 2, 3], to: [1, 3]) == .remove([1]))
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 2, 3, 4], to: [2, 4]) == .remove([0, 2]))
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 3], to: [1, 2, 3, 4]) == .insert([1, 3]))
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 2], to: []) == .remove([0, 1]))
        // Reorders, mixed edits, no-ops, and duplicate ids keep the reload path.
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 2, 3], to: [3, 1]) == nil)
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 2, 3], to: [1, 4]) == nil)
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 2], to: [1, 2]) == nil)
        #expect(SidebarWorkspaceTableRowEdit(from: [1, 1, 2], to: [1, 2]) == nil)
    }

    private func mount(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) async throws -> (
        controller: SidebarWorkspaceTableController,
        container: SidebarWorkspaceTableContainerView,
        window: NSWindow,
        tableActions: SidebarWorkspaceTableActions,
        cell: SidebarWorkspaceRowTableCellView
    ) {
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let tableActions = makeTableActions()
        let row = makeRowConfiguration(model: model, actions: actions)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFront(nil)
        controller.apply(
            rows: [row],
            actions: tableActions,
            workspaceIds: [model.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        container.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()
        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView
        )
        cell.layoutSubtreeIfNeeded()
        return (controller, container, window, tableActions, cell)
    }

    private func makeRowConfiguration(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions
    ) -> SidebarWorkspaceTableRowConfiguration {
        SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: actions,
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
    }

    private func removeMountedRow(_ mounted: (
        controller: SidebarWorkspaceTableController,
        container: SidebarWorkspaceTableContainerView,
        window: NSWindow,
        tableActions: SidebarWorkspaceTableActions,
        cell: SidebarWorkspaceRowTableCellView
    )) async {
        mounted.controller.apply(
            rows: [],
            actions: mounted.tableActions,
            workspaceIds: [],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await flushStagedTableMutations()
        mounted.container.tableView.layoutSubtreeIfNeeded()
    }

    private func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in }, closeWorkspace: { _ in }, createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {}, beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 }, endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true }, updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false }, commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {}, currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw }, canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil }, didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {}, setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

@MainActor
private final class SidebarPopoverCloseWaiter: NSObject {
    private let window: NSWindow
    private var didClose = false
    private var waitContinuation: CheckedContinuation<Void, Never>?

    init(window: NSWindow) {
        self.window = window
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popoverDidClose(_:)),
            name: NSPopover.didCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func wait() async {
        guard window.isVisible, !didClose else {
            finish()
            return
        }
        await withCheckedContinuation { continuation in
            guard window.isVisible, !didClose else {
                finish()
                continuation.resume()
                return
            }
            precondition(waitContinuation == nil)
            waitContinuation = continuation
        }
    }

    @objc
    private func popoverDidClose(_ notification: Notification) {
        // AppKit still has the popover content attached when it posts
        // `didClose`; use that stable relationship to reject unrelated
        // popovers, then let its backing-window visibility settle after the
        // notification-delivery turn.
        guard let popover = notification.object as? NSPopover,
              popover.contentViewController?.view.window === window
        else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish()
            }
        }
    }

    private func finish() {
        guard !didClose else { return }
        didClose = true
        NotificationCenter.default.removeObserver(self)
        waitContinuation?.resume()
        waitContinuation = nil
    }
}
#endif
