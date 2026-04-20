import Foundation
#if canImport(Security)
import Security
#endif

/// Protocol for custom token storage implementations.
/// Constrained to AnyObject (classes/actors) to enable identity-based locking.
public protocol TokenStoreProtocol: AnyObject, Sendable {
    /// Get the currently stored access token, or null if not set.
    /// This is internal - use getOrFetchLikelyValidTokens() instead for automatic refresh.
    func getStoredAccessToken() async -> String?
    
    /// Get the currently stored refresh token, or null if not set.
    func getStoredRefreshToken() async -> String?
    
    /// Set both tokens at once
    func setTokens(accessToken: String?, refreshToken: String?) async
    
    /// Clear both tokens
    func clearTokens() async
    
    /// Atomically compare-and-set tokens.
    /// Compares compareRefreshToken to current refreshToken.
    /// If they match: set refreshToken to newRefreshToken and accessToken to newAccessToken.
    /// If they don't match: do nothing (another thread updated the refresh token).
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async
}

/// Token storage configuration
public enum TokenStoreInit: Sendable {
    #if canImport(Security)
    /// Store tokens in Keychain (default, secure, persists across launches)
    /// Only available on Apple platforms (iOS, macOS, etc.)
    case keychain
    #endif
    
    /// Store tokens in memory (lost on app restart)
    case memory
    
    /// Explicit tokens (for server-side usage)
    case explicit(accessToken: String, refreshToken: String)
    
    /// No token storage
    case none
    
    /// Custom storage implementation
    case custom(any TokenStoreProtocol)
}

// MARK: - Token Store Registry

/// Manages singleton instances of token stores keyed by projectId.
/// Ensures that multiple uses of keychain/memory with the same projectId
/// share the same token storage and refresh lock.
///
/// Uses NSLock for thread safety so it can be called synchronously from
/// non-async contexts (like init). The lock is only held briefly during
/// dictionary lookup/insert - actual token operations use the store's
/// own actor serialization.
public final class TokenStoreRegistry: @unchecked Sendable {
    public static let shared = TokenStoreRegistry()
    
    private let lock = NSLock()
    
    #if canImport(Security)
    private var keychainStores: [String: KeychainTokenStore] = [:]
    #endif
    private var memoryStores: [String: MemoryTokenStore] = [:]
    
    private init() {}
    
    #if canImport(Security)
    func getKeychainStore(projectId: String) -> KeychainTokenStore {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = keychainStores[projectId] {
            return existing
        }
        let store = KeychainTokenStore(projectId: projectId)
        keychainStores[projectId] = store
        return store
    }
    #endif
    
    func getMemoryStore(projectId: String) -> MemoryTokenStore {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = memoryStores[projectId] {
            return existing
        }
        let store = MemoryTokenStore()
        memoryStores[projectId] = store
        return store
    }
    
    /// Reset all cached stores. Only for testing purposes.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        #if canImport(Security)
        keychainStores.removeAll()
        #endif
        memoryStores.removeAll()
    }
}

// MARK: - Keychain Token Store (Apple platforms only)

#if canImport(Security)
actor KeychainTokenStore: TokenStoreProtocol {
    private let accessTokenKey: String
    private let refreshTokenKey: String
    
    init(projectId: String) {
        self.accessTokenKey = "stack-auth-access-\(projectId)"
        self.refreshTokenKey = "stack-auth-refresh-\(projectId)"
    }
    
    func getStoredAccessToken() async -> String? {
        return getKeychainItem(key: accessTokenKey)
    }
    
    func getStoredRefreshToken() async -> String? {
        return getKeychainItem(key: refreshTokenKey)
    }
    
    func setTokens(accessToken: String?, refreshToken: String?) async {
        if let accessToken = accessToken {
            setKeychainItem(key: accessTokenKey, value: accessToken)
        } else {
            deleteKeychainItem(key: accessTokenKey)
        }
        
        if let refreshToken = refreshToken {
            setKeychainItem(key: refreshTokenKey, value: refreshToken)
        } else {
            deleteKeychainItem(key: refreshTokenKey)
        }
    }
    
    func clearTokens() async {
        deleteKeychainItem(key: accessTokenKey)
        deleteKeychainItem(key: refreshTokenKey)
    }
    
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        let currentRefreshToken = getKeychainItem(key: refreshTokenKey)
        if currentRefreshToken == compareRefreshToken {
            if let newRefreshToken = newRefreshToken {
                setKeychainItem(key: refreshTokenKey, value: newRefreshToken)
            } else {
                deleteKeychainItem(key: refreshTokenKey)
            }
            if let newAccessToken = newAccessToken {
                setKeychainItem(key: accessTokenKey, value: newAccessToken)
            } else {
                deleteKeychainItem(key: accessTokenKey)
            }
        }
    }
    
    // MARK: - Keychain Helpers
    
    private func getKeychainItem(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
    }
    
    private func setKeychainItem(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        // First try to update
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        
        if updateStatus == errSecItemNotFound {
            // Item doesn't exist, add it
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
    
    private func deleteKeychainItem(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
#endif

// MARK: - Memory Token Store

actor MemoryTokenStore: TokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?
    
    func getStoredAccessToken() async -> String? {
        return accessToken
    }
    
    func getStoredRefreshToken() async -> String? {
        return refreshToken
    }
    
    func setTokens(accessToken: String?, refreshToken: String?) async {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
    
    func clearTokens() async {
        self.accessToken = nil
        self.refreshToken = nil
    }
    
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        if self.refreshToken == compareRefreshToken {
            self.refreshToken = newRefreshToken
            self.accessToken = newAccessToken
        }
    }
}

// MARK: - Explicit Token Store

/// Token store initialized with explicit tokens.
/// Starts with the provided tokens, but stores any refreshed tokens in memory
/// to avoid infinite refresh loops when access tokens expire.
actor ExplicitTokenStore: TokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?
    
    init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
    
    func getStoredAccessToken() async -> String? {
        return accessToken
    }
    
    func getStoredRefreshToken() async -> String? {
        return refreshToken
    }
    
    func setTokens(accessToken: String?, refreshToken: String?) async {
        // Store refreshed tokens in memory to prevent infinite refresh loops
        if let accessToken = accessToken {
            self.accessToken = accessToken
        }
        if let refreshToken = refreshToken {
            self.refreshToken = refreshToken
        }
    }
    
    func clearTokens() async {
        self.accessToken = nil
        self.refreshToken = nil
    }
    
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        if self.refreshToken == compareRefreshToken {
            self.refreshToken = newRefreshToken
            self.accessToken = newAccessToken
        }
    }
}

// MARK: - Null Token Store

/// Token store with no initial tokens.
/// Still stores any refreshed tokens in memory to prevent infinite refresh loops.
actor NullTokenStore: TokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?
    
    func getStoredAccessToken() async -> String? {
        return accessToken
    }
    
    func getStoredRefreshToken() async -> String? {
        return refreshToken
    }
    
    func setTokens(accessToken: String?, refreshToken: String?) async {
        // Store refreshed tokens in memory to prevent infinite refresh loops
        if let accessToken = accessToken {
            self.accessToken = accessToken
        }
        if let refreshToken = refreshToken {
            self.refreshToken = refreshToken
        }
    }
    
    func clearTokens() async {
        self.accessToken = nil
        self.refreshToken = nil
    }
    
    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        if self.refreshToken == compareRefreshToken {
            self.refreshToken = newRefreshToken
            self.accessToken = newAccessToken
        }
    }
}
