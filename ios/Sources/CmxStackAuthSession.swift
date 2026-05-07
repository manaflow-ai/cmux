import Foundation
import Security

struct CmxStackAuthSession: Codable, Equatable, CustomStringConvertible {
    let refreshToken: String
    let accessToken: String

    var authorizationHeaders: [String: String] {
        [
            "Authorization": "Bearer \(accessToken)",
            "X-Stack-Refresh-Token": refreshToken,
        ]
    }

    var description: String {
        "StackAuthSession(refreshToken: redacted, accessToken: redacted)"
    }
}

protocol CmxStackAuthSessionStore {
    func load() throws -> CmxStackAuthSession?
    func save(_ session: CmxStackAuthSession) throws
    func clear() throws
}

struct CmxLaunchTicketState: Codable, Equatable {
    let ticket: String
    let autoconnect: Bool
}

protocol CmxLaunchTicketStateStore {
    func load() throws -> CmxLaunchTicketState?
    func save(_ state: CmxLaunchTicketState) throws
    func clear() throws
}

struct CmxDisabledLaunchTicketStateStore: CmxLaunchTicketStateStore {
    func load() throws -> CmxLaunchTicketState? {
        nil
    }

    func save(_: CmxLaunchTicketState) throws {}
    func clear() throws {}
}

enum CmxStackAuthCallback {
    static func parse(url: URL) throws -> CmxStackAuthSession {
        guard isSupportedCallbackURL(url) else {
            throw CmxStackAuthCallbackError.unsupportedURL
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CmxStackAuthCallbackError.unsupportedURL
        }

        let queryItems = components.queryItems ?? []
        let refreshToken = queryItems.value(named: "stack_refresh")?.nonEmpty
        guard let rawAccess = queryItems.value(named: "stack_access")?.nonEmpty else {
            throw CmxStackAuthCallbackError.missingTokens
        }

        let decoded = decodeAccessPayload(rawAccess)
        guard let resolvedRefresh = (refreshToken ?? decoded.refreshToken)?.nonEmpty,
              let resolvedAccess = (decoded.accessToken ?? rawAccess).nonEmpty else {
            throw CmxStackAuthCallbackError.missingTokens
        }

        return CmxStackAuthSession(refreshToken: resolvedRefresh, accessToken: resolvedAccess)
    }

    private static func isSupportedCallbackURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "cmux" || scheme == "cmux-nightly" || scheme.hasPrefix("cmux-dev") else { return false }
        return url.host == "auth-callback" || url.path == "/auth-callback"
    }

    private static func decodeAccessPayload(_ value: String) -> (refreshToken: String?, accessToken: String?) {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
              let data = value.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data),
              array.count >= 2 else {
            return (nil, value)
        }
        return (array[0], array[1])
    }
}

enum CmxStackAuthCallbackError: LocalizedError, Equatable {
    case unsupportedURL
    case missingTokens

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return String(localized: "auth.error.unsupported_callback", defaultValue: "This sign-in callback is not for cmux.")
        case .missingTokens:
            return String(localized: "auth.error.missing_tokens", defaultValue: "The sign-in callback did not include Stack Auth tokens.")
        }
    }
}

struct CmxKeychainStackAuthSessionStore: CmxStackAuthSessionStore {
    private let service: String
    private let account: String

    init(
        service: String = "dev.cmux.ios.stack-auth",
        account: String = "stack-auth-session"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> CmxStackAuthSession? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CmxStackAuthSessionStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw CmxStackAuthSessionStoreError.invalidPayload
        }
        return try JSONDecoder().decode(CmxStackAuthSession.self, from: data)
    }

    func save(_ session: CmxStackAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CmxStackAuthSessionStoreError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw CmxStackAuthSessionStoreError.keychain(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CmxStackAuthSessionStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct CmxKeychainLaunchTicketStateStore: CmxLaunchTicketStateStore {
    private let service: String
    private let account: String

    init(
        service: String = "dev.cmux.ios.launch-ticket",
        account: String = "last-launch-ticket"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> CmxLaunchTicketState? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CmxLaunchTicketStateStoreError.keychain(status)
        }
        guard let data = result as? Data else {
            throw CmxLaunchTicketStateStoreError.invalidPayload
        }
        return try JSONDecoder().decode(CmxLaunchTicketState.self, from: data)
    }

    func save(_ state: CmxLaunchTicketState) throws {
        let data = try JSONEncoder().encode(state)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CmxLaunchTicketStateStoreError.keychain(updateStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw CmxLaunchTicketStateStoreError.keychain(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CmxLaunchTicketStateStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum CmxStackAuthSessionStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return String(
                format: String(localized: "auth.error.keychain", defaultValue: "Could not update Stack Auth session in Keychain (%d)."),
                status
            )
        case .invalidPayload:
            return String(localized: "auth.error.invalid_session", defaultValue: "The saved Stack Auth session is invalid.")
        }
    }
}

enum CmxLaunchTicketStateStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return String(
                format: String(localized: "ticket.error.keychain", defaultValue: "Could not update the saved cmux ticket (%d)."),
                status
            )
        case .invalidPayload:
            return String(localized: "ticket.error.invalid_saved_ticket", defaultValue: "The saved cmux ticket is invalid.")
        }
    }
}

private extension Array where Element == URLQueryItem {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
