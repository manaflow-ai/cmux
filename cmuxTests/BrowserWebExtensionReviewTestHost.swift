import AppKit
import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserWebExtensionReviewTestHost: BrowserWebExtensionHosting {
    private let extensionHost: String?
    private let contextToken = NSObject()

    init(extensionHost: String?) {
        self.extensionHost = extensionHost
    }

    var contextIdentifier: ObjectIdentifier {
        ObjectIdentifier(contextToken)
    }

    func attach(to configuration: WKWebViewConfiguration) {}

    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration? {
        guard url.scheme?.lowercased() == "webkit-extension",
              url.host == extensionHost else { return nil }
        // Mirror WKWebExtensionContext.webViewConfiguration: a fresh configuration
        // per navigation so fixed-name message handlers never share a controller.
        return BrowserWebExtensionNavigationConfiguration(
            contextIdentifier: contextIdentifier,
            webViewConfiguration: WKWebViewConfiguration()
        )
    }

    func register(panel: BrowserPanel) {}
    func unregister(panelID: UUID) {}
    func noteActivated(panelID: UUID) {}
    func noteTabMetadataChanged(panelID: UUID) {}
    func performCommand(for event: NSEvent) -> Bool { false }
}
