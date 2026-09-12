#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import Observation
import OSLog
import Security

extension NextTransportDialClient {
    static func currentIdentity(
        defaults: UserDefaults = .standard,
        keychainService: String = "dev.cmux.nextTransport.ios.identity.v1"
    ) -> PeerIdentity {
        loadOrCreateIdentity(defaults: defaults, keychainService: keychainService)
    }

    /// Boxes preferences on the main actor before resolving the durable identity
    /// on the generic executor, so Keychain/defaults work stays off MainActor.
    static func currentIdentityOffMain(
        defaults: UserDefaults = .standard,
        keychainService: String = "dev.cmux.nextTransport.ios.identity.v1"
    ) async -> PeerIdentity {
        let box = NextTransportDefaultsBox(defaults)
        return await currentIdentityOffMain(
            defaults: box, keychainService: keychainService)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func currentIdentityOffMain(
        defaults: NextTransportDefaultsBox, keychainService: String
    ) async -> PeerIdentity {
        loadOrCreateIdentity(defaults: defaults.value, keychainService: keychainService)
    }

    nonisolated static func loadOrCreateIdentity(
        defaults: UserDefaults, keychainService: String
    ) -> PeerIdentity {
        let legacyKeyKey = "dev.cmux.nextTransport.ios.identity.key"
        let idKey = "dev.cmux.nextTransport.ios.identity.deviceID"
        let deviceID: String
        if let stored = defaults.string(forKey: idKey) {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString.lowercased()
            defaults.set(deviceID, forKey: idKey)
        }
        if let key = NextTransportIdentityKeychain(logger: Self.logger).read(service: keychainService, account: NextTransportIdentityKeychain.account) {
            if let identity = try? PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
            {
                return identity
            }
            Self.logger.error(
                "identity keychain bytes invalid; replacing the corrupted identity")
        }
        // One-time migration: early dev builds kept the private key in
        // UserDefaults. Move it into the Keychain and clear the old slot
        // only once the Keychain write stuck.
        if let keyB64 = defaults.string(forKey: legacyKeyKey),
            let key = Data(base64Encoded: keyB64)
        {
            if NextTransportIdentityKeychain(logger: Self.logger).write(
                key, service: keychainService, account: NextTransportIdentityKeychain.account)
            {
                defaults.removeObject(forKey: legacyKeyKey)
                Self.logger.notice("identity key migrated defaults -> keychain")
            }
            if let identity = try? PeerIdentity(
                appIdentity: "dev.cmux.next.ios", deviceID: deviceID, privateKeyData: key)
            {
                return identity
            }
            defaults.removeObject(forKey: legacyKeyKey)
            Self.logger.error(
                "legacy identity bytes invalid; generating a fresh identity")
        }
        let fresh = PeerIdentity.generate(
            appIdentity: "dev.cmux.next.ios", deviceID: deviceID)
        if !NextTransportIdentityKeychain(logger: Self.logger).write(
            fresh.privateKeyData, service: keychainService, account: NextTransportIdentityKeychain.account)
        {
            Self.logger.error(
                "identity keychain write failed; identity is ephemeral this launch")
        }
        return fresh
    }

    /// Staging broker credentials from the dev launch env (mobile-dev-launch
    /// exports the dogfood pair into the app's environment on dev installs).
    static func brokerClient(identity: PeerIdentity) -> BrokerCredentialClient? {
        let env = ProcessInfo.processInfo.environment
        guard
            let email = env["CMUX_DOGFOOD_STACK_EMAIL"],
            let password = env["CMUX_DOGFOOD_STACK_PASSWORD"]
        else { return nil }
        return BrokerCredentialClient(
            environment: .staging,
            identity: identity,
            auth: .password(email: email, password: password),
            tag: "next-transport-ios",
            platform: "ios")
    }
}
#endif
