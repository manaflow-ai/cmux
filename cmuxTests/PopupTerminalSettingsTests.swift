import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PopupTerminalSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PopupTerminalSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Default values

    func testDefaultsReturnExpectedValuesWhenNothingIsSet() {
        XCTAssertTrue(PopupTerminalSettings.isEnabled(defaults: defaults))
        XCTAssertEqual(PopupTerminalSettings.position(defaults: defaults), .top)
        XCTAssertEqual(PopupTerminalSettings.screen(defaults: defaults), .activeScreen)
        XCTAssertEqual(PopupTerminalSettings.widthPercent(defaults: defaults), 100)
        XCTAssertEqual(PopupTerminalSettings.heightPercent(defaults: defaults), 50)
        XCTAssertTrue(PopupTerminalSettings.autoHideOnFocusLoss(defaults: defaults))
        XCTAssertEqual(PopupTerminalSettings.animationDuration(defaults: defaults), 0.08)
    }

    // MARK: - Bool round-trips

    func testIsEnabledPersistsValue() {
        defaults.set(false, forKey: PopupTerminalSettings.enabledKey)
        XCTAssertFalse(PopupTerminalSettings.isEnabled(defaults: defaults))

        defaults.set(true, forKey: PopupTerminalSettings.enabledKey)
        XCTAssertTrue(PopupTerminalSettings.isEnabled(defaults: defaults))
    }

    func testAutoHideOnFocusLossPersistsValue() {
        defaults.set(false, forKey: PopupTerminalSettings.autoHideOnFocusLossKey)
        XCTAssertFalse(PopupTerminalSettings.autoHideOnFocusLoss(defaults: defaults))

        defaults.set(true, forKey: PopupTerminalSettings.autoHideOnFocusLossKey)
        XCTAssertTrue(PopupTerminalSettings.autoHideOnFocusLoss(defaults: defaults))
    }

    // MARK: - Enum round-trips

    func testPositionPersistsAllCases() {
        for position in PopupTerminalSettings.Position.allCases {
            defaults.set(position.rawValue, forKey: PopupTerminalSettings.positionKey)
            XCTAssertEqual(PopupTerminalSettings.position(defaults: defaults), position)
        }
    }

    func testPositionFallsBackToDefaultForInvalidRawValue() {
        defaults.set("diagonal", forKey: PopupTerminalSettings.positionKey)
        XCTAssertEqual(PopupTerminalSettings.position(defaults: defaults), .top)
    }

    func testScreenSelectionPersistsAllCases() {
        for screen in PopupTerminalSettings.ScreenSelection.allCases {
            defaults.set(screen.rawValue, forKey: PopupTerminalSettings.screenKey)
            XCTAssertEqual(PopupTerminalSettings.screen(defaults: defaults), screen)
        }
    }

    func testScreenSelectionFallsBackToDefaultForInvalidRawValue() {
        defaults.set("thirdMonitor", forKey: PopupTerminalSettings.screenKey)
        XCTAssertEqual(PopupTerminalSettings.screen(defaults: defaults), .activeScreen)
    }

    // MARK: - Double round-trips

    func testWidthPercentPersistsValue() {
        defaults.set(75.0, forKey: PopupTerminalSettings.widthPercentKey)
        XCTAssertEqual(PopupTerminalSettings.widthPercent(defaults: defaults), 75.0)
    }

    func testHeightPercentPersistsValue() {
        defaults.set(30.0, forKey: PopupTerminalSettings.heightPercentKey)
        XCTAssertEqual(PopupTerminalSettings.heightPercent(defaults: defaults), 30.0)
    }

    func testAnimationDurationPersistsValue() {
        defaults.set(0.2, forKey: PopupTerminalSettings.animationDurationKey)
        XCTAssertEqual(PopupTerminalSettings.animationDuration(defaults: defaults), 0.2)
    }

    func testZeroDoubleFallsBackToDefault() {
        defaults.set(0.0, forKey: PopupTerminalSettings.widthPercentKey)
        XCTAssertEqual(PopupTerminalSettings.widthPercent(defaults: defaults), 100)

        defaults.set(0.0, forKey: PopupTerminalSettings.heightPercentKey)
        XCTAssertEqual(PopupTerminalSettings.heightPercent(defaults: defaults), 50)

        defaults.set(0.0, forKey: PopupTerminalSettings.animationDurationKey)
        XCTAssertEqual(PopupTerminalSettings.animationDuration(defaults: defaults), 0.08)
    }

    // MARK: - Enum labels

    func testPositionLabelsAreNonEmpty() {
        for position in PopupTerminalSettings.Position.allCases {
            XCTAssertFalse(position.label.isEmpty, "\(position) has empty label")
        }
    }

    func testScreenSelectionLabelsAreNonEmpty() {
        for screen in PopupTerminalSettings.ScreenSelection.allCases {
            XCTAssertFalse(screen.label.isEmpty, "\(screen) has empty label")
        }
    }
}

