import XCTest
import Foundation
import AppKit
import CmuxAppKitSupportUI
import CmuxBrowser
import CmuxFoundation
import CmuxSettings
import CmuxWindowing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserInsecureHTTPSettingsTests: XCTestCase {
    func testDefaultAllowlistPatternsArePresent() {
        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: nil),
            ["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]
        )
    }

    func testWildcardAndExactHostMatching() {
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("localhost", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("a.localhost", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("deep.a.localhost", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("127.0.0.1", rawAllowlist: nil))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("a.127.0.0.1", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("::1", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("0.0.0.0", rawAllowlist: nil))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("api.localtest.me", rawAllowlist: nil))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("neverssl.com", rawAllowlist: nil))
    }

    func testCustomAllowlistNormalizesAndDeduplicatesEntries() {
        let raw = """
        localhost
        *.example.com
        127.0.0.1
        https://dev.internal:8080/path
        *.example.com
        """

        XCTAssertEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: raw),
            ["localhost", "*.example.com", "127.0.0.1", "dev.internal"]
        )
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("foo.example.com", rawAllowlist: raw))
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("dev.internal", rawAllowlist: raw))
        XCTAssertFalse(BrowserInsecureHTTPSettings.isHostAllowed("example.net", rawAllowlist: raw))
    }

    func testBlockDecisionUsesAllowlistAndSchemeRules() throws {
        let localURL = try XCTUnwrap(URL(string: "http://foo.localtest.me:3000"))
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldBlock(localURL, rawAllowlist: nil))

        let localhostSubdomainURL = try XCTUnwrap(URL(string: "http://a.localhost:3000"))
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldBlock(localhostSubdomainURL, rawAllowlist: nil))

        let insecureURL = try XCTUnwrap(URL(string: "http://neverssl.com"))
        XCTAssertTrue(BrowserInsecureHTTPSettings.shouldBlock(insecureURL, rawAllowlist: nil))

        let httpsURL = try XCTUnwrap(URL(string: "https://neverssl.com"))
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldBlock(httpsURL, rawAllowlist: nil))
    }

    func testPreparedNavigationRequestPreservesOriginalMethodBodyAndHeaders() throws {
        let url = try XCTUnwrap(URL(string: "http://localtest.me:3000/submit"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("token=abc123".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let webView = CapturingBrowserLoadWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        _ = webView.browserLoadRequest(request)
        let prepared = try XCTUnwrap(webView.capturedRequest)

        XCTAssertEqual(prepared.url, url)
        XCTAssertEqual(prepared.httpMethod, "POST")
        XCTAssertEqual(prepared.httpBody, Data("token=abc123".utf8))
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(prepared.cachePolicy, .useProtocolCachePolicy)
    }

    func testOneTimeBypassIsConsumedAfterFirstNavigation() throws {
        let insecureURL = try XCTUnwrap(URL(string: "http://neverssl.com"))
        var bypassHostOnce: String? = "neverssl.com"

        XCTAssertTrue(BrowserInsecureHTTPSettings.shouldConsumeOneTimeBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        XCTAssertNil(bypassHostOnce)

        // Subsequent visits should prompt again unless host was saved.
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldConsumeOneTimeBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        XCTAssertTrue(BrowserInsecureHTTPSettings.shouldBlock(insecureURL, rawAllowlist: nil))
    }

    func testAddAllowedHostPersistsToDefaultsAndUnblocksHTTP() throws {
        let suiteName = "BrowserInsecureHTTPSettingsTests.Persist.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = try XCTUnwrap(URL(string: "http://persist-me.test"))
        XCTAssertTrue(BrowserInsecureHTTPSettings.shouldBlock(url, defaults: defaults))

        BrowserInsecureHTTPSettings.addAllowedHost("persist-me.test", defaults: defaults)
        let persisted = defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
        XCTAssertNotNil(persisted)
        XCTAssertTrue(BrowserInsecureHTTPSettings.isHostAllowed("persist-me.test", defaults: defaults))
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldBlock(url, defaults: defaults))
    }

    func testAllowlistSelectionPersistsForProceedAndOpenExternal() {
        XCTAssertTrue(BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(
            response: .alertFirstButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertTrue(BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(
            response: .alertThirdButtonReturn,
            suppressionEnabled: true
        ))
        XCTAssertFalse(BrowserInsecureHTTPSettings.shouldPersistAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: false
        ))
    }
}

private final class CapturingBrowserLoadWebView: WKWebView {
    private(set) var capturedRequest: URLRequest?

    override func load(_ request: URLRequest) -> WKNavigation? {
        capturedRequest = request
        return nil
    }
}

final class TitlebarControlsSizingPolicyTests: XCTestCase {
    func testSchedulePolicyRequiresMeaningfulViewSizeChange() {
        let policy = TitlebarControlsSizingPolicy()
        XCTAssertFalse(policy.shouldSchedule(previous: .zero, current: .zero))
        XCTAssertTrue(
            policy.shouldSchedule(
                previous: .zero,
                current: NSSize(width: 240, height: 38)
            )
        )
        XCTAssertFalse(
            policy.shouldSchedule(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 240.2, height: 38.1)
            )
        )
        XCTAssertTrue(
            policy.shouldSchedule(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 247, height: 38)
            )
        )
    }

    func testLayoutApplyPolicySkipsEquivalentSnapshots() {
        let policy = TitlebarControlsSizingPolicy()
        let baseline = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 128, height: 22),
            containerHeight: 28,
            xOffset: 0,
            yOffset: 3
        )
        XCTAssertTrue(policy.shouldApplyLayout(previous: nil, next: baseline))
        XCTAssertFalse(policy.shouldApplyLayout(previous: baseline, next: baseline))

        let changed = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 132, height: 22),
            containerHeight: 28,
            xOffset: 0,
            yOffset: 3
        )
        XCTAssertTrue(policy.shouldApplyLayout(previous: baseline, next: changed))

        let offsetChanged = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 128, height: 22),
            containerHeight: 28,
            xOffset: 1,
            yOffset: 3
        )
        XCTAssertTrue(policy.shouldApplyLayout(previous: baseline, next: offsetChanged))
    }

    func testTitlebarControlsListenForWindowGeometryChanges() {
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.didResizeNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.didEndLiveResizeNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.willEnterFullScreenNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.didEnterFullScreenNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.willExitFullScreenNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.didExitFullScreenNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.didChangeScreenNotification))
        XCTAssertTrue([Notification.Name].titlebarWindowGeometry.contains(NSWindow.didChangeBackingPropertiesNotification))
    }

    func testShortcutHintVerticalOffsetTucksPillIntoBottomOfButtonLane() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let hintHeight = config.shortcutHintHeight
            let verticalOffset = config.shortcutHintVerticalOffset

            XCTAssertLessThan(verticalOffset, config.buttonSize)
            XCTAssertGreaterThan(verticalOffset + hintHeight, config.buttonSize)
        }
    }

    func testShortcutHintVerticalGapStaysTuckedAgainstButtonLane() {
        XCTAssertEqual(TitlebarControlsStyleConfig.shortcutHintVerticalGap, -3, accuracy: 0.001)
    }

    func testTitlebarControlsUseNeutralVisualLift() {
        XCTAssertEqual(
            TitlebarControlsVisualMetrics.standard.liftedYOffset(3),
            3,
            accuracy: 0.001
        )
    }

    func testTitlebarControlsDefaultStyleIsCompact() {
        let suiteName = "TitlebarControlsDefaultStyleIsCompact-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TitlebarControlsStyle.defaultStyle, .compact)
        XCTAssertEqual(TitlebarControlsStyle.stored(in: defaults), .compact)

        defaults.set(TitlebarControlsStyle.classic.rawValue, forKey: TitlebarControlsStyle.storageKey)
        XCTAssertEqual(TitlebarControlsStyle.stored(in: defaults), .classic)

        defaults.set(999, forKey: TitlebarControlsStyle.storageKey)
        XCTAssertEqual(TitlebarControlsStyle.stored(in: defaults), .compact)
    }

    func testTitlebarControlsUseDeterministicContentSize() {
        let classic = TitlebarControlsStyle.classic.config.contentSize()
        XCTAssertEqual(classic.width, 152, accuracy: 0.001)
        XCTAssertEqual(classic.height, WindowChromeMetrics.appTitlebarHeight, accuracy: 0.001)

        let compact = TitlebarControlsStyle.compact.config.contentSize()
        XCTAssertEqual(compact.width, 139, accuracy: 0.001)
        XCTAssertEqual(compact.height, WindowChromeMetrics.appTitlebarHeight, accuracy: 0.001)
    }

    func testTitlebarControlsLeadingOffsetDoesNotDoubleApplyTrafficLightPosition() {
        let snapshot = MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultLeftControlsLeadingInset,
            leftControlsTopInset: MinimalModeTitlebarDebugSnapshot.defaultLeftControlsTopInset,
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTitlebarLeadingInset
        )
        let trafficLightFrame = NSRect(x: 18, y: 7, width: 14, height: 14)

        XCTAssertEqual(
            TitlebarControlsStyleConfig.leadingOffset(
                trafficLightFrame: trafficLightFrame,
                debugSnapshot: snapshot
            ),
            0,
            accuracy: 0.001
        )
    }

    func testTitlebarControlsLeadingOffsetDoesNotFollowSidebarTrailingEdge() {
        let snapshot = MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: 150,
            leftControlsTopInset: MinimalModeTitlebarDebugSnapshot.defaultLeftControlsTopInset,
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSnapshot.defaultTrafficLightTitlebarLeadingInset
        )

        XCTAssertEqual(
            TitlebarControlsStyleConfig.leadingOffset(
                trafficLightFrame: NSRect(x: 18, y: 7, width: 14, height: 14),
                debugSnapshot: snapshot
            ),
            78,
            accuracy: 0.001
        )
    }

    func testTitlebarControlsVerticalOffsetAlignsToTrafficLightsWhenAvailable() {
        let snapshot = MinimalModeTitlebarDebugSnapshot.snapshot()
        let yOffset = TitlebarControlsStyleConfig.yOffset(
            contentHeight: WindowChromeMetrics.appTitlebarHeight,
            containerHeight: 32,
            trafficLightFrame: NSRect(x: 20, y: 7, width: 14, height: 14),
            debugSnapshot: snapshot
        )

        XCTAssertEqual(yOffset, 0, accuracy: 0.001)
    }

    func testTitlebarControlsBalanceTopAndBottomAgainstTrafficLights() {
        let snapshot = MinimalModeTitlebarDebugSnapshot.snapshot()
        let trafficLightFrame = NSRect(x: 20, y: 7, width: 14, height: 14)
        let contentHeight = WindowChromeMetrics.appTitlebarHeight
        let yOffset = TitlebarControlsStyleConfig.yOffset(
            contentHeight: contentHeight,
            containerHeight: 32,
            trafficLightFrame: trafficLightFrame,
            debugSnapshot: snapshot
        )
        let contentFrame = NSRect(x: 0, y: yOffset, width: 100, height: contentHeight)

        XCTAssertEqual(contentFrame.midY, trafficLightFrame.midY, accuracy: 0.001)
        XCTAssertEqual(
            trafficLightFrame.minY - contentFrame.minY,
            contentFrame.maxY - trafficLightFrame.maxY,
            accuracy: 0.001
        )
    }

    func testTitlebarControlsVerticalOffsetFallsBackToTitlebarCenter() {
        let snapshot = MinimalModeTitlebarDebugSnapshot.snapshot()
        let yOffset = TitlebarControlsStyleConfig.yOffset(
            contentHeight: WindowChromeMetrics.appTitlebarHeight,
            containerHeight: 32,
            trafficLightFrame: nil,
            debugSnapshot: snapshot
        )

        XCTAssertEqual(yOffset, 2, accuracy: 0.001)
    }

    func testNotificationBadgeIsSmallAndShiftedUpRight() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config

            XCTAssertLessThan(
                config.notificationBadgeFontSize,
                8,
                "Expected a compact notification badge font for style \(style)"
            )
            XCTAssertGreaterThanOrEqual(
                config.badgeOffset.width,
                3,
                "Expected notification badge to sit farther right for style \(style)"
            )
            XCTAssertLessThanOrEqual(
                config.badgeOffset.height,
                -3,
                "Expected notification badge to sit farther up for style \(style)"
            )
        }
    }
}

