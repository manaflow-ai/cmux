import Foundation

/// A one-time setup file: `Documents/seed-hosts.json`, copied into the app's
/// data container from a Mac (`devicectl device copy to`). Hosts are added
/// (or updated by address), passwords go to the Keychain, and the file is
/// deleted so no password stays on disk.
struct SeedImport {
    struct Entry: Decodable {
        var name: String
        var address: String
        var username: String?
        var password: String?
    }

    @MainActor
    func run(into store: HostStore) {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let file = folder.appendingPathComponent("seed-hosts.json")
        guard let data = try? Data(contentsOf: file) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in entries {
            var host = store.hosts.first { $0.address == entry.address } ?? SavedHost(name: entry.name, address: entry.address, username: "")
            host.name = entry.name
            host.username = entry.username ?? ""
            store.upsert(host, password: entry.password)
        }
    }
}
