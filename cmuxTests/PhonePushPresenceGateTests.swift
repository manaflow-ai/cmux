import CoreGraphics
import CMUXMobileCore
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
@Suite(.serialized) struct PhonePushPresenceGateTests {
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

    // MARK: - Heuristic details

    @Test func idleExactlyAtThresholdCountsAsActive() {
        let decision = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold
        ).evaluate()
        #expect(decision.isActive)
        #expect(!PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    @Test func idleJustOverThresholdCountsAsAway() {
        let decision = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold + 1
        ).evaluate()
        #expect(
            decision.verdict == .awayNoRecentHardwareInput(
                secondsSinceLastHardwareInput: MacPresenceMonitor.recentHardwareInputThreshold + 1
            )
        )
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

    @Test func modeDefaultsToOnlyWhenAwayWhenUnset() throws {
        // Legacy Mac opt-ins predate a stored mode, and their effective behavior
        // was away-only until the user explicitly chose Always.
        try withScratchDefaults { defaults in
            #expect(PhoneForwardingMode.fromDefaults(defaults) == .onlyWhenAway)
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
            #expect(PhoneForwardingMode.fromDefaults(defaults) == .onlyWhenAway)
        }
    }

    @Test func mobileHostAdvertisesNotificationSettingsSyncCapability() {
        #expect(MobileHostService.mobileHostCapabilities.contains("notification.settings.v1"))
    }

    @Test func attachTicketsMaySyncNotificationSettings() throws {
        let ticket = try CmxAttachTicket(
            workspaceID: "workspace-docs",
            terminalID: "terminal-notes",
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            routes: [],
            expiresAt: Self.now,
            authToken: "ticket"
        )
        let request = MobileHostRPCRequest(
            id: "settings",
            method: "notification.settings.set",
            params: [
                "enabled": true,
                "mode": PhoneForwardingMode.always.rawValue,
                "hide_content": false,
            ],
            auth: nil
        )

        #expect(MobileHostService.ticketAuthorizationError(ticket: ticket, request: request) == nil)
    }

    @MainActor
    @Test func mobileNotificationSettingsRPCUpdatesForwardingDefaults() async {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: PhonePushSettings.forwardEnabledKey)
        let savedMode = defaults.object(forKey: PhonePushSettings.forwardModeKey)
        let savedHideContent = defaults.object(forKey: PhonePushSettings.hideContentKey)
        defer {
            restore(savedEnabled, key: PhonePushSettings.forwardEnabledKey, defaults: defaults)
            restore(savedMode, key: PhonePushSettings.forwardModeKey, defaults: defaults)
            restore(savedHideContent, key: PhonePushSettings.hideContentKey, defaults: defaults)
        }

        defaults.set(false, forKey: PhonePushSettings.forwardEnabledKey)
        defaults.set(PhoneForwardingMode.onlyWhenAway.rawValue, forKey: PhonePushSettings.forwardModeKey)
        defaults.set(false, forKey: PhonePushSettings.hideContentKey)

        let request = MobileHostRPCRequest(
            id: "settings",
            method: "notification.settings.set",
            params: [
                "enabled": true,
                "mode": PhoneForwardingMode.always.rawValue,
                "hide_content": true,
            ],
            auth: nil
        )

        guard case let .ok(payload) = await TerminalController.shared.mobileHostHandleRPC(request),
              let object = payload as? [String: Any] else {
            Issue.record("expected notification.settings.set to succeed")
            return
        }

        #expect(object["enabled"] as? Bool == true)
        #expect(object["mode"] as? String == PhoneForwardingMode.always.rawValue)
        #expect(object["hide_content"] as? Bool == true)
        #expect(defaults.bool(forKey: PhonePushSettings.forwardEnabledKey))
        #expect(PhoneForwardingMode.fromDefaults(defaults) == .always)
        #expect(defaults.bool(forKey: PhonePushSettings.hideContentKey))
    }

    @MainActor
    @Test func invalidMobileNotificationSettingsRPCDoesNotPartiallyWriteDefaults() async {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.object(forKey: PhonePushSettings.forwardEnabledKey)
        let savedMode = defaults.object(forKey: PhonePushSettings.forwardModeKey)
        let savedHideContent = defaults.object(forKey: PhonePushSettings.hideContentKey)
        defer {
            restore(savedEnabled, key: PhonePushSettings.forwardEnabledKey, defaults: defaults)
            restore(savedMode, key: PhonePushSettings.forwardModeKey, defaults: defaults)
            restore(savedHideContent, key: PhonePushSettings.hideContentKey, defaults: defaults)
        }

        defaults.set(false, forKey: PhonePushSettings.forwardEnabledKey)
        defaults.set(PhoneForwardingMode.onlyWhenAway.rawValue, forKey: PhonePushSettings.forwardModeKey)
        defaults.set(false, forKey: PhonePushSettings.hideContentKey)

        let request = MobileHostRPCRequest(
            id: "settings",
            method: "notification.settings.set",
            params: [
                "enabled": true,
                "mode": "sometimes",
                "hide_content": true,
            ],
            auth: nil
        )

        guard case .failure = await TerminalController.shared.mobileHostHandleRPC(request) else {
            Issue.record("expected invalid settings to fail")
            return
        }

        #expect(!defaults.bool(forKey: PhonePushSettings.forwardEnabledKey))
        #expect(PhoneForwardingMode.fromDefaults(defaults) == .onlyWhenAway)
        #expect(!defaults.bool(forKey: PhonePushSettings.hideContentKey))
    }

    // MARK: - willForwardReplacement (superseded-banner buffering gate)

    /// The store's superseded-banner buffering decision must match the real
    /// send gate: only the burst throttle is a legitimate defer case, so
    /// `willForwardReplacement` reports `false` whenever forwarding is off or
    /// the `.onlyWhenAway` presence gate would suppress the replacement while
    /// the Mac is active. A `true` answer there would stash the old phone
    /// banner waiting for a push that never comes, stranding it until reconcile.
    /// A presence monitor pinned to a specific instant, so successive samples in
    /// one test step past the shared client's 1 s active-decision cache TTL
    /// instead of reusing a stale ACTIVE decision across monitor swaps.
    private func monitor(at instant: Date, hardwareIdleSeconds: TimeInterval?) -> MacPresenceMonitor {
        MacPresenceMonitor(
            now: { instant },
            signals: {
                MacPresenceMonitor.Signals(
                    isConsoleSessionActiveAndUnlocked: true,
                    areDisplaysAwake: true,
                    isScreensaverRunning: false,
                    secondsSinceLastHardwareInput: hardwareIdleSeconds
                )
            }
        )
    }

    @MainActor
    @Test func willForwardReplacementMirrorsTheRealSendGate() throws {
        let client = PhonePushClient.shared
        let savedMonitor = client.presenceMonitor
        defer { client.presenceMonitor = savedMonitor }

        // Advance the clock past the active-decision cache TTL between samples so
        // each step re-evaluates the swapped monitor rather than a cached active.
        let step = MacPresenceDecisionCache.ttl + 1
        var t = Self.now

        try withScratchDefaults { defaults in
            // Forwarding off: never a replacement, regardless of presence.
            client.presenceMonitor = monitor(at: t, hardwareIdleSeconds: 3_600) // away
            #expect(!client.willForwardReplacement(defaults: defaults))

            defaults.set(true, forKey: PhonePushSettings.forwardEnabledKey)

            // .always ignores presence: a replacement is always coming.
            defaults.set(PhoneForwardingMode.always.rawValue, forKey: PhonePushSettings.forwardModeKey)
            t = t.addingTimeInterval(step)
            client.presenceMonitor = monitor(at: t, hardwareIdleSeconds: 0) // active
            #expect(client.willForwardReplacement(defaults: defaults))

            // .onlyWhenAway + active Mac: the replacement push is suppressed, so
            // no replacement is coming — the store must emit the dismiss now.
            defaults.set(PhoneForwardingMode.onlyWhenAway.rawValue, forKey: PhonePushSettings.forwardModeKey)
            t = t.addingTimeInterval(step)
            client.presenceMonitor = monitor(at: t, hardwareIdleSeconds: 0) // active
            #expect(!client.willForwardReplacement(defaults: defaults))

            // .onlyWhenAway + away Mac: the replacement will forward, so the
            // store defers the superseded dismiss until that push is queued.
            t = t.addingTimeInterval(step)
            client.presenceMonitor = monitor(at: t, hardwareIdleSeconds: 3_600) // away
            #expect(client.willForwardReplacement(defaults: defaults))
        }
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
