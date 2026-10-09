public import Foundation

/// Whether the user chose "Use SSH Without an Account" on this device
/// (client view state, never synced). Cleared when they sign in or tap
/// Sign In from the guest shell.
public struct GuestModeStore {
    public static let key = "dev.cmux.ios.next.guest.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isChosen: Bool { defaults.bool(forKey: Self.key) }

    public func choose() { defaults.set(true, forKey: Self.key) }

    public func clear() { defaults.removeObject(forKey: Self.key) }
}
