import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for portal publication; run this suite explicitly in CI.
@MainActor
@Suite(.serialized)
struct TerminalWindowPortalCommittedGeometryTests {
    @Test func bindPublishesOnlyAfterSettledPass() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.hosted.paneGeometryIsPortalOwned)
        #expect(fixture.surface.committedPaneGeometry == nil)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        #expect(fixture.surface.committedPaneGeometry == nil)
        try await fixture.requireCommit()
        let geometry = try #require(fixture.surface.committedPaneGeometry)
        #expect(geometry.phase == .settled)
        #expect(geometry.size == fixture.hosted.surfaceView.frame.size)
        #expect(fixture.hosted.commitPortalGeometry(phase: .settled))
    }

    @Test func hiddenEntryNeverPublishes() async {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind(visible: false)
        fixture.anchor.setFrameSize(NSSize(width: 17, height: 19))
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        await fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.surface.committedPaneGeometry == nil)
    }

    @Test func hidingDoesNotPublishCollapsedGeometry() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        let before = try #require(fixture.surface.rawSizingSample())
        fixture.anchor.setFrameSize(NSSize(width: 17, height: 19))
        _ = fixture.portal.updateEntryVisibility(forHostedId: fixture.hostedID, visibleInUI: false)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        await fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.surface.committedPaneGeometry == nil)
        let after = try #require(fixture.surface.rawSizingSample())
        #expect(before.columns == after.columns)
        #expect(before.rows == after.rows)
    }

    @Test func unmountedEntryCannotBeRevealedByAQueuedGeometryPass() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        fixture.portal.hideEntry(forHostedId: fixture.hostedID)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        await fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.visibleInUI == false)
        #expect(fixture.hosted.isHidden)
        #expect(fixture.surface.committedPaneGeometry == nil)
    }

    @Test(arguments: [false, true])
    func dragTicksStayInteractiveUntilEnd(native: Bool) async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        let scrollView = try #require(fixture.hosted.subviews.compactMap { $0 as? NSScrollView }.first)
        fixture.beginResize(native: native)
        fixture.anchor.setFrameSize(NSSize(width: 320, height: 220))
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        #expect(fixture.surface.committedPaneGeometry?.phase == .interactive)
        #expect(fixture.hosted.frame.width == 320)
        #expect(fixture.surface.committedPaneGeometry?.size == scrollView.contentView.bounds.size)
        await fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.surface.committedPaneGeometry?.phase == .interactive)
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == true)
        fixture.endResize()
        try await fixture.requireCommit()
        #expect(fixture.surface.committedPaneGeometry?.phase == .settled)
        #expect(fixture.surface.committedPaneGeometry?.size == scrollView.contentView.bounds.size)
    }

    @Test func visibleRuntimeCreationWaitsForFirstGeometry() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.surface.surface == nil)
        try await fixture.requireCommit()
        let geometry = try #require(fixture.surface.committedPaneGeometry)
        let runtime = try #require(fixture.surface.surface)
        let size = ghostty_surface_size(runtime)
        #expect(abs(CGFloat(size.width_px) - geometry.backingSize.width) <= 1)
        #expect(abs(CGFloat(size.height_px) - geometry.backingSize.height) <= 1)
    }

    @Test func contentWidthChangesCommitWithoutOuterFrameChange() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        let outerFrame = fixture.hosted.frame
        fixture.hosted.setSessionContentWidthPresentation(SessionContentWidthPresentation(
            // Use a supported maximum below the fixture pane's width;
            // values below the policy minimum of 320 are clamped.
            storedMaximumWidth: 400, storedAlignment: "center"
        ))
        let scrollView = try #require(fixture.hosted.subviews.compactMap { $0 as? NSScrollView }.first)
        #expect(scrollView.frame.width == 400)
        try await fixture.requireCommit()
        #expect(fixture.surface.committedPaneGeometry?.size == scrollView.contentView.bounds.size)
        #expect(fixture.hosted.frame == outerFrame)
        let runtime = try #require(fixture.surface.surface)
        let geometry = try #require(fixture.surface.committedPaneGeometry)
        #expect(abs(CGFloat(ghostty_surface_size(runtime).width_px) - geometry.backingSize.width) <= 1)
        fixture.hosted.setSessionContentWidthPresentation(.disabled)
        #expect(scrollView.frame.width == outerFrame.width)
        try await fixture.requireCommit()
        #expect(fixture.surface.committedPaneGeometry?.size == scrollView.contentView.bounds.size)
    }

    @Test func legacyScrollerCommitsClipWidthWithoutPaneResize() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        try await fixture.requireScrollback()
        let scrollView = try #require(fixture.hosted.subviews.compactMap { $0 as? NSScrollView }.first)
        let outerFrame = fixture.hosted.frame
        scrollView.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        try await fixture.requireCommit(width: scrollView.contentView.bounds.width)
        #expect(scrollView.contentView.bounds.width < outerFrame.width)
        #expect(fixture.hosted.frame == outerFrame)
        #expect(fixture.surface.committedPaneGeometry?.size == scrollView.contentView.bounds.size)
        scrollView.scrollerStyle = .overlay
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        try await fixture.requireCommit(width: scrollView.contentView.bounds.width)
        #expect(scrollView.contentView.bounds.width == outerFrame.width)
    }

    @Test func aNewSettlementEpisodeRestoresItsRetryBudget() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        fixture.portal.geometrySettlementPassesRemaining = 0
        fixture.portal.markNeedsSettledCommit(for: fixture.hostedID)
        #expect(fixture.portal.geometrySettlementPassesRemaining == 4)
        fixture.portal.geometrySettlementPassesRemaining = 2
        fixture.portal.markNeedsSettledCommit(for: fixture.hostedID)
        #expect(fixture.portal.geometrySettlementPassesRemaining == 2)
    }

    @Test func unavailableSurfaceKeepsPublicationPending() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        fixture.portal.markNeedsSettledCommit(for: fixture.hostedID)
        fixture.hosted.isHidden = true
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == true)
        fixture.hosted.isHidden = false
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == false)
    }

    @Test func exhaustedRetriesDoNotCommitAMovingHierarchy() async throws {
        let anchor = GeometryMovingAnchorView(frame: NSRect(x: 8, y: 8, width: 520, height: 280))
        let fixture = TerminalPortalGeometryFixture(anchorView: anchor)
        defer { fixture.close() }
        fixture.bind()
        try await fixture.requireCommit()
        let before = try #require(fixture.surface.committedPaneGeometry)

        anchor.setFrameSize(NSSize(width: 320, height: 280))
        fixture.portal.synchronizeHostedViewForAnchor(anchor, syncLayout: false)
        anchor.nextLayoutWidth = 280
        anchor.needsLayout = true
        fixture.portal.geometrySettlementPassesRemaining = 0
        fixture.portal.synchronizeAllEntriesFromExternalGeometryChange()

        #expect(anchor.frame.width == 280, "The forced layout must actually move the anchor")
        #expect(fixture.surface.committedPaneGeometry == before)
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == true)
        fixture.portal.synchronizeAllEntriesFromExternalGeometryChange()
        try await fixture.requireCommit()
        #expect(fixture.surface.committedPaneGeometry?.size.width != before.size.width)
    }
}

@MainActor
private final class GeometryMovingAnchorView: NSView {
    var nextLayoutWidth: CGFloat?

    override func layout() {
        super.layout()
        guard let width = nextLayoutWidth else { return }
        nextLayoutWidth = nil
        setFrameSize(NSSize(width: width, height: frame.height))
    }
}
