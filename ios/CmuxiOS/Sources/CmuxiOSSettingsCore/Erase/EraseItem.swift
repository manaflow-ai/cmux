public import Foundation

/// One thing Erase All Data removes.
public enum EraseItem: Hashable, Sendable {
    /// Every item of this class the app can read, synchronizable or not.
    case keychain(KeychainItemClass)
    /// The directory's contents; the directory itself stays (the system owns it).
    case directoryContents(URL)
    /// A whole folder this app owns inside a shared container.
    case folder(URL)
    /// The app's standard defaults (persistent domain = bundle id).
    case defaultsDomain(String)
    /// The keys with this prefix in a shared defaults suite.
    case defaultsKeys(suite: String, prefix: String)
}
