import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension XCTestCase {
    /// Pins the window-glass keys for one test and restores them after.
    /// Window glass is on by default, and a glass window clears a blank
    /// browser page so the glass shows through, so opaque-path tests opt out.
    func pinWindowGlass(enabled: Bool) {
        let defaults = UserDefaults.standard
        let savedGlass = defaults.object(forKey: "bgGlassEnabled") as? Bool
        let savedBlendMode = defaults.string(forKey: "sidebarBlendMode")
        defaults.set(enabled, forKey: "bgGlassEnabled")
        defaults.set("behindWindow", forKey: "sidebarBlendMode")
        addTeardownBlock {
            if let savedGlass { defaults.set(savedGlass, forKey: "bgGlassEnabled") } else { defaults.removeObject(forKey: "bgGlassEnabled") }
            if let savedBlendMode { defaults.set(savedBlendMode, forKey: "sidebarBlendMode") } else { defaults.removeObject(forKey: "sidebarBlendMode") }
        }
    }
}

@MainActor
final class BrowserGlassWindowBackgroundTests: XCTestCase {
    /// With window glass on (the default), a blank page leaves the glass
    /// showing: the panel clears its under-page fill instead of painting the
    /// terminal colour over it.
    func testBlankPageClearsUnderPageBackgroundOnGlassWindow() throws {
        pinWindowGlass(enabled: true)
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertTrue(panel.isShowingNewTabPage)

        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0),
                GhosttyNotificationKey.backgroundOpacity: 1.0,
            ]
        )

        let actual = try XCTUnwrap(panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.alphaComponent, 0, accuracy: 0.005)
    }
}
