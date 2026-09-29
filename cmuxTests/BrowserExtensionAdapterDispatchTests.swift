import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// WebKit calls the optional delegate and tab methods by Objective-C
/// selector. A Swift method whose name differs from the declared async name
/// (`snapshot(using:for:)` for `takeSnapshot...`) compiles but is never
/// called, and WebKit silently falls back to its default behavior, skipping
/// cmux's policy checks. These tests fail when an adapter method stops
/// matching its selector.
@MainActor
@Suite
struct BrowserExtensionAdapterDispatchTests {
    @Test func tabAdapterImplementsPolicyGatedSelectors() throws {
        guard #available(macOS 15.4, *) else { return }
        let selectors: [Selector] = [
            #selector(WKWebExtensionTab.takeSnapshot(using:for:completionHandler:)),
            #selector(WKWebExtensionTab.loadURL(_:for:completionHandler:)),
            #selector(WKWebExtensionTab.close(for:completionHandler:)),
            #selector(WKWebExtensionTab.activate(for:completionHandler:)),
            #selector(WKWebExtensionTab.reload(fromOrigin:for:completionHandler:)),
            #selector(WKWebExtensionTab.goBack(for:completionHandler:)),
            #selector(WKWebExtensionTab.goForward(for:completionHandler:)),
            #selector(WKWebExtensionTab.setZoomFactor(_:for:completionHandler:)),
            #selector(WKWebExtensionTab.webView(for:)),
            #selector(WKWebExtensionTab.shouldGrantPermissionsOnUserGesture(for:)),
        ]
        for selector in selectors {
            #expect(BrowserExtensionTab.instancesRespond(to: selector), "\(selector)")
        }
    }

    @Test func windowAdapterImplementsFocus() throws {
        guard #available(macOS 15.4, *) else { return }
        #expect(BrowserExtensionWindow.instancesRespond(to: #selector(WKWebExtensionWindow.focus(for:completionHandler:))))
    }

    @Test func controllerDelegateImplementsPolicyGatedSelectors() throws {
        guard #available(macOS 15.4, *) else { return }
        let selectors: [Selector] = [
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:openNewTabUsing:for:completionHandler:)),
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:openNewWindowUsing:for:completionHandler:)),
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:openOptionsPageFor:completionHandler:)),
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:promptForPermissions:in:for:completionHandler:)),
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:promptForPermissionToAccess:in:for:completionHandler:)),
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:promptForPermissionMatchPatterns:in:for:completionHandler:)),
            #selector(WKWebExtensionControllerDelegate.webExtensionController(_:presentActionPopup:for:completionHandler:)),
        ]
        for selector in selectors {
            #expect(BrowserExtensionController.instancesRespond(to: selector), "\(selector)")
        }
    }

    /// Repeated opens of one extension page (1Password's welcome page on every
    /// toolbar click) reuse its window; different pages get their own.
    @Test func extensionPageWindowsMatchByPageNotQuery() throws {
        guard #available(macOS 15.4, *) else { return }
        let base = "webkit-extension://abc/app/app.html"
        let welcome = try #require(URL(string: base + "#/page/welcome?language=en"))
        let again = try #require(URL(string: base + "#/page/welcome?language=fr"))
        let options = try #require(URL(string: "webkit-extension://abc/options/index.html"))
        let otherExtension = try #require(URL(string: "webkit-extension://def/app/app.html"))
        #expect(BrowserExtensions.samePage(welcome, again))
        #expect(!BrowserExtensions.samePage(welcome, options))
        #expect(!BrowserExtensions.samePage(welcome, otherExtension))
    }
}
