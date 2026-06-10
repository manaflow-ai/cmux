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


// MARK: - Scroll lag capture
extension GhosttyConfigTests {
    func testScrollLagCaptureRequiresSustainedLag() {
        let cases: [(samples: Int, averageMs: Double, maxMs: Double, expected: Bool)] = [
            (4, 18, 85, false),
            (10, 6, 85, false),
            (10, 18, 35, false),
            (10, 18, 85, true),
        ]
        for testCase in cases {
            XCTAssertEqual(
                GhosttyApp.shouldCaptureScrollLagEvent(
                    samples: testCase.samples,
                    averageMs: testCase.averageMs,
                    maxMs: testCase.maxMs,
                    thresholdMs: 40,
                    nowUptime: 1000,
                    lastReportedUptime: nil
                ),
                testCase.expected
            )
        }
    }

    func testScrollLagCaptureRespectsCooldownWindow() {
        XCTAssertFalse(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 12,
                averageMs: 22,
                maxMs: 90,
                thresholdMs: 40,
                nowUptime: 1200,
                lastReportedUptime: 1005,
                cooldown: 300
            )
        )
        XCTAssertTrue(
            GhosttyApp.shouldCaptureScrollLagEvent(
                samples: 12,
                averageMs: 22,
                maxMs: 90,
                thresholdMs: 40,
                nowUptime: 1406,
                lastReportedUptime: 1005,
                cooldown: 300
            )
        )
    }

}
