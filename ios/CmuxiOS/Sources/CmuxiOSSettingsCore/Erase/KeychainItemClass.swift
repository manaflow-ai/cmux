/// Every Keychain item class an app can store. Erase deletes all of them in
/// the app's own access group (the only group the app's entitlements claim).
public enum KeychainItemClass: String, CaseIterable, Hashable, Sendable {
    case genericPassword
    case internetPassword
    /// Includes Secure Enclave keys (SSH and presence keys).
    case key
    case certificate
    case identity
}
