import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5704.
///
/// cmux crashed with `EXC_BREAKPOINT` inside
/// `-[NSView addSubview:positioned:relativeTo:]` because the window portal reparented the
/// hosted terminal surface synchronously from `HostContainerView.viewDidMoveToWindow()` —
/// a callback AppKit delivers while it is still enumerating the view tree inside
/// `-[NSView _setWindow:]`. Mutating the hierarchy mid-enumeration corrupts AppKit's internal
/// subview bookkeeping. The portal must instead defer the structural bind (and the geometry
/// reconcile, which can install/reorder portal views) while a host is mid window-attachment.
///
/// The suite is serialized because it exercises the registry's shared attachment-depth counter.
@MainActor
@Suite(.serialized)
struct TerminalWindowPortalReentrancyGuardTests {
    /// Drain any depth left over from a previous test so the shared counter starts clean.
    private func resetDepth() {
        while TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress {
            TerminalWindowPortalRegistry.endHostWindowAttachment()
        }
    }

    @Test func bindDefersAndAppliesAfterHostWindowAttachmentCompletes() throws {
        resetDepth()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            resetDepth()
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        let contentView = try #require(window.contentView)
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        let bindApplied = TerminalWindowPortalRegistry.bind(
            hostedView: hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )

        #expect(!bindApplied)
        #expect(!TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: anchor))

        TerminalWindowPortalRegistry.endHostWindowAttachment()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: anchor))
    }

    @Test func bindAppliesImmediatelyOutsideHostWindowAttachment() throws {
        resetDepth()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 120, height: 80))
        let contentView = try #require(window.contentView)
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let bindApplied = TerminalWindowPortalRegistry.bind(
            hostedView: hostedView,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        #expect(bindApplied)
        #expect(TerminalWindowPortalRegistry.isHostedView(hostedView, boundTo: anchor))
    }

    @Test func hostWindowAttachmentDepthTracksNestedBeginEnd() {
        resetDepth()
        #expect(!TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        #expect(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        // Nested split trees can re-enter viewDidMoveToWindow, so the depth must nest.
        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        #expect(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        TerminalWindowPortalRegistry.endHostWindowAttachment()
        #expect(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        TerminalWindowPortalRegistry.endHostWindowAttachment()
        #expect(!TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
    }

    @Test func endWithoutBeginDoesNotUnderflow() {
        resetDepth()
        TerminalWindowPortalRegistry.endHostWindowAttachment()
        #expect(!TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        // An unbalanced end must not drive the depth negative and leave the registry stuck.
        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        #expect(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
        TerminalWindowPortalRegistry.endHostWindowAttachment()
        #expect(!TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
    }
}
