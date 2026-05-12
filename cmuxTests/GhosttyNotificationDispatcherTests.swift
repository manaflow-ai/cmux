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
