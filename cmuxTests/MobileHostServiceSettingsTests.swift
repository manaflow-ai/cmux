import CMUXMobileCore
import CmuxIrohTransport
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MobileHostServiceSettingsTests {
    @Test func mobileHostListenerHonorsDevelopmentDefaultUntilIOSPairingIsOverridden() throws {
        let suiteName = "MobileHostServiceSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))

        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .dev))
    }

    @Test func signedInIrohStartsWithoutEnablingTheLegacyListener() {
        let automatic = MobileHostService.startupPlan(
            legacyListenerEnabled: false,
            legacyListenerRunning: false
        )
        #expect(automatic.activatesIroh)
        #expect(!automatic.startsLegacyListener)

        let tailscaleCompatible = MobileHostService.startupPlan(
            legacyListenerEnabled: true,
            legacyListenerRunning: false
        )
        #expect(tailscaleCompatible.activatesIroh)
        #expect(tailscaleCompatible.startsLegacyListener)

        let alreadyListening = MobileHostService.startupPlan(
            legacyListenerEnabled: true,
            legacyListenerRunning: true
        )
        #expect(alreadyListening.activatesIroh)
        #expect(!alreadyListening.startsLegacyListener)
    }

    @Test func mobileHostListenerPreservesHistoricalExplicitOptIn() throws {
        let suiteName = "MobileHostServiceSettingsTests.Legacy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "cmuxMobilePairingHostEnabled")
        #expect(MobileHostService.isListeningEnabled(defaults: defaults))

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)
        #expect(!MobileHostService.isListeningEnabled(defaults: defaults))
    }

    @Test func nightlyPreservesLegacyListenerWhenNoSettingWasEverWritten() throws {
        let suiteName = "MobileHostServiceSettingsTests.NightlyCompatibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .nightly))
    }

    @Test func explicitDisableWinsOverNightlyCompatibility() throws {
        let suiteName = "MobileHostServiceSettingsTests.NightlyDisabled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: MobileHostService.listeningEnabledDefaultsKey)

        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .nightly))
    }

    @Test func legacyExplicitDisableWinsOverNightlyCompatibility() throws {
        let suiteName = "MobileHostServiceSettingsTests.LegacyNightlyDisabled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: "cmuxMobilePairingHostEnabled")

        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .nightly))
    }

    @Test func stableWithoutExplicitOptInKeepsLegacyListenerOff() throws {
        let suiteName = "MobileHostServiceSettingsTests.StableDefault.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!MobileHostService.isListeningEnabled(defaults: defaults, buildFlavor: .stable))
    }

    @Test func stablePreservesExplicitTailscaleCompatibilityRequest() throws {
        let suiteName = "MobileHostServiceSettingsTests.StableOptIn.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)

        let enabled = MobileHostService.isListeningEnabled(
            defaults: defaults,
            buildFlavor: .stable
        )
        let plan = MobileHostService.startupPlan(
            legacyListenerEnabled: enabled,
            legacyListenerRunning: false
        )

        #expect(plan.activatesIroh)
        #expect(plan.startsLegacyListener)
    }

    @Test func stablePreservesHistoricalTailscaleCompatibilityRequest() throws {
        let suiteName = "MobileHostServiceSettingsTests.StableLegacyOptIn.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cmuxMobilePairingHostEnabled")

        let enabled = MobileHostService.isListeningEnabled(
            defaults: defaults,
            buildFlavor: .stable
        )
        let plan = MobileHostService.startupPlan(
            legacyListenerEnabled: enabled,
            legacyListenerRunning: false
        )

        #expect(plan.activatesIroh)
        #expect(plan.startsLegacyListener)
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

