import Bonsplit
import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure projection of bonsplit's post-split pane frames from the pre-split
/// content frame (https://github.com/manaflow-ai/cmux/issues/13387). The
/// suite is deliberately not main-actor bound: the projection is a value
/// computation with no actor isolation.
struct SplitPaneGeometryProjectionTests {
    private typealias Projection = SplitPaneGeometryProjection

    private static let chrome = Projection.Chrome(
        tabBarHeight: 28,
        dividerThickness: 1,
        minimumPaneWidth: 100,
        minimumPaneHeight: 100,
        dividerPositionRange: 0.1...0.9
    )

    /// 800x572 of content below a 28pt tab bar: a 600pt tall, 800pt wide pane.
    private static let content = CGRect(x: 100, y: 100, width: 800, height: 572)

    private static func request(
        orientation: SplitOrientation,
        sourceIsFirst: Bool,
        dividerPosition: CGFloat = 0.5,
        imposedFirstExtent: CGFloat? = nil,
        content: CGRect = content,
        tabBars: Bool = true
    ) -> Projection.Request {
        Projection.Request(
            orientation: orientation,
            sourceIsFirst: sourceIsFirst,
            dividerPosition: dividerPosition,
            imposedFirstExtent: imposedFirstExtent,
            sourceContentFrame: content,
            baseShowsTabBar: tabBars,
            sourceShowsTabBar: tabBars,
            newPaneShowsTabBar: tabBars
        )
    }

    @Test func splitDownKeepsTheSourceOnTopBelowItsTabBar() throws {
        let result = try #require(Projection.project(
            Self.request(orientation: .vertical, sourceIsFirst: true), chrome: Self.chrome
        ))
        // 600 tall pane, 1pt divider: 599 available, 299.5 each.
        #expect(result.sourceContentFrame == CGRect(x: 100, y: 400.5, width: 800, height: 271.5))
        #expect(result.newPaneContentFrame == CGRect(x: 100, y: 100, width: 800, height: 271.5))
        #expect(result.sourceContentFrame.maxY == Self.content.maxY)
        #expect(!result.sourceContentFrame.intersects(result.newPaneContentFrame))
    }

    @Test func splitUpMovesTheSourceBelowTheNewPane() throws {
        let result = try #require(Projection.project(
            Self.request(orientation: .vertical, sourceIsFirst: false), chrome: Self.chrome
        ))
        #expect(result.sourceContentFrame == CGRect(x: 100, y: 100, width: 800, height: 271.5))
        #expect(result.newPaneContentFrame == CGRect(x: 100, y: 400.5, width: 800, height: 271.5))
        #expect(result.sourceContentFrame.minY == Self.content.minY)
    }

    @Test func splitRightKeepsTheSourceLeadingAndSkipsTheDivider() throws {
        let result = try #require(Projection.project(
            Self.request(orientation: .horizontal, sourceIsFirst: true), chrome: Self.chrome
        ))
        #expect(result.sourceContentFrame == CGRect(x: 100, y: 100, width: 399.5, height: 572))
        #expect(result.newPaneContentFrame == CGRect(x: 500.5, y: 100, width: 399.5, height: 572))
        #expect(result.newPaneContentFrame.minX - result.sourceContentFrame.maxX == 1)
    }

    @Test func splitLeftMovesTheSourceTrailing() throws {
        let result = try #require(Projection.project(
            Self.request(orientation: .horizontal, sourceIsFirst: false), chrome: Self.chrome
        ))
        #expect(result.sourceContentFrame == CGRect(x: 500.5, y: 100, width: 399.5, height: 572))
        #expect(result.newPaneContentFrame == CGRect(x: 100, y: 100, width: 399.5, height: 572))
        #expect(result.sourceContentFrame.maxX == Self.content.maxX)
    }

    @Test func dividerPositionAndImposedExtentPlaceTheDivider() throws {
        let fractional = try #require(Projection.project(
            Self.request(orientation: .horizontal, sourceIsFirst: true, dividerPosition: 0.25), chrome: Self.chrome
        ))
        #expect(fractional.sourceContentFrame.width == 799 * 0.25)

        let imposed = try #require(Projection.project(
            Self.request(orientation: .horizontal, sourceIsFirst: true, imposedFirstExtent: 200), chrome: Self.chrome
        ))
        #expect(imposed.sourceContentFrame.width == 200)
        #expect(imposed.newPaneContentFrame.minX == 301)
    }

    @Test func dividerRangeAndPaneMinimumsClampTheDivider() throws {
        // The 100pt pane minimum narrows the 0.1...0.9 range to
        // 100/799...1-100/799 of the 799 available points before the
        // position is clamped, so the first pane stops one minimum short of
        // the far edge.
        let ranged = try #require(Projection.project(
            Self.request(orientation: .horizontal, sourceIsFirst: true, dividerPosition: 0.99), chrome: Self.chrome
        ))
        #expect(abs(ranged.sourceContentFrame.width - (799 - 100)) < 0.001)
        #expect(abs(ranged.newPaneContentFrame.width - 100) < 0.001)

        // A 128pt tall pane cannot hold two 100pt panes: bonsplit shares the
        // 127 available points evenly instead of forcing invalid bounds.
        let tiny = try #require(Projection.project(
            Self.request(
                orientation: .vertical, sourceIsFirst: true, dividerPosition: 0.9,
                content: CGRect(x: 0, y: 0, width: 300, height: 100)
            ),
            chrome: Self.chrome
        ))
        #expect(tiny.sourceContentFrame.height == 63.5 - 28)
        #expect(tiny.newPaneContentFrame.height == 63.5 - 28)
    }

    @Test func tabBarsOnlyInsetPanesThatShowThem() throws {
        let bare = try #require(Projection.project(
            Self.request(orientation: .vertical, sourceIsFirst: true, tabBars: false), chrome: Self.chrome
        ))
        // 572 tall pane, 571 available, 285.5 each, no tab strip anywhere.
        #expect(bare.sourceContentFrame == CGRect(x: 100, y: 386.5, width: 800, height: 285.5))
        #expect(bare.newPaneContentFrame == CGRect(x: 100, y: 100, width: 800, height: 285.5))
    }

    @Test func degenerateInputProjectsNothing() {
        #expect(Projection.project(
            Self.request(orientation: .vertical, sourceIsFirst: true, content: .zero), chrome: Self.chrome
        ) == nil)
        #expect(Projection.project(
            Self.request(
                orientation: .horizontal, sourceIsFirst: true,
                content: CGRect(x: 0, y: 0, width: 1, height: 100)
            ),
            chrome: Self.chrome
        ) == nil)
        #expect(Projection.project(
            Self.request(
                orientation: .vertical, sourceIsFirst: true,
                content: CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100)
            ),
            chrome: Self.chrome
        ) == nil)
    }
}
