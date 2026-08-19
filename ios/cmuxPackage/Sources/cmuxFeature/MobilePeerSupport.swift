import CMUXMobileCore
import CmuxMobileShell
import CmuxPeerTransport
import CmuxPeerTransportCore
import Foundation
import OSLog
import Security

/// A stable, retry-aware failure returned by every connection entrypoint after
/// one endpoint activation fails.
struct MobilePeerRuntimePreparationError:
    Error,
    CmxRetryAfterProviding,
    DiagnosticFailureProviding,
    Equatable
{
    let diagnosticFailureKind: DiagnosticFailureKind
    let retryAfterSeconds: Int?
}

/// Keeps synchronous Keychain and defaults work off the UI actor while
/// serializing concurrent activation reads through one identity owner.
///
/// `UserDefaults` documents its API as thread-safe but does not conform to
/// `Sendable`. Keep the unchecked boundary private and pass only this owner
/// across the actor boundary.
final class MobilePeerSendableDefaults: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

/// Resolves the durable device id off the MainActor: the witness
/// (`identifierForVendor`) is captured with one cheap MainActor hop, then the
/// Keychain reads/writes, the defaults mirror, and the continuity probe all
/// run on this actor's executor so activation never blocks app UI on Keychain
/// service latency.
actor MobilePeerDurableDeviceIDResolver {
    private let defaults: MobilePeerSendableDefaults
    private let appNamespace: MobileIOSAppNamespace
    private let keychainAccessGroup: String?

    init(
        defaults: MobilePeerSendableDefaults,
        appNamespace: MobileIOSAppNamespace,
        keychainAccessGroup: String?
    ) {
        self.defaults = defaults
        self.appNamespace = appNamespace
        self.keychainAccessGroup = keychainAccessGroup
    }

    func resolve() async -> String? {
        let witness = await DeviceRegistryService.currentDeviceWitness()
        return appNamespace.durableDeviceRegistryDeviceID(
            keychainAccessGroup: keychainAccessGroup,
            defaults: defaults.value,
            deviceWitness: witness,
            evidence: MobilePeerRuntimeComposition.sameDeviceEvidenceProbe(
                bundleIdentifier: appNamespace.bundleIdentifier
            )
        )
    }
}

#if DEBUG
/// DEBUG same-device evidence: dev builds keep peer endpoint identities in a
/// development FILE store, not the Keychain, so continuity is proven by any
/// record in that store. The filesystem is always readable, so the verdict is
/// two-state (never `.unavailable`).
struct MobilePeerDevelopmentFileEvidenceProbe: SameDeviceEvidenceProbing {
    let bundleIdentifier: String?

    func probe() -> SameDeviceEvidence {
        #if targetEnvironment(simulator)
        // The dev launcher seeds a deterministic UserDefaults mirror because
        // unsigned Simulator apps cannot read Keychain. A Simulator cannot be
        // the destination of an iPhone backup restore, so that mirror is local
        // same-device evidence even before the development identity file exists.
        return .present
        #else
        let exists = MobilePeerDevelopmentFileBlobStore(
            directory: MobilePeerRuntimeComposition.developmentStoreDirectory(
                service: "identity",
                bundleIdentifier: bundleIdentifier
            )
        ).containsAnyRecordSync()
        return exists ? .present : .absent
        #endif
    }
}

/// File-backed secure-blob store for DEBUG builds, where unsigned Simulator
/// apps cannot use the Keychain. Mirrors the previous transport's
/// development-file store role; records live under Application Support.
struct MobilePeerDevelopmentFileBlobStore: PeerSecureBlobStoring {
    let directory: URL

    private func fileURL(account: String) -> URL {
        let name = Data(account.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("\(name).bin", isDirectory: false)
    }

    func read(account: String) async -> PeerSecureReadResult {
        let url = fileURL(account: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else {
            return .unavailable(status: -1)
        }
        return .found(data)
    }

    func write(_ data: Data, account: String) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL(account: account), options: [.atomic])
    }

