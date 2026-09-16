import CMUXMobileCore
import CmuxIrxTransport
import CryptoKit
import Foundation

/// Device-local routes keyed by complete v2 account/team/build scope; never synchronized.
actor MobileIrohV2LocalPathStore {
    struct Path: Codable, Sendable {
        let macDeviceID: String
        let instanceTag: String?
        let macDisplayName: String
        let addresses: [String]
        let isEnabled: Bool
    }
    private let files = FileManager()
    private let root: URL
    init(root: URL) { self.root = root.appendingPathComponent("cmux-iroh-v2/local-paths", isDirectory: true) }

    func load(identity: V2Identity) throws -> [Path] {
        let url = try file(identity)
        guard files.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Path].self, from: Data(contentsOf: url))
    }

    func upsert(_ draft: CmxIrohCustomPrivatePathDraft, identity: V2Identity) throws {
        guard !draft.addresses.isEmpty, draft.addresses.count <= CmxIrohCustomPrivatePathDraft.maximumAddressCount else {
            throw CmxIrohCustomPrivateAddressError.invalidAddress
        }
        let addresses = try draft.addresses.map { raw in
            try CmxIrohLocalSocketAddress(raw).value
        }
        var paths = try load(identity: identity)
        paths.removeAll { $0.macDeviceID == draft.macDeviceID && $0.instanceTag == draft.instanceTag }
        guard paths.count < 64 else { throw CmxIrohSettingsControlError.unsupported }
        paths.append(Path(macDeviceID: draft.macDeviceID, instanceTag: draft.instanceTag,
            macDisplayName: draft.macDisplayName, addresses: addresses, isEnabled: draft.isEnabled))
        try save(paths, identity: identity)
    }

    func remove(macDeviceID: String, instanceTag: String?, identity: V2Identity) throws {
        try save(load(identity: identity).filter { $0.macDeviceID != macDeviceID || $0.instanceTag != instanceTag }, identity: identity)
    }

    private func save(_ paths: [Path], identity: V2Identity) throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = try file(identity)
        try JSONEncoder().encode(paths).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func file(_ identity: V2Identity) throws -> URL {
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest + ".json")
    }
}
