import Foundation

/// A saved SSH connection to a remote Mac.
struct SavedConnection: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String
    var host: String
    var port: Int
    var username: String
    /// Reference to an SSHKeyStore key label for authentication.
    var keyLabel: String?
    /// When true, this host is running cmux and workspace features are enabled.
    var isCmux: Bool
    var lastConnected: Date?

    init(
        id: UUID = UUID(),
        label: String,
        host: String,
        port: Int = 22,
        username: String,
        keyLabel: String? = nil,
        isCmux: Bool = false,
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.keyLabel = keyLabel
        self.isCmux = isCmux
        self.lastConnected = lastConnected
    }
}

// MARK: - Persistence

/// Stores saved connections in UserDefaults (will migrate to CloudKit/Keychain later).
struct SavedConnectionStore {
    private static let key = "ai.manaflow.cmux.saved-connections"

    static func load() -> [SavedConnection] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
    }

    static func save(_ connections: [SavedConnection]) {
        let data = try? JSONEncoder().encode(connections)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func add(_ connection: SavedConnection) {
        var all = load()
        all.append(connection)
        save(all)
    }

    static func update(_ connection: SavedConnection) {
        var all = load()
        if let idx = all.firstIndex(where: { $0.id == connection.id }) {
            all[idx] = connection
            save(all)
        }
    }

    static func delete(id: UUID) {
        var all = load()
        all.removeAll { $0.id == id }
        save(all)
    }
}