    func delete(account: String) async throws {
        let url = fileURL(account: account)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func deleteAll() async throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func containsAnyRecordSync() -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents?.isEmpty == false
    }
}
#endif

/// Persists one durable app-instance id per `(account, tag)` in install state,
/// replacing the previous transport's app-instance repository. The mapping is
/// intentionally device-local and erased on sign-out.
actor MobilePeerAppInstanceRegistry {
    private static let storageKey = "cmux.peer.app-instances.v1"

    private let store: any PeerInstallStateStoring
    private let mintID: @Sendable () -> String

    init(
        store: any PeerInstallStateStoring,
        mintID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.store = store
        self.mintID = mintID
    }

    func appInstanceID(accountID: String, tag: String) -> String {
        var mapping = load()
        let key = "\(accountID)|\(tag)"
        if let existing = mapping[key] { return existing }
        let minted = mintID()
        mapping[key] = minted
        save(mapping)
        return minted
    }

    func deactivate() {
        store.set(nil, forKey: Self.storageKey)
    }

    private func load() -> [String: String] {
        guard let raw = store.string(forKey: Self.storageKey),
              let data = raw.data(using: .utf8),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return mapping
    }

    private func save(_ mapping: [String: String]) {
        guard let data = try? JSONEncoder().encode(mapping),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.set(raw, forKey: Self.storageKey)
    }
}

/// In-memory relay-policy record store for tests and the injectable designated
/// initializer default.
actor MobilePeerInMemoryRelayPolicyRecordActor {
    var record: Data?

    func read() -> Data? { record }

    func write(_ data: Data) { record = data }

    func removeAll() { record = nil }
}

struct MobilePeerInMemoryRelayPolicyStore: PeerRelayPolicyStoring {
    private let storage = MobilePeerInMemoryRelayPolicyRecordActor()

    init() {}

    func readRecord() async throws -> Data? {
        await storage.read()
    }

    func writeRecord(_ data: Data) async throws {
        await storage.write(data)
    }

    func removeAll() async throws {
        await storage.removeAll()
    }
}

/// Adapts an account-keyed secure blob store into the relay-policy cache's
/// single-record storage contract.
struct MobilePeerRelayPolicyRecordStore: PeerRelayPolicyStoring {
    private static let account = "relay-policy"

    private let store: any PeerSecureBlobStoring

    init(store: any PeerSecureBlobStoring) {
        self.store = store
    }

    struct StoreUnavailable: Error {
        let status: Int32
    }

    func readRecord() async throws -> Data? {
        switch await store.read(account: Self.account) {
        case let .found(data):
            return data
        case .absent:
            return nil
        case let .unavailable(status):
            throw StoreUnavailable(status: status)
        }
    }

    func writeRecord(_ data: Data) async throws {
        try await store.write(data, account: Self.account)
    }

    func removeAll() async throws {
        try await store.delete(account: Self.account)
    }
}

/// Validates a configured Keychain access group against the process's actual
/// entitlements before the transport builds identity stores on it.
///
/// Fleet-archived dev builds bake `$(AppIdentifierPrefix)` into
/// `CMUXKeychainAccessGroup` without a signing context, so the plist carries
/// the bare bundle identifier while the local re-sign entitles only the
/// team-prefixed group. Passing that unentitled group made every Keychain
/// read fail with `errSecMissingEntitlement`, which the durable device-id
/// store correctly treats as "unavailable" — permanently wedging endpoint
/// activation. An unentitled group therefore falls back to the app's default
/// access group instead of poisoning every downstream read.
enum MobilePeerKeychainAccessGroupValidator {
    static func entitledGroup(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.cmux.keychain-access-group-probe",
            kSecAttrAccessGroup as String: candidate,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            #if DEBUG
            Logger(subsystem: "dev.cmux.ios", category: "peer-transport")
                .error(
                    "keychain access group not entitled, using default group: \(candidate, privacy: .public)"
                )
            #endif
            return nil
        }
        return candidate
    }
}
