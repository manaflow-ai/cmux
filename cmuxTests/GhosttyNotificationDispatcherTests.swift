import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyDefaultBackgroundNotificationDispatcherTests: XCTestCase {
    func testSignalCoalescesBurstToLatestBackground() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "coalesced notification")
        expectation.expectedFulfillmentCount = 1
        var postedUserInfos: [[AnyHashable: Any]] = []
        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                postedUserInfos.append(userInfo)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            self.signal(dispatcher, backgroundColor: dark, opacity: 0.95, eventId: 1, source: "test.dark")
            self.signal(dispatcher, backgroundColor: light, opacity: 0.75, eventId: 2, source: "test.light")
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedUserInfos.count, 1)
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString(),
            "#FDF6E3"
        )
        XCTAssertEqual(
            postedOpacity(from: postedUserInfos[0][GhosttyNotificationKey.backgroundOpacity]),
            0.75,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (postedUserInfos[0][GhosttyNotificationKey.backgroundEventId] as? NSNumber)?.uint64Value,
            2
        )
        XCTAssertEqual(
            postedUserInfos[0][GhosttyNotificationKey.backgroundSource] as? String,
            "test.light"
        )
    }

    func testSignalAcrossSeparateBurstsPostsMultipleNotifications() {
        guard let dark = NSColor(hex: "#272822"),
              let light = NSColor(hex: "#FDF6E3") else {
            XCTFail("Expected valid test colors")
            return
        }

        let expectation = expectation(description: "two notifications")
        expectation.expectedFulfillmentCount = 2
        var postedHexes: [String] = []
        let dispatcher = GhosttyDefaultBackgroundNotificationDispatcher(
            delay: 0.01,
            postNotification: { userInfo in
                let hex = (userInfo[GhosttyNotificationKey.backgroundColor] as? NSColor)?.hexString() ?? "nil"
                postedHexes.append(hex)
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            self.signal(dispatcher, backgroundColor: dark, opacity: 1.0, eventId: 1, source: "test.dark")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.signal(dispatcher, backgroundColor: light, opacity: 1.0, eventId: 2, source: "test.light")
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedHexes, ["#272822", "#FDF6E3"])
    }

    private func signal(
        _ dispatcher: GhosttyDefaultBackgroundNotificationDispatcher,
        backgroundColor: NSColor,
        opacity: Double,
        eventId: UInt64,
        source: String
    ) {
        dispatcher.signal(
            backgroundColor: backgroundColor,
            opacity: opacity,
            eventId: eventId,
            source: source,
            foregroundColor: backgroundColor,
            cursorColor: backgroundColor,
            cursorTextColor: backgroundColor,
            selectionBackground: backgroundColor,
            selectionForeground: backgroundColor
        )
    }

    private func postedOpacity(from value: Any?) -> Double {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        XCTFail("Expected background opacity payload")
        return -1
    }
}

final class GhosttyTitleNotificationDispatcherTests: XCTestCase {
    func testSignalCoalescesBurstToLatestTitle() {
        let tabId = UUID()
        let surfaceId = UUID()
        let expectation = expectation(description: "coalesced title notification")
        expectation.expectedFulfillmentCount = 1
        var postedTitles: [String] = []
        let dispatcher = GhosttyTitleNotificationDispatcher(
            delay: 0.01,
            postNotification: { _, userInfo in
                postedTitles.append(userInfo[GhosttyNotificationKey.title] as? String ?? "")
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: surfaceId, title: "vim")
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: surfaceId, title: "shell")
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedTitles, ["shell"])
    }

    func testSignalPostsLatestTitleForEachSurfaceInBurst() {
        let tabId = UUID()
        let firstSurfaceId = UUID()
        let secondSurfaceId = UUID()
        let expectation = expectation(description: "coalesced title notifications")
        expectation.expectedFulfillmentCount = 2
        var postedTitlesBySurface: [UUID: String] = [:]
        let dispatcher = GhosttyTitleNotificationDispatcher(
            delay: 0.01,
            postNotification: { _, userInfo in
                guard let surfaceId = userInfo[GhosttyNotificationKey.surfaceId] as? UUID else {
                    XCTFail("Expected surface id")
                    return
                }
                postedTitlesBySurface[surfaceId] = userInfo[GhosttyNotificationKey.title] as? String ?? ""
                expectation.fulfill()
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: firstSurfaceId, title: "old-1")
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: secondSurfaceId, title: "old-2")
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: firstSurfaceId, title: "new-1")
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(postedTitlesBySurface[firstSurfaceId], "new-1")
        XCTAssertEqual(postedTitlesBySurface[secondSurfaceId], "old-2")
    }

    func testSignalDropsRepeatedTitleAfterFlush() {
        let tabId = UUID()
        let surfaceId = UUID()
        let firstExpectation = expectation(description: "single repeated title notification")
        var postedTitles: [String] = []
        var repeatedExpectation: XCTestExpectation?
        let dispatcher = GhosttyTitleNotificationDispatcher(
            delay: 0.01,
            postNotification: { _, userInfo in
                postedTitles.append(userInfo[GhosttyNotificationKey.title] as? String ?? "")
                if postedTitles.count == 1 {
                    firstExpectation.fulfill()
                } else {
                    repeatedExpectation?.fulfill()
                }
            }
        )

        DispatchQueue.main.async {
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: surfaceId, title: "tmux")
        }
        wait(for: [firstExpectation], timeout: 1.0)

        let invertedExpectation = expectation(description: "repeated title not posted")
        invertedExpectation.isInverted = true
        repeatedExpectation = invertedExpectation
        DispatchQueue.main.async {
            dispatcher.signal(object: nil, tabId: tabId, surfaceId: surfaceId, title: "tmux")
        }
        wait(for: [invertedExpectation], timeout: 0.05)
        XCTAssertEqual(postedTitles, ["tmux"])
    }
}
