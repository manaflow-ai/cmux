import CmuxScreenKit
import CmuxVNC
import CmuxVNCWebRTC
import Foundation
import Observation
import Security
import UIKit

/// A saved VNC computer. The password lives in the Keychain, never here.
struct SavedHost: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// `host`, `host:port`, `host:display` or a `vnc://` URL.
    var address: String
    var username: String
    var options = ScreenPreferences()
    /// Set for a Mac paired over WebRTC (its cmux-vnc-host room); `address` is then a label.
    var pairing: VNCPairing?

    var endpoint: VNCEndpoint? { VNCEndpoint.parse(address)?.endpoint }
    var subtitle: String { pairing != nil ? "WebRTC · paired with cmux-vnc-host" : (endpoint?.label ?? address) }
}

/// Saved hosts in UserDefaults, passwords in the Keychain.
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [SavedHost] = []
    private let key = "cmux.vnc.hosts.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([SavedHost].self, from: data) {
            hosts = saved
        }
    }

    func upsert(_ host: SavedHost, password: String?) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) { hosts[index] = host } else { hosts.append(host) }
        if let password { Keychain().setPassword(password.isEmpty ? nil : password, for: host.id) }
        persist()
    }

    /// Adds (or updates) the Mac behind a pairing link.
    @discardableResult
    func pair(_ pairing: VNCPairing, username: String = "", password: String? = nil) -> SavedHost {
        var host = hosts.first { $0.pairing?.room == pairing.room }
            ?? SavedHost(name: pairing.name, address: "webrtc:\(pairing.room.prefix(8))", username: username)
        host.pairing = pairing
        if !username.isEmpty { host.username = username }
        upsert(host, password: password)
        return host
    }

    /// Keeps a session's menu choices (quality, fit) for the next one.
    func setOptions(_ options: ScreenPreferences, for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }), hosts[index].options != options else { return }
        hosts[index].options = options
        persist()
    }

    func remove(_ host: SavedHost) {
        hosts.removeAll { $0.id == host.id }
        Keychain().setPassword(nil, for: host.id)
        persist()
    }

    func password(for host: SavedHost) -> String? { Keychain().password(for: host.id) }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Generic-password items, one per saved host.
struct Keychain {
    private let service = "dev.cmux.vnc.demo"

    func password(for id: UUID) -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String?, for id: UUID) {
        SecItemDelete(base(id) as CFDictionary)
        guard let password, let data = password.data(using: .utf8) else { return }
        var add = base(id)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
}
