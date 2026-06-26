import XCTest

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
/// subview bookkeeping. The portal must instead defer the structural bind while a host is
/// mid window-attachment.
@MainActor
final class TerminalWindowPortalReentrancyGuardTests: XCTestCase {
    override func tearDown() {
        // Drain any depth left over from a failed assertion so tests stay independent.
        while TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress {
            TerminalWindowPortalRegistry.endHostWindowAttachment()
        }
        super.tearDown()
    }

    func testBindDefersWhileHostWindowAttachmentInProgress() {
        XCTAssertEqual(
            TerminalWindowPortalRegistry.hostWindowAttachmentBindAction(
                hostWindowAttachmentInProgress: true
            ),
            .deferUntilHostWindowAttachmentCompletes,
            "A portal bind requested during a host's viewDidMoveToWindow must defer its "
                + "structural reparent until AppKit finishes its _setWindow: enumeration."
        )
    }

    func testBindIsImmediateOutsideHostWindowAttachment() {
        XCTAssertEqual(
            TerminalWindowPortalRegistry.hostWindowAttachmentBindAction(
                hostWindowAttachmentInProgress: false
            ),
            .bindImmediately,
            "Outside a window-attachment callback the portal may reparent synchronously."
        )
    }

    func testHostWindowAttachmentDepthTracksNestedBeginEnd() {
        XCTAssertFalse(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        XCTAssertTrue(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        // Nested split trees can re-enter viewDidMoveToWindow, so the depth must nest.
        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        XCTAssertTrue(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        TerminalWindowPortalRegistry.endHostWindowAttachment()
        XCTAssertTrue(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        TerminalWindowPortalRegistry.endHostWindowAttachment()
        XCTAssertFalse(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
    }

    func testEndWithoutBeginDoesNotUnderflow() {
        XCTAssertFalse(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
        TerminalWindowPortalRegistry.endHostWindowAttachment()
        XCTAssertFalse(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)

        // An unbalanced end must not drive the depth negative and leave the registry stuck.
        TerminalWindowPortalRegistry.beginHostWindowAttachment()
        XCTAssertTrue(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
        TerminalWindowPortalRegistry.endHostWindowAttachment()
        XCTAssertFalse(TerminalWindowPortalRegistry.isHostWindowAttachmentInProgress)
    }
}