final class TitlebarControlsHoverPolicyTests: XCTestCase {
    func testHoverTrackingEnabledForEveryTitlebarStyle() {
        for style in TitlebarControlsStyle.allCases {
            XCTAssertTrue(
                style.config.shouldTrackButtonHover,
                "Expected hover tracking for titlebar style \(style)"
            )
        }
    }

    func testButtonsStayVisuallyEvenAcrossTitlebarStyles() {
        let sizes = TitlebarControlsStyle.allCases.map { $0.config.buttonSize }
        let smallest = sizes.min() ?? 0
        let largest = sizes.max() ?? 0

        XCTAssertLessThanOrEqual(largest - smallest, 4)

        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)

            XCTAssertEqual(ranges.count, MinimalModeSidebarControlActionSlot.allCases.count)
            for (index, range) in ranges.enumerated() {
                let slot = MinimalModeSidebarControlActionSlot(rawValue: index)
                let expectedWidth: CGFloat = switch slot {
                case .some(.newTab):
                    TitlebarNewWorkspaceCloudSplitButtonMetrics.primaryWidth(config: config)
                case .some(.cloudVM):
                    TitlebarNewWorkspaceCloudSplitButtonMetrics.dropdownWidth(config: config)
                case .some(.toggleSidebar), .some(.showNotifications), .some(.focusHistoryBack), .some(.focusHistoryForward), nil:
                    config.buttonSize
                }
                XCTAssertEqual(
                    range.upperBound - range.lowerBound,
                    expectedWidth,
                    accuracy: 0.001,
                    "Expected titlebar hit lane width to match its visible control for style \(style)"
                )
            }
        }
    }

    func testHoverAndPressedStatesHaveVisibleDelta() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let idleForeground = TitlebarControlsStyleConfig.controlForegroundOpacity(isHovering: false, isPressed: false)
            let hoverForeground = TitlebarControlsStyleConfig.controlForegroundOpacity(isHovering: true, isPressed: false)
            let pressedForeground = TitlebarControlsStyleConfig.controlForegroundOpacity(isHovering: true, isPressed: true)

            XCTAssertGreaterThan(hoverForeground, idleForeground, "Expected hover foreground delta for style \(style)")
            XCTAssertGreaterThan(pressedForeground, hoverForeground, "Expected pressed foreground delta for style \(style)")
            XCTAssertGreaterThan(
                config.controlBackgroundOpacity(isHovering: true, isPressed: false),
                config.controlBackgroundOpacity(isHovering: false, isPressed: false),
                "Expected hover background delta for style \(style)"
            )
            XCTAssertGreaterThan(
                config.controlBackgroundOpacity(isHovering: true, isPressed: true),
                config.controlBackgroundOpacity(isHovering: true, isPressed: false),
                "Expected pressed background delta for style \(style)"
            )
            XCTAssertGreaterThanOrEqual(
                config.controlBorderOpacity(isHovering: true, isPressed: true),
                config.controlBorderOpacity(isHovering: true, isPressed: false),
                "Expected pressed border to stay at least as visible as hover for style \(style)"
            )
        }
    }

    func testStandaloneTitlebarHoverMatchesSplitButtonActiveSegment() {
        let compactConfig = TitlebarControlsStyle.compact.config
        let standaloneHoverOpacity = max(
            titlebarControlBackgroundOpacity(config: compactConfig, isHovering: true, isPressed: false),
            titlebarControlActiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true)
        )

        XCTAssertEqual(
            titlebarControlActiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true),
            standaloneHoverOpacity,
            accuracy: 0.001
        )
        XCTAssertEqual(
            titlebarControlPassiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true),
            0.016,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            titlebarControlPassiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true),
            titlebarControlBackgroundOpacity(config: compactConfig, isHovering: true, isPressed: false),
            "The inactive half of the compound plus/cloud control should be lighter than a normal hovered titlebar icon."
        )
        XCTAssertEqual(
            titlebarControlActiveHoverBackgroundOpacity(isHovering: false, isPressed: false, isEnabled: true),
            0,
            accuracy: 0.001
        )
    }

    func testIdleTitlebarButtonsStayReadableButMuted() {
        let idleForeground = TitlebarControlsStyleConfig.controlForegroundOpacity(isHovering: false, isPressed: false)

        XCTAssertGreaterThanOrEqual(idleForeground, 0.84)
        XCTAssertLessThan(idleForeground, 1.0)
    }

    func testPressedStateDoesNotScaleTitlebarButtons() {
        XCTAssertEqual(TitlebarControlsStyleConfig.controlPressedScale(isPressed: false), 1, accuracy: 0.001)
        XCTAssertEqual(TitlebarControlsStyleConfig.controlPressedScale(isPressed: true), 1, accuracy: 0.001)
    }

    func testDisabledStateMutesTitlebarButtons() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config

            XCTAssertLessThan(
                TitlebarControlsStyleConfig.controlForegroundOpacity(isHovering: true, isPressed: false, isEnabled: false),
                TitlebarControlsStyleConfig.controlForegroundOpacity(isHovering: false, isPressed: false, isEnabled: true),
                "Expected disabled foreground to stay muted for style \(style)"
            )
            XCTAssertEqual(
                config.controlBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: false),
                0,
                "Expected disabled titlebar button hover to have no active background for style \(style)"
            )
        }
    }

    func testMinimalModeHoverTrackerPassesMouseMovedThroughWhenButtonsAreVisible() {
        XCTAssertTrue(
            PassthroughHoverHitDecision(
                capturesPassiveHits: true,
                eventType: .mouseMoved,
                pressedMouseButtons: 0,
                boundsContainsPoint: true
            ).capturesHit,
            "Expected the hidden minimal-mode hover tracker to capture passive hover so controls reveal"
        )

        XCTAssertFalse(
            PassthroughHoverHitDecision(
                capturesPassiveHits: false,
                eventType: .mouseMoved,
                pressedMouseButtons: 0,
                boundsContainsPoint: true
            ).capturesHit,
            "Expected revealed minimal-mode buttons to receive mouseMoved so their hover style can update"
        )
    }

    func testMinimalModeHoverTrackerDoesNotCaptureMouseDownOrDraggedHover() {
        XCTAssertFalse(
            PassthroughHoverHitDecision(
                capturesPassiveHits: true,
                eventType: .leftMouseDown,
                pressedMouseButtons: 0,
                boundsContainsPoint: true
            ).capturesHit
        )
        XCTAssertFalse(
            PassthroughHoverHitDecision(
                capturesPassiveHits: true,
                eventType: .mouseMoved,
                pressedMouseButtons: 1,
                boundsContainsPoint: true
            ).capturesHit
        )
        XCTAssertFalse(
            PassthroughHoverHitDecision(
                capturesPassiveHits: true,
                eventType: .mouseMoved,
                pressedMouseButtons: 0,
                boundsContainsPoint: false
            ).capturesHit
        )
    }
}

