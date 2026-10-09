public import CmuxiOSFeatureKit
public import Foundation

/// Device-local settings per host, as JSON in Application Support (no
/// secrets: passwords are in the Keychain, keys in `SSHKeyStore`).
public actor SSHHostSettingsStore {
    private let url: URL
    private var settings: [String: SSHHostSettings]

    public init(url: URL) {
        self.url = url
        settings = (try? JSONDecoder().decode([String: SSHHostSettings].self, from: Data(contentsOf: url))) ?? [:]
    }

    public func settings(for id: HostID) -> SSHHostSettings {
        settings[id.rawValue] ?? SSHHostSettings()
    }

    public func set(_ value: SSHHostSettings, for id: HostID) throws {
        settings[id.rawValue] = value
        try persist()
    }

    public func remove(_ id: HostID) throws {
        guard settings.removeValue(forKey: id.rawValue) != nil else { return }
        try persist()
    }

    /// Hosts that log in with `keyID` (to warn before deleting a key).
    public func hosts(using keyID: UUID) -> [HostID] {
        settings.compactMap { $0.value.auth == .key(keyID) ? HostID($0.key) : nil }.sorted { $0.rawValue < $1.rawValue }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
