import AppKit
import Foundation
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class PrewarmTestWebExtensionHost: BrowserWebExtensionHosting {
    private(set) var attachedConfigurationCount = 0

    func attach(to configuration: WKWebViewConfiguration) {
        attachedConfigurationCount += 1
    }

    func webViewConfiguration(forNavigatingTo url: URL) -> BrowserWebExtensionNavigationConfiguration? {
        nil
    }

    func register(panel: BrowserPanel) {}
    func unregister(panelID: UUID) {}
    func noteActivated(panelID: UUID) {}
    func noteTabMetadataChanged(panelID: UUID) {}
    func performCommand(for event: NSEvent) -> Bool { false }
}
