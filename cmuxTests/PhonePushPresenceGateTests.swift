import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior spec for the "forward notifications to phone only when away from
/// the Mac" gate. All signals go through the injected seams of
/// `MacPresenceMonitor`; no real HID/WindowServer state, no sleeps.
final class PhonePushPresenceGateTests: XCTestCase {
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

    func testActiveMacSuppressesForwardInOnlyWhenAwayMode() {
        let decision = monitor(hardwareIdleSeconds: 10).evaluate()
        XCTAssertTrue(decision.isActive)
        XCTAssertFalse(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testIdleBeyondThresholdForwardsInOnlyWhenAwayMode() {
        let decision = monitor(hardwareIdleSeconds: 121).evaluate()
        XCTAssertFalse(decision.isActive)
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testLockedMacForwardsImmediatelyDespiteRecentInput() {
        // Locking flips to away instantly; there is no 120 s wait.
        let decision = monitor(unlocked: false, hardwareIdleSeconds: 1).evaluate()
        XCTAssertEqual(decision.verdict, .awayConsoleSessionInactiveOrLocked)
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testDisplaySleepForwardsImmediatelyDespiteRecentInput() {
        let decision = monitor(displaysAwake: false, hardwareIdleSeconds: 1).evaluate()
        XCTAssertEqual(decision.verdict, .awayDisplaysAsleep)
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testScreensaverForwardsImmediatelyDespiteRecentInput() {
        let decision = monitor(screensaverRunning: true, hardwareIdleSeconds: 1).evaluate()
        XCTAssertEqual(decision.verdict, .awayScreensaverRunning)
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testSyntheticInputOnlyForwards() {
        // Agents typing through the debug socket or accessibility tooling
        // produce synthetic events. The provider contract reads hardware HID
        // state only (`CGEventSource` `.hidSystemState`), so synthetic-only
        // activity leaves the hardware idle clock running: an unlocked, awake
        // Mac with a large hardware idle is exactly that case, and it must
        // count as away.
        let decision = monitor(hardwareIdleSeconds: 3_600).evaluate()
        XCTAssertFalse(decision.isActive)
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testAlwaysModeForwardsEvenWhenMacActive() {
        let decision = monitor(hardwareIdleSeconds: 0).evaluate()
        XCTAssertTrue(decision.isActive)
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .always, presence: decision))
    }

    // MARK: - Heuristic details

    func testIdleExactlyAtThresholdCountsAsActive() {
        let decision = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold
        ).evaluate()
        XCTAssertTrue(decision.isActive)
        XCTAssertFalse(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testIdleJustOverThresholdCountsAsAway() {
        let decision = monitor(
            hardwareIdleSeconds: MacPresenceMonitor.recentHardwareInputThreshold + 1
        ).evaluate()
        XCTAssertEqual(
            decision.verdict,
            .awayNoRecentHardwareInput(
                secondsSinceLastHardwareInput: MacPresenceMonitor.recentHardwareInputThreshold + 1
            )
        )
    }

    func testUnknownHardwareIdleCountsAsAway() {
        let decision = monitor(hardwareIdleSeconds: nil).evaluate()
        XCTAssertEqual(
            decision.verdict,
            .awayNoRecentHardwareInput(secondsSinceLastHardwareInput: nil)
        )
        XCTAssertTrue(PhonePushClient.shouldForward(mode: .onlyWhenAway, presence: decision))
    }

    func testDecisionCarriesInjectedClockTimestamp() {
        XCTAssertEqual(monitor().evaluate().evaluatedAt, Self.now)
    }

    // MARK: - Mode persistence

    private func makeScratchDefaults() throws -> UserDefaults {
        let suiteName = "PhonePushPresenceGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    func testModeDefaultsToOnlyWhenAwayWhenUnset() throws {
        // The default applies to everyone, including users who already had
        // forwarding enabled before the mode existed.
        let defaults = try makeScratchDefaults()
        XCTAssertEqual(PhoneForwardingMode.fromDefaults(defaults), .onlyWhenAway)
    }

    func testModeParsesStoredAlwaysValue() throws {
        let defaults = try makeScratchDefaults()
        defaults.set(PhoneForwardingMode.always.rawValue, forKey: PhonePushSettings.forwardModeKey)
        XCTAssertEqual(PhoneForwardingMode.fromDefaults(defaults), .always)
    }

    func testModeFallsBackToDefaultOnUnrecognizedValue() throws {
        let defaults = try makeScratchDefaults()
        defaults.set("sometimes", forKey: PhonePushSettings.forwardModeKey)
        XCTAssertEqual(PhoneForwardingMode.fromDefaults(defaults), .onlyWhenAway)
    }
}
