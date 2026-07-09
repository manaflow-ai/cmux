import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import XCTest
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications
// Selective imports: the app target also defines AppIconMode/StoredShortcut/etc.,
// so a blanket `import CmuxSettings` here makes those names ambiguous. Import only
// the settings symbols this file needs.
import struct CmuxSettings.AccountCatalogSection
import struct CmuxSettings.AppCatalogSection
import struct CmuxSettings.FileRouteSettingsStore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class FilePreviewFocusTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
}

@MainActor
@Suite(.serialized)
final class FilePreviewFocusCoordinatorTests {
    @Test func testPDFKeyboardRoutingUsesFocusedRegion() {
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [],
                region: .pdfThumbnails
            ),
            .navigatePage(-1)
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [],
                region: .pdfThumbnails
            ),
            .navigatePage(1)
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_UpArrow),
                modifiers: [],
                region: .pdfCanvas
            ),
            .native
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_DownArrow),
                modifiers: [],
                region: .pdfOutline
            ),
            .native
        )
        XCTAssertEqual(
            FilePreviewPDFKeyboardRouting.action(
                keyCode: UInt16(kVK_PageDown),
                modifiers: .command,
                region: .pdfThumbnails
            ),
            .native
        )
    }

    @Test func testCoordinatorResolvesMostSpecificRegisteredSubregion() {
        let root = FilePreviewFocusTestView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let thumbnailHost = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 240))
        let thumbnailResponder = FilePreviewFocusTestView(frame: thumbnailHost.bounds)
        thumbnailHost.addSubview(thumbnailResponder)
        root.addSubview(thumbnailHost)

        let coordinator = FilePreviewFocusCoordinator(preferredIntent: .pdfCanvas)
        coordinator.register(root: root, primaryResponder: root, intent: .pdfCanvas)
        coordinator.register(
            root: thumbnailHost,
            primaryResponder: thumbnailResponder,
            intent: .pdfThumbnails
        )

        XCTAssertEqual(coordinator.ownedIntent(for: root), .pdfCanvas)
        XCTAssertEqual(coordinator.ownedIntent(for: thumbnailResponder), .pdfThumbnails)
        XCTAssertTrue(coordinator.endpoint(for: .pdfThumbnails) === thumbnailResponder)
        coordinator.notePreferredIntent(.pdfThumbnails)
        XCTAssertEqual(coordinator.preferredIntent, .pdfThumbnails)
    }
}
