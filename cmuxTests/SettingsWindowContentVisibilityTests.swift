import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Settings window rendering a blank placeholder on
/// every open after the first within a session.
///
/// SwiftUI reuses the Settings `Window` scene across close / reopen, so the
/// scene's content-visibility state persists and the `WindowAccessor` that
/// supplies the window does not fire a second time. The original implementation
/// cleared the observed window on close and then rejected every subsequent
/// "became visible" notification, leaving the body stuck on the placeholder.
@MainActor
@Suite struct SettingsWindowContentVisibilityTests {
    /// Distinct object identities standing in for `NSWindow` instances.
    private final class WindowToken {}

    @Test func rendersContentOnFirstConfigure() {
        var visibility = SettingsWindowContentVisibility()
        let window = WindowToken()

        visibility.windowConfigured(ObjectIdentifier(window), isMiniaturized: false)

        #expect(visibility.shouldRenderContent)
    }

    @Test func hidesContentWhileMiniaturizedAndRestoresOnDeminiaturize() {
        var visibility = SettingsWindowContentVisibility()
        let window = WindowToken()
        let id = ObjectIdentifier(window)
        visibility.windowConfigured(id, isMiniaturized: false)

        visibility.windowDidMiniaturize(id)
        #expect(!visibility.shouldRenderContent)

        visibility.windowDidBecomeVisible(id, isSettingsWindow: true)
        #expect(visibility.shouldRenderContent)
    }

    /// The core regression: close then reopen the reused window. Because the
    /// reopen arrives only as a "became visible" notification (the accessor does
    /// not fire again), the model must re-adopt the Settings window and restore
    /// content. Before the fix this stayed `false` — a permanently blank window.
    @Test func restoresContentWhenReusedWindowReopensAfterClose() {
        var visibility = SettingsWindowContentVisibility()
        let window = WindowToken()
        let id = ObjectIdentifier(window)
        visibility.windowConfigured(id, isMiniaturized: false)

        visibility.windowWillClose(id)
        #expect(!visibility.shouldRenderContent)

        // Reopen: same reused NSWindow, only a become-visible notification.
        visibility.windowDidBecomeVisible(id, isSettingsWindow: true)
        #expect(visibility.shouldRenderContent)
    }

    @Test func survivesRepeatedCloseReopenCycles() {
        var visibility = SettingsWindowContentVisibility()
        let window = WindowToken()
        let id = ObjectIdentifier(window)
        visibility.windowConfigured(id, isMiniaturized: false)

        for _ in 0..<5 {
            visibility.windowWillClose(id)
            #expect(!visibility.shouldRenderContent)
            visibility.windowDidBecomeVisible(id, isSettingsWindow: true)
            #expect(visibility.shouldRenderContent)
        }
    }

    @Test func ignoresUnrelatedWindowsAfterClose() {
        var visibility = SettingsWindowContentVisibility()
        let settingsWindow = WindowToken()
        let otherWindow = WindowToken()
        visibility.windowConfigured(ObjectIdentifier(settingsWindow), isMiniaturized: false)
        visibility.windowWillClose(ObjectIdentifier(settingsWindow))

        // A non-settings window becoming key must not flip content back on.
        visibility.windowDidBecomeVisible(ObjectIdentifier(otherWindow), isSettingsWindow: false)
        #expect(!visibility.shouldRenderContent)
    }

    @Test func miniaturizeNotificationForUnrelatedWindowIsIgnored() {
        var visibility = SettingsWindowContentVisibility()
        let settingsWindow = WindowToken()
        let otherWindow = WindowToken()
        visibility.windowConfigured(ObjectIdentifier(settingsWindow), isMiniaturized: false)

        visibility.windowDidMiniaturize(ObjectIdentifier(otherWindow))
        #expect(visibility.shouldRenderContent)
    }
}
