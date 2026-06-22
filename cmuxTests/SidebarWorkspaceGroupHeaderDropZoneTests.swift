import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SidebarWorkspaceReorderDropOverlayHitTestingTests {
    @Test func doesNotCaptureMouseDownBeforeDragStart() {
        #expect(!SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDown,
            pasteboardTypes: [NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)]
        ))
    }

    @Test func doesNotCapturePointerDragWithoutSidebarPasteboardType() {
        #expect(!SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDragged,
            pasteboardTypes: []
        ))
    }

    @Test func capturesPointerDragAfterSidebarPasteboardTypeExists() {
        #expect(SidebarWorkspaceReorderDropOverlay.shouldCaptureHitTest(
            eventType: .leftMouseDragged,
            pasteboardTypes: [NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)]
        ))
    }
}
