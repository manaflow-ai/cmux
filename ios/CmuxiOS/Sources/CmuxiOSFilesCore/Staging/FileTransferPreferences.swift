import Foundation

/// Device preferences for transfers (client view state, this device only).
public struct FileTransferPreferences {
    public static let convertHEICKey = "cmux.files.convertHEIC"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-encode HEIC photos as JPEG before saving them to the Mac (default on).
    public var convertHEIC: Bool {
        get { defaults.object(forKey: Self.convertHEICKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.convertHEICKey) }
    }
}
