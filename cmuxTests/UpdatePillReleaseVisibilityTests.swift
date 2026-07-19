import Foundation
import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func requireValue<T>(_ value: T?, _ message: String = "") throws -> T {
    do {
        return try #require(value)
    } catch {
        if !message.isEmpty {
            Issue.record(Comment(rawValue: message))
        }
        throw error
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual == expected, Comment(rawValue: message))
}

private func checkEqual<T: BinaryFloatingPoint>(_ actual: T, _ expected: T, accuracy: T, _ message: String = "") {
    let comment = message.isEmpty ? "\(actual) != \(expected) +/- \(accuracy)" : message
    #expect(abs(actual - expected) <= accuracy, Comment(rawValue: comment))
}

private func checkTrue(_ condition: @autoclosure () -> Bool, _ message: String = "") {
    #expect(condition(), Comment(rawValue: message))
}

private func checkFalse(_ condition: @autoclosure () -> Bool, _ message: String = "") {
    #expect(!condition(), Comment(rawValue: message))
}

private func checkNil<T>(_ value: @autoclosure () -> T?, _ message: String = "") {
    #expect(value() == nil, Comment(rawValue: message))
}

private func checkNotNil<T>(_ value: @autoclosure () -> T?, _ message: String = "") {
    #expect(value() != nil, Comment(rawValue: message))
}

private func checkLessThan<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual < expected, Comment(rawValue: message))
}

private func checkLessThanOrEqual<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual <= expected, Comment(rawValue: message))
}

private func checkGreaterThan<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual > expected, Comment(rawValue: message))
}

private func checkGreaterThanOrEqual<T: Comparable>(_ actual: T, _ expected: T, _ message: String = "") {
    #expect(actual >= expected, Comment(rawValue: message))
}

