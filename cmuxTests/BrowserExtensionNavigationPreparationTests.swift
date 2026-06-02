import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Browser extension navigation preparation")
struct BrowserExtensionNavigationPreparationTests {
    @Test("same-tab main-frame navigation needing preparation is intercepted")
    func sameTabMainFrameNavigationNeedingPreparationIsIntercepted() throws {
        let url = try #require(URL(string: "https://example.com/account"))

        #expect(
            browserNavigationShouldPrepareWebExtensionsBeforeAllowingMainFrameNavigation(
                requestURL: url,
                targetFrameIsMainFrame: true,
                shouldOpenInNewTab: false,
                needsPreparation: { $0.host == "example.com" }
            )
        )
    }

    @Test("subframe navigation does not intercept for extension preparation")
    func subframeNavigationDoesNotInterceptForExtensionPreparation() throws {
        let url = try #require(URL(string: "https://example.com/frame"))

        #expect(
            !browserNavigationShouldPrepareWebExtensionsBeforeAllowingMainFrameNavigation(
                requestURL: url,
                targetFrameIsMainFrame: false,
                shouldOpenInNewTab: false,
                needsPreparation: { _ in true }
            )
        )
    }

    @Test("new-tab navigation does not intercept for extension preparation")
    func newTabNavigationDoesNotInterceptForExtensionPreparation() throws {
        let url = try #require(URL(string: "https://example.com/new-tab"))

        #expect(
            !browserNavigationShouldPrepareWebExtensionsBeforeAllowingMainFrameNavigation(
                requestURL: url,
                targetFrameIsMainFrame: true,
                shouldOpenInNewTab: true,
                needsPreparation: { _ in true }
            )
        )
    }
}
