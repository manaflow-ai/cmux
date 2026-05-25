import Foundation
import SwiftUI
import CmuxKit
import Combine

/// Persistent host catalog. Hosts themselves live in UserDefaults (no
/// secrets); credential material lives in the Keychain via
/// `CmuxCredentialStore`.
@MainActor
final class HostStore: ObservableObject {
    static let shared = HostStore()

    private let defaultsKey = "cmux.hosts.v1"
    private let activeHostKey = "cmux.hosts.active.v1"

    // CRITICAL: use the App Group suite so the widget extension and
    // App Intents — which run in separate sandboxes — can read the
    // active host and the host list. `defaults` is
    // isolated per-target and would leave widgets/intents with an
    // empty roster.
    private let defaults: UserDefaults = UserDefaults(
        suiteName: "group.com.cmuxterm.remote"
    ) ?? .standard

    @Published private(set) var hosts: [CmuxHost] = []
    @Published var activeHostID: UUID?

    var activeHost: CmuxHost? {
        guard let id = activeHostID else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    private init() {
        load()
    }

    func addOrUpdate(_ host: CmuxHost) {
        if let idx = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[idx] = host
        } else {
            hosts.append(host)
        }
        save()
    }

    func remove(_ hostID: UUID) {
        hosts.removeAll(where: { $0.id == hostID })
        if activeHostID == hostID { activeHostID = hosts.first?.id }
        Task { await CmuxCredentialStore.shared.deleteAll(hostID: hostID) }
        save()
    }

    func setActive(_ hostID: UUID?) {
        activeHostID = hostID
        save()
    }

    private func load() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([CmuxHost].self, from: data) {
            hosts = decoded
        }
        if let idString = defaults.string(forKey: activeHostKey),
           let id = UUID(uuidString: idString) {
            activeHostID = id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: defaultsKey)
        }
        if let id = activeHostID {
            defaults.set(id.uuidString, forKey: activeHostKey)
        } else {
            defaults.removeObject(forKey: activeHostKey)
        }
    }
}
