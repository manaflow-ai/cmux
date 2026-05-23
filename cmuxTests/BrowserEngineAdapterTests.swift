import AppKit
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserEngineAdapterTests: XCTestCase {
    func testWebKitAdapterCapabilityMapPreservesCurrentBrowserBehavior() throws {
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let adapter = BrowserWebKitEngineAdapter(webView: webView)

        XCTAssertEqual(adapter.descriptor.kind, .webKit)
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.navigation))
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.javaScript))
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.snapshot))
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.downloads))
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.passkeys))
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.findInPage))
        XCTAssertTrue(adapter.descriptor.capabilities.supports(.frameScopedJavaScript))
        XCTAssertFalse(adapter.descriptor.capabilities.supports(.networkInterception))
        XCTAssertNoThrow(try adapter.descriptor.capabilities.require(.navigation, engineKind: adapter.descriptor.kind))
        XCTAssertThrowsError(
            try adapter.descriptor.capabilities.require(.networkInterception, engineKind: adapter.descriptor.kind)
        ) { error in
            XCTAssertEqual(
                error as? BrowserEngineUnsupportedCapabilityError,
                BrowserEngineUnsupportedCapabilityError(engineKind: .webKit, capability: .networkInterception)
            )
        }
    }

    func testOwlChromiumCapabilityMapMakesUnsupportedCapabilitiesExplicit() throws {
        let descriptor = BrowserEngineDescriptor(
            kind: .owlChromium,
            displayName: "Owl 2 Chromium",
            capabilities: .owlChromium,
            runtimeDescription: "test",
            fallbackReason: nil
        )

        XCTAssertTrue(descriptor.capabilities.supports(.navigation))
        XCTAssertTrue(descriptor.capabilities.supports(.javaScript))
        XCTAssertTrue(descriptor.capabilities.supports(.snapshot))
        XCTAssertTrue(descriptor.capabilities.supports(.focus))
        XCTAssertTrue(descriptor.capabilities.supports(.resize))
        XCTAssertTrue(descriptor.capabilities.supports(.contextMenus))
        XCTAssertTrue(descriptor.capabilities.supports(.profiles))
        XCTAssertFalse(descriptor.capabilities.supports(.devTools))
        XCTAssertFalse(descriptor.capabilities.supports(.downloads))
        XCTAssertFalse(descriptor.capabilities.supports(.passkeys))
        XCTAssertFalse(descriptor.capabilities.supports(.findInPage))
        XCTAssertFalse(descriptor.capabilities.supports(.frameScopedJavaScript))
        XCTAssertFalse(descriptor.capabilities.supports(.networkInterception))

        let payload = descriptor.socketPayload
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: Bool])
        XCTAssertEqual(capabilities[BrowserEngineCapability.navigation.rawValue], true)
        XCTAssertEqual(capabilities[BrowserEngineCapability.devTools.rawValue], false)
        XCTAssertEqual(capabilities[BrowserEngineCapability.downloads.rawValue], false)
        XCTAssertEqual(capabilities[BrowserEngineCapability.frameScopedJavaScript.rawValue], false)

        XCTAssertThrowsError(
            try descriptor.capabilities.require(.downloads, engineKind: descriptor.kind)
        ) { error in
            XCTAssertEqual(
                error as? BrowserEngineUnsupportedCapabilityError,
                BrowserEngineUnsupportedCapabilityError(engineKind: .owlChromium, capability: .downloads)
            )
        }

        XCTAssertFalse(BrowserEngineAdapterFactory.cmuxOwlConfiguration(profileID: UUID()).devToolsEnabled)
    }

    func testBrowserPanelRoutesNormalBrowserLifecycleThroughChromiumAdapter() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        let adapter = TestChromiumBrowserEngineAdapter()
        panel.installBrowserEngineForTesting(adapter)

        let url = try XCTUnwrap(URL(string: "https://example.com/owl"))
        panel.navigate(to: url, recordTypedNavigation: true)

        XCTAssertEqual(panel.browserEngineDescriptor.kind, .owlChromium)
        XCTAssertEqual(adapter.loadedURLs.last, url)
        XCTAssertEqual(panel.currentURL, url)

        XCTAssertTrue(panel.requestExplicitWebViewFocus())
        XCTAssertEqual(adapter.focusCount, 1)

        panel.updateBrowserEngineSurfaceGeometry(size: CGSize(width: 640, height: 480), scale: 2)
        XCTAssertEqual(adapter.resizeRequests.last?.size, CGSize(width: 640, height: 480))
        XCTAssertEqual(adapter.resizeRequests.last?.scale, 2)

        XCTAssertFalse(panel.showDeveloperTools())
        XCTAssertFalse(panel.toggleDeveloperTools())
        XCTAssertFalse(panel.showDeveloperToolsConsole())
        XCTAssertFalse(panel.isDeveloperToolsVisible())
        XCTAssertTrue(panel.hideDeveloperTools())
    }
}

@MainActor
private final class TestChromiumBrowserEngineAdapter: BrowserEngineAdapter {
    let nativeView = NSView(frame: .zero)
    let descriptor = BrowserEngineDescriptor(
        kind: .owlChromium,
        displayName: "Owl 2 Chromium Test",
        capabilities: .owlChromium,
        runtimeDescription: "test",
        fallbackReason: nil
    )
    var currentURL: URL?
    var title: String?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var estimatedProgress = 1.0
    var onStateChanged: (() -> Void)?
    private(set) var loadedURLs: [URL] = []
    private(set) var focusCount = 0
    private(set) var unfocusCount = 0
    private(set) var resizeRequests: [(size: CGSize, scale: CGFloat)] = []

    func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        loadedURLs.append(url)
        currentURL = url
        title = url.host
        onStateChanged?()
    }

    func goBack() {
        canGoBack = false
        onStateChanged?()
    }

    func goForward() {
        canGoForward = false
        onStateChanged?()
    }

    func reload() {
        onStateChanged?()
    }

    func stopLoading() {
        isLoading = false
        onStateChanged?()
    }

    func focus() {
        focusCount += 1
    }

    func unfocus() {
        unfocusCount += 1
    }

    func resize(to size: CGSize, scale: CGFloat) {
        resizeRequests.append((size: size, scale: scale))
    }

    func evaluateJavaScript(_ script: String) async throws -> Any? {
        script
    }

    func evaluateJavaScriptSynchronously(_ script: String) throws -> Any? {
        script
    }

    func takeSnapshot(completion: @escaping (NSImage?) -> Void) {
        completion(nil)
    }

    func close() {}
}
