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


final class PostHogAnalyticsPropertiesTests: XCTestCase {
    func testDailyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["day_utc"] as? String, "2026-02-21")
        XCTAssertEqual(properties["reason"] as? String, "didBecomeActive")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testSuperPropertiesIncludePlatformVersionAndBuild() {
        let properties = PostHogAnalytics.superProperties(
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["platform"] as? String, "cmuxterm")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testHourlyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        XCTAssertEqual(properties["hour_utc"] as? String, "2026-02-21T14")
        XCTAssertEqual(properties["reason"] as? String, "didBecomeActive")
        XCTAssertEqual(properties["app_version"] as? String, "0.31.0")
        XCTAssertEqual(properties["app_build"] as? String, "230")
    }

    func testHourlyPropertiesOmitVersionFieldsWhenUnavailable() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "activeTimer",
            infoDictionary: [:]
        )

        XCTAssertEqual(properties["hour_utc"] as? String, "2026-02-21T14")
        XCTAssertEqual(properties["reason"] as? String, "activeTimer")
        XCTAssertNil(properties["app_version"])
        XCTAssertNil(properties["app_build"])
    }

    func testPropertiesOmitVersionFieldsWhenUnavailable() {
        let superProperties = PostHogAnalytics.superProperties(infoDictionary: [:])
        XCTAssertEqual(superProperties["platform"] as? String, "cmuxterm")
        XCTAssertNil(superProperties["app_version"])
        XCTAssertNil(superProperties["app_build"])

        let dailyProperties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "activeTimer",
            infoDictionary: [:]
        )
        XCTAssertEqual(dailyProperties["day_utc"] as? String, "2026-02-21")
        XCTAssertEqual(dailyProperties["reason"] as? String, "activeTimer")
        XCTAssertNil(dailyProperties["app_version"])
        XCTAssertNil(dailyProperties["app_build"])
    }

    func testFlushPolicyIncludesDailyAndHourlyActiveEvents() {
        XCTAssertTrue(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_daily_active"))
        XCTAssertTrue(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_hourly_active"))
        XCTAssertFalse(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_other_event"))
    }
}

