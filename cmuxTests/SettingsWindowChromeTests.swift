import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
extension SettingsWindowSharedStateSuites {
    /// Window-construction coverage for the modern Settings chrome contract
    /// (https://github.com/manaflow-ai/cmux/issues/8010).
    @MainActor
    @Suite(.serialized)
    struct SettingsWindowChromeTests {
        @Test func factoryBuildsModernUnifiedChromeWithSwiftUIToolbarBridge() throws {
            let window = SettingsWindowFactory.makeSettingsWindow(onContentAppear: {})
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                window.contentView = nil
                window.close()
            }

            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.toolbarStyle == .unifiedCompact)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarSeparatorStyle == .none)

            let hostingController = try #require(
                window.contentViewController as? NSHostingController<SettingsWindowHostRoot>
            )
            #expect(hostingController.sceneBridgingOptions.contains(.toolbars))
            #expect(hostingController.sceneBridgingOptions.contains(.title))
        }
    }
}
#endif
