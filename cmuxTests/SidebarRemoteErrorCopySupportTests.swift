import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class SidebarRemoteErrorCopySupportTests: XCTestCase {
    func testMenuLabelIsNilWhenThereAreNoErrors() {
        XCTAssertNil(SidebarRemoteErrorCopySupport.menuLabel(for: []))
        XCTAssertNil(SidebarRemoteErrorCopySupport.clipboardText(for: []))
    }

    func testSingleErrorUsesCopyErrorLabelAndSingleLinePayload() {
        let entries = [
            SidebarRemoteErrorCopyEntry(
                workspaceTitle: "alpha",
                target: "devbox:22",
                detail: "failed to start reverse relay"
            )
        ]

        XCTAssertEqual(SidebarRemoteErrorCopySupport.menuLabel(for: entries), "Copy Error")
        XCTAssertEqual(
            SidebarRemoteErrorCopySupport.clipboardText(for: entries),
            "SSH error (devbox:22): failed to start reverse relay"
        )
    }

    func testMultipleErrorsUseCopyErrorsLabelAndEnumeratedPayload() {
        let entries = [
            SidebarRemoteErrorCopyEntry(
                workspaceTitle: "alpha",
                target: "devbox-a:22",
                detail: "connection timed out"
            ),
            SidebarRemoteErrorCopyEntry(
                workspaceTitle: "beta",
                target: "devbox-b:22",
                detail: "permission denied"
            ),
        ]

        XCTAssertEqual(SidebarRemoteErrorCopySupport.menuLabel(for: entries), "Copy Errors")
        XCTAssertEqual(
            SidebarRemoteErrorCopySupport.clipboardText(for: entries),
            """
            1. alpha (devbox-a:22): connection timed out
            2. beta (devbox-b:22): permission denied
            """
        )
    }

    func testClipboardTextSingleEntryUsesStructuredEntryFields() {
        let entry = SidebarRemoteErrorCopyEntry(
            workspaceTitle: "alpha",
            target: "devbox:22",
            detail: "failed to bootstrap daemon"
        )
        XCTAssertEqual(
            SidebarRemoteErrorCopySupport.clipboardText(for: [entry]),
            "SSH error (devbox:22): failed to bootstrap daemon"
        )
    }
}


