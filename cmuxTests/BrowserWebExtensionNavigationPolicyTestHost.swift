import AppKit
import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class BrowserWebExtensionNavigationPolicyTestHost: BrowserWebExtensionHosting {
    private let extensionHost: String?
    private let contextToken = NSObject()
    private let configuration = WKWebViewConfiguration()

    init(extensionHost: String?) {
        self.extensionHost = extensionHost
    }

    func attach(to configuration: WKWebViewConfiguration) {}

    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration? {
        guard url.scheme?.lowercased() == "webkit-extension",
              url.host == extensionHost else { return nil }
        return BrowserWebExtensionNavigationConfiguration(
            contextIdentifier: ObjectIdentifier(contextToken),
            webViewConfiguration: configuration
        )
    }

    func register(panel: BrowserPanel) {}
    func unregister(panelID: UUID) {}
    func noteActivated(panelID: UUID) {}
    func noteTabMetadataChanged(panelID: UUID) {}
    func performCommand(for event: NSEvent) -> Bool { false }
}