#if DEBUG
@Suite(.serialized)
struct MobileHostTransportRouteCompositionTests {
    @Test func tcpRouteRefreshDoesNotRemoveTheActiveIrohRoute() throws {
        defer { MobileHostPublicStatusCache.removeAll() }
        MobileHostPublicStatusCache.removeAll()
        let binding = try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: Data(
                """
                {
                  "binding_id":"123e4567-e89b-42d3-a456-426614174010",
                  "device_id":"123e4567-e89b-42d3-a456-426614174011",
                  "app_instance_id":"123e4567-e89b-42d3-a456-426614174012",
                  "tag":"dev",
                  "platform":"mac",
                  "display_name":"Test Mac",
                  "endpoint_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "identity_generation":1,
                  "pairing_enabled":true,
                  "capabilities":["mobile-rpc-v1","multistream-v1"],
                  "path_hints":[],
                  "last_seen_at":"2026-07-09T12:00:00.000Z"
                }
                """.utf8
            )
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 58_465),
            priority: 10
        )

        MobileHostPublicStatusCache.update(irohBinding: binding)
        MobileHostPublicStatusCache.update(routes: [tailscale])
        #expect(MobileHostPublicStatusCache.snapshot().map(\.kind) == [.iroh, .tailscale])

        MobileHostPublicStatusCache.update(routes: [])
        #expect(MobileHostPublicStatusCache.snapshot().map(\.kind) == [.iroh])
    }

    @MainActor
    @Test func tcpListenerRestartDoesNotEraseIrohClientState() {
        let service = MobileHostService.shared
        let irohConnectionID = UUID()
        service.debugResetMobileLifecycleStateForTesting()
        defer { service.debugResetMobileLifecycleStateForTesting() }
        service.debugRecordClientIDForTesting(
            "iroh-client",
            connectionID: irohConnectionID
        )

        service.debugStopLegacyListenerForTesting()

        #expect(
            service.debugTrackedClientIDsForTesting(connectionID: irohConnectionID)
                == ["iroh-client"]
        )
    }

    @Test func irohBindingLifecycleDoesNotRemoveTailscaleRoute() throws {
        defer { MobileHostPublicStatusCache.removeAll() }
        MobileHostPublicStatusCache.removeAll()
        let binding = try JSONDecoder().decode(
            CmxIrohBrokerBinding.self,
            from: Data(
                """
                {
                  "binding_id":"123e4567-e89b-42d3-a456-426614174010",
                  "device_id":"123e4567-e89b-42d3-a456-426614174011",
                  "app_instance_id":"123e4567-e89b-42d3-a456-426614174012",
                  "tag":"dev",
                  "platform":"mac",
                  "display_name":"Test Mac",
                  "endpoint_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "identity_generation":1,
                  "pairing_enabled":true,
                  "capabilities":["mobile-rpc-v1","multistream-v1"],
                  "path_hints":[],
                  "last_seen_at":"2026-07-09T12:00:00.000Z"
                }
                """.utf8
            )
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.0.1", port: 58_465),
            priority: 10
        )

        MobileHostPublicStatusCache.update(routes: [tailscale])
        MobileHostPublicStatusCache.update(irohBinding: binding)
        #expect(MobileHostPublicStatusCache.snapshot().map(\.kind) == [.iroh, .tailscale])

        MobileHostPublicStatusCache.update(irohBinding: nil)
        #expect(MobileHostPublicStatusCache.snapshot().map(\.kind) == [.tailscale])
    }
}

@Suite(.serialized)
@MainActor
struct MobileHostMacScopedMutationAuthorizationTests {
    @Test func ignoresUnknownAttachTokenForBroadWorkspaceRequests() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        for method in ["workspace.list", "workspace.create"] {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: [:],
                auth: MobileHostRPCAuth(attachToken: "stale-ticket", stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            #expect(result == nil)
        }
    }

    @Test func rejectsMacScopedMutationsWithoutAttachToken() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        let cases: [(String, [String: String])] = [
            ("workspace.create", ["group_id": "group-main"]),
            ("workspace.move", ["workspace_id": "workspace-main", "before_workspace_id": "workspace-next"]),
            ("workspace.group.action", ["group_id": "group-main", "action": "rename"]),
            ("workspace.group.create", ["title": "Ops"]),
        ]
        for (method, params) in cases {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: params,
                auth: MobileHostRPCAuth(attachToken: nil, stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            guard case let .failure(error) = result else {
                return #expect(Bool(false), "missing attach token should reject \(method)")
            }
            #expect(error.code == "forbidden")
        }
    }

    @Test func rejectsMacScopedMutationsWithUnknownAttachToken() async {
        let service = MobileHostService.shared
        service.debugConfigureAcceptedStackAuthTokenForTesting("cmux-dev-token")
        defer { service.debugConfigureAcceptedStackAuthTokenForTesting(nil) }
        let cases: [(String, [String: String])] = [
            ("workspace.create", ["group_id": "group-main"]),
            ("workspace.move", ["workspace_id": "workspace-main", "before_workspace_id": "workspace-next"]),
            ("workspace.group.action", ["group_id": "group-main", "action": "rename"]),
            ("workspace.group.create", ["title": "Ops"]),
        ]
        for (method, params) in cases {
            let request = MobileHostRPCRequest(
                id: method,
                method: method,
                params: params,
                auth: MobileHostRPCAuth(attachToken: "stale-ticket", stackAccessToken: "cmux-dev-token")
            )
            let result = await service.debugAuthorizationError(for: request)
            guard case let .failure(error) = result else {
                return #expect(Bool(false), "stale attach token should reject \(method)")
            }
            #expect(error.code == "forbidden")
        }
    }
}
#endif
