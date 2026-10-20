import AppKit
import Bonsplit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `SplitPaneGeometryProjection` mirrors the divider placement bonsplit's
/// `SplitContainerView.Coordinator` performs. This suite renders real splits
/// through `BonsplitView` and checks the projected first extent against the
/// `NSSplitView` AppKit actually laid out, so a change to bonsplit's rounding,
/// clamping, or divider rules fails here instead of drifting silently
/// (https://github.com/manaflow-ai/cmux/issues/13387).
@MainActor
@Suite(.serialized)
struct SplitPaneGeometryProjectionRenderParityTests {
    struct Case: Sendable {
        let direction: CmuxSplitDirection
        let split: Double
    }

    @Test(arguments: [
        Case(direction: .horizontal, split: 0.5),
        Case(direction: .horizontal, split: 0.33),
        Case(direction: .horizontal, split: 0.875),
        Case(direction: .vertical, split: 0.5),
        Case(direction: .vertical, split: 0.2),
    ])
    func projectedFirstExtentMatchesTheRenderedSplitView(testCase: Case) async throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        workspace.applyCustomLayout(
            .split(CmuxSplitDefinition(
                direction: testCase.direction,
                split: testCase.split,
                children: [
                    .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal, name: "First")])),
                    .pane(CmuxPaneDefinition(surfaces: [CmuxSurfaceDefinition(type: .terminal, name: "Second")])),
                ]
            )),
            baseCwd: NSTemporaryDirectory()
        )
        let split = try #require(Self.firstSplit(in: workspace.bonsplitController.treeSnapshot()))

        let hostingView = NSHostingView(
            rootView: BonsplitView(controller: workspace.bonsplitController) { _, _ in
                Color.clear
            } emptyPane: { _ in
                Color.clear
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let contentView = try #require(window.contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        window.makeKeyAndOrderFront(nil)

        let splitView = try await Self.settledSplitView(in: hostingView, contentView: contentView)
        let isHorizontal = split.orientation == SplitOrientation.horizontal.rawValue
        let renderedFirstExtent = isHorizontal
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height

        // Feed the projection a pane whose container is exactly the split
        // view's extent: the tab strip above the content counts toward the
        // container, and the horizontal axis has no strip at all.
        let configuration = workspace.bonsplitController.configuration
        let tabBarHeight = configuration.appearance.tabBarHeight
        let content = CGRect(
            x: 0, y: 0,
            width: splitView.bounds.width,
            height: splitView.bounds.height - tabBarHeight
        )
        let projection = try #require(SplitPaneGeometryProjection.project(
            SplitPaneGeometryProjection.Request(
                orientation: isHorizontal ? .horizontal : .vertical,
                sourceIsFirst: true,
                dividerPosition: CGFloat(split.dividerPosition),
                imposedFirstExtent: split.imposedFirstExtent.map { CGFloat($0) },
                sourceContentFrame: content,
                baseShowsTabBar: true,
                sourceShowsTabBar: false,
                newPaneShowsTabBar: false
            ),
            chrome: SplitPaneGeometryProjection.Chrome(configuration: configuration)
        ))
        let projectedFirstExtent = isHorizontal
            ? projection.sourceContentFrame.width
            : projection.sourceContentFrame.height
        let context = "for \(testCase.direction) at \(testCase.split): divider \(split.dividerPosition), " +
            "imposed \(String(describing: split.imposedFirstExtent)), split view \(splitView.bounds.size)"
        #expect(
            abs(projectedFirstExtent - renderedFirstExtent) <= 1,
            "projected \(projectedFirstExtent) vs rendered \(renderedFirstExtent) \(context)"
        )
        let renderedSecondExtent = isHorizontal
            ? splitView.arrangedSubviews[1].frame.width
            : splitView.arrangedSubviews[1].frame.height
        let projectedSecondExtent = isHorizontal
            ? projection.newPaneContentFrame.width
            : projection.newPaneContentFrame.height
        #expect(abs(projectedSecondExtent - renderedSecondExtent) <= 1)
    }

    private static func firstSplit(in node: ExternalTreeNode) -> ExternalSplitNode? {
        switch node {
        case .pane:
            return nil
        case .split(let split):
            return split
        }
    }

    private static func firstDescendant<ViewType: NSView>(ofType type: ViewType.Type, in root: NSView) -> ViewType? {
        if let match = root as? ViewType { return match }
        for subview in root.subviews {
            if let match = firstDescendant(ofType: type, in: subview) { return match }
        }
        return nil
    }

    /// The rendered split view once its arranged subviews hold stable,
    /// non-degenerate frames for two consecutive main-queue turns.
    private static func settledSplitView(in hostingView: NSView, contentView: NSView) async throws -> NSSplitView {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var previous: [NSRect] = []
        var stableTurns = 0
        while ContinuousClock.now < deadline, !Task.isCancelled {
            contentView.layoutSubtreeIfNeeded()
            if let splitView = firstDescendant(ofType: NSSplitView.self, in: hostingView),
               splitView.arrangedSubviews.count == 2 {
                splitView.layoutSubtreeIfNeeded()
                let frames = splitView.arrangedSubviews.map(\.frame)
                if frames == previous, frames.allSatisfy({ $0.width > 1 && $0.height > 1 }) {
                    stableTurns += 1
                    if stableTurns >= 2 { return splitView }
                } else {
                    stableTurns = 0
                }
                previous = frames
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        throw ParityError.splitViewNeverSettled
    }

    private enum ParityError: Error {
        case splitViewNeverSettled
    }
}
