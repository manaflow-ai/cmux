import CMUXMobileCore
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileHostServiceSettingsTests {
    @Test func mobileHostListenerDefaultsOffUntilIOSPairingIsEnabled() throws {
        let suiteName = "MobileHostServiceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
    }

    @Test func configuredPortDefaultsToCatalogDefaultWhenUnset() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let expected = SettingCatalog().mobile.iOSPairingPort.defaultValue
        #expect(MobileHostService.configuredPort(defaults: defaults) == expected)
    }

    @Test func configuredPortHonorsValidOverride() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Valid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(9000, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.configuredPort(defaults: defaults) == 9000)
    }

    @Test(arguments: [0, -1, 70000, 65536])
    func configuredPortFallsBackForOutOfRangeOverride(invalidPort: Int) throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Invalid.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(invalidPort, forKey: MobileHostService.portDefaultsKey)
        let expected = SettingCatalog().mobile.iOSPairingPort.defaultValue
        #expect(MobileHostService.configuredPort(defaults: defaults) == expected)
    }

    @Test func resolvedDesiredPortIsNilForInvalidSoRunningListenerIsNotDisturbed() throws {
        let suiteName = "MobileHostServiceSettingsTests.Port.Resolved.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Unset → catalog default (a valid desired port).
        #expect(MobileHostService.resolvedDesiredPort(defaults: defaults)
            == SettingCatalog().mobile.iOSPairingPort.defaultValue)

        // Valid override → that port.
        defaults.set(58_470, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.resolvedDesiredPort(defaults: defaults) == 58_470)

        // Invalid override → nil, so syncToSettings keeps the running listener
        // on its applied port instead of restarting onto the default.
        defaults.set(70_000, forKey: MobileHostService.portDefaultsKey)
        #expect(MobileHostService.resolvedDesiredPort(defaults: defaults) == nil)
    }

    @Test func manualHostRouteRefreshOnlyWhenNormalizedValueChanges() throws {
        let suiteName = "MobileHostServiceSettingsTests.ManualHost.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostService.configuredManualHost(defaults: defaults) == nil)
        defaults.set(" studio-mac.corp.example ", forKey: MobileHostService.manualHostDefaultsKey)
        #expect(MobileHostService.configuredManualHost(defaults: defaults) == "studio-mac.corp.example")
        #expect(MobileHostService.manualHostNeedsRouteRefresh(previous: nil, current: "studio-mac.corp.example"))
        #expect(!MobileHostService.manualHostNeedsRouteRefresh(
            previous: "studio-mac.corp.example",
            current: "studio-mac.corp.example"
        ))
        #expect(MobileHostService.manualHostNeedsRouteRefresh(
            previous: "studio-mac.corp.example",
            current: nil
        ))

        defaults.set("my:host", forKey: MobileHostService.manualHostDefaultsKey)
        #expect(MobileHostService.configuredManualHost(defaults: defaults) == nil)
    }

    @Test(arguments: ["127.0.0.1", "127.1", "0.0.0.0", "localhost", "[::1]"])
    func configuredManualHostRejectsLoopbackHosts(rawHost: String) throws {
        let suiteName = "MobileHostServiceSettingsTests.ManualHost.Loopback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(rawHost, forKey: MobileHostService.manualHostDefaultsKey)

        #expect(MobileHostService.configuredManualHost(defaults: defaults) == nil)
    }

    @Test func routeResolverDoesNotAdvertiseLoopbackManualHost() {
        let routes = MobileRouteResolver().routes(
            port: 58_465,
            tailscaleHosts: ["100.82.214.112"],
            manualHost: "127.1"
        ).routes

        #expect(routes.contains { $0.kind == .tailscale })
        #expect(!routes.contains { $0.kind == .manualHost })
    }

    @Test func portApplyPreBindClassifiesNonBindCases() {
        // Out of range → invalid, regardless of anything else.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: nil, requestedPort: 0) == .invalid)
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: nil, requestedPort: 70000) == .invalid)
        // Pairing off → saved for when it's enabled.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: false, currentBoundPort: nil, requestedPort: 58465) == .savedWhileDisabled)
        // Already bound to the requested port → applied, no bind attempt.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: 58465, requestedPort: 58465) == .applied(58465))
    }

    @Test func portApplyPreBindReturnsNilWhenABindIsNeeded() {
        // Enabled, valid, different from the bound port → needs a real bind
        // attempt (make-before-break), signalled by nil.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: 58465, requestedPort: 58470) == nil)
        // Not running yet, enabled, valid → also needs a bind.
        #expect(MobileHostService.portApplyPreBindOutcome(enabled: true, currentBoundPort: nil, requestedPort: 58470) == nil)
    }

    @Test func syncDecisionStartsStopsAndNoOpsForEnabledState() {
        // Disabled: stop only when something is running, otherwise no-op.
        #expect(MobileHostService.syncDecision(enabled: false, listenerRunning: false, desiredPort: 58465, appliedPort: nil) == .noop)
        #expect(MobileHostService.syncDecision(enabled: false, listenerRunning: true, desiredPort: 58465, appliedPort: 58465) == .stop)
        // Enabled but not running: start.
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: false, desiredPort: 58465, appliedPort: nil) == .start)
    }

    @Test func syncDecisionRestartsOnlyWhenPortChanges() {
        // Running on the desired port: nothing to do (does not drop connections
        // on unrelated UserDefaults writes).
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: true, desiredPort: 58465, appliedPort: 58465) == .noop)
        // Running on a different port than desired: restart to rebind.
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: true, desiredPort: 9000, appliedPort: 58465) == .restart)
        // Running but the applied port is unknown: restart to reconcile.
        #expect(MobileHostService.syncDecision(enabled: true, listenerRunning: true, desiredPort: 58465, appliedPort: nil) == .restart)
    }
}
