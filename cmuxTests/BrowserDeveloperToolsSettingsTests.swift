import XCTest
import Combine
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Network

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Developer tools button, shortcut defaults, and configuration settings
final class BrowserDevToolsButtonDebugSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "BrowserDevToolsButtonDebugSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testIconCatalogIncludesExpandedChoices() {
        XCTAssertGreaterThanOrEqual(BrowserDevToolsIconOption.allCases.count, 10)
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.terminal))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.globe))
        XCTAssertTrue(BrowserDevToolsIconOption.allCases.contains(.curlyBracesSquare))
    }

    func testIconOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("this.symbol.does.not.exist", forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.iconOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultIcon
        )
    }

    func testColorOptionFallsBackToDefaultForUnknownRawValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set("notAValidColor", forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        XCTAssertEqual(
            BrowserDevToolsButtonDebugSettings.colorOption(defaults: defaults),
            BrowserDevToolsButtonDebugSettings.defaultColor
        )
    }

    func testBrowserToolbarAccessorySpacingDefaultsToTwoWhenUnset() {
        let defaults = makeIsolatedDefaults()
        defaults.removeObject(forKey: BrowserToolbarAccessorySpacingDebugSettings.key)

        XCTAssertEqual(
            BrowserToolbarAccessorySpacingDebugSettings.current(defaults: defaults),
            BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        )
    }

    func testBrowserToolbarAccessorySpacingFallsBackToDefaultForUnsupportedValue() {
        let defaults = makeIsolatedDefaults()
        defaults.set(99, forKey: BrowserToolbarAccessorySpacingDebugSettings.key)

        XCTAssertEqual(
            BrowserToolbarAccessorySpacingDebugSettings.current(defaults: defaults),
            BrowserToolbarAccessorySpacingDebugSettings.defaultSpacing
        )
    }

    func testBrowserProfilePopoverPaddingDefaultsWhenUnset() {
        let defaults = makeIsolatedDefaults()
        defaults.removeObject(forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        defaults.removeObject(forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)

        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
        )
        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultVerticalPadding
        )
    }

    func testBrowserProfilePopoverPaddingFallsBackForUnsupportedValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(-3, forKey: BrowserProfilePopoverDebugSettings.horizontalPaddingKey)
        defaults.set(999, forKey: BrowserProfilePopoverDebugSettings.verticalPaddingKey)

        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentHorizontalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultHorizontalPadding
        )
        XCTAssertEqual(
            BrowserProfilePopoverDebugSettings.currentVerticalPadding(defaults: defaults),
            BrowserProfilePopoverDebugSettings.defaultVerticalPadding
        )
    }

    func testCopyPayloadUsesPersistedValues() {
        let defaults = makeIsolatedDefaults()
        defaults.set(BrowserDevToolsIconOption.scope.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconNameKey)
        defaults.set(BrowserDevToolsIconColorOption.bonsplitActive.rawValue, forKey: BrowserDevToolsButtonDebugSettings.iconColorKey)

        let payload = BrowserDevToolsButtonDebugSettings.copyPayload(defaults: defaults)
        XCTAssertTrue(payload.contains("browserDevToolsIconName=scope"))
        XCTAssertTrue(payload.contains("browserDevToolsIconColor=bonsplitActive"))
    }
}


final class BrowserDeveloperToolsShortcutDefaultsTests: XCTestCase {
    func testSafariDefaultShortcutForToggleDeveloperTools() {
        let shortcut = KeyboardShortcutSettings.Action.toggleBrowserDeveloperTools.defaultShortcut
        XCTAssertEqual(shortcut.key, "i")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

    func testSafariDefaultShortcutForShowJavaScriptConsole() {
        let shortcut = KeyboardShortcutSettings.Action.showBrowserJavaScriptConsole.defaultShortcut
        XCTAssertEqual(shortcut.key, "c")
        XCTAssertTrue(shortcut.command)
        XCTAssertTrue(shortcut.option)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }

    func testDefaultShortcutForToggleReactGrabUsesCommandShiftG() {
        let shortcut = KeyboardShortcutSettings.Action.toggleReactGrab.defaultShortcut
        XCTAssertEqual(shortcut.key, "g")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.option)
        XCTAssertTrue(shortcut.shift)
        XCTAssertFalse(shortcut.control)
    }
}


@MainActor
final class BrowserDeveloperToolsConfigurationTests: XCTestCase {
    func testBrowserPanelEnablesInspectableWebViewAndDeveloperExtras() {
        let panel = BrowserPanel(workspaceId: UUID())
        let developerExtras = panel.webView.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool
        XCTAssertEqual(developerExtras, true)

        if #available(macOS 13.3, *) {
            XCTAssertTrue(panel.webView.isInspectable)
        }
    }

    func testBrowserPanelRefreshesUnderPageBackgroundColorWhenGhosttyBackgroundChanges() {
        let panel = BrowserPanel(workspaceId: UUID())
        let updatedColor = NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0)
        let updatedOpacity = 0.57

        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: updatedColor,
                GhosttyNotificationKey.backgroundOpacity: updatedOpacity
            ]
        )

        guard let actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB),
              let expected = updatedColor.withAlphaComponent(updatedOpacity).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible under-page background colors")
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.005)
    }

    func testBrowserPanelStartsAsNewTabWithoutLoadingAboutBlank() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertEqual(panel.displayTitle, "New tab")
        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertTrue(panel.isShowingNewTabPage)
        XCTAssertNil(panel.webView.url)
        XCTAssertNil(panel.currentURL)
    }

    func testBrowserPanelLeavesNewTabPageStateWhenNavigationStarts() {
        let panel = BrowserPanel(workspaceId: UUID())

        XCTAssertTrue(panel.isShowingNewTabPage)
        panel.navigate(to: URL(string: "https://example.com")!)
        XCTAssertFalse(panel.isShowingNewTabPage)
    }

    func testBrowserPanelWithDeferredInitialURLIsNotNewTabPage() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/restored"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            renderInitialNavigation: false
        )

        XCTAssertFalse(panel.shouldRenderWebView)
        XCTAssertEqual(panel.currentURL, url)
        XCTAssertFalse(panel.isShowingNewTabPage)
        XCTAssertEqual(panel.webViewLifecycleState, .deferredURL)
    }

    func testBrowserPanelThemeModeUpdatesWebViewAppearance() {
        let panel = BrowserPanel(workspaceId: UUID())

        panel.setBrowserThemeMode(.dark)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

        panel.setBrowserThemeMode(.light)
        XCTAssertEqual(panel.webView.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        panel.setBrowserThemeMode(.system)
        XCTAssertNil(panel.webView.appearance)
    }

    func testBrowserPanelRefreshesUnderPageBackgroundColorWithGhosttyOpacity() {
        let panel = BrowserPanel(workspaceId: UUID())
        let updatedColor = NSColor(srgbRed: 0.18, green: 0.29, blue: 0.44, alpha: 1.0)

        NotificationCenter.default.post(
            name: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.backgroundColor: updatedColor,
                GhosttyNotificationKey.backgroundOpacity: NSNumber(value: 0.57),
            ]
        )

        guard let actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB),
              let expected = updatedColor.withAlphaComponent(0.57).usingColorSpace(.sRGB) else {
            XCTFail("Expected sRGB-convertible under-page background colors")
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.005)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.005)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.005)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.005)
    }
}


