public import Foundation

/// The last remote config for each signed-in account on this device. A
/// projection; cleared on sign-out. Account keys prevent one account's flags
/// or demo state from appearing during another account's restore.
public struct RemoteConfigCache: @unchecked Sendable {
    public static let defaultsKey = "cmux.ios.remoteConfig"
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load(for account: String) -> RemoteConfig? {
        defaults.data(forKey: key(for: account)).flatMap { try? JSONDecoder().decode(RemoteConfig.self, from: $0) }
    }

    public func save(_ config: RemoteConfig, for account: String) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key(for: account))
    }

    public func clear(for account: String) { defaults.removeObject(forKey: key(for: account)) }

    private func key(for account: String) -> String {
        let encoded = Data(account.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(Self.defaultsKey).\(encoded)"
    }
}
