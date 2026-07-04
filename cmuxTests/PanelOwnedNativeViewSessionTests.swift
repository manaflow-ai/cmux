import AppKit
import Quartz
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PanelOwnedNativeViewSessionTests: XCTestCase {
    private final class ProbeView: NSView {
        var isClosed = false
        var configureCount = 0
    }

    func testUpdateAfterCloseDoesNotReAdoptClosedNativeView() {
        var makeCount = 0
        let session = PanelOwnedNativeViewSession<ProbeView>(
            makeView: {
                makeCount += 1
                return ProbeView(frame: .zero)
            },
            closeView: { view in
                view.isClosed = true
                view.removeFromSuperview()
            }
        )

        let initialView = session.view { view in
            XCTAssertFalse(view.isClosed)
            view.configureCount += 1
        }

        XCTAssertEqual(makeCount, 1)
        XCTAssertEqual(initialView.configureCount, 1)

        session.close()

        XCTAssertTrue(initialView.isClosed)

        session.update(initialView) { view in
            XCTFail("Closed native views must not be re-adopted or configured after the panel session closes")
            view.configureCount += 1
        }

        XCTAssertEqual(initialView.configureCount, 1)

        let replacementView = session.view { view in
            XCTAssertFalse(view.isClosed)
            view.configureCount += 1
        }

        XCTAssertFalse(replacementView === initialView)
        XCTAssertEqual(replacementView.configureCount, 1)
        XCTAssertEqual(makeCount, 2)
    }

    func testQuickLookSessionCreatesFreshViewForEachRepresentableMount() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-4455-quicklook-\(UUID().uuidString).bin")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        let session = FilePreviewQuickLookSession()

        let firstView = session.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )
        let remountedView = session.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        XCTAssertFalse(
            firstView === remountedView,
            "QuickLook views must be owned by the SwiftUI representable mount, because AppKit can deactivate a QLPreviewView when that mount is removed"
        )

        session.dismantle(firstView)
        session.dismantle(remountedView)
        panel.close()
    }

    func testQuickLookUpdateAfterWindowDetachRetiresStaleInnerPreviewView() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-quicklook-a-\(UUID().uuidString).txt")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-quicklook-b-\(UUID().uuidString).txt")
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let firstPanel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        let secondPanel = FilePreviewPanel(workspaceId: UUID(), filePath: secondURL.path)
        let session = FilePreviewQuickLookSession()
        let container = try XCTUnwrap(session.view(
            panel: firstPanel,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        ) as? FilePreviewQuickLookContainerView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            session.dismantle(container)
            firstPanel.close()
            secondPanel.close()
            window.close()
        }

        window.contentView = container
        let stalePreviewView = try XCTUnwrap(container.livePreviewView())
        XCTAssertNotNil(stalePreviewView.previewItem)

        window.contentView = nil
        session.update(
            container,
            panel: secondPanel,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        let freshPreviewView = try XCTUnwrap(container.livePreviewView())
        XCTAssertFalse(freshPreviewView === stalePreviewView)
        XCTAssertNil(stalePreviewView.previewItem)
    }
}