@MainActor
final class NotificationsPopoverAnchorPolicyTests: XCTestCase {
    func testPreferredPopoverAnchorUsesVisibleButtonAnchorBeforeWideFallback() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let fallback = NSView(frame: NSRect(x: 20, y: 40, width: 160, height: 24))
        let buttonAnchor = NSView(frame: NSRect(x: 50, y: 2, width: 20, height: 20))
        contentView.addSubview(fallback)
        fallback.addSubview(buttonAnchor)

        XCTAssertTrue(
            NSView.preferredNotificationsPopoverAnchor(buttonAnchor: buttonAnchor, fallbackAnchor: fallback) === buttonAnchor
        )

        buttonAnchor.isHidden = true
        XCTAssertTrue(
            NSView.preferredNotificationsPopoverAnchor(buttonAnchor: buttonAnchor, fallbackAnchor: fallback) === fallback
        )
    }

    func testPreferredPopoverAnchorRejectsButtonAnchorFromDifferentWindow() {
        let sourceWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { sourceWindow.orderOut(nil) }
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { otherWindow.orderOut(nil) }
        guard let sourceContentView = sourceWindow.contentView,
              let otherContentView = otherWindow.contentView else {
            XCTFail("Expected content views")
            return
        }

        let fallback = NSView(frame: NSRect(x: 20, y: 40, width: 160, height: 24))
        let buttonAnchor = NSView(frame: NSRect(x: 50, y: 2, width: 20, height: 20))
        sourceContentView.addSubview(fallback)
        otherContentView.addSubview(buttonAnchor)

        XCTAssertTrue(
            NSView.preferredNotificationsPopoverAnchor(buttonAnchor: buttonAnchor, fallbackAnchor: fallback) === fallback
        )
    }

    func testNotificationAnchorRegistryFindsNearestVisibleButtonAnchor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let bellAnchor = NSView(frame: NSRect(x: 90, y: 60, width: 20, height: 20))
        let plusAnchor = NSView(frame: NSRect(x: 140, y: 60, width: 20, height: 20))
        contentView.addSubview(bellAnchor)
        contentView.addSubview(plusAnchor)
        NotificationsAnchorRegistry.shared.register(bellAnchor)
        NotificationsAnchorRegistry.shared.register(plusAnchor)

        let pointNearBell = NSPoint(x: bellAnchor.frame.midX + 2, y: bellAnchor.frame.midY)
        XCTAssertTrue(
            NotificationsAnchorRegistry.shared.closestAnchor(in: window, to: pointNearBell) === bellAnchor
        )

        bellAnchor.isHidden = true
        XCTAssertTrue(
            NotificationsAnchorRegistry.shared.closestAnchor(in: window, to: pointNearBell) === plusAnchor
        )
    }
}

