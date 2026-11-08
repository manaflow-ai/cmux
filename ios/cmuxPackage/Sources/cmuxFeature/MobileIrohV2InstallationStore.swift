import CryptoKit
import CmuxIrxTransport
import Foundation

/// Fresh per-installation v2 identifiers. Production seeds remain in this device's keychain.
actor MobileIrohV2InstallationStore {
    private let configuration: MobileIrohV2Configuration
    private let accessGroup: String?
    private let files = FileManager()
    private let keys: V2IdentityKeyStore
    private let installationIDs: V2InstallationIDStore

    init(configuration: MobileIrohV2Configuration, accessGroup: String?) {
        self.configuration = configuration
        self.accessGroup = accessGroup
        keys = V2IdentityKeyStore(applicationNamespace: configuration.appNamespace, accessGroup: accessGroup)
        installationIDs = V2InstallationIDStore(
            applicationNamespace: configuration.appNamespace,
            accessGroup: accessGroup
        )
    }

    func deviceID() throws -> String {
        #if targetEnvironment(simulator)
        let file = try simulatorDirectory().appendingPathComponent("installation-id")
        if let stored = try? String(contentsOf: file, encoding: .utf8), UUID(uuidString: stored) != nil { return stored }
        let value = UUID().uuidString.lowercased()
        try Data(value.utf8).write(to: file, options: .atomic)
        return value
        #else
        return try installationIDs.loadOrCreate()
        #endif
    }

    func key(identity: V2Identity) async throws -> V2IdentityKey {
        #if targetEnvironment(simulator)
        // Unsigned simulator builds have no keychain entitlement. This store is
        // intentionally confined to their new v2 container, never legacy files.
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
            .map { String(format: "%02x", $0) }.joined()
        let file = try simulatorDirectory().appendingPathComponent(digest + ".key")
        if files.fileExists(atPath: file.path) { return try V2IdentityKey(secretKey: Data(contentsOf: file)) }
        let key = V2IdentityKey()
        try key.secretKey.write(to: file, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return key
        #else
        return try await keys.loadOrCreate(identity: identity)
        #endif
    }

    #if targetEnvironment(simulator)
    private func simulatorDirectory() throws -> URL {
        let directory = configuration.stateDirectory.appendingPathComponent("cmux-iroh-v2/simulator-keys", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    #endif
}
