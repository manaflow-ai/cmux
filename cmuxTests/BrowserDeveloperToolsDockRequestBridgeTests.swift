import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserDeveloperToolsDockRequestBridgeTests: XCTestCase {
    private final class FakeInspector: NSObject {
        private(set) var attachCount = 0
        var attached = false
        var visible = true
        var frontendWebView: WKWebView?

        @objc func isAttached() -> Bool {
            attached
        }

        @objc func isVisible() -> Bool {
            visible
        }

        @objc func attach() {
            attachCount += 1
            attached = true
        }

        @objc func inspectorWebView() -> WKWebView? {
            frontendWebView
        }
    }

    override class func setUp() {
        super.setUp()
        installCmuxUnitTestInspectorOverride()
    }

    func testDockRequestAttachesDetachedInspectorOnce() {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        panel.webView.cmuxSetUnitTestInspector(inspector)
        defer { panel.webView.cmuxSetUnitTestInspector(nil) }

        XCTAssertTrue(panel.handleDeveloperToolsDockRequestFromFrontend(side: "bottom"))
        XCTAssertEqual(inspector.attachCount, 1)
        XCTAssertTrue(inspector.attached)

        XCTAssertTrue(panel.handleDeveloperToolsDockRequestFromFrontend(side: "left"))
        XCTAssertEqual(inspector.attachCount, 1)
    }

    func testDockRequestRejectsUnknownSide() {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        panel.webView.cmuxSetUnitTestInspector(inspector)
        defer { panel.webView.cmuxSetUnitTestInspector(nil) }

        XCTAssertFalse(panel.handleDeveloperToolsDockRequestFromFrontend(side: "window"))
        XCTAssertEqual(inspector.attachCount, 0)
    }

    func testDockRequestHostsDetachedInspectorFrontend() {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        hostView.addSubview(panel.webView)
        panel.webView.frame = hostView.bounds
        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let frontendWebView = WKWebView(frame: detachedWindow.contentView?.bounds ?? .zero)
        detachedWindow.contentView?.addSubview(frontendWebView)
        inspector.frontendWebView = frontendWebView
        panel.webView.cmuxSetUnitTestInspector(inspector)
        defer {
            panel.webView.cmuxSetUnitTestInspector(nil)
            detachedWindow.close()
        }

        XCTAssertTrue(panel.handleDeveloperToolsDockRequestFromFrontend(side: "right"))
        XCTAssertTrue(frontendWebView.isDescendant(of: hostView))
        XCTAssertEqual(inspector.attachCount, 0)
        XCTAssertEqual(panel.webView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(frontendWebView.frame.maxX, hostView.bounds.maxX, accuracy: 0.5)
    }
}
