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

    @Test func bindDefersWhileHostWindowAttachmentInProgress() {
        #expect(
            TerminalWindowPortalRegistry.shouldDeferHostWindowAttachmentBind(
                hostWindowAttachmentInProgress: true
            )
        )
    }

    @Test func bindIsImmediateOutsideHostWindowAttachment() {
        #expect(
            !TerminalWindowPortalRegistry.shouldDeferHostWindowAttachmentBind(
                hostWindowAttachmentInProgress: false
            )
        )
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