@MainActor
final class AppIconAppearanceObserverTests: XCTestCase {
    private final class ObservationToken: AppIconAppearanceObservation {
        private(set) var invalidateCallCount = 0

        func invalidate() {
            invalidateCallCount += 1
        }
    }

    @MainActor
    private final class Harness {
        var isFinishedLaunching = false
        var isDark = false
        var startObservationCallCount = 0
        var currentAppearanceIsDarkCallCount = 0
        var imageRequests: [String] = []
        var appliedIconCount = 0
        var didFinishLaunchingObserverCount = 0
        private(set) var didFinishLaunchingHandler: (() -> Void)?
        private(set) var appearanceHandler: (() -> Void)?
        let observation = ObservationToken()
        let launchObservation = ObservationToken()

        lazy var environment = AppIconAppearanceObserver.Environment(
            isApplicationFinishedLaunching: { [unowned self] in
                self.isFinishedLaunching
            },
            startEffectiveAppearanceObservation: { [unowned self] handler in
                self.startObservationCallCount += 1
                self.appearanceHandler = handler
                return self.observation
            },
            addDidFinishLaunchingObserver: { [unowned self] handler in
                self.didFinishLaunchingObserverCount += 1
                self.didFinishLaunchingHandler = handler
                return self.launchObservation
            },
            currentAppearanceIsDark: { [unowned self] in
                self.currentAppearanceIsDarkCallCount += 1
                return self.isDark
            },
            applyIconImage: { [unowned self] imageName in
                self.imageRequests.append(imageName)
                self.appliedIconCount += 1
                return true
            }
        )

