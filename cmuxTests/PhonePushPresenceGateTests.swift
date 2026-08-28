import CoreGraphics
import CmuxPhonePush
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior spec for the "forward notifications to phone only when away from
/// the Mac" gate. All signals go through the injected seams of
/// `MacPresenceMonitor`; no real HID/WindowServer state, no sleeps.
@Suite struct PhonePushPresenceGateTests {
    @Test func testAlertReportsOnlyItsSynchronousAdmissionStage() {
        #expect(PhonePushForwardAdmission.disabled.testStageRawValue == "forwarding_disabled")
        #expect(PhonePushForwardAdmission.presenceSuppressed.testStageRawValue == "suppressed_mac_active")
        #expect(PhonePushForwardAdmission.authenticationUnavailable.testStageRawValue == "authentication_unavailable")
        #expect(PhonePushForwardAdmission.encodingFailed.testStageRawValue == "encoding_failed")
        #expect(PhonePushForwardAdmission.queueFull.testStageRawValue == "queue_full")
        #expect(PhonePushForwardAdmission.queued.testStageRawValue == "queued")
    }

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func monitor(
        unlocked: Bool = true,
        displaysAwake: Bool = true,
        screensaverRunning: Bool = false,
        hardwareIdleSeconds: TimeInterval? = 10
    ) -> MacPresenceMonitor {
        MacPresenceMonitor(
            now: { Self.now },
            signals: {
                MacPresenceMonitor.Signals(
                    isConsoleSessionActiveAndUnlocked: unlocked,
                    areDisplaysAwake: displaysAwake,
                    isScreensaverRunning: screensaverRunning,
                    secondsSinceLastHardwareInput: hardwareIdleSeconds
                )
            }
        )
    }

    // MARK: - Gate behavior (mode x presence)

