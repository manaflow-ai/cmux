import Foundation

final class NotificationTokenStore {
    static let shared = NotificationTokenStore()

    private let tokenKey = "notifications.deviceToken"

    private init() {}

    func load() -> String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    func save(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }
}
