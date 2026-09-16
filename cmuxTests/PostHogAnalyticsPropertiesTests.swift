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

    @Test("feature flag control plane stops consuming an oversized response")
    func featureFlagControlPlaneBoundsStreamingResponse() async throws {
        let counter = FeatureFlagByteConsumptionCounter()
        let bytes = FeatureFlagCountingByteSequence(count: 100, counter: counter)

        let data = try await CmuxFeatureFlags.boundedPostHogControlPlaneData(
            from: bytes,
            maximumByteCount: 3
        )

        #expect(data == nil)
        #expect(await counter.count == 4)
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
    @Test("Tailscale Pairing button defaults hidden without a flag value")
    func tailscalePairingButtonDefaultsHidden() throws {
        let suiteName = "cmux.feature.flags.mobile-connect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let flags = CmuxFeatureFlags(
            defaults: defaults,
            remoteFlagValueProvider: { _ in nil }
        )

        #expect(!flags.isMobileConnectButtonEnabled)
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
    @Test("Mobile terminal Files chip defaults enabled and accepts a remote disable")
    func mobileTerminalFilesChipFeatureFlagKillSwitch() throws {
        let suiteName = "cmux.feature.flags.mobile-terminal-files-chip.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        var remoteValues: [String: Any] = [:]
        let flags = CmuxFeatureFlags(defaults: defaults) { key in
            remoteValues[key]
        }
        #expect(flags.isMobileTerminalFilesChipEnabled)

        remoteValues[CmuxFeatureFlags.mobileTerminalFilesChipFlag.key] = false
        flags.applyLoadedFlags()
        #expect(!flags.isMobileTerminalFilesChipEnabled)

        let offlineRelaunch = CmuxFeatureFlags(defaults: defaults) { _ in nil }
        #expect(!offlineRelaunch.isMobileTerminalFilesChipEnabled)
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
        let analytics = PostHogAnalytics(
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
        let analytics = PostHogAnalytics(
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

    @Test
    func crashExceptionPropertiesIncludeCrashAndLaunchVersions() throws {
        let reported = GhosttyCrashReportMetadata.ReportedException(
            type: "EXC_BAD_ACCESS",
            value: "KERN_INVALID_ADDRESS at 0x0000000000000000",
            mechanismType: "mach",
            appVersion: "0.64.22",
            appBuild: "6422",
            appNamespace: "com.cmuxterm.app"
        )
        let properties = PostHogAnalytics.crashExceptionProperties(
            reported: reported,
            infoDictionary: [
                "CFBundleShortVersionString": "0.64.23",
                "CFBundleVersion": "6423",
            ]
        )

        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:EXC_BAD_ACCESS")
        let list = try #require(properties["$exception_list"] as? [[String: Any]])
        let entry = try #require(list.first)
        #expect(entry["type"] as? String == "EXC_BAD_ACCESS")
        #expect(entry["value"] as? String == "Previous launch crashed")
        let mechanism = try #require(entry["mechanism"] as? [String: Any])
        #expect(mechanism["handled"] as? Bool == false)
        #expect(mechanism["type"] as? String == "mach")
        // The crashed build and the reporting launch are identified separately.
        #expect(properties["crash_app_version"] as? String == "0.64.22")
        #expect(properties["crash_app_build"] as? String == "6422")
        #expect(properties["crash_app_namespace"] as? String == "com.cmuxterm.app")
        #expect(properties["app_version"] as? String == "0.64.23")
        #expect(properties["app_build"] as? String == "6423")
        #expect((properties["channel"] as? String)?.isEmpty == false)
    }

    @Test
    func crashExceptionPropertiesTolerateMissingReport() {
        let properties = PostHogAnalytics.crashExceptionProperties(
            reported: nil,
            infoDictionary: [:]
        )

        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:UnknownCrash")
        let entry = (properties["$exception_list"] as? [[String: Any]])?.first
        #expect(entry?["type"] as? String == "UnknownCrash")
        let mechanism = entry?["mechanism"] as? [String: Any]
        #expect(mechanism?["handled"] as? Bool == false)
        #expect(mechanism?["type"] as? String == "ghostty_crash_report")
        #expect(properties["crash_app_version"] == nil)
        #expect(properties["crash_app_build"] == nil)
        #expect(properties["crash_app_namespace"] == nil)
        #expect(properties["app_version"] == nil)
        #expect(properties["app_build"] == nil)
    }

    @Test
    func crashExceptionPropertiesSanitizeTokensAndScrubValues() {
        #expect(PostHogAnalytics.sanitizedExceptionToken("EXC_CRASH") == "EXC_CRASH")
        #expect(PostHogAnalytics.sanitizedExceptionToken("NSInternalInconsistencyException") == "NSInternalInconsistencyException")
        #expect(PostHogAnalytics.sanitizedExceptionToken("bad type /Users/lawrence") == nil)
        #expect(PostHogAnalytics.sanitizedExceptionToken("   ") == nil)
        #expect(PostHogAnalytics.sanitizedExceptionToken(nil) == nil)

    }

    @Test(arguments: [
        "Crash at /Users/Jane Doe/Private Project.swift",
        "Opening /tmp/Customer Contract.pdf failed",
        "password=hunter2 token=private-token alice@example.com",
        "Server returned confidential customer content",
    ])
    func crashExceptionDoesNotTransmitRawReason(reason: String) throws {
        let reported = GhosttyCrashReportMetadata.ReportedException(
            type: "EXC_CRASH",
            value: reason,
            mechanismType: "signal",
            appVersion: "0.64.22",
            appBuild: "6422",
            appNamespace: "com.cmuxterm.app"
        )
        let properties = PostHogAnalytics.crashExceptionProperties(reported: reported, infoDictionary: [:])
        let entry = try #require((properties["$exception_list"] as? [[String: Any]])?.first)
        #expect(entry["value"] as? String == "Previous launch crashed")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: properties), as: UTF8.self)
        #expect(!serialized.contains(reason))
    }

    @Test
    func reportedExceptionReadsCrashAndAppContextFromEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-exception-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashURL = directory.appendingPathComponent("sample.ghosttycrash")
        let event: [String: Any] = [
            "exception": [
                "values": [
                    [
                        "type": "EXC_BAD_ACCESS",
                        "value": "KERN_INVALID_ADDRESS at 0x0",
                        "mechanism": ["type": "mach"],
                    ],
                ],
            ],
            "contexts": [
                "app": [
                    "app_version": "0.64.22",
                    "app_build": "6422",
                    "app_identifier": "com.cmuxterm.app",
                ],
            ],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event)
        var envelope = Data(#"{"event_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        envelope.append(0x0A)
        envelope.append(Data(#"{"type":"event","length":\#(eventData.count)}"#.utf8))
        envelope.append(0x0A)
        envelope.append(eventData)
        envelope.append(0x0A)
        try envelope.write(to: crashURL)

        let reported = try #require(GhosttyCrashReportMetadata.reportedException(in: crashURL))
        #expect(reported.type == "EXC_BAD_ACCESS")
        #expect(reported.value == "KERN_INVALID_ADDRESS at 0x0")
        #expect(reported.mechanismType == "mach")
        #expect(reported.appVersion == "0.64.22")
        #expect(reported.appBuild == "6422")
        #expect(reported.appNamespace == "com.cmuxterm.app")
    }

    @Test
    func reportedExceptionFallsBackWithoutExceptionPayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-exception-empty-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashURL = directory.appendingPathComponent("no-exception.ghosttycrash")
        let eventData = try JSONSerialization.data(withJSONObject: [
            "debug_meta": ["images": [["code_file": "/Applications/cmux.app/Contents/MacOS/cmux"]]],
        ])
        var envelope = Data(#"{"event_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        envelope.append(0x0A)
        envelope.append(Data(#"{"type":"event","length":\#(eventData.count)}"#.utf8))
        envelope.append(0x0A)
        envelope.append(eventData)
        envelope.append(0x0A)
        try envelope.write(to: crashURL)

        #expect(GhosttyCrashReportMetadata.reportedException(in: crashURL)?.type == "UnknownCrash")
        #expect(GhosttyCrashReportMetadata.reportedException(
            in: directory.appendingPathComponent("missing.ghosttycrash")
        ) == nil)
    }

    @Test
    func captureCrashExceptionCapturesOncePerCrashArtifact() throws {
        let suiteName = "cmux.posthog.crash.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let crashURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-capture-\(UUID().uuidString).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: crashURL) }
        try Data("not an envelope".utf8).write(to: crashURL)
        let crashDate = Date(timeIntervalSince1970: 1_000)

        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.analytics")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.capture")
        var capturedEvents: [(event: String, properties: [String: Any])] = []
        let analytics = PostHogAnalytics(
            workQueue: workQueue,
            didStart: true,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { event, properties in
                capturedQueue.sync {
                    capturedEvents.append((event: event, properties: properties))
                }
            },
            flushPostHog: {}
        )
        let pendingCrash = GhosttyCrashBreadcrumb.PendingCrash(fileURL: crashURL, modifiedAt: crashDate)

        analytics.captureCrashException(pendingCrash: pendingCrash)
        workQueue.sync {}
        #expect(capturedQueue.sync { capturedEvents }.count == 1)

        // The same crash artifact is never reported twice.
        analytics.captureCrashException(pendingCrash: pendingCrash)
        workQueue.sync {}
        #expect(capturedQueue.sync { capturedEvents }.count == 1)

        // A newer crash artifact reports again.
        let newerCrash = GhosttyCrashBreadcrumb.PendingCrash(
            fileURL: crashURL,
            modifiedAt: crashDate.addingTimeInterval(60)
        )
        analytics.captureCrashException(pendingCrash: newerCrash)
        workQueue.sync {}
        let events = capturedQueue.sync { capturedEvents }
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.event == "$exception" })
        let properties = try #require(events.first?.properties)
        #expect(properties["$exception_level"] as? String == "error")
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:UnknownCrash")
    }

    @Test(arguments: [false, true])
    func nativeCrashWithoutAppContextUsesPreviousLaunchIdentity(olderArtifact: Bool) throws {
        let suiteName = "cmux.posthog.native.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([
            "started_at": Date(timeIntervalSince1970: 900),
            "app_version": "0.64.22",
            "app_build": "6422",
            "app_namespace": "com.cmuxterm.app",
        ], forKey: "posthog.previousLaunchIdentity")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: url) }
        // Real sentry.native envelopes have a Ghostty release, OS context and
        // a minidump attachment, with no JSON exception list or app context.
        let event: [String: Any] = ["platform": "native", "release": "1.3.2-HEAD-ghostty",
                                    "contexts": ["os": ["name": "macOS"]]]
        let payload = try JSONSerialization.data(withJSONObject: event)
        var envelope = Data("{}\n".utf8)
        envelope.append(try JSONSerialization.data(withJSONObject: ["type": "event", "length": payload.count]))
        envelope.append(Data("\n".utf8))
        envelope.append(payload)
        envelope.append(Data("\n".utf8))
        try envelope.write(to: url)
        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.native")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.native.captures")
        var captured: [String: Any] = [:]
        let analytics = PostHogAnalytics(
            workQueue: workQueue, didStart: true, userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { _, properties in capturedQueue.sync { captured = properties } },
            flushPostHog: {}, environment: [:], telemetryEnabled: { true }
        )
        analytics.recordLaunchIdentity()
        workQueue.sync {}
        #expect(defaults.dictionary(forKey: "posthog.previousLaunchIdentity")?["started_at"] as? Date == Date(timeIntervalSince1970: 2_000))
        analytics.captureCrashException(pendingCrash: .init(fileURL: url, modifiedAt: Date(timeIntervalSince1970: olderArtifact ? 800 : 1_000)))
        workQueue.sync {}
        let properties = capturedQueue.sync { captured }
        #expect(properties["crash_app_version"] as? String == (olderArtifact ? nil : "0.64.22"))
        #expect(properties["crash_app_build"] as? String == (olderArtifact ? nil : "6422"))
        #expect(properties["crash_app_namespace"] as? String == (olderArtifact ? nil : "com.cmuxterm.app"))
        #expect(properties["$exception_fingerprint"] as? String == "cmux-mac-crash:UnknownCrash")
    }

    @Test
    func captureCrashExceptionSkipsUnderXCTestEvenWhenTelemetryIsEnabled() throws {
        let suiteName = "cmux.posthog.crash.xctest.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let crashURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-capture-xctest-\(UUID().uuidString).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: crashURL) }
        try Data("not an envelope".utf8).write(to: crashURL)

        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.xctest.analytics")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.xctest.capture")
        var capturedEvents: [String] = []
        let analytics = PostHogAnalytics(
            workQueue: workQueue,
            didStart: false,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { event, _ in
                capturedQueue.sync { capturedEvents.append(event) }
            },
            flushPostHog: {},
            environment: ["CMUX_TEST_PROCESS": "1", "CMUX_POSTHOG_ENABLE": "1"],
            telemetryEnabled: { true }
        )

        analytics.captureCrashException(pendingCrash: GhosttyCrashBreadcrumb.PendingCrash(
            fileURL: crashURL,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        ))
        workQueue.sync {}

        #expect(capturedQueue.sync { capturedEvents }.isEmpty)
        #expect(defaults.object(forKey: "posthog.lastReportedCrashAt") == nil)
    }

    @Test
    func captureCrashExceptionSkipsWhenTelemetryNeverStarted() throws {
        let suiteName = "cmux.posthog.crash.disabled.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let crashURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-crash-capture-disabled-\(UUID().uuidString).ghosttycrash")
        defer { try? FileManager.default.removeItem(at: crashURL) }
        try Data("not an envelope".utf8).write(to: crashURL)

        let workQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.disabled.analytics")
        let capturedQueue = DispatchQueue(label: "com.cmux.tests.posthog.crash.disabled.capture")
        var capturedEvents: [String] = []
        let analytics = PostHogAnalytics(
            workQueue: workQueue,
            didStart: false,
            userDefaults: defaults,
            now: { Date(timeIntervalSince1970: 2_000) },
            capturePostHog: { event, _ in
                capturedQueue.sync { capturedEvents.append(event) }
            },
            flushPostHog: {}
        )

        analytics.captureCrashException(pendingCrash: GhosttyCrashBreadcrumb.PendingCrash(
            fileURL: crashURL,
            modifiedAt: Date(timeIntervalSince1970: 1_000)
        ))
        workQueue.sync {}

        #expect(capturedQueue.sync { capturedEvents }.isEmpty)
        #expect(defaults.object(forKey: "posthog.lastReportedCrashAt") == nil)
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

private actor FeatureFlagByteConsumptionCounter {
    private(set) var count = 0

    func recordByte() {
        count += 1
    }
}

private struct FeatureFlagCountingByteSequence: AsyncSequence, Sendable {
    typealias Element = UInt8

    let count: Int
    let counter: FeatureFlagByteConsumptionCounter

    func makeAsyncIterator() -> Iterator {
        Iterator(remaining: count, counter: counter)
    }

    struct Iterator: AsyncIteratorProtocol {
        var remaining: Int
        let counter: FeatureFlagByteConsumptionCounter

        mutating func next() async -> UInt8? {
            guard remaining > 0 else { return nil }
            remaining -= 1
            await counter.recordByte()
            return 0x7B
        }
    }
}
#endif
