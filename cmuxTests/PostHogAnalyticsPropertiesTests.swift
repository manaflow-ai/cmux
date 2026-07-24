import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

@Suite(.serialized)
struct PostHogAnalyticsPropertiesTests {
    @MainActor
    @Test("feature flag control plane starts its injected remote loader")
    func featureFlagControlPlaneStartsInjectedRemoteLoader() async throws {
        let suiteName = "cmux.feature.flags.loader.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let probe = FeatureFlagRemoteLoaderProbe()
        let flags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil },
            remoteFlagLoader: { await probe.load() }
        )

        flags.start()
        await probe.waitUntilCalled()

        #expect(await probe.callCount == 1)
    }

    @MainActor
    @Test("feature flag control plane uses a stable anonymous rollout identity and targeting context")
    func featureFlagControlPlaneRespectsTelemetryConsent() throws {
        let suiteName = "cmux.feature.flags.identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identityKey = "cmux.flags.releaseControlDistinctID"

        let firstRequest = try #require(CmuxFeatureFlags.postHogControlPlaneRequest(
            telemetryEnabled: true,
            defaults: defaults
        ))
        let secondRequest = try #require(CmuxFeatureFlags.postHogControlPlaneRequest(
            telemetryEnabled: true,
            defaults: defaults
        ))
        let firstBody = try #require(firstRequest.httpBody)
        let secondBody = try #require(secondRequest.httpBody)
        let firstPayload = try #require(
            JSONSerialization.jsonObject(with: firstBody) as? [String: Any]
        )
        let secondPayload = try #require(
            JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        )
        let distinctID = try #require(firstPayload["distinctId"] as? String)
        let prefix = "cmux-desktop-release-control-"
        let context = try #require(firstPayload["context"] as? [String: Any])
        let personProperties = try #require(context["personProperties"] as? [String: Any])

        #expect(firstRequest.url?.host == "cmux.com")
        #expect(distinctID.hasPrefix(prefix))
        #expect(UUID(uuidString: String(distinctID.dropFirst(prefix.count))) != nil)
        #expect(secondPayload["distinctId"] as? String == distinctID)
        #expect(personProperties["$os"] as? String == "macOS")
        #expect((personProperties["cmux_architecture"] as? String)?.isEmpty == false)
        #expect(firstPayload["$anon_distinct_id"] == nil)
        #expect(firstPayload["person_properties"] == nil)
    }

    @MainActor
    @Test("feature flag control plane sends no persistent identity after telemetry opt-out")
    func featureFlagControlPlaneHonorsTelemetryOptOut() throws {
        let suiteName = "cmux.feature.flags.optout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let request = try #require(CmuxFeatureFlags.postHogControlPlaneRequest(
            telemetryEnabled: false,
            defaults: defaults
        ))
        let body = try #require(request.httpBody)
        let payload = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        #expect(payload["distinctId"] as? String == "cmux-desktop-release-control")
        #expect((payload["context"] as? [String: Any])?.isEmpty == true)
        #expect(defaults.object(forKey: "cmux.flags.releaseControlDistinctID") == nil)
    }

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

    @Test("feature flag control plane rejects partial errored responses")
    func featureFlagControlPlaneRejectsPartialErroredResponses() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            !$0.defaultWhenUnavailable
        })
        let payload = try JSONSerialization.data(withJSONObject: [
            "featureFlags": [flag.key: true],
            "featureFlagPayloads": [:],
            "errorsWhileComputingFlags": true,
        ])
        let completePayload = try JSONSerialization.data(withJSONObject: [
            "featureFlags": [flag.key: true],
            "featureFlagPayloads": [:],
            "errorsWhileComputingFlags": false,
        ])

        #expect(CmuxFeatureFlags.postHogControlPlaneFlagValues(from: payload) == nil)
        #expect(CmuxFeatureFlags.postHogControlPlaneFlagValues(
            from: completePayload
        ) == [flag.key: true])
    }

    @MainActor
    @Test("feature flag resolution prefers remote, then override, then default")
    func featureFlagResolutionPrecedence() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-appkit-list-experiment"
        })
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

        flags.setOverride(false, for: flag)
        #expect(flags.overrideValue(for: flag) == false)
        #expect(!flags.effectiveValue(for: flag))

        remoteValues[flag.key] = true
        flags.applyLoadedFlags()
        #expect(flags.overrideValue(for: flag) == false)
        #expect(flags.remoteValue(for: flag) == true)
        #expect(flags.effectiveValue(for: flag))

        remoteValues.removeValue(forKey: flag.key)
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == nil)
        #expect(!flags.effectiveValue(for: flag))

        flags.setOverride(nil, for: flag)
        #expect(flags.overrideValue(for: flag) == nil)
        #expect(flags.effectiveValue(for: flag))
    }

    @MainActor
    @Test("AppKit sidebar feature flag defaults on")
    func appKitSidebarFeatureFlagDefaultsOn() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-appkit-list-experiment"
        })
        #expect(flag.defaultWhenUnavailable)
    }

    @MainActor
    @Test("remote-controlled flags reject new local override writes")
    func remoteControlledFlagsRejectNewLocalOverrideWrites() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-appkit-list-experiment"
        })
        let suiteName = "cmux.feature.flags.remote.controlled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let remoteValues: [String: Any] = [flag.key: true]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }
        flags.applyLoadedFlags()

        flags.setOverride(false, for: flag)

        #expect(flags.overrideValue(for: flag) == nil)
        #expect(flags.effectiveValue(for: flag))
    }

    @MainActor
    @Test("Simulator defaults enabled and accepts a remote disable")
    func simulatorFeatureFlagKillSwitch() throws {
        let suiteName = "cmux.feature.flags.simulator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let flags = CmuxFeatureFlags(defaults: defaults) { _ in false }
        #expect(flags.isSimulatorEnabled)

        flags.applyLoadedFlags()
        #expect(!flags.isSimulatorEnabled)

        let offlineRelaunch = CmuxFeatureFlags(defaults: defaults) { _ in nil }
        #expect(!offlineRelaunch.isSimulatorEnabled)

        offlineRelaunch.applyLoadedFlags()
        #expect(!offlineRelaunch.isSimulatorEnabled)
    }

    @MainActor
    @Test("successful control-plane omission clears a cached remote disable")
    func successfulControlPlaneOmissionClearsCachedDisable() async throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.defaultWhenUnavailable
        })
        let suiteName = "cmux.feature.flags.omitted-disable.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let remoteCacheKey = "cmux.flags.remote.\(flag.key)"
        defaults.set(false, forKey: remoteCacheKey)
        let probe = FeatureFlagRemoteLoaderProbe()
        let flags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil },
            remoteFlagLoader: { await probe.load() }
        )
        #expect(flags.remoteValue(for: flag) == false)
        #expect(!flags.effectiveValue(for: flag))

        flags.start()
        await probe.waitUntilCalled()
        for _ in 0..<1_000 where flags.remoteValue(for: flag) != nil {
            await Task.yield()
        }

        #expect(flags.remoteValue(for: flag) == nil)
        #expect(flags.effectiveValue(for: flag))
        #expect(defaults.object(forKey: remoteCacheKey) == nil)
    }

    @MainActor
    @Test("missing refresh clears a cached enable for a default-off flag")
    func missingRefreshClearsCachedEnableForDefaultOffFlag() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first { !$0.defaultWhenUnavailable })
        let suiteName = "cmux.feature.flags.missing-enable.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var remoteValues: [String: Any] = [flag.key: true]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == true)
        #expect(flags.effectiveValue(for: flag))

        remoteValues.removeValue(forKey: flag.key)
        flags.applyLoadedFlags()
        #expect(flags.remoteValue(for: flag) == nil)
        #expect(!flags.effectiveValue(for: flag))

        let offlineRelaunch = CmuxFeatureFlags(defaults: defaults) { _ in nil }
        #expect(offlineRelaunch.remoteValue(for: flag) == nil)
        #expect(!offlineRelaunch.effectiveValue(for: flag))
    }

    @MainActor
    @Test("workspace todo controls feature flag follows remote values")
    func workspaceTodoControlsFeatureFlagFollowsRemoteValues() throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "workspace-todo-controls-enabled-release"
        })
        let suiteName = "cmux.workspace.todo.controls.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var remoteValues: [String: Any] = [:]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }

        #expect(!flags.isWorkspaceTodoControlsEnabled)

        remoteValues[flag.key] = false
        flags.applyLoadedFlags()
        #expect(!flags.isWorkspaceTodoControlsEnabled)

        remoteValues[flag.key] = true
        flags.applyLoadedFlags()
        #expect(flags.isWorkspaceTodoControlsEnabled)
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
    @Test("remote payload superseding a local override posts a change notification")
    func remotePayloadSupersedingLocalOverridePostsChangeNotification() async throws {
        let flag = try #require(CmuxFeatureFlags.allFlags.first {
            $0.key == "sidebar-appkit-list-experiment"
        })
        let suiteName = "cmux.feature.flags.notifications.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var remoteValues: [String: Any] = [:]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }
        flags.setOverride(false, for: flag)

        await confirmation("feature flag resolution changed") { didChange in
            let token = NotificationCenter.default.addObserver(
                forName: .cmuxFeatureFlagsDidChange,
                object: flags,
                queue: nil
            ) { _ in
                didChange()
            }
            defer { NotificationCenter.default.removeObserver(token) }

            remoteValues[flag.key] = true
            flags.applyLoadedFlags()
        }

        #expect(flags.overrideValue(for: flag) == false)
        #expect(flags.remoteValue(for: flag) == true)
        #expect(flags.effectiveValue(for: flag))
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

private actor FeatureFlagRemoteLoaderProbe {
    private(set) var callCount = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func load() -> [String: Bool]? {
        callCount += 1
        waiter?.resume()
        waiter = nil
        return [:]
    }

    func waitUntilCalled() async {
        if callCount > 0 { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
#endif
