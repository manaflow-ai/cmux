public import Foundation

/// Deletes every Keychain item of one class the app can read.
public protocol KeychainWiping: Sendable {
    func deleteAll(_ itemClass: KeychainItemClass) throws
}

/// File removal for Erase All Data.
public protocol FileWiping: Sendable {
    func children(of directory: URL) throws -> [URL]
    func exists(_ url: URL) -> Bool
    func remove(_ url: URL) throws
}

/// Defaults removal for Erase All Data.
public protocol DefaultsWiping: Sendable {
    func removeDomain(_ name: String)
    func removeKeys(suite: String, prefix: String)
}