@Suite
struct BrowserInsecureHTTPSettingsTests {
    @Test
    func testDefaultAllowlistPatternsArePresent() {
        checkEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: nil),
            ["localhost", "*.localhost", "127.0.0.1", "::1", "0.0.0.0", "*.localtest.me"]
        )
    }

    @Test
    func testWildcardAndExactHostMatching() {
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("localhost", rawAllowlist: nil))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("a.localhost", rawAllowlist: nil))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("deep.a.localhost", rawAllowlist: nil))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("127.0.0.1", rawAllowlist: nil))
        checkFalse(BrowserInsecureHTTPSettings.isHostAllowed("a.127.0.0.1", rawAllowlist: nil))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("::1", rawAllowlist: nil))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("0.0.0.0", rawAllowlist: nil))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("api.localtest.me", rawAllowlist: nil))
        checkFalse(BrowserInsecureHTTPSettings.isHostAllowed("neverssl.com", rawAllowlist: nil))
    }

    @Test
    func testCustomAllowlistNormalizesAndDeduplicatesEntries() {
        let raw = """
        localhost
        *.example.com
        127.0.0.1
        https://dev.internal:8080/path
        *.example.com
        """

        checkEqual(
            BrowserInsecureHTTPSettings.normalizedAllowlistPatterns(rawValue: raw),
            ["localhost", "*.example.com", "127.0.0.1", "dev.internal"]
        )
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("foo.example.com", rawAllowlist: raw))
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("dev.internal", rawAllowlist: raw))
        checkFalse(BrowserInsecureHTTPSettings.isHostAllowed("example.net", rawAllowlist: raw))
    }

    @Test
    func testBlockDecisionUsesAllowlistAndSchemeRules() throws {
        let localURL = try requireValue(URL(string: "http://foo.localtest.me:3000"))
        checkFalse(browserShouldBlockInsecureHTTPURL(localURL, rawAllowlist: nil))

        let localhostSubdomainURL = try requireValue(URL(string: "http://a.localhost:3000"))
        checkFalse(browserShouldBlockInsecureHTTPURL(localhostSubdomainURL, rawAllowlist: nil))

        let insecureURL = try requireValue(URL(string: "http://neverssl.com"))
        checkTrue(browserShouldBlockInsecureHTTPURL(insecureURL, rawAllowlist: nil))

        let httpsURL = try requireValue(URL(string: "https://neverssl.com"))
        checkFalse(browserShouldBlockInsecureHTTPURL(httpsURL, rawAllowlist: nil))
    }

    @Test
    func testPreparedNavigationRequestPreservesOriginalMethodBodyAndHeaders() throws {
        let url = try requireValue(URL(string: "http://localtest.me:3000/submit"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("token=abc123".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let prepared = browserPreparedNavigationRequest(request)

        checkEqual(prepared.url, url)
        checkEqual(prepared.httpMethod, "POST")
        checkEqual(prepared.httpBody, Data("token=abc123".utf8))
        checkEqual(prepared.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        checkEqual(prepared.cachePolicy, .useProtocolCachePolicy)
    }

    @Test
    func testOneTimeBypassIsConsumedAfterFirstNavigation() throws {
        let insecureURL = try requireValue(URL(string: "http://neverssl.com"))
        var bypassHostOnce: String? = "neverssl.com"

        checkTrue(browserShouldConsumeOneTimeInsecureHTTPBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        checkNil(bypassHostOnce)

        // Subsequent visits should prompt again unless host was saved.
        checkFalse(browserShouldConsumeOneTimeInsecureHTTPBypass(
            insecureURL,
            bypassHostOnce: &bypassHostOnce
        ))
        checkTrue(browserShouldBlockInsecureHTTPURL(insecureURL, rawAllowlist: nil))
    }

    @Test
    func testAddAllowedHostPersistsToDefaultsAndUnblocksHTTP() throws {
        let suiteName = "BrowserInsecureHTTPSettingsTests.Persist.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let url = try requireValue(URL(string: "http://persist-me.test"))
        checkTrue(browserShouldBlockInsecureHTTPURL(url, defaults: defaults))

        BrowserInsecureHTTPSettings.addAllowedHost("persist-me.test", defaults: defaults)
        let persisted = defaults.string(forKey: BrowserInsecureHTTPSettings.allowlistKey)
        checkNotNil(persisted)
        checkTrue(BrowserInsecureHTTPSettings.isHostAllowed("persist-me.test", defaults: defaults))
        checkFalse(browserShouldBlockInsecureHTTPURL(url, defaults: defaults))
    }

    @Test
    func testAllowlistSelectionPersistsForProceedAndOpenExternal() {
        checkTrue(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertFirstButtonReturn,
            suppressionEnabled: true
        ))
        checkTrue(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: true
        ))
        checkFalse(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertThirdButtonReturn,
            suppressionEnabled: true
        ))
        checkFalse(browserShouldPersistInsecureHTTPAllowlistSelection(
            response: .alertSecondButtonReturn,
            suppressionEnabled: false
        ))
    }
}

@Suite
struct TitlebarControlsSizingPolicyTests {
    @Test
    func testSchedulePolicyRequiresMeaningfulViewSizeChange() {
        checkFalse(titlebarControlsShouldScheduleForViewSizeChange(previous: .zero, current: .zero))
        checkTrue(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: .zero,
                current: NSSize(width: 240, height: 38)
            )
        )
        checkFalse(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 240.2, height: 38.1)
            )
        )
        checkTrue(
            titlebarControlsShouldScheduleForViewSizeChange(
                previous: NSSize(width: 240, height: 38),
                current: NSSize(width: 247, height: 38)
            )
        )
    }

    @Test
    func testLayoutApplyPolicySkipsEquivalentSnapshots() {
        let baseline = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 128, height: 22),
            containerHeight: 28,
            xOffset: 0,
            yOffset: 3
        )
        checkTrue(titlebarControlsShouldApplyLayout(previous: nil, next: baseline))
        checkFalse(titlebarControlsShouldApplyLayout(previous: baseline, next: baseline))

        let changed = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 132, height: 22),
            containerHeight: 28,
            xOffset: 0,
            yOffset: 3
        )
        checkTrue(titlebarControlsShouldApplyLayout(previous: baseline, next: changed))

        let offsetChanged = TitlebarControlsLayoutSnapshot(
            contentSize: NSSize(width: 128, height: 22),
            containerHeight: 28,
            xOffset: 1,
            yOffset: 3
        )
        checkTrue(titlebarControlsShouldApplyLayout(previous: baseline, next: offsetChanged))
    }

    @Test
    func testTitlebarControlsListenForWindowGeometryChanges() {
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.didResizeNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.didEndLiveResizeNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.willEnterFullScreenNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.didEnterFullScreenNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.willExitFullScreenNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.didExitFullScreenNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.didChangeScreenNotification))
        checkTrue(TitlebarWindowGeometryNotifications.names.contains(NSWindow.didChangeBackingPropertiesNotification))
    }

    @Test
    func testShortcutHintVerticalOffsetTucksPillIntoBottomOfButtonLane() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let hintHeight = titlebarShortcutHintHeight(for: config)
            let verticalOffset = titlebarShortcutHintVerticalOffset(for: config)

            checkLessThan(verticalOffset, config.buttonSize)
            checkGreaterThan(verticalOffset + hintHeight, config.buttonSize)
        }
    }

    @Test
    func testShortcutHintVerticalGapStaysTuckedAgainstButtonLane() {
        checkEqual(TitlebarShortcutHintMetrics.verticalGap, -3, accuracy: 0.001)
    }

    @Test
    func testTitlebarControlsUseNeutralVisualLift() {
        checkEqual(
            TitlebarControlsVisualMetrics.liftedYOffset(3),
            3,
            accuracy: 0.001
        )
    }

    @Test
    func testTitlebarControlsDefaultStyleIsClassic() {
        let suiteName = "TitlebarControlsDefaultStyleIsClassic-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        checkEqual(TitlebarControlsStyle.defaultStyle, .classic)
        checkEqual(TitlebarControlsStyle.stored(in: defaults), .classic)

        defaults.set(TitlebarControlsStyle.compact.rawValue, forKey: TitlebarControlsStyle.storageKey)
        checkEqual(TitlebarControlsStyle.stored(in: defaults), .compact)

        defaults.set(999, forKey: TitlebarControlsStyle.storageKey)
        checkEqual(TitlebarControlsStyle.stored(in: defaults), .classic)
    }

    @Test
    func testTitlebarControlsUseDeterministicContentSize() {
        let classicConfig = TitlebarControlsStyle.classic.config
        let classic = TitlebarControlsLayoutMetrics.contentSize(config: classicConfig)
        let classicRepeat = TitlebarControlsLayoutMetrics.contentSize(config: classicConfig)
        checkEqual(classic, classicRepeat)
        checkEqual(classic.width, 152, accuracy: 0.001)
        checkEqual(classic.height, WindowChromeMetrics.appTitlebarHeight, accuracy: 0.001)

        let compactConfig = TitlebarControlsStyle.compact.config
        let compact = TitlebarControlsLayoutMetrics.contentSize(config: compactConfig)
        let compactRepeat = TitlebarControlsLayoutMetrics.contentSize(config: compactConfig)
        checkEqual(compact, compactRepeat)
        checkEqual(compact.width, 139, accuracy: 0.001)
        checkEqual(compact.height, WindowChromeMetrics.appTitlebarHeight, accuracy: 0.001)
    }

    @Test
    func testTitlebarControlsLeadingOffsetDoesNotDoubleApplyTrafficLightPosition() {
        let snapshot = MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset,
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        )
        let trafficLightFrame = NSRect(x: 18, y: 7, width: 14, height: 14)

        checkEqual(
            TitlebarControlsLayoutMetrics.leadingOffset(
                trafficLightFrame: trafficLightFrame,
                debugSnapshot: snapshot
            ),
            0,
            accuracy: 0.001
        )
    }

    @Test
    func testTitlebarControlsLeadingOffsetDoesNotFollowSidebarTrailingEdge() {
        let snapshot = MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: 150,
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset,
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset,
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset
        )

        checkEqual(
            TitlebarControlsLayoutMetrics.leadingOffset(
                trafficLightFrame: NSRect(x: 18, y: 7, width: 14, height: 14),
                debugSnapshot: snapshot
            ),
            78,
            accuracy: 0.001
        )
    }

    @Test
    func testTitlebarControlsVerticalOffsetAlignsToTrafficLightsWhenAvailable() {
        let snapshot = MinimalModeTitlebarDebugSettings.snapshot()
        let yOffset = TitlebarControlsLayoutMetrics.yOffset(
            contentHeight: WindowChromeMetrics.appTitlebarHeight,
            containerHeight: 32,
            trafficLightFrame: NSRect(x: 20, y: 7, width: 14, height: 14),
            debugSnapshot: snapshot
        )

        checkEqual(yOffset, 0, accuracy: 0.001)
    }

    @Test
    func testTitlebarControlsBalanceTopAndBottomAgainstTrafficLights() {
        let snapshot = MinimalModeTitlebarDebugSettings.snapshot()
        let trafficLightFrame = NSRect(x: 20, y: 7, width: 14, height: 14)
        let contentHeight = WindowChromeMetrics.appTitlebarHeight
        let yOffset = TitlebarControlsLayoutMetrics.yOffset(
            contentHeight: contentHeight,
            containerHeight: 32,
            trafficLightFrame: trafficLightFrame,
            debugSnapshot: snapshot
        )
        let contentFrame = NSRect(x: 0, y: yOffset, width: 100, height: contentHeight)

        checkEqual(contentFrame.midY, trafficLightFrame.midY, accuracy: 0.001)
        checkEqual(
            trafficLightFrame.minY - contentFrame.minY,
            contentFrame.maxY - trafficLightFrame.maxY,
            accuracy: 0.001
        )
    }

    @Test
    func testTitlebarControlsVerticalOffsetFallsBackToTitlebarCenter() {
        let snapshot = MinimalModeTitlebarDebugSettings.snapshot()
        let yOffset = TitlebarControlsLayoutMetrics.yOffset(
            contentHeight: WindowChromeMetrics.appTitlebarHeight,
            containerHeight: 32,
            trafficLightFrame: nil,
            debugSnapshot: snapshot
        )

        checkEqual(yOffset, 2, accuracy: 0.001)
    }

    @Test
    func testNotificationBadgeIsSmallAndShiftedUpRight() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config

            checkLessThan(
                titlebarNotificationBadgeFontSize(for: config),
                8,
                "Expected a compact notification badge font for style \(style)"
            )
            checkGreaterThanOrEqual(
                config.badgeOffset.width,
                3,
                "Expected notification badge to sit farther right for style \(style)"
            )
            checkLessThanOrEqual(
                config.badgeOffset.height,
                -3,
                "Expected notification badge to sit farther up for style \(style)"
            )
        }
    }
}

