import AppKit
import Bonsplit
import CmuxPanes
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A split must move the source terminal's portal view in the same
/// transaction as the bonsplit tree update. The hosted view is a transparent
/// glyph layer above SwiftUI, so a view left at its pre-split frame paints the
/// source pane's content over the new pane's tab bar and content until SwiftUI
/// re-hosts the pane (https://github.com/manaflow-ai/cmux/issues/13387).
@MainActor
@Suite(.serialized)
struct WorkspaceSplitProvisionalGeometryTests {
    @Test func rootSplitAddsAFullHeightSiblingToTheExistingTree() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let firstSplit = try #require(fixture.workspace.newTerminalSplit(
            from: fixture.sourcePanelId,
            orientation: .vertical,
            focus: false
        ))
        _ = try #require(fixture.workspace.newTerminalSplit(
            from: firstSplit.id,
            orientation: .horizontal,
            focus: false
        ))

        let rootSplit = try #require(fixture.workspace.newTerminalRootSplit(
            direction: .right,
            focus: false
        ))

        guard case .split(let root) = fixture.workspace.bonsplitController.treeSnapshot() else {
            return Issue.record("Expected a root split")
        }
        guard case .split = root.first,
              case .pane(let newPane) = root.second else {
            return Issue.record("Expected the existing tree to remain the first root child")
        }
        #expect(root.orientation == SplitOrientation.horizontal.rawValue)
        #expect(newPane.tabs.contains { $0.id == rootSplit.id.uuidString })
    }

    @Test func rootSplitProjectsEveryExistingTerminalIntoTheShrunkenTree() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let firstSplit = try #require(fixture.workspace.newTerminalSplit(
            from: fixture.sourcePanelId,
            orientation: .vertical,
            focus: false
        ))
        let sibling = try #require(fixture.workspace.terminalPanel(for: firstSplit.id))
        let siblingAnchor = NSView(frame: fixture.anchor.frame)
        fixture.window.contentView?.addSubview(siblingAnchor)
        sibling.hostedView.setVisibleInUI(true)
        TerminalWindowPortalRegistry.bind(hostedView: sibling.hostedView, to: siblingAnchor, visibleInUI: true)
        try #require(TerminalWindowPortalRegistry.isPresented(sibling.hostedView))
        defer {
            TerminalWindowPortalRegistry.detach(hostedView: sibling.hostedView)
            siblingAnchor.removeFromSuperview()
        }

        let beforeSource = fixture.sourceFrameInWindow()
        let beforeSibling = sibling.hostedView.convert(sibling.hostedView.bounds, to: nil)
        let oldTreeFrame = beforeSource.union(beforeSibling)
        _ = try #require(fixture.workspace.newTerminalRootSplit(direction: .right, focus: false))

        let newPaneRegion = Fixture.newPaneRegion(of: oldTreeFrame, direction: .right)
        let afterSource = fixture.sourceFrameInWindow()
        let afterSibling = sibling.hostedView.convert(sibling.hostedView.bounds, to: nil)
        #expect(!afterSource.intersects(newPaneRegion))
        #expect(!afterSibling.intersects(newPaneRegion))
        #expect(afterSibling.width < beforeSibling.width * 0.7)
    }

    @Test(arguments: [SplitDirection.down, .up, .right, .left])
    func splitMovesSourceTerminalOutOfTheNewPaneInTheSameTransaction(direction: SplitDirection) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let before = fixture.sourceFrameInWindow()
        #expect(before.width > 200 && before.height > 200)

        let outcome = fixture.workspace.newTerminalSplitOutcome(
            from: fixture.sourcePanelId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: false
        )
        #expect(outcome.isAccepted)

        // Read back synchronously: no run-loop turn, SwiftUI update, or AppKit
        // layout has run, which is exactly the state the first commit after
        // the split paints.
        let after = fixture.sourceFrameInWindow()
        let newPaneRegion = Fixture.newPaneRegion(of: before, direction: direction)
        #expect(
            !after.intersects(newPaneRegion),
            "source terminal still covers the new pane after \(direction): \(after) intersects \(newPaneRegion)"
        )
        #expect(after.width > 24 && after.height > 18, "source terminal collapsed: \(after)")
        switch direction {
        case .down:
            #expect(abs(after.maxY - before.maxY) < 0.5, "top edge moved: \(after) vs \(before)")
            #expect(abs(after.width - before.width) < 0.5)
        case .up:
            #expect(abs(after.minY - before.minY) < 0.5, "bottom edge moved: \(after) vs \(before)")
            #expect(abs(after.width - before.width) < 0.5)
        case .right:
            #expect(abs(after.minX - before.minX) < 0.5, "leading edge moved: \(after) vs \(before)")
            #expect(abs(after.height - before.height) < 0.5)
        case .left:
            #expect(abs(after.maxX - before.maxX) < 0.5, "trailing edge moved: \(after) vs \(before)")
            #expect(abs(after.height - before.height) < 0.5)
        }
    }

    /// A split that leaves the model again before SwiftUI rendered it must not
    /// leave the source terminal at its projected half frame: the anchor, which
    /// never moved, is the truth again as soon as the split is gone.
    @Test func closingTheSplitBeforeItRendersHandsGeometryBackToTheAnchor() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let before = fixture.sourceFrameInWindow()

        let outcome = fixture.workspace.newTerminalSplitOutcome(
            from: fixture.sourcePanelId, orientation: .vertical, insertFirst: false, focus: false
        )
        let newPanel = try #require(outcome.panel)
        #expect(fixture.sourceFrameInWindow().height < before.height * 0.6)

        #expect(fixture.workspace.closePanel(newPanel.id, force: true))

        let after = fixture.sourceFrameInWindow()
        #expect(abs(after.minY - before.minY) < 0.5 && abs(after.height - before.height) < 0.5, "\(after) vs \(before)")
        #expect(TerminalWindowPortalRegistry.provisionalPaneGeometry(for: fixture.hosted) == nil)
    }

    /// Hosts one workspace terminal through the real window portal, the way
    /// the app does once SwiftUI has bound its anchor.
    @MainActor
    private final class Fixture {
        /// Tab bar plus divider slack: the new pane's region is measured with
        /// this margin from the pre-split midline so the assertion tracks the
        /// contract, not bonsplit's exact chrome metrics.
        static let chromeMargin: CGFloat = 40

        private let testWorkspace: TerminalPortalTestWorkspace
        let window: NSWindow
        let anchor: NSView
        let sourcePanelId: UUID
        let hosted: GhosttySurfaceScrollView
        var workspace: Workspace { testWorkspace.workspace }

        init() throws {
            testWorkspace = TerminalPortalTestWorkspace()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            anchor = NSView(frame: NSRect(x: 20, y: 20, width: 600, height: 360))
            window.contentView?.addSubview(anchor)

            let workspace = testWorkspace.workspace
            sourcePanelId = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: sourcePanelId))
            hosted = panel.hostedView
            hosted.setVisibleInUI(true)
            TerminalWindowPortalRegistry.bind(hostedView: hosted, to: anchor, visibleInUI: true)
            try #require(TerminalWindowPortalRegistry.isPresented(hosted), "terminal was not presented by the portal")
        }

        func sourceFrameInWindow() -> NSRect {
            hosted.convert(hosted.bounds, to: nil)
        }

        /// The part of the pre-split content rect that belongs to the new
        /// pane, inset from the midline by the chrome margin.
        static func newPaneRegion(of before: NSRect, direction: SplitDirection) -> NSRect {
            switch direction {
            case .down:
                return NSRect(
                    x: before.minX, y: before.minY,
                    width: before.width, height: before.height / 2 - chromeMargin
                )
            case .up:
                return NSRect(
                    x: before.minX, y: before.midY + chromeMargin,
                    width: before.width, height: before.height / 2 - chromeMargin
                )
            case .right:
                return NSRect(
                    x: before.midX + chromeMargin, y: before.minY,
                    width: before.width / 2 - chromeMargin, height: before.height
                )
            case .left:
                return NSRect(
                    x: before.minX, y: before.minY,
                    width: before.width / 2 - chromeMargin, height: before.height
                )
            }
        }

        func close() {
            TerminalWindowPortalRegistry.detach(hostedView: hosted)
            window.close()
            testWorkspace.tearDown()
        }
    }
}