    @Test func activeMacSuppressesForwardInOnlyWhenAwayMode() {
        let decision = monitor(hardwareIdleSeconds: 10).evaluate()
        #expect(decision.isActive)
        #expect(!PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func idleBeyondThresholdForwardsInOnlyWhenAwayMode() {
        let decision = monitor(hardwareIdleSeconds: 121).evaluate()
        #expect(!decision.isActive)
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func lockedMacForwardsImmediatelyDespiteRecentInput() {
        // Locking flips to away instantly; there is no 120 s wait.
        let decision = monitor(unlocked: false, hardwareIdleSeconds: 1).evaluate()
        #expect(decision.verdict == .awayConsoleSessionInactiveOrLocked)
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func displaySleepForwardsImmediatelyDespiteRecentInput() {
        let decision = monitor(displaysAwake: false, hardwareIdleSeconds: 1).evaluate()
        #expect(decision.verdict == .awayDisplaysAsleep)
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func screensaverForwardsImmediatelyDespiteRecentInput() {
        let decision = monitor(screensaverRunning: true, hardwareIdleSeconds: 1).evaluate()
        #expect(decision.verdict == .awayScreensaverRunning)
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func syntheticInputOnlyForwards() {
        // Agents typing through the debug socket or accessibility tooling
        // produce synthetic events. The provider contract reads hardware HID
        // state only (`CGEventSource` `.hidSystemState`), so synthetic-only
        // activity leaves the hardware idle clock running: an unlocked, awake
        // Mac with a large hardware idle is exactly that case, and it must
        // count as away.
        let decision = monitor(hardwareIdleSeconds: 3_600).evaluate()
        #expect(!decision.isActive)
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func alwaysModeForwardsEvenWhenMacActive() {
        let decision = monitor(hardwareIdleSeconds: 0).evaluate()
        #expect(decision.isActive)
        #expect(PhonePushClient.shouldForward(mode: .always, presence: decision))
    }

    @Test func desktopBannerOffDoesNotDisableExplicitPhoneForwarding() {
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = false

        #expect(TerminalNotificationStore.shouldAttemptPhoneForward(
            effects: effects,
            phoneForwardingEnabled: true,
            categoryAllowsDelivery: true
        ))
    }

    @Test func allLocalEffectsOffStillAllowsExplicitPhoneForwarding() {
        var effects = TerminalNotificationPolicyEffects()
        effects.desktop = false
        effects.sound = false
        effects.command = false

        #expect(TerminalNotificationStore.shouldAttemptPhoneForward(
            effects: effects,
            phoneForwardingEnabled: true,
            categoryAllowsDelivery: true
        ))
    }

    @Test func categoryNeverRemainsAuthoritativeOverPhoneOptIn() {
        let effects = TerminalNotificationPolicyEffects()

        #expect(!TerminalNotificationStore.shouldAttemptPhoneForward(
            effects: effects,
            phoneForwardingEnabled: true,
            categoryAllowsDelivery: false
        ))
    }

    @Test func phonePayloadOmitsSurfaceForConfinedNotificationsOnly() {
        let workspaceId = UUID()
        let surfaceId = UUID()
        let confined = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            retargetsToLiveSurfaceOwner: false,
            title: "Relay",
            subtitle: "Completed",
            body: "Confined to its authorized workspace",
            createdAt: Self.now,
            isRead: false
        )
        let trusted = TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "May follow its live surface",
            createdAt: Self.now,
            isRead: false,
            replyShape: .text
        )

        let confinedPayload = PhonePushPayload(
            notification: confined,
            macDeviceId: "mac-1",
            macInstanceTag: "stable",
            badgeCount: 1,
            hideContent: false
        )
        let trustedPayload = PhonePushPayload(
            notification: trusted,
            macDeviceId: "mac-1",
            macInstanceTag: "nightly",
            badgeCount: 2,
            hideContent: false
        )

        #expect(confinedPayload.workspaceId == workspaceId.uuidString)
        #expect(confinedPayload.surfaceId == surfaceId.uuidString)
        #expect(!confinedPayload.retargetsToLiveSurfaceOwner)
        #expect(confinedPayload.replyShape == "none")
        #expect(confinedPayload.macInstanceTag == "stable")
        #expect(trustedPayload.workspaceId == workspaceId.uuidString)
        #expect(trustedPayload.surfaceId == surfaceId.uuidString)
        #expect(trustedPayload.retargetsToLiveSurfaceOwner)
        #expect(trustedPayload.macInstanceTag == "nightly")
        #expect(trustedPayload.replyShape == "text")
    }

    // MARK: - Heuristic details

    @Test func idleBoundaryForwardsAtTwoMinutes() {
        let justBefore = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold - 1
        ).evaluate()
        let decision = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold
        ).evaluate()
        let justAfter = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold + 1
        ).evaluate()

        #expect(justBefore.isActive)
        #expect(!decision.isActive)
        #expect(!justAfter.isActive)
        #expect(
            decision.verdict == .awayNoRecentHardwareInput(
                secondsSinceLastHardwareInput: MacPresenceMonitor.recentHardwareInputThreshold
            )
        )
        #expect(!PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: justBefore))
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: justAfter))
    }

    @Test func unknownHardwareIdleCountsAsAway() {
        let decision = monitor(hardwareIdleSeconds: nil).evaluate()
        #expect(
            decision.verdict == .awayNoRecentHardwareInput(secondsSinceLastHardwareInput: nil)
        )
        #expect(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func decisionCarriesInjectedClockTimestamp() {
        #expect(monitor().evaluate().evaluatedAt == Self.now)
    }

    // MARK: - Lock-state sources

    @Test func missingSessionDictionaryCountsAsLockedOrAway() {
        // No WindowServer session (e.g. SSH-only context): away.
        #expect(
            !MacPresenceMonitor.consoleSessionActiveAndUnlocked(
                sessionDictionary: nil,
                observedScreenLocked: false
            )
        )
    }

    @Test func dictionaryLockKeyCountsAsLocked() {
        #expect(
            !MacPresenceMonitor.consoleSessionActiveAndUnlocked(
                sessionDictionary: [
                    kCGSessionOnConsoleKey as String: true,
                    "CGSSessionScreenIsLocked": true,
                ],
                observedScreenLocked: false
            )
        )
    }

    @Test func observedLockNotificationCountsAsLockedWhenDictionaryKeyAbsent() {
        // `CGSSessionScreenIsLocked` is a de-facto key. If a macOS version or
        // session context omits it, the distributed-notification source must
        // still flip the gate to away while the screen is locked.
        #expect(
            !MacPresenceMonitor.consoleSessionActiveAndUnlocked(
                sessionDictionary: [kCGSessionOnConsoleKey as String: true],
                observedScreenLocked: true
            )
        )
    }

    @Test func unlockedConsoleSessionCountsAsUnlocked() {
        #expect(
            MacPresenceMonitor.consoleSessionActiveAndUnlocked(
                sessionDictionary: [kCGSessionOnConsoleKey as String: true],
                observedScreenLocked: false
            )
        )
    }

    @Test func offConsoleSessionCountsAsAway() {
        // Fast user switch or login window owning the console.
        #expect(
            !MacPresenceMonitor.consoleSessionActiveAndUnlocked(
                sessionDictionary: [kCGSessionOnConsoleKey as String: false],
                observedScreenLocked: false
            )
        )
    }

    // MARK: - Burst coalescing and transition freshness

    @Test func presenceCacheCoalescesActiveEvaluationsUnderBursts() {
        var evaluations = 0
        var currentNow = Self.now
        let counting = MacPresenceMonitor(
            now: { currentNow },
            signals: {
                evaluations += 1
                return MacPresenceMonitor.Signals(
                    isConsoleSessionActiveAndUnlocked: true,
                    areDisplaysAwake: true,
                    isScreensaverRunning: false,
                    secondsSinceLastHardwareInput: 5
                )
            }
        )
        var cache = MacPresenceDecisionCache()

        let first = cache.decision(from: counting)
        let second = cache.decision(from: counting)
        #expect(first == second)
        #expect(evaluations == 1)

        // The cached active decision expires after the TTL and is re-evaluated.
        currentNow = Self.now.addingTimeInterval(MacPresenceDecisionCache.ttl)
        _ = cache.decision(from: counting)
        #expect(evaluations == 2)
    }

    @Test func presenceCacheNeverReusesAwayDecisions() {
        // User-return transition: an away answer must never be served stale,
        // otherwise a notification arriving just after the user comes back
        // would still forward to the phone.
        var evaluations = 0
        var hardwareIdle: TimeInterval = 3_600
        let transitioning = MacPresenceMonitor(
            now: { Self.now },
            signals: {
                evaluations += 1
                return MacPresenceMonitor.Signals(
                    isConsoleSessionActiveAndUnlocked: true,
                    areDisplaysAwake: true,
                    isScreensaverRunning: false,
                    secondsSinceLastHardwareInput: hardwareIdle
                )
            }
        )
        var cache = MacPresenceDecisionCache()

        #expect(!cache.decision(from: transitioning).isActive)
        #expect(evaluations == 1)

        // The user moves the mouse; the very next notification re-samples
        // (same instant, well inside the TTL) and sees the Mac as active.
        hardwareIdle = 1
        let afterReturn = cache.decision(from: transitioning)
        #expect(evaluations == 2)
        #expect(afterReturn.isActive)
        #expect(!PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: afterReturn))
    }

    @Test func evaluationIsFreshOnEveryCall() {
        // The gate evaluates per notification at delivery time; no caching
        // means lock and user-return transitions affect the very next
        // notification in both directions.
        var hardwareIdle: TimeInterval = 3_600
        let transitioning = MacPresenceMonitor(
            now: { Self.now },
            signals: {
                MacPresenceMonitor.Signals(
                    isConsoleSessionActiveAndUnlocked: true,
                    areDisplaysAwake: true,
                    isScreensaverRunning: false,
                    secondsSinceLastHardwareInput: hardwareIdle
                )
            }
        )

        #expect(!transitioning.evaluate().isActive)

        // The user moves the mouse; the very next evaluation sees it.
        hardwareIdle = 1
        let afterReturn = transitioning.evaluate()
        #expect(afterReturn.isActive)
        #expect(!PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: afterReturn))
    }

    // MARK: - Mode persistence

    private func withScratchDefaults(_ body: (UserDefaults) -> Void) throws {
        let suiteName = "PhonePushPresenceGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func absentPreferencesDefaultToEnabledAlwaysWithVisibleContent() throws {
        try withScratchDefaults { defaults in
            let configuration = PhonePushConfiguration(defaults: defaults)

            #expect(configuration.forwardingEnabled)
            #expect(configuration.mode == .always)
            #expect(!configuration.hideContent)
        }
    }

    @Test func explicitPreferencesRemainAuthoritative() throws {
        try withScratchDefaults { defaults in
            defaults.set(false, forKey: PhonePushSettings.forwardEnabledKey)
            defaults.set(
                PhoneForwardingMode.onlyWhenAway.rawValue,
                forKey: PhonePushSettings.forwardModeKey
            )
            defaults.set(true, forKey: PhonePushSettings.hideContentKey)

            let configuration = PhonePushConfiguration(defaults: defaults)
            #expect(!configuration.forwardingEnabled)
            #expect(configuration.mode == .onlyWhenAway)
            #expect(configuration.hideContent)
        }
    }

    @Test func modeParsesStoredAlwaysValue() throws {
        try withScratchDefaults { defaults in
            defaults.set(
                PhoneForwardingMode.always.rawValue,
                forKey: PhonePushSettings.forwardModeKey
            )
            #expect(PhoneForwardingMode.fromDefaults(defaults) == .always)
        }
    }

    @Test func modeFallsBackToDefaultOnUnrecognizedValue() throws {
        try withScratchDefaults { defaults in
            defaults.set("sometimes", forKey: PhonePushSettings.forwardModeKey)
            #expect(PhoneForwardingMode.fromDefaults(defaults) == .always)
        }
    }

    // MARK: - Server acknowledgement

    @Test func requestEnvelopePinsCorrelationExpirationAndRedactsBeforeEncoding() throws {
        let payload = PhonePushPayload(
            kind: .notify,
            title: "secret title",
            subtitle: "secret subtitle",
            body: "secret terminal output",
            replyShape: "",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            retargetsToLiveSurfaceOwner: true,
            macDeviceId: UUID().uuidString,
            macInstanceTag: "nightly",
            notificationId: UUID().uuidString,
            notificationIds: [],
            badgeCount: 7,
            hideContent: true
        )
        let correlationID = UUID(
            uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        )!
        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            correlationID: correlationID,
            expirationEpochSeconds: 1_750_000_120
        )
        let body = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )
        let encoded = String(decoding: envelope.body, as: UTF8.self)

        #expect(
            envelope.correlationID
                == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
        #expect(envelope.expirationEpochSeconds == 1_750_000_120)
        #expect(
            body["correlationId"] as? String
                == "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )
        #expect(
            body["expirationEpochSeconds"] as? Int == 1_750_000_120
        )
        #expect(body["hideContent"] as? Bool == true)
        #expect(body["macInstanceTag"] as? String == "nightly")
        #expect(!encoded.contains("secret title"))
        #expect(!encoded.contains("secret subtitle"))
        #expect(!encoded.contains("secret terminal output"))
    }

    @Test func requestEnvelopeBoundsVisibleTextWithoutSplittingCharacters() throws {
        let longCharacter = "👩🏽‍💻"
        let payload = PhonePushPayload(
            kind: .notify,
            title: "  \(String(repeating: longCharacter, count: 100))  ",
            subtitle: String(repeating: longCharacter, count: 100),
            body: String(repeating: longCharacter, count: 300),
            replyShape: "",
            workspaceId: UUID().uuidString,
            surfaceId: UUID().uuidString,
            retargetsToLiveSurfaceOwner: true,
            macDeviceId: UUID().uuidString,
            macInstanceTag: nil,
            notificationId: UUID().uuidString,
            notificationIds: [],
            badgeCount: 1,
            hideContent: false
        )

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_120
        )
        let body = try #require(
            JSONSerialization.jsonObject(with: envelope.body)
                as? [String: Any]
        )
        let title = try #require(body["title"] as? String)
        let subtitle = try #require(body["subtitle"] as? String)
        let text = try #require(body["body"] as? String)

        #expect(title.utf16.count <= 120)
        #expect(subtitle.utf16.count <= 120)
        #expect(text.utf16.count <= 500)
        #expect(title.allSatisfy { String($0) == longCharacter })
        #expect(subtitle.allSatisfy { String($0) == longCharacter })
        #expect(text.allSatisfy { String($0) == longCharacter })
        #expect(envelope.body.count <= 8 * 1_024)
    }

    @Test func requestEnvelopeRejectsUnboundedOpaqueIdentifiers() {
        let payload = PhonePushPayload(
            kind: .notify,
            title: "agent",
            subtitle: "",
            body: "done",
            replyShape: "",
            workspaceId: String(repeating: "a", count: 201),
            surfaceId: nil,
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: nil,
            macInstanceTag: nil,
            notificationId: nil,
            notificationIds: [],
            badgeCount: 1,
            hideContent: false
        )

        #expect(throws: (any Error).self) {
            try PhonePushRequestEnvelope(
                payload: payload,
                expirationEpochSeconds: 1_750_000_120
            )
        }
    }

    @Test func worstCaseDismissBatchFitsTheRouteRequestLimit() throws {
        let maximumEscapedIdentifier = String(repeating: "\u{0000}", count: 200)
        let payload = PhonePushPayload(
            kind: .dismiss,
            title: "",
            subtitle: "",
            body: "",
            replyShape: "",
            workspaceId: nil,
            surfaceId: nil,
            retargetsToLiveSurfaceOwner: false,
            macDeviceId: nil,
            macInstanceTag: nil,
            notificationId: nil,
            notificationIds: Array(
                repeating: maximumEscapedIdentifier,
                count: 4
            ),
            badgeCount: 0,
            hideContent: false
        )

        let envelope = try PhonePushRequestEnvelope(
            payload: payload,
            expirationEpochSeconds: 1_750_000_120
        )
        #expect(envelope.body.count <= 8 * 1_024)
    }

    @Test func retryPolicyHonorsServerDelayWithoutRefreshingEventTTL() {
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .retryableFailure,
                retryAfterSeconds: 7,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 1_120
            ) == 7
        )
        // A malformed provider header can carry a negative Retry-After; the
        // clamp floors it at an immediate retry instead of a negative delay.
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .retryableFailure,
                retryAfterSeconds: -30,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 1_120
            ) == 0
        )
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .retryableFailure,
                retryAfterSeconds: 600,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 2_000
            ) == 600
        )
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .retryableFailure,
                retryAfterSeconds: 900,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 1_120
            ) == nil
        )
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .retryableFailure,
                retryAfterSeconds: 10,
                nowEpochSeconds: Int.max - 1,
                expirationEpochSeconds: Int.max
            ) == nil
        )
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .retryableFailure,
                retryAfterSeconds: 7,
                nowEpochSeconds: 1_113,
                expirationEpochSeconds: 1_120
            ) == nil
        )
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 3,
                result: .retryableFailure,
                retryAfterSeconds: nil,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 1_120
            ) == nil
        )
    }

    @Test func transientAuthenticationAcquisitionUsesTheBoundedRetryPolicy() {
        #expect(PhonePushHTTPResult.authenticationUnavailable.shouldRetry)
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: 1,
                result: .authenticationUnavailable,
                retryAfterSeconds: nil,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 1_120
            ) == 1
        )
        #expect(
            PhonePushRetryPolicy.delaySeconds(
                afterAttempt: PhonePushRetryPolicy.maximumAttempts,
                result: .authenticationUnavailable,
                retryAfterSeconds: nil,
                nowEpochSeconds: 1_000,
                expirationEpochSeconds: 1_120
            ) == nil
        )
    }

    @Test func retryWaitUsesInjectedClockInsteadOfRuntimeSleeping() async throws {
        let clock = PhonePushClock(
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            sleep: { duration in
                #expect(duration == .seconds(7))
            }
        )

        #expect(clock.nowEpochSeconds == 1_750_000_000)
        try await clock.sleep(for: .seconds(7))
    }

    @Test func successfulHTTPStatusWithNoRegisteredDevicesIsNotDeliverySuccess() throws {
        let body = try JSONEncoder().encode(
            PhonePushServerSummary(
                sent: 0,
                devices: 0,
                pruned: 0,
                transientFailures: 0,
                permanentFailures: 0
            )
        )

        #expect(PhonePushHTTPResult.decode(statusCode: 200, data: body) == .noRegisteredDevices)
    }

    @Test func successfulHTTPStatusWithAllTransientAPNsFailuresRequestsRetry() throws {
        let body = try JSONEncoder().encode(
            PhonePushServerSummary(
                sent: 0,
                devices: 2,
                pruned: 0,
                transientFailures: 2,
                permanentFailures: 0
            )
        )

        #expect(PhonePushHTTPResult.decode(statusCode: 200, data: body) == .retryableFailure)
    }

    @Test func partialAPNsDeliveryIsReportedTruthfullyWithoutRetryingPermanentFailures() throws {
        let body = try JSONEncoder().encode(
            PhonePushServerSummary(
                sent: 1,
                devices: 2,
                pruned: 1,
                transientFailures: 0,
                permanentFailures: 1
            )
        )

        #expect(PhonePushHTTPResult.decode(statusCode: 200, data: body) == .partial(
            sent: 1,
            devices: 2,
            pruned: 1
        ))
    }

    @Test func rateLimitAndServiceOutageRetryButAuthenticationDoesNot() {
        #expect(PhonePushHTTPResult.decode(statusCode: 429, data: Data()).shouldRetry)
        #expect(PhonePushHTTPResult.decode(statusCode: 503, data: Data()).shouldRetry)
        #expect(!PhonePushHTTPResult.decode(statusCode: 401, data: Data()).shouldRetry)
    }

    @Test func retryClassificationSeparatesAuthConflictAndInProgressResponses() throws {
        let inProgress = try JSONSerialization.data(withJSONObject: [
            "error": "push_event_in_progress",
        ])
        let conflict = try JSONSerialization.data(withJSONObject: [
            "error": "correlation_payload_mismatch",
        ])

        #expect(PhonePushHTTPResult.decode(statusCode: 401, data: Data()) == .authenticationRequired)
        #expect(PhonePushHTTPResult.decode(statusCode: 403, data: Data()) == .authenticationRequired)
        #expect(PhonePushHTTPResult.decode(statusCode: 409, data: inProgress) == .retryableFailure)
        #expect(PhonePushHTTPResult.decode(statusCode: 409, data: conflict) == .correlationConflict)
        #expect(PhonePushHTTPResult.decode(statusCode: 429, data: Data()) == .retryableFailure)
        #expect(PhonePushHTTPResult.decode(statusCode: 500, data: Data()) == .retryableFailure)
        #expect(PhonePushHTTPResult.decode(statusCode: 599, data: Data()) == .retryableFailure)
        #expect(PhonePushHTTPResult.classifyTransportError(URLError(.timedOut)) == .retryableFailure)
        #expect(PhonePushHTTPResult.classifyTransportError(URLError(.cancelled)) == .cancelled)
    }

    @Test func malformedHTTP200BodyCannotMasqueradeAsDeliverySuccess() {
        #expect(PhonePushHTTPResult.decode(
            statusCode: 200,
            data: Data("not-json".utf8)
        ) == .invalidResponse)
    }
}
