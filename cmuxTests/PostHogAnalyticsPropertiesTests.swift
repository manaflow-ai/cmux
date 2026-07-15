import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite(.serialized)
struct PostHogAnalyticsPropertiesTests {
    @Test("feature flag bool coercion accepts PostHog bool-like values")
    func featureFlagBoolCoercionAcceptsPostHogBoolLikeValues() {
        #expect(CmuxFeatureFlags.coerceBoolFlagValue(true, default: false))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(false, default: true))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue(NSNumber(value: true), default: false))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(NSNumber(value: false), default: true))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue("TRUE", default: false))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(" false ", default: true))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue("not-a-bool", default: true))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue("not-a-bool", default: false))
        #expect(CmuxFeatureFlags.coerceBoolFlagValue(nil, default: true))
        #expect(!CmuxFeatureFlags.coerceBoolFlagValue(nil, default: false))
    }

    @MainActor
    @Test("feature flag resolution prefers override, then remote, then default")
    func featureFlagResolutionPrecedence() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first { $0.defaultWhenUnavailable })
        let suiteName = "cmux.feature.flags.precedence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var remoteValues: [String: Any] = [:]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }

        #expect(flags.overrideValue(for: flag) == nil)
        #expect(flags.remoteValue(for: flag) == nil)
        #expect(flags.effectiveValue(for: flag))

        remoteValues[flag.key] = false
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == false)
        #expect(!flags.effectiveValue(for: flag))

        flags.setOverride(true, for: flag)
        #expect(flags.overrideValue(for: flag) == true)
        #expect(flags.remoteValue(for: flag) == false)
        #expect(flags.effectiveValue(for: flag))

        flags.setOverride(nil, for: flag)
        #expect(flags.overrideValue(for: flag) == nil)
        #expect(!flags.effectiveValue(for: flag))

        remoteValues.removeValue(forKey: flag.key)
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == nil)
        #expect(flags.effectiveValue(for: flag))
    }

    @MainActor
    @Test("feature flag overrides persist through UserDefaults")
    func featureFlagOverridePersistenceRoundTrip() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first { $0.defaultWhenUnavailable })
        let suiteName = "cmux.feature.flags.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstLoad = CmuxFeatureFlags(defaults: defaults) { _ in true }
        firstLoad.setOverride(false, for: flag)
        #expect(firstLoad.overrideValue(for: flag) == false)
        #expect(!firstLoad.effectiveValue(for: flag))

        let secondLoad = CmuxFeatureFlags(defaults: defaults) { _ in true }
        #expect(secondLoad.overrideValue(for: flag) == false)
        #expect(!secondLoad.effectiveValue(for: flag))

        secondLoad.setOverride(nil, for: flag)
        let thirdLoad = CmuxFeatureFlags(defaults: defaults) { _ in true }
        #expect(thirdLoad.overrideValue(for: flag) == nil)
        #expect(thirdLoad.effectiveValue(for: flag))
    }

    @MainActor
    @Test("feature flag override notifications follow effective value changes")
    func featureFlagOverrideNotificationsFollowEffectiveValueChanges() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first { $0.defaultWhenUnavailable })
        let suiteName = "cmux.feature.flags.notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let remoteValues: [String: Any] = [flag.key: false]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }
        flags.applyLoadedFlags()

        let notificationQueue = DispatchQueue(label: "cmux.feature.flags.notification.count")
        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: .cmuxFeatureFlagsDidChange,
            object: flags,
            queue: nil
        ) { _ in
            notificationQueue.sync {
                notificationCount += 1
            }
        }
        defer {
            NotificationCenter.default.removeObserver(token)
        }

        flags.setOverride(false, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 0)

        flags.setOverride(true, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 1)

        flags.setOverride(true, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 1)

        flags.setOverride(nil, for: flag)
        #expect(notificationQueue.sync { notificationCount } == 2)
    }

    @Test
    func dailyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        #expect(properties["day_utc"] as? String == "2026-02-21")
        #expect(properties["reason"] as? String == "didBecomeActive")
        #expect(properties["app_version"] as? String == "0.31.0")
        #expect(properties["app_build"] as? String == "230")
    }

    @Test
    func superPropertiesIncludePlatformVersionAndBuild() {
        let properties = PostHogAnalytics.superProperties(
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        #expect(properties["platform"] as? String == "cmuxterm")
        #expect(properties["app_version"] as? String == "0.31.0")
        #expect(properties["app_build"] as? String == "230")
    }

    @Test
    func hourlyActivePropertiesIncludeVersionAndBuild() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "didBecomeActive",
            infoDictionary: [
                "CFBundleShortVersionString": "0.31.0",
                "CFBundleVersion": "230",
            ]
        )

        #expect(properties["hour_utc"] as? String == "2026-02-21T14")
        #expect(properties["reason"] as? String == "didBecomeActive")
        #expect(properties["app_version"] as? String == "0.31.0")
        #expect(properties["app_build"] as? String == "230")
    }

    @Test
    func hourlyPropertiesOmitVersionFieldsWhenUnavailable() {
        let properties = PostHogAnalytics.hourlyActiveProperties(
            hourUTC: "2026-02-21T14",
            reason: "activeTimer",
            infoDictionary: [:]
        )

        #expect(properties["hour_utc"] as? String == "2026-02-21T14")
        #expect(properties["reason"] as? String == "activeTimer")
        #expect(properties["app_version"] == nil)
        #expect(properties["app_build"] == nil)
    }

    @Test
    func propertiesOmitVersionFieldsWhenUnavailable() {
        let superProperties = PostHogAnalytics.superProperties(infoDictionary: [:])
        #expect(superProperties["platform"] as? String == "cmuxterm")
        #expect(superProperties["app_version"] == nil)
        #expect(superProperties["app_build"] == nil)

        let dailyProperties = PostHogAnalytics.dailyActiveProperties(
            dayUTC: "2026-02-21",
            reason: "activeTimer",
            infoDictionary: [:]
        )
        #expect(dailyProperties["day_utc"] as? String == "2026-02-21")
        #expect(dailyProperties["reason"] as? String == "activeTimer")
        #expect(dailyProperties["app_version"] == nil)
        #expect(dailyProperties["app_build"] == nil)
    }

    @Test
    func flushPolicyIncludesDailyAndHourlyActiveEvents() {
        #expect(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_daily_active"))
        #expect(PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_hourly_active"))
        #expect(!PostHogAnalytics.shouldFlushAfterCapture(event: "cmux_other_event"))
    }

    @Test
    func activeEventCaptureFlushesBeforeShutdown() throws {
        let suiteName = "cmux.posthog.analytics.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fixedDate = try #require(Calendar(identifier: .iso8601).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 21,
            hour: 14
        )))
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.capture")
        var capturedEvents: [(event: String, properties: [String: Any])] = []
        let eventsCaptured = DispatchSemaphore(value: 0)
        let flushCalled = DispatchSemaphore(value: 0)
        let analytics = PostHogAnalytics.makeForTesting(
            workQueue: DispatchQueue(label: "com.cmux.tests.posthog.analytics"),
            didStart: true,
            userDefaults: defaults,
            now: { fixedDate },
            capturePostHog: { event, properties in
                capturedQueue.sync {
                    capturedEvents.append((event: event, properties: properties))
                    if capturedEvents.count == 2 {
                        eventsCaptured.signal()
                    }
                }
            },
            flushPostHog: {
                flushCalled.signal()
            }
        )

        analytics.trackActive(reason: "didBecomeActive")
        #expect(eventsCaptured.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushCalled.wait(timeout: .now() + .seconds(1)) == .success)
        let events = capturedQueue.sync { capturedEvents }
        #expect(events.map(\.event) == ["cmux_daily_active", "cmux_hourly_active"])
        let dailyEvent = try #require(events.first)
        let hourlyEvent = try #require(events.dropFirst().first)
        #expect(dailyEvent.properties["day_utc"] as? String == "2026-02-21")
        #expect(dailyEvent.properties["reason"] as? String == "didBecomeActive")
        #expect(hourlyEvent.properties["hour_utc"] as? String == "2026-02-21T14")
        #expect(hourlyEvent.properties["reason"] as? String == "didBecomeActive")
    }

    @Test
    func activeFlushDoesNotBlockMainThreadWhenSDKFlushBlocks() throws {
        let suiteName = "cmux.posthog.analytics.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fixedDate = try #require(Calendar(identifier: .iso8601).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 2,
            day: 21,
            hour: 14
        )))
        let flushStarted = DispatchSemaphore(value: 0)
        let flushCanReturn = DispatchSemaphore(value: 0)
        let flushReturned = DispatchSemaphore(value: 0)
        let flushRanOnMainThread = DispatchSemaphore(value: 0)
        let flushRanOffMainThread = DispatchSemaphore(value: 0)
        let callerReturned = DispatchSemaphore(value: 0)
        let analytics = PostHogAnalytics.makeForTesting(
            workQueue: DispatchQueue(label: "com.cmux.tests.posthog.analytics"),
            didStart: true,
            userDefaults: defaults,
            now: { fixedDate },
            capturePostHog: { _, _ in },
            flushPostHog: {
                if Thread.isMainThread {
                    flushRanOnMainThread.signal()
                } else {
                    flushRanOffMainThread.signal()
                }
                flushStarted.signal()
                _ = flushCanReturn.wait(timeout: .now() + .seconds(5))
                flushReturned.signal()
            }
        )

        let trackActiveOnMainThread = {
            analytics.trackActive(reason: "didBecomeActive")
            callerReturned.signal()
        }

        if Thread.isMainThread {
            trackActiveOnMainThread()
        } else {
            DispatchQueue.main.async(execute: trackActiveOnMainThread)
        }

        #expect(callerReturned.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushStarted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushRanOffMainThread.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(flushRanOnMainThread.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        #expect(flushReturned.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
        flushCanReturn.signal()
        #expect(flushReturned.wait(timeout: .now() + .seconds(1)) == .success)
    }
}
#endif
