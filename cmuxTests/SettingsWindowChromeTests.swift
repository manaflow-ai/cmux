import AppKit
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
        @Test func factoryBuildsModernUnifiedChromeWithWorkingSidebarToggle() throws {
            let window = SettingsWindowFactory.makeSettingsWindow(onContentAppear: {})
            defer {
                window.contentViewController = nil
                window.contentView = nil
                window.close()
            }

            #expect(window.styleMask.contains(.fullSizeContentView))
            #expect(window.toolbarStyle == .unifiedCompact)
            #expect(window.titlebarAppearsTransparent)
            #expect(window.titleVisibility == .hidden)
            #expect(window.titlebarSeparatorStyle == .none)

            let toolbar = try #require(window.toolbar)
            #expect(toolbar.delegate === window)
            #expect(!toolbar.allowsUserCustomization)
            #expect(!toolbar.autosavesConfiguration)
            #expect(toolbar.displayMode == .iconOnly)

            let sidebarToggle = try #require(
                toolbar.items.first { $0.itemIdentifier == .toggleSidebar }
            )
            #expect(sidebarToggle.target === window)
            #expect(sidebarToggle.action == #selector(NSSplitViewController.toggleSidebar(_:)))

            let recorder = SettingsSidebarToggleRecorder()
            defer { recorder.stopObserving() }
            let action = try #require(sidebarToggle.action)
            #expect(NSApp.sendAction(action, to: sidebarToggle.target, from: sidebarToggle))
            #expect(recorder.receivedCount == 1)
        }
    }
}
#endif
