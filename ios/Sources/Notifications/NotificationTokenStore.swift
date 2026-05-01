import Foundation

protocol NotificationTokenStoring: AnyObject {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

final class NotificationTokenStore: NotificationTokenStoring {
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