        func fireDidFinishLaunching() {
            didFinishLaunchingHandler?()
        }

        func fireAppearanceChanged() {
            appearanceHandler?()
        }
    }

    func testStartObservingDefersInitialApplyUntilLaunch() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()

        XCTAssertEqual(harness.didFinishLaunchingObserverCount, 1)
        XCTAssertEqual(harness.startObservationCallCount, 0)
        XCTAssertEqual(harness.currentAppearanceIsDarkCallCount, 0)
        XCTAssertTrue(harness.imageRequests.isEmpty)

        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        XCTAssertEqual(harness.startObservationCallCount, 1)
        XCTAssertEqual(harness.currentAppearanceIsDarkCallCount, 1)
        XCTAssertEqual(harness.imageRequests, ["AppIconLight"])
        XCTAssertEqual(harness.appliedIconCount, 1)
    }

    func testStopObservingCancelsDeferredLaunchApply() {
        let harness = Harness()
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()
        harness.isFinishedLaunching = true
        harness.fireDidFinishLaunching()

        XCTAssertEqual(harness.startObservationCallCount, 0)
        XCTAssertEqual(harness.currentAppearanceIsDarkCallCount, 0)
        XCTAssertTrue(harness.imageRequests.isEmpty)
        XCTAssertEqual(harness.appliedIconCount, 0)
    }

    func testStopObservingInvalidatesActiveObservation() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        observer.stopObserving()

        XCTAssertEqual(harness.startObservationCallCount, 1)
        XCTAssertEqual(harness.observation.invalidateCallCount, 1)
    }

    func testUnchangedAutomaticAppearanceDoesNotReapplyIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.fireAppearanceChanged()

        XCTAssertEqual(harness.currentAppearanceIsDarkCallCount, 2)
        XCTAssertEqual(harness.imageRequests, ["AppIconLight"])
        XCTAssertEqual(harness.appliedIconCount, 1)
    }

    func testAutomaticAppearanceChangeAppliesNewIcon() {
        let harness = Harness()
        harness.isFinishedLaunching = true
        let observer = AppIconAppearanceObserver(environment: harness.environment)

        observer.startObserving()
        harness.isDark = true
        harness.fireAppearanceChanged()

        XCTAssertEqual(harness.imageRequests, ["AppIconLight", "AppIconDark"])
        XCTAssertEqual(harness.appliedIconCount, 2)
    }
}