@Suite
struct TitlebarControlsHoverPolicyTests {
    @Test
    func testHoverTrackingEnabledForEveryTitlebarStyle() {
        for style in TitlebarControlsStyle.allCases {
            checkTrue(
                titlebarControlsShouldTrackButtonHover(config: style.config),
                "Expected hover tracking for titlebar style \(style)"
            )
        }
    }

    @Test
    func testButtonsStayVisuallyEvenAcrossTitlebarStyles() {
        let sizes = TitlebarControlsStyle.allCases.map { $0.config.buttonSize }
        let smallest = sizes.min() ?? 0
        let largest = sizes.max() ?? 0

        checkLessThanOrEqual(largest - smallest, 4)

        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let ranges = TitlebarControlsHitRegions.buttonXRanges(config: config)

            checkEqual(ranges.count, MinimalModeSidebarControlActionSlot.allCases.count)
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
                checkEqual(
                    range.upperBound - range.lowerBound,
                    expectedWidth,
                    accuracy: 0.001,
                    "Expected titlebar hit lane width to match its visible control for style \(style)"
                )
            }
        }
    }

    @Test
    func testHoverAndPressedStatesHaveVisibleDelta() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config
            let idleForeground = titlebarControlForegroundOpacity(isHovering: false, isPressed: false)
            let hoverForeground = titlebarControlForegroundOpacity(isHovering: true, isPressed: false)
            let pressedForeground = titlebarControlForegroundOpacity(isHovering: true, isPressed: true)

            checkGreaterThan(hoverForeground, idleForeground, "Expected hover foreground delta for style \(style)")
            checkGreaterThan(pressedForeground, hoverForeground, "Expected pressed foreground delta for style \(style)")
            checkGreaterThan(
                titlebarControlBackgroundOpacity(config: config, isHovering: true, isPressed: false),
                titlebarControlBackgroundOpacity(config: config, isHovering: false, isPressed: false),
                "Expected hover background delta for style \(style)"
            )
            checkGreaterThan(
                titlebarControlBackgroundOpacity(config: config, isHovering: true, isPressed: true),
                titlebarControlBackgroundOpacity(config: config, isHovering: true, isPressed: false),
                "Expected pressed background delta for style \(style)"
            )
            checkGreaterThanOrEqual(
                titlebarControlBorderOpacity(config: config, isHovering: true, isPressed: true),
                titlebarControlBorderOpacity(config: config, isHovering: true, isPressed: false),
                "Expected pressed border to stay at least as visible as hover for style \(style)"
            )
        }
    }

    @Test
    func testStandaloneTitlebarHoverMatchesSplitButtonActiveSegment() {
        let compactConfig = TitlebarControlsStyle.compact.config
        let standaloneHoverOpacity = max(
            titlebarControlBackgroundOpacity(config: compactConfig, isHovering: true, isPressed: false),
            titlebarControlActiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true)
        )

        checkEqual(
            titlebarControlActiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true),
            standaloneHoverOpacity,
            accuracy: 0.001
        )
        checkEqual(
            titlebarControlPassiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true),
            0.016,
            accuracy: 0.001
        )
        checkLessThan(
            titlebarControlPassiveHoverBackgroundOpacity(isHovering: true, isPressed: false, isEnabled: true),
            titlebarControlBackgroundOpacity(config: compactConfig, isHovering: true, isPressed: false),
            "The inactive half of the compound plus/cloud control should be lighter than a normal hovered titlebar icon."
        )
        checkEqual(
            titlebarControlActiveHoverBackgroundOpacity(isHovering: false, isPressed: false, isEnabled: true),
            0,
            accuracy: 0.001
        )
    }

    @Test
    func testIdleTitlebarButtonsStayReadableButMuted() {
        let idleForeground = titlebarControlForegroundOpacity(isHovering: false, isPressed: false)

        checkGreaterThanOrEqual(idleForeground, 0.84)
        checkLessThan(idleForeground, 1.0)
    }

    @Test
    func testPressedStateDoesNotScaleTitlebarButtons() {
        checkEqual(titlebarControlPressedScale(isPressed: false), 1, accuracy: 0.001)
        checkEqual(titlebarControlPressedScale(isPressed: true), 1, accuracy: 0.001)
    }

    @Test
    func testDisabledStateMutesTitlebarButtons() {
        for style in TitlebarControlsStyle.allCases {
            let config = style.config

            checkLessThan(
                titlebarControlForegroundOpacity(isHovering: true, isPressed: false, isEnabled: false),
                titlebarControlForegroundOpacity(isHovering: false, isPressed: false, isEnabled: true),
                "Expected disabled foreground to stay muted for style \(style)"
            )
            checkEqual(
                titlebarControlBackgroundOpacity(config: config, isHovering: true, isPressed: false, isEnabled: false),
                0,
                "Expected disabled titlebar button hover to have no active background for style \(style)"
            )
        }
    }

    @Test
    func testMinimalModeHoverTrackerPassesMouseMovedThroughWhenButtonsAreVisible() {
        checkTrue(
            minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: true,
                eventType: .mouseMoved,
                pressedMouseButtons: 0,
                boundsContainsPoint: true
            ),
            "Expected the hidden minimal-mode hover tracker to capture passive hover so controls reveal"
        )

        checkFalse(
            minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: false,
                eventType: .mouseMoved,
                pressedMouseButtons: 0,
                boundsContainsPoint: true
            ),
            "Expected revealed minimal-mode buttons to receive mouseMoved so their hover style can update"
        )
    }

    @Test
    func testMinimalModeHoverTrackerDoesNotCaptureMouseDownOrDraggedHover() {
        checkFalse(
            minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: true,
                eventType: .leftMouseDown,
                pressedMouseButtons: 0,
                boundsContainsPoint: true
            )
        )
        checkFalse(
            minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: true,
                eventType: .mouseMoved,
                pressedMouseButtons: 1,
                boundsContainsPoint: true
            )
        )
        checkFalse(
            minimalModePassthroughHoverTrackerCapturesHit(
                capturesPassiveHits: true,
                eventType: .mouseMoved,
                pressedMouseButtons: 0,
                boundsContainsPoint: false
            )
        )
    }
}

