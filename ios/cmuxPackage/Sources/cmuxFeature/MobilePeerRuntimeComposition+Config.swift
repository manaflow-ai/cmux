import CMUXMobileCore
import CmuxMobileShell
import CmuxPeerTransport
import Foundation

// Static build-configuration helpers: broker origin resolution, tagged-build
// scope, Keychain plumbing, and the same-device evidence probe. Behavior is
// carried over unchanged from the previous composition; only the store types
// moved to the peer-transport package.
extension MobilePeerRuntimeComposition {
    static func identityStore(
        appNamespace: MobileIOSAppNamespace
    ) -> any PeerSecureBlobStoring {
        #if DEBUG
        MobilePeerDevelopmentFileBlobStore(
            directory: developmentStoreDirectory(
                service: "identity",
                bundleIdentifier: appNamespace.bundleIdentifier
            )
        )
        #else
        PeerIdentityStore()
        #endif
    }

    static func credentialStore(
        service: String,
        appNamespace: MobileIOSAppNamespace
    ) -> any PeerSecureBlobStoring {
        #if DEBUG
        MobilePeerDevelopmentFileBlobStore(
            directory: developmentStoreDirectory(
                service: service,
                bundleIdentifier: appNamespace.bundleIdentifier
            )
        )
        #else
        PeerIdentityStore(
            service: appNamespace.keychainService(
                base: "com.cmuxterm.iroh.\(service).v1"
            )
        )
        #endif
    }

    /// The same-device evidence probe `DeviceRegistryService` gates pre-witness
    /// mirror adoption on, aware of where THIS composition actually stores peer
    /// endpoint identities.
    ///
    /// In Release the identity is a device-only Keychain item that never
    /// travels in a device backup, so its presence proves the install is
    /// continuing on the same hardware. In DEBUG the identity lives in a
    /// development FILE store instead, so probe that store there.
    nonisolated static func sameDeviceEvidenceProbe(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> any SameDeviceEvidenceProbing {
        #if DEBUG
        MobilePeerDevelopmentFileEvidenceProbe(bundleIdentifier: bundleIdentifier)
        #else
        IrohEndpointIdentityEvidenceProbe()
        #endif
    }

    static func keychainAccessGroup(
        infoDictionary: [String: Any]?
    ) -> String? {
        let raw = infoDictionary?["CMUXKeychainAccessGroup"] as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        return trimmed
    }

    static func initialTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        #if DEBUG
        if let rawValue = defaults.string(
            forKey: CmxIrohTransportVerificationMode.debugDefaultsKey
        ), let mode = CmxIrohTransportVerificationMode(rawValue: rawValue) {
            return mode
        }
        #endif
        return CmxIrohPathPreference.stored(in: defaults).transportVerificationMode
    }

    #if DEBUG
    static func debugTransportVerificationMode(
        defaults: UserDefaults
    ) -> CmxIrohTransportVerificationMode {
        initialTransportVerificationMode(defaults: defaults)
    }

    nonisolated static func developmentStoreDirectory(
        service: String,
        bundleIdentifier: String?
    ) -> URL {
        let rawBundleScope = bundleIdentifier ?? "dev.cmux.ios.debug"
        let bundleScope = String(rawBundleScope.map { character in
            character.isASCII
                && (character.isLetter
                    || character.isNumber
                    || ["-", ".", "_"].contains(character))
                ? character
                : "_"
        })
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("peer-debug", isDirectory: true)
            .appendingPathComponent(bundleScope, isDirectory: true)
            .appendingPathComponent(service, isDirectory: true)
    }
    #endif

    nonisolated static func discoveryPeerTags(
        for policy: MobileMacBuildCompatibilityPolicy?
    ) -> [String]? {
        switch policy {
        case let .development(expectedInstanceTag, additionalInstanceTags):
            [expectedInstanceTag] + additionalInstanceTags.sorted()
        case .official:
            ["default", "nightly"]
        case nil:
            nil
        }
    }

    static func currentTag(
        infoDictionary: [String: Any]?,
        bundleIdentifier: String?
    ) -> String {
        let raw = MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        )?.value ?? "default"
        let normalized = String(raw.prefix(64)).lowercased().map { character in
            (character.isASCII && (character.isLetter || character.isNumber))
                || ["-", ".", ":", "_"].contains(character)
                ? character
                : "-"
        }
        let value = String(normalized)
        return value.isEmpty ? "default" : value
    }

    static func resolvedBrokerBaseURL(
        apiBaseURL: String,
        infoDictionary: [String: Any]?,
        bundleIdentifier: String? = nil,
        allowsLoopback: Bool = true
    ) -> URL? {
        if let baked = infoDictionary?["CMUXIrohBrokerBaseURL"] as? String {
            let trimmed = baked.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return validatedBrokerBaseURL(trimmed, allowsLoopback: allowsLoopback)
            }
        }
        let authEnvironment = (infoDictionary?["CMUXAuthEnvironment"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if authEnvironment == "production" {
            return URL(string: "https://cmux.com")
        }
        if MobileIOSBuildScope.current(
            infoDictionary: infoDictionary,
            bundleIdentifier: bundleIdentifier
        ) != nil {
            return URL(string: "https://cmux-staging.vercel.app")
        }
        return validatedBrokerBaseURL(apiBaseURL, allowsLoopback: allowsLoopback)
    }

    private static func validatedBrokerBaseURL(
        _ rawValue: String,
        allowsLoopback: Bool
    ) -> URL? {
        guard let url = URL(string: rawValue),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }
        if scheme == "https" { return url }
        let loopbackHosts = ["127.0.0.1", "::1", "localhost"]
        guard allowsLoopback,
              scheme == "http",
              loopbackHosts.contains(host) else { return nil }
        return url
    }

    nonisolated static func relayPolicyTrustRoot(
        infoDictionary: [String: Any]?
    ) -> PeerRelayPolicyTrustRoot? {
        PeerRelayPolicyTrustRoot.appPinned(infoDictionary: infoDictionary)
    }
}
