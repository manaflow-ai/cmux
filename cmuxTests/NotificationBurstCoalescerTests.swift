@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class NotificationBurstCoalescerTests: XCTestCase {
    func testSignalsInSameBurstFlushOnce() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush once")
        expectation.expectedFulfillmentCount = 1
        var flushCount = 0

        DispatchQueue.main.async {
            for _ in 0..<8 {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(flushCount, 1)
    }

    func testLatestActionWinsWithinBurst() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "latest action flushed")
        var value = 0

        DispatchQueue.main.async {
            coalescer.signal {
                value = 1
            }
            coalescer.signal {
                value = 2
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(value, 2)
    }

    func testSignalsAcrossBurstsFlushMultipleTimes() {
        let coalescer = NotificationBurstCoalescer(delay: 0.01)
        let expectation = expectation(description: "flush twice")
        expectation.expectedFulfillmentCount = 2
        var flushCount = 0

        DispatchQueue.main.async {
            coalescer.signal {
                flushCount += 1
                expectation.fulfill()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                coalescer.signal {
                    flushCount += 1
                    expectation.fulfill()
                }
            }
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(flushCount, 2)
    }
}

