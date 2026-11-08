import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Provisional pane geometry: a model-projected frame the portal applies ahead
/// of a SwiftUI re-host and releases the moment an anchor re-asserts geometry
/// or the model transaction it came from ends
/// (https://github.com/manaflow-ai/cmux/issues/13387).
@MainActor
@Suite(.serialized)
struct TerminalWindowPortalProvisionalGeometryTests {
    @Test func projectionAppliesNowAndOutlivesPassesFromAnUnchangedAnchor() async throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        let projected = Self.topHalf(of: Self.frameInWindow(fixture.anchor))

        #expect(fixture.portal.applyProvisionalPaneFrame(projected, forHostedId: fixture.hostedID, transactionID: UUID()))
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), projected))
        #expect(fixture.hosted.bounds.size == fixture.hosted.frame.size)

        // The stale anchor carries no new information: neither an inline
        // anchor pass nor the queued window passes may restore its frame.
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), projected))
        await fixture.flushLayout()
        await fixture.flushLayout()
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), projected))
        #expect(fixture.portal.provisionalPaneGeometry(forHostedId: fixture.hostedID) != nil)
        #expect(!fixture.hosted.isHidden)
    }

    @Test func secondProjectionInTheSameTransactionReusesThePreSplitBase() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        let anchorFrame = Self.frameInWindow(fixture.anchor)
        let transaction = UUID()
        #expect(fixture.portal.applyProvisionalPaneFrame(
            Self.topHalf(of: anchorFrame), forHostedId: fixture.hostedID, transactionID: transaction
        ))
        let base = try #require(fixture.portal.provisionalBaseFrameInWindow(forHostedId: fixture.hostedID))
        #expect(Self.approximatelyEqual(base, anchorFrame))

        let narrower = NSRect(x: anchorFrame.minX, y: anchorFrame.minY, width: anchorFrame.width / 3, height: anchorFrame.height)
        #expect(fixture.portal.applyProvisionalPaneFrame(narrower, forHostedId: fixture.hostedID, transactionID: transaction))
        let baseAfterSecondProjection = try #require(fixture.portal.provisionalBaseFrameInWindow(forHostedId: fixture.hostedID))
        #expect(Self.approximatelyEqual(baseAfterSecondProjection, anchorFrame))
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), narrower))
    }

    @Test func anchorThatMovesTakesGeometryBack() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.portal.applyProvisionalPaneFrame(
            Self.topHalf(of: Self.frameInWindow(fixture.anchor)), forHostedId: fixture.hostedID, transactionID: UUID()
        ))

        fixture.anchor.setFrameSize(NSSize(width: 400, height: 200))
        fixture.portal.synchronizeHostedViewForAnchor(fixture.anchor)

        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), Self.frameInWindow(fixture.anchor)))
        #expect(fixture.portal.provisionalPaneGeometry(forHostedId: fixture.hostedID) == nil)
    }

    @Test func bindingToANewAnchorTakesGeometryBack() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        #expect(fixture.portal.applyProvisionalPaneFrame(
            Self.topHalf(of: Self.frameInWindow(fixture.anchor)), forHostedId: fixture.hostedID, transactionID: UUID()
        ))

        let replacement = NSView(frame: NSRect(x: 30, y: 12, width: 300, height: 150))
        let contentView = try #require(fixture.window.contentView)
        contentView.addSubview(replacement)
        fixture.portal.bind(hostedView: fixture.hosted, to: replacement, visibleInUI: true)

        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), Self.frameInWindow(replacement)))
        #expect(fixture.portal.provisionalPaneGeometry(forHostedId: fixture.hostedID) == nil)
    }

    @Test func endingTheTransactionHandsGeometryBackToTheLiveAnchor() throws {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind()
        let anchorFrame = Self.frameInWindow(fixture.anchor)
        let projected = Self.topHalf(of: anchorFrame)
        let transaction = UUID()
        #expect(fixture.portal.applyProvisionalPaneFrame(projected, forHostedId: fixture.hostedID, transactionID: transaction))
        let workspaceID = fixture.surface.tabId

        // Another workspace's transactions, and other transactions of this
        // workspace, leave the projection in place.
        fixture.portal.releaseProvisionalPaneGeometry(inWorkspace: UUID()) { _ in true }
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), projected))
        fixture.portal.releaseProvisionalPaneGeometry(inWorkspace: workspaceID) { $0 != transaction }
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), projected))
        #expect(fixture.portal.provisionalPaneGeometry(forHostedId: fixture.hostedID) != nil)

        // The transaction ending hands geometry back to the anchor at once.
        fixture.portal.releaseProvisionalPaneGeometry(inWorkspace: workspaceID) { $0 == transaction }
        #expect(Self.approximatelyEqual(Self.frameInWindow(fixture.hosted), anchorFrame))
        #expect(fixture.portal.provisionalPaneGeometry(forHostedId: fixture.hostedID) == nil)
    }

    @Test func hiddenEntryRejectsProjection() {
        let fixture = TerminalPortalGeometryFixture()
        defer { fixture.close() }
        fixture.bind(visible: false)
        #expect(!fixture.portal.applyProvisionalPaneFrame(
            Self.topHalf(of: Self.frameInWindow(fixture.anchor)), forHostedId: fixture.hostedID, transactionID: UUID()
        ))
        #expect(fixture.portal.provisionalPaneGeometry(forHostedId: fixture.hostedID) == nil)
    }

    private static func frameInWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    private static func topHalf(of frame: NSRect) -> NSRect {
        NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2 - 20)
    }

    private static func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }
}
