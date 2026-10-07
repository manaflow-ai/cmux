public import Foundation

/// The last remote config on this device, so a cold start applies it before
/// the first snapshot. A projection; cleared on sign-out.
public struct RemoteConfigCache: @unchecked Sendable {
    public static let defaultsKey = "cmux.ios.remoteConfig"
    // UserDefaults is documented thread-safe.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> RemoteConfig? {
        defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(RemoteConfig.self, from: $0) }
    }

    public func save(_ config: RemoteConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func clear() { defaults.removeObject(forKey: Self.defaultsKey) }
}
