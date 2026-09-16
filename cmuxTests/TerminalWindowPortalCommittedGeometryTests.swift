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
    @Test func bindPublishesOnlyAfterSettledPass() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.hosted.paneGeometryIsPortalOwned)
        #expect(fixture.surface.committedPaneGeometry == nil)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        #expect(fixture.surface.committedPaneGeometry == nil)
        #expect(fixture.waitForCommit())
        let geometry = try #require(fixture.surface.committedPaneGeometry)
        #expect(geometry.phase == .settled)
        #expect(geometry.size == fixture.hosted.surfaceView.frame.size)
        #expect(fixture.hosted.commitPortalGeometry(phase: .settled))
    }

    @Test func hiddenEntryNeverPublishes() {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind(visible: false)
        fixture.anchor.setFrameSize(NSSize(width: 17, height: 19))
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.surface.committedPaneGeometry == nil)
    }

    @Test func hidingDoesNotPublishCollapsedGeometry() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.waitForCommit())
        let before = try #require(fixture.surface.rawSizingSample())
        fixture.anchor.setFrameSize(NSSize(width: 17, height: 19))
        _ = fixture.portal.updateEntryVisibility(forHostedId: fixture.hostedID, visibleInUI: false)
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.surface.committedPaneGeometry == nil)
        let after = try #require(fixture.surface.rawSizingSample())
        #expect(before.columns == after.columns)
        #expect(before.rows == after.rows)
    }

    @Test(arguments: [false, true])
    func dragTicksStayInteractiveUntilEnd(native: Bool) throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.waitForCommit())
        fixture.beginResize(native: native)
        fixture.anchor.setFrameSize(NSSize(width: 320, height: 220))
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor, syncLayout: false)
        #expect(fixture.surface.committedPaneGeometry?.phase == .interactive)
        #expect(fixture.surface.committedPaneGeometry?.size.width == 320)
        fixture.flushLayout()
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.surface.committedPaneGeometry?.phase == .interactive)
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == true)
        fixture.endResize()
        #expect(fixture.waitForCommit())
        #expect(fixture.surface.committedPaneGeometry?.phase == .settled)
        #expect(fixture.surface.committedPaneGeometry?.size.width == 320)
    }

    @Test func visibleRuntimeCreationWaitsForFirstGeometry() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.hosted.setVisibleInUI(true)
        fixture.bind()
        #expect(fixture.surface.surface == nil)
        #expect(fixture.waitForCommit())
        let geometry = try #require(fixture.surface.committedPaneGeometry)
        let runtime = try #require(fixture.surface.surface)
        let size = ghostty_surface_size(runtime)
        #expect(abs(CGFloat(size.width_px) - geometry.backingSize.width) <= 1)
        #expect(abs(CGFloat(size.height_px) - geometry.backingSize.height) <= 1)
    }

    @Test func contentWidthChangesCommitWithoutOuterFrameChange() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.waitForCommit())
        let outerFrame = fixture.hosted.frame
        fixture.hosted.setSessionContentWidthPresentation(SessionContentWidthPresentation(
            storedMaximumWidth: 280, storedAlignment: "center"
        ))
        #expect(fixture.waitForCommit(width: 280))
        #expect(fixture.hosted.frame == outerFrame)
        let runtime = try #require(fixture.surface.surface)
        let geometry = try #require(fixture.surface.committedPaneGeometry)
        #expect(abs(CGFloat(ghostty_surface_size(runtime).width_px) - geometry.backingSize.width) <= 1)
        fixture.hosted.setSessionContentWidthPresentation(.disabled)
        #expect(fixture.waitForCommit(width: outerFrame.width))
    }

    @Test func legacyScrollerCommitsClipWidthWithoutPaneResize() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.waitForCommit())
        let scrollView = try #require(fixture.hosted.subviews.compactMap { $0 as? NSScrollView }.first)
        let outerFrame = fixture.hosted.frame
        scrollView.scrollerStyle = .legacy
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect(fixture.waitForCommit(width: scrollView.contentView.bounds.width))
        #expect(fixture.hosted.frame == outerFrame)
        #expect(fixture.surface.committedPaneGeometry?.size == scrollView.contentView.bounds.size)
        scrollView.scrollerStyle = .overlay
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect(fixture.waitForCommit(width: scrollView.contentView.bounds.width))
    }

    @Test func aNewSettlementEpisodeRestoresItsRetryBudget() {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.waitForCommit())
        fixture.portal.geometrySettlementPassesRemaining = 0
        fixture.portal.markNeedsSettledCommit(for: fixture.hostedID)
        #expect(fixture.portal.geometrySettlementPassesRemaining == 4)
        fixture.portal.geometrySettlementPassesRemaining = 2
        fixture.portal.markNeedsSettledCommit(for: fixture.hostedID)
        #expect(fixture.portal.geometrySettlementPassesRemaining == 2)
    }

    @Test func unavailableSurfaceKeepsPublicationPending() {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.waitForCommit())
        fixture.portal.markNeedsSettledCommit(for: fixture.hostedID)
        fixture.hosted.isHidden = true
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == true)
        fixture.hosted.isHidden = false
        fixture.portal.commitSettledPaneGeometries()
        #expect(fixture.portal.entriesByHostedId[fixture.hostedID]?.needsSettledCommit == false)
    }
}
