public import CmuxMobileSSH
public import Foundation

/// Pinned host keys of this device, in OpenSSH `known_hosts` format.
///
/// Device state (never synced): trust is a decision this device made about
/// a key it saw. Writes are atomic; a missing or unreadable file reads as
/// empty. One key per identity: re-pinning replaces it.
public actor SSHKnownHostsFile: SSHKnownHostsStore {
    private let url: URL
    private var pins: [String: SSHHostKey]
    /// File order of identities, so rewrites keep the user's order.
    private var order: [String]

    public init(url: URL) {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var pins: [String: SSHHostKey] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            for entry in SSHKnownHostsLine.parse(String(line)) where pins[entry.identity] == nil {
                pins[entry.identity] = entry.key
                order.append(entry.identity)
            }
        }
        self.pins = pins
        self.order = order
    }

    public func pinnedKey(for identity: String) -> SSHHostKey? { pins[identity.lowercased()] }

    public func pin(_ key: SSHHostKey, for identity: String) {
        let identity = identity.lowercased()
        if pins[identity] == nil { order.append(identity) }
        pins[identity] = key
        persist()
    }

    public func forget(identity: String) {
        let identity = identity.lowercased()
        guard pins.removeValue(forKey: identity) != nil else { return }
        order.removeAll { $0 == identity }
        persist()
    }

    /// Every pin in file order.
    public func entries() -> [SSHKnownHostsLine] {
        order.compactMap { identity in pins[identity].map { SSHKnownHostsLine(identity: identity, key: $0) } }
    }

    /// The file's text.
    public func text() -> String {
        entries().map(\.text).joined(separator: "\n") + (order.isEmpty ? "" : "\n")
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text().utf8).write(to: url, options: [.atomic])
        } catch {
            // Keeping the in-memory pin is safe: the next connect asks again
            // after a relaunch instead of trusting silently.
        }
    }
}