// MARK: - Frame computation tests

final class PopupTerminalFrameComputationTests: XCTestCase {

    /// A 1920x1080 visible frame starting at (0, 0).
    private let standardScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)

    /// A screen offset from origin (e.g. secondary monitor).
    private let offsetScreen = NSRect(x: 1920, y: 200, width: 1440, height: 900)

    // MARK: - Target frame positions

    func testTopPositionFramePinsToTopCenter() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .top, widthPercent: 100, heightPercent: 50,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.height, 540)
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxY, 1080)
    }

    func testBottomPositionFramePinsToBottomCenter() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .bottom, widthPercent: 100, heightPercent: 50,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.height, 540)
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.minY, 0)
    }

    func testLeftPositionFramePinsToLeftCenter() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .left, widthPercent: 50, heightPercent: 100,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.width, 960)
        XCTAssertEqual(frame.height, 1080)
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.midY, 540, accuracy: 1)
    }

    func testRightPositionFramePinsToRightCenter() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .right, widthPercent: 50, heightPercent: 100,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.width, 960)
        XCTAssertEqual(frame.height, 1080)
        XCTAssertEqual(frame.maxX, 1920)
        XCTAssertEqual(frame.midY, 540, accuracy: 1)
    }

    // MARK: - Centering with partial width

    func testTopPositionCentersHorizontallyWithPartialWidth() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .top, widthPercent: 80, heightPercent: 50,
            visibleFrame: standardScreen
        )
        let expectedWidth = 1920 * 0.8
        XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.01)
        XCTAssertEqual(frame.midX, 960, accuracy: 0.01)
    }

    // MARK: - Offset screen

    func testTargetFrameRespectsScreenOffset() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .top, widthPercent: 100, heightPercent: 50,
            visibleFrame: offsetScreen
        )
        XCTAssertEqual(frame.minX, 1920)
        XCTAssertEqual(frame.maxY, 1100)
        XCTAssertEqual(frame.width, 1440)
        XCTAssertEqual(frame.height, 450)
    }

    // MARK: - Percentage clamping

    func testWidthPercentClampedToMinimum10Percent() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .top, widthPercent: 1, heightPercent: 50,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.width, 1920 * 0.1, accuracy: 0.01)
    }

    func testHeightPercentClampedToMinimum10Percent() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .top, widthPercent: 50, heightPercent: 5,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.height, 1080 * 0.1, accuracy: 0.01)
    }

    func testPercentAbove100ClampedTo100() {
        let frame = PopupTerminalSettings.computeTargetFrame(
            position: .top, widthPercent: 200, heightPercent: 150,
            visibleFrame: standardScreen
        )
        XCTAssertEqual(frame.width, 1920)
        XCTAssertEqual(frame.height, 1080)
    }

    // MARK: - Offscreen frame computation

    func testTopOffscreenFrameMovesAboveScreen() {
        let target = NSRect(x: 0, y: 540, width: 1920, height: 540)
        let offscreen = PopupTerminalSettings.computeOffscreenFrame(
            for: target, position: .top, screenFrame: standardScreen
        )
        XCTAssertEqual(offscreen.minY, target.minY + target.height)
        XCTAssertGreaterThanOrEqual(offscreen.minY, standardScreen.maxY)
    }

    func testBottomOffscreenFrameMovesBelow() {
        let target = NSRect(x: 0, y: 0, width: 1920, height: 540)
        let offscreen = PopupTerminalSettings.computeOffscreenFrame(
            for: target, position: .bottom, screenFrame: standardScreen
        )
        XCTAssertEqual(offscreen.maxY, 0)
    }

    func testLeftOffscreenFrameMovesOffLeft() {
        let target = NSRect(x: 0, y: 0, width: 960, height: 1080)
        let offscreen = PopupTerminalSettings.computeOffscreenFrame(
            for: target, position: .left, screenFrame: standardScreen
        )
        XCTAssertLessThanOrEqual(offscreen.maxX, standardScreen.minX)
    }

    func testRightOffscreenFrameMovesOffRight() {
        let target = NSRect(x: 960, y: 0, width: 960, height: 1080)
        let offscreen = PopupTerminalSettings.computeOffscreenFrame(
            for: target, position: .right, screenFrame: standardScreen
        )
        XCTAssertGreaterThanOrEqual(offscreen.minX, standardScreen.maxX)
    }

    func testOffscreenFramePreservesSize() {
        for position in PopupTerminalSettings.Position.allCases {
            let target = NSRect(x: 100, y: 100, width: 800, height: 600)
            let offscreen = PopupTerminalSettings.computeOffscreenFrame(
                for: target, position: position, screenFrame: standardScreen
            )
            XCTAssertEqual(offscreen.width, target.width, "\(position) changed width")
            XCTAssertEqual(offscreen.height, target.height, "\(position) changed height")
        }
    }
}
