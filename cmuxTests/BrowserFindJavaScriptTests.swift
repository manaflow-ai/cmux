import Testing
import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Find-in-page script generation and escaping moved into the CmuxBrowser package
// (BrowserFindScript). Its behavior is covered by CmuxBrowserTests/Find/BrowserFindServiceTests.

@Suite struct BrowserPopupDecisionTests {
    @Test func testLinkActivatedPlainLeftClickDoesNotCreatePopup() {
        #expect(
            !browserNavigationShouldCreatePopup(
                navigationType: .linkActivated,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    @Test func testOtherNavigationWithPopupFeaturesCreatesPopup() {
        #expect(
            browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0,
                popupFeaturesWereSpecified: true,
                currentEventType: .keyDown,
                currentEventButtonNumber: 0
            )
        )
    }

    @Test func testOtherNavigationWithoutPopupFeaturesDoesNotCreatePopup() {
        #expect(
            !browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 0
            )
        )
    }

    @Test func testOtherNavigationMiddleClickDoesNotCreatePopup() {
        #expect(
            !browserNavigationShouldCreatePopup(
                navigationType: .other,
                modifierFlags: [],
                buttonNumber: 2
            )
        )
    }

    @Test func testLinkActivatedCmdClickDoesNotCreatePopup() {
        #expect(
            !browserNavigationShouldCreatePopup(
                navigationType: .linkActivated,
                modifierFlags: [.command],
                buttonNumber: 0
            )
        )
    }

    @Test func testPopupFeaturesAreAbsentWhenAllWindowFeaturesAreNil() {
        #expect(
            !browserNavigationPopupFeaturesWereSpecified(
                x: nil,
                y: nil,
                width: nil,
                height: nil,
                menuBarVisibility: nil,
                statusBarVisibility: nil,
                toolbarsVisibility: nil,
                allowsResizing: nil
            )
        )
    }

    @Test func testPopupFeaturesArePresentWhenWidthIsSpecified() {
        #expect(
            browserNavigationPopupFeaturesWereSpecified(
                x: nil,
                y: nil,
                width: NSNumber(value: 640),
                height: nil,
                menuBarVisibility: nil,
                statusBarVisibility: nil,
                toolbarsVisibility: nil,
                allowsResizing: nil
            )
        )
    }
}

// MARK: - Blank-targeted scripted popups (#6649)

/// Covers the deferred-navigation popup predicate that fixes VS Code Web's inline
/// auth popup opening about:blank on the first attempt: a scripted window.open()
/// targeting a blank/empty document must return a live popup web view so the JS
/// window handle stays navigable, while still honoring explicit user new-tab gestures.
@Suite struct BrowserBlankScriptedPopupDecisionTests {
    @Test func testAboutBlankScriptedWindowOpenCreatesPopup() throws {
        // window.open("about:blank") with no features is the deferred-navigation
        // pattern (VS Code Web auth). It must return a live popup web view, even
        // though no window features were specified.
        let url = try #require(URL(string: "about:blank"))
        #expect(
            BrowserPanel.shouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: url,
                modifierFlags: [],
                buttonNumber: 0,
                hasRecentMiddleClickIntent: false,
                currentEventType: .leftMouseUp,
                currentEventButtonNumber: 0
            )
        )
    }

    @Test func testNilURLScriptedWindowOpenCreatesPopup() {
        // window.open() with no argument can surface a nil request URL.
        #expect(
            BrowserPanel.shouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: nil,
                modifierFlags: [],
                buttonNumber: 0,
                hasRecentMiddleClickIntent: false,
                currentEventType: .leftMouseUp,
                currentEventButtonNumber: 0
            )
        )
    }

    @Test func testRealDestinationURLDoesNotUseBlankPopupPath() throws {
        // window.open("https://example.com") already carries its destination, so a
        // tab navigation works; do not force it onto the blank-popup path.
        let url = try #require(URL(string: "https://example.com/"))
        #expect(
            !BrowserPanel.shouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: url,
                modifierFlags: [],
                buttonNumber: 0,
                hasRecentMiddleClickIntent: false,
                currentEventType: .leftMouseUp,
                currentEventButtonNumber: 0
            )
        )
    }

    @Test func testLinkActivatedNavigationDoesNotUseBlankPopupPath() throws {
        // A real link click (target=_blank) is .linkActivated, not scripted, and
        // must keep falling through to tab handling.
        let url = try #require(URL(string: "about:blank"))
        #expect(
            !BrowserPanel.shouldCreateBlankScriptedPopup(
                navigationType: .linkActivated,
                requestURL: url,
                modifierFlags: [],
                buttonNumber: 0,
                hasRecentMiddleClickIntent: false,
                currentEventType: .leftMouseUp,
                currentEventButtonNumber: 0
            )
        )
    }

    @Test func testBlankScriptedCmdClickFallsBackToNewTab() throws {
        // Cmd-click is an explicit user new-tab gesture: keep the new-tab fallback
        // instead of a floating popup, mirroring browserNavigationShouldCreatePopup.
        let url = try #require(URL(string: "about:blank"))
        #expect(
            !BrowserPanel.shouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: url,
                modifierFlags: [.command],
                buttonNumber: 0,
                hasRecentMiddleClickIntent: false,
                currentEventType: .leftMouseUp,
                currentEventButtonNumber: 0
            )
        )
    }

    @Test func testBlankScriptedMiddleClickFallsBackToNewTab() throws {
        // Middle-click is an explicit user new-tab gesture: keep the new-tab fallback.
        let url = try #require(URL(string: "about:blank"))
        #expect(
            !BrowserPanel.shouldCreateBlankScriptedPopup(
                navigationType: .other,
                requestURL: url,
                modifierFlags: [],
                buttonNumber: 2,
                hasRecentMiddleClickIntent: true,
                currentEventType: .otherMouseUp,
                currentEventButtonNumber: 2
            )
        )
    }
}
