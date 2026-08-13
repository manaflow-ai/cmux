import CMUXMobileCore
import CmuxSettings
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct MobileHostIdentityTests {
    @Test func appInstanceTagDistinguishesReleaseChannelsAndTaggedDevBuilds() {
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app"
        ) == "default")
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.nightly"
        ) == "nightly")
        #expect(MobileHostIdentity.instanceTag(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.staging"
        ) == "staging")
        #expect(MobileHostIdentity.instanceTag(
            environment: ["CMUX_TAG": "future-one"],
            bundleIdentifier: "com.cmuxterm.app.debug.future-one"
        ) == "future-one")
    }

    @Test func stableMacOffersAndPersistsExactReleaseLaneTarget() throws {
        let suiteName = "mobile-ios-target-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileIOSPairingTargetStore(
            defaults: defaults,
            macInstanceTag: "default"
        )

        #expect(store.availableNamespaces.map(\.bundleIdentifier) == [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ])
        #expect(store.selectedNamespace?.bundleIdentifier == "com.cmux.app")
        #expect(
            store.selectedPairingURLScheme?.rawValue
                == "cmux-ios-com.cmux.app"
        )
        #expect(
            store.pushTargetNamespace?.bundleIdentifier == "com.cmux.app"
        )

        let internalNamespace = try #require(MobileIOSAppNamespace(
            bundleIdentifier: "dev.cmux.app.internal"
        ))
        #expect(store.select(internalNamespace))
        #expect(store.selectedNamespace == internalNamespace)
        #expect(store.pushTargetNamespace == internalNamespace)
        #expect(
            store.selectedPairingURLScheme?.rawValue
                == "cmux-ios-dev.cmux.app.internal"
        )
    }

    @Test func nightlyMacOffersOfficialIOSBuildsInsteadOfTaggedDev() throws {
        let suiteName = "mobile-ios-target-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileIOSPairingTargetStore(
            defaults: defaults,
            macInstanceTag: "nightly"
        )

        #expect(store.availableNamespaces.map(\.bundleIdentifier) == [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ])
        #expect(store.selectedNamespace?.bundleIdentifier == "com.cmux.app")
        #expect(
            store.selectedPairingURLScheme?.rawValue
                == "cmux-ios-com.cmux.app"
        )
        #expect(
            store.pushTargetNamespace?.bundleIdentifier == "com.cmux.app"
        )
    }

    @Test func taggedMacTargetsOnlyItsMatchingTaggedIOSBuild() throws {
        let suiteName = "mobile-ios-target-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "dev.cmux.app.demo",
            forKey: MobileIOSPairingTargetStore.defaultsKey
        )
        let store = MobileIOSPairingTargetStore(
            defaults: defaults,
            macInstanceTag: "future-one"
        )

        #expect(store.availableNamespaces.map(\.bundleIdentifier) == [
            "dev.cmux.ios.future-one",
        ])
        #expect(
            store.selectedNamespace?.bundleIdentifier
                == "dev.cmux.ios.future-one"
        )
        let demoNamespace = try #require(MobileIOSAppNamespace(
            bundleIdentifier: "dev.cmux.app.demo"
        ))
        #expect(!store.select(demoNamespace))
        #expect(
            defaults.string(forKey: MobileIOSPairingTargetStore.defaultsKey)
                == "dev.cmux.app.demo"
        )
    }

    @Test func irohRegistrationUsesAuthoritativeAppInstanceTag() {
        let cases: [([String: String], String)] = [
            ([:], "com.cmuxterm.app"),
            ([:], "com.cmuxterm.app.nightly"),
            ([:], "com.cmuxterm.app.staging"),
            ([:], "com.cmuxterm.app.debug.future-one"),
            (["CMUX_TAG": "future-two"], "com.cmuxterm.app.debug.future-two"),
        ]

        for (environment, bundleIdentifier) in cases {
            #expect(MobileHostIrohRuntime.currentTag(
                environment: environment,
                bundleIdentifier: bundleIdentifier
            ) == MobileHostIdentity.instanceTag(
                environment: environment,
                bundleIdentifier: bundleIdentifier
            ))
        }
    }

    @Test func authenticatedStatusIncludesAuthoritativeInstanceTag() {
        let previousTag = ProcessInfo.processInfo.environment["CMUX_TAG"]
        setenv("CMUX_TAG", "future-one", 1)
        defer {
            if let previousTag {
                setenv("CMUX_TAG", previousTag, 1)
            } else {
                unsetenv("CMUX_TAG")
            }
        }

        let payload = MobileHostService.identityStatusPayload(routes: [])
        #expect(payload["mac_instance_tag"] as? String == "future-one")
        #expect(!(payload["terminal_theme_revision_epoch"] as? String ?? "").isEmpty)
    }

    @Test func publicStatusOmitsInstanceTag() {
        let payload = MobileHostService.publicStatusPayload(routes: [])
        #expect(payload["mac_instance_tag"] == nil)
        #expect(payload["terminal_theme_revision_epoch"] == nil)
    }

    @Test func authenticatedStatusReportsLivePhoneForwardingGateAndOrigin() throws {
        let suiteName = "mobile-host-push-status-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PhonePushSettings.forwardEnabledKey)
        defaults.set(
            PhoneForwardingMode.onlyWhenAway.rawValue,
            forKey: PhonePushSettings.forwardModeKey
        )

        let payload = MobileHostService.identityStatusPayload(
            routes: [],
            phonePushDefaults: defaults,
            phonePushAdmission: .suppressedMacActive,
            phonePushQueuePersistenceStatus: .saveFailed,
            phonePushAPIBaseURL: URL(string: "https://cmux-staging.vercel.app")!
        )
        let phonePush = try #require(payload["phone_push"] as? [String: Any])

        #expect(phonePush["forwarding_enabled"] as? Bool == true)
        #expect(phonePush["mode"] as? String == "onlyWhenAway")
        #expect(phonePush["admission"] as? String == "suppressed_mac_active")
        #expect(phonePush["queue_persistence"] as? String == "save_failed")
        #expect(phonePush["hide_content"] as? Bool == false)
        #expect(phonePush["api_origin"] as? String == "https://cmux-staging.vercel.app")
        #expect(phonePush["account_scope"] as? String == "verified_same_account")
    }

    @Test func publicStatusNeverDisclosesPhoneForwardingState() {
        let payload = MobileHostService.publicStatusPayload(routes: [])
        #expect(payload["phone_push"] == nil)
        #expect(!String(describing: payload).contains("api_origin"))
    }

    #if DEBUG
    @Test func debugSuppressionAlsoHidesAuthenticatedPhoneCapabilities() throws {
        let previous = ProcessInfo.processInfo.environment[
            "CMUX_DEBUG_SUPPRESS_MOBILE_CAPS"
        ]
        setenv(
            "CMUX_DEBUG_SUPPRESS_MOBILE_CAPS",
            MobileHostService.phonePushStatusCapability,
            1
        )
        defer {
            if let previous {
                setenv("CMUX_DEBUG_SUPPRESS_MOBILE_CAPS", previous, 1)
            } else {
                unsetenv("CMUX_DEBUG_SUPPRESS_MOBILE_CAPS")
            }
        }

        let payload = MobileHostService.identityStatusPayload(routes: [])
        let capabilities = try #require(payload["capabilities"] as? [String])
        #expect(!capabilities.contains(
            MobileHostService.phonePushStatusCapability
        ))
    }
    #endif

    @Test func authenticatedPhoneSettingsMutationUpdatesTheSharedStatusSource() throws {
        let suiteName = "mobile-host-push-mutation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let result = TerminalController.shared.v2MobilePhonePushSettingsUpdate(
            params: [
                "forwarding_enabled": true,
                "mode": "always",
                "hide_content": true,
            ],
            defaults: defaults
        )
        guard case .ok = result else {
            Issue.record("Expected phone push settings mutation to succeed")
            return
        }

        let payload = MobileHostService.identityStatusPayload(
            routes: [],
            phonePushDefaults: defaults,
            phonePushAPIBaseURL: URL(string: "https://cmux.com")!
        )
        let phonePush = try #require(payload["phone_push"] as? [String: Any])
        #expect(phonePush["forwarding_enabled"] as? Bool == true)
        #expect(phonePush["mode"] as? String == "always")
        #expect(phonePush["hide_content"] as? Bool == true)
    }

    @Test func phoneSettingsMutationUsesTheSameAccountAuthorizationGate() async {
        let request = MobileHostRPCRequest(
            id: "push-settings",
            method: "phone_push.settings.update",
            params: ["forwarding_enabled": true],
            auth: nil
        )
        let denied = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .stackBearer,
            stackAuthorization: { _ in
                .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Mobile sync authorization failed."
                ))
            }
        )

        guard case let .failure(error) = denied else {
            Issue.record("Expected unauthenticated mutation to fail")
            return
        }
        #expect(error.code == "unauthorized")
    }

    @Test func phoneStatusReadUsesTheSameAccountAuthorizationGate() async {
        let request = MobileHostRPCRequest(
            id: "push-status",
            method: "phone_push.status.get",
            params: [:],
            auth: nil
        )
        let denied = await MobileHostService.connectionAuthorizationError(
            for: request,
            authorization: .stackBearer,
            stackAuthorization: { _ in
                .failure(MobileHostRPCError(
                    code: "unauthorized",
                    message: "Mobile sync authorization failed."
                ))
            }
        )

        guard case let .failure(error) = denied else {
            Issue.record("Expected unauthenticated status read to fail")
            return
        }
        #expect(error.code == "unauthorized")
    }

    @Test func taggedDebugBuildSuffixesPairingDisplayName() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set("Desk Mac", forKey: key)

        let previousTag = ProcessInfo.processInfo.environment["CMUX_TAG"]
        setenv("CMUX_TAG", "future-one", 1)
        defer {
            if let previousTag {
                setenv("CMUX_TAG", previousTag, 1)
            } else {
                unsetenv("CMUX_TAG")
            }
        }

        #expect(MobileHostIdentity.baseDisplayName(defaults: defaults) == "Desk Mac")
        #if DEBUG
        #expect(MobileHostIdentity.instanceDisplayName(defaults: defaults) == "Desk Mac (future-one)")
        #else
        #expect(MobileHostIdentity.instanceDisplayName(defaults: defaults) == "Desk Mac")
        #endif
    }

    @Test func taggedDisplayNameUsesOverrideWithoutDuplicatingSuffix() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set("Desk Mac (future-one)", forKey: key)

        #expect(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: "System Mac",
            buildTag: " future-one "
        ) == "Desk Mac (future-one)")
    }

    @Test func untaggedDisplayNameFallsBackToSystemName() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: " System Mac ",
            buildTag: "default"
        ) == "System Mac")
    }

    @Test func taggedDisplayNamePreservesSuffixWithinCloudLimit() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set(String(repeating: "A", count: 128), forKey: key)

        let displayName = try #require(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: nil,
            buildTag: "future-one"
        ))

        #expect(displayName.utf16.count == 128)
        #expect(displayName.hasSuffix(" (future-one)"))
    }

    @Test func taggedDisplayNameDoesNotSplitExtendedCharactersAtCloudLimit() throws {
        let suiteName = "mobile-host-display-name-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = SettingCatalog().mobile.iOSPairingDisplayName.userDefaultsKey
        defaults.set(String(repeating: "👩🏽‍💻", count: 40), forKey: key)

        let displayName = try #require(MobileHostIdentity.instanceDisplayName(
            defaults: defaults,
            hostName: nil,
            buildTag: "future-one"
        ))

        #expect(displayName.utf16.count <= 128)
        #expect(displayName.hasSuffix(" (future-one)"))
        #expect(displayName.hasPrefix("👩🏽‍💻"))
    }

    @Test func prefersSharedIDAcrossBundleDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "3D56C547-271C-47D8-84F6-5C79C9394A37"
        try sharedID.lowercased().write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("175dff61-cabe-4076-b5ac-f5c1c04b62fa", forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == sharedID.lowercased())
        #expect(defaults.string(forKey: "mobileHost.deviceID") == sharedID.lowercased())
    }

    @Test func canonicalEquivalentSharedDeviceIDDoesNotRewriteDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "3D56C547-271C-47D8-84F6-5C79C9394A37".lowercased()
        try sharedID.write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyStoredID = "  \(sharedID.uppercased())\n"
        defaults.set(legacyStoredID, forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(
            defaults: defaults,
            sharedIDURL: sharedIDURL
        ) == sharedID)
        #expect(defaults.string(forKey: "mobileHost.deviceID") == legacyStoredID)
    }

    @Test func migratesExistingBundleIDToSharedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let defaultID = "C2FD4C2D-E0AF-447D-A8A4-D37BF67751EF"
        defaults.set(defaultID.lowercased(), forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == defaultID.lowercased())
        let persisted = try String(contentsOf: sharedIDURL, encoding: .utf8)
        #expect(persisted == defaultID.lowercased())
    }

    @Test func taggedBuildMigratesStableBundleIDBeforeOwnBundleID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")

        let taggedSuiteName = "mobile-host-identity-tagged-\(UUID().uuidString)"
        let taggedDefaults = try #require(UserDefaults(suiteName: taggedSuiteName))
        defer { taggedDefaults.removePersistentDomain(forName: taggedSuiteName) }
        let taggedID = "91FD1481-336E-4230-BE5F-2EE6800B6E1A"
        taggedDefaults.set(taggedID, forKey: "mobileHost.deviceID")

        let stableSuiteName = "mobile-host-identity-stable-\(UUID().uuidString)"
        let stableDefaults = try #require(UserDefaults(suiteName: stableSuiteName))
        defer { stableDefaults.removePersistentDomain(forName: stableSuiteName) }
        let stableID = "0BF0E843-17CA-44AF-8B65-FC5C67D1D084"
        stableDefaults.set(stableID.lowercased(), forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(
            defaults: taggedDefaults,
            sharedIDURL: sharedIDURL,
            stableDefaults: stableDefaults,
            bundleIdentifier: "com.cmuxterm.app.debug.mpick"
        ) == stableID.lowercased())
        #expect(taggedDefaults.string(forKey: "mobileHost.deviceID") == stableID.lowercased())
        #expect(try String(contentsOf: sharedIDURL, encoding: .utf8) == stableID.lowercased())
    }

    @Test func readsExistingSharedIDWithoutDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        let sharedID = "4BF9566D-5D67-4C79-8974-B42D5CF39DE9"
        try sharedID.write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == sharedID.lowercased())
        #expect(defaults.string(forKey: "mobileHost.deviceID") == sharedID.lowercased())
    }

    @Test func repairsInvalidSharedIDFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedIDURL = directory.appendingPathComponent("mobile-host-device-id")
        try "not-a-uuid".write(to: sharedIDURL, atomically: true, encoding: .utf8)

        let suiteName = "mobile-host-identity-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fallbackID = "08E3578B-195D-486F-B874-023CDA2B647D"
        defaults.set(fallbackID, forKey: "mobileHost.deviceID")

        #expect(MobileHostIdentity.deviceID(defaults: defaults, sharedIDURL: sharedIDURL) == fallbackID.lowercased())
        #expect(defaults.string(forKey: "mobileHost.deviceID") == fallbackID.lowercased())
        #expect(try String(contentsOf: sharedIDURL, encoding: .utf8) == fallbackID.lowercased())
    }

    @Test func testMobileHostRouteDisclosureSeparatesAuthenticatedAndPublicHints() throws {
        let now = Date()
        let privateAddress = "100.64.1.2:49152"
        let endpointID = String(repeating: "a", count: 64)
        let iroh = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: endpointID
                ),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: privateAddress,
                        source: .tailscale,
                        privacyScope: .privateNetwork,
                        observedAt: now,
                        expiresAt: now.addingTimeInterval(300),
                        networkProfile: CmxIrohNetworkProfileKey(
                            source: .tailscale,
                            profileID: String(repeating: "a", count: 64)
                        )
                    ),
                    try CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example.test/",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            )
        )
        let tailscale = try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: "100.64.1.2", port: 49152)
        )
        let websocketURL = "wss://private.example.test/connect?token=secret"
        let websocket = try CmxAttachRoute(
            id: "websocket",
            kind: .websocket,
            endpoint: .url(websocketURL)
        )

        let authenticatedPayload = MobileHostService.identityStatusPayload(
            routes: [iroh, tailscale, websocket],
            now: now
        )
        let authenticated = try #require(authenticatedPayload["routes"] as? [[String: Any]])
        #expect(authenticated.count == 3)
        let authenticatedEndpoint = try #require(
            authenticated.first?["endpoint"] as? [String: Any]
        )
        let authenticatedHints = try #require(
            authenticatedEndpoint["path_hints"] as? [[String: Any]]
        )
        #expect(authenticatedHints.count == 2)
        #expect(authenticatedHints.contains { $0["value"] as? String == privateAddress })
        #expect(authenticatedHints.contains { $0["network_profile"] != nil })

        let publicPayload = MobileHostService.publicStatusPayload(
            routes: [iroh, tailscale, websocket],
            now: now
        )
        let publicRoutes = try #require(publicPayload["routes"] as? [[String: Any]])
        #expect(publicRoutes.isEmpty)
        #expect(!String(describing: publicPayload).contains(endpointID))
        #expect(!String(describing: publicRoutes).contains(privateAddress))
        #expect(!String(describing: publicRoutes).contains(websocketURL))
    }
}
