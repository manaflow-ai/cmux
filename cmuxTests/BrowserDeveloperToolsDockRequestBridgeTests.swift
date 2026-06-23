import AppKit
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
    }

    override class func setUp() {
        super.setUp()
        installCmuxUnitTestInspectorOverride()
    }

    func testDockRequestDoesNotCallPrivateAttach() {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        panel.webView.cmuxSetUnitTestInspector(inspector)
        defer { panel.webView.cmuxSetUnitTestInspector(nil) }

        XCTAssertFalse(panel.handleDeveloperToolsDockRequestFromFrontend(side: "bottom"))
        XCTAssertEqual(inspector.attachCount, 0)
        XCTAssertFalse(inspector.attached)
    }

    func testDockRequestRejectsUnknownSide() {
        let panel = BrowserPanel(workspaceId: UUID())
        let inspector = FakeInspector()
        panel.webView.cmuxSetUnitTestInspector(inspector)
        defer { panel.webView.cmuxSetUnitTestInspector(nil) }

        XCTAssertFalse(panel.handleDeveloperToolsDockRequestFromFrontend(side: "window"))
        XCTAssertEqual(inspector.attachCount, 0)
    }

}