@MainActor
@Suite(.serialized)
struct NotificationsPopoverAnchorPolicyTests {
    @Test
    func testPreferredPopoverAnchorUsesVisibleButtonAnchorBeforeWideFallback() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            Issue.record("Expected content view")
            return
        }

        let fallback = NSView(frame: NSRect(x: 20, y: 40, width: 160, height: 24))
        let buttonAnchor = NSView(frame: NSRect(x: 50, y: 2, width: 20, height: 20))
        contentView.addSubview(fallback)
        fallback.addSubview(buttonAnchor)

        checkTrue(
            preferredNotificationsPopoverAnchor(buttonAnchor: buttonAnchor, fallbackAnchor: fallback) === buttonAnchor
        )

        buttonAnchor.isHidden = true
        checkTrue(
            preferredNotificationsPopoverAnchor(buttonAnchor: buttonAnchor, fallbackAnchor: fallback) === fallback
        )
    }

    @Test
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
            Issue.record("Expected content views")
            return
        }

        let fallback = NSView(frame: NSRect(x: 20, y: 40, width: 160, height: 24))
        let buttonAnchor = NSView(frame: NSRect(x: 50, y: 2, width: 20, height: 20))
        sourceContentView.addSubview(fallback)
        otherContentView.addSubview(buttonAnchor)

        checkTrue(
            preferredNotificationsPopoverAnchor(buttonAnchor: buttonAnchor, fallbackAnchor: fallback) === fallback
        )
    }

    @Test
    func testNotificationAnchorRegistryFindsNearestVisibleButtonAnchor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            Issue.record("Expected content view")
            return
        }

        let bellAnchor = NSView(frame: NSRect(x: 90, y: 60, width: 20, height: 20))
        let plusAnchor = NSView(frame: NSRect(x: 140, y: 60, width: 20, height: 20))
        contentView.addSubview(bellAnchor)
        contentView.addSubview(plusAnchor)
        NotificationsAnchorRegistry.shared.register(bellAnchor)
        NotificationsAnchorRegistry.shared.register(plusAnchor)

        let pointNearBell = NSPoint(x: bellAnchor.frame.midX + 2, y: bellAnchor.frame.midY)
        checkTrue(
            NotificationsAnchorRegistry.shared.closestAnchor(in: window, to: pointNearBell) === bellAnchor
        )

        bellAnchor.isHidden = true
        checkTrue(
            NotificationsAnchorRegistry.shared.closestAnchor(in: window, to: pointNearBell) === plusAnchor
        )
    }
}
