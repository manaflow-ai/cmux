import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class AppIconSettingsTests: XCTestCase {
    func testApplyDarkSetsRuntimeIconAndNotifiesDockTilePlugin() {
        let expectedIcon = NSImage(size: NSSize(width: 16, height: 16))
        var receivedRuntimeIcon: NSImage?
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { mode in
                XCTAssertEqual(mode, .dark)
                return expectedIcon
            },
            setApplicationIconImage: { icon in
                receivedRuntimeIcon = icon
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.dark, environment: environment)

        XCTAssertTrue(receivedRuntimeIcon === expectedIcon)
        XCTAssertEqual(dockTileNotificationCount, 1)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 1)
    }

    func testApplyAutomaticStartsObservationAndNotifiesDockTilePlugin() {
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { mode in
                XCTFail("Automatic mode should not request a manual icon image: \(mode.rawValue)")
                return nil
            },
            setApplicationIconImage: { _ in
                XCTFail("Automatic mode should delegate live updates to the appearance observer")
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.automatic, environment: environment)

        XCTAssertEqual(dockTileNotificationCount, 1)
        XCTAssertEqual(startObservationCallCount, 1)
        XCTAssertEqual(stopObservationCallCount, 0)
    }

    func testApplyDarkBeforeLaunchDoesNotTouchRuntimeIconState() {
        var imageRequestCount = 0
        var runtimeIconSetCount = 0
        var dockTileNotificationCount = 0
        var startObservationCallCount = 0
        var stopObservationCallCount = 0

        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { false },
            imageForMode: { _ in
                imageRequestCount += 1
                return NSImage(size: NSSize(width: 16, height: 16))
            },
            setApplicationIconImage: { _ in
                runtimeIconSetCount += 1
            },
            startAppearanceObservation: {
                startObservationCallCount += 1
            },
            stopAppearanceObservation: {
                stopObservationCallCount += 1
            },
            notifyDockTilePlugin: {
                dockTileNotificationCount += 1
            }
        )

        AppIconSettings.applyIcon(.dark, environment: environment)

        XCTAssertEqual(imageRequestCount, 0)
        XCTAssertEqual(runtimeIconSetCount, 0)
        XCTAssertEqual(dockTileNotificationCount, 0)
        XCTAssertEqual(startObservationCallCount, 0)
        XCTAssertEqual(stopObservationCallCount, 0)
    }
}

