import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserDeveloperToolsDockControlNormalizerTests: XCTestCase {
    private final class TrackingInspectorFrontendWebView: WKWebView {
        private(set) var evaluatedJavaScript: [String] = []

        @MainActor override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
        ) {
            evaluatedJavaScript.append(javaScriptString)
            completionHandler?(nil, nil)
        }
    }

    func testDetachedInspectorFrontendUsesDetachedDockButtonState() {
        let hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let inspectorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            hostWindow.close()
            inspectorWindow.close()
        }

        let inspectorFrontendWebView = TrackingInspectorFrontendWebView(
            frame: inspectorWindow.contentView?.bounds ?? .zero,
            configuration: WKWebViewConfiguration()
        )
        inspectorWindow.contentView?.addSubview(inspectorFrontendWebView)

        BrowserDeveloperToolsDockControlNormalizer().normalize(
            inspectorFrontendWebView: inspectorFrontendWebView,
            hostWindow: hostWindow
        )

        let script = inspectorFrontendWebView.evaluatedJavaScript.joined(separator: "\n")
        XCTAssertTrue(script.contains("const detachedFromHostWindow = true;"))
        XCTAssertTrue(script.contains("WI._dockBottomTabBarButton"))
        XCTAssertTrue(script.contains("WI._detachTabBarButton"))
    }
}
