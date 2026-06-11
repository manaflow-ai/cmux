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

    // MARK: - Burst coalescing

    @Test func presenceCacheCoalescesBurstEvaluations() {
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

        // The cached decision expires after the TTL and is re-evaluated.
        currentNow = Self.now.addingTimeInterval(MacPresenceDecisionCache.ttl)
        _ = cache.decision(from: counting)
        #expect(evaluations == 2)
    }

    // MARK: - Mode persistence

    private func withScratchDefaults(_ body: (UserDefaults) -> Void) throws {
        let suiteName = "PhonePushPresenceGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func modeDefaultsToOnlyWhenAwayWhenUnset() throws {
        // The default applies to everyone, including users who already had
        // forwarding enabled before the mode existed.
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
}
