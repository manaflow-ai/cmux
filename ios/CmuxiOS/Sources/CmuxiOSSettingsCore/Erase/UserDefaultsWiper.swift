import Foundation

/// The real defaults wipe: the app's domain, and prefixed keys in a shared suite.
public struct UserDefaultsWiper: DefaultsWiping {
    public init() {}

    public func removeDomain(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    public func removeKeys(suite: String, prefix: String) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
