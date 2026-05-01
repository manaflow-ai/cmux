import Foundation

/// Centralized source of truth for configuring the daemon's remote APNs push
/// path (Phase 4.3). Holds the current hex-encoded device token, reads the
/// Next.js push endpoint and bearer from UserDefaults / Info.plist, and fires
/// `NotificationCenter` change notifications whenever any of those inputs
/// change so `TerminalDaemonConnection` can re-provision `daemon.configure_notifications`
/// on the live daemon socket.
///
/// Default off: if endpoint or bearer is empty, `currentConfiguration()` returns
/// nil and the daemon call is skipped (remote push disabled).
final class PushNotificationConfigurator: @unchecked Sendable {
    static let shared = PushNotificationConfigurator()

    /// Fired when the device token, the configured endpoint, or the bearer
    /// token changes. Observers reprovision the daemon push config.
    static let didChangeNotification = Notification.Name(
        "PushNotificationConfigurator.didChange"
    )

    enum UserDefaultsKeys {
        static let pushEndpoint = "cmux.pushEndpoint"
        static let pushBearer = "cmux.pushBearer"
    }

    enum InfoPlistKeys {
        static let pushEndpoint = "CMUXPushEndpoint"
        static let pushBearer = "CMUXPushBearer"
    }

    struct DaemonConfiguration: Equatable, Sendable {
        let endpoint: String
        let bearerToken: String
        let deviceTokens: [String]
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let bundle: Bundle
    private var currentDeviceTokenHex: String?
    private var defaultsObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) {
        self.defaults = defaults
        self.bundle = bundle
        observeUserDefaultsChanges()
    }

    deinit {
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Device token

    func updateDeviceToken(_ hex: String?) {
        let trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed

        let changed: Bool = lock.withLock {
            if currentDeviceTokenHex == normalized { return false }
            currentDeviceTokenHex = normalized
            return true
        }

        guard changed else { return }
        postDidChange()
    }

    func deviceTokenHex() -> String? {
        lock.withLock { currentDeviceTokenHex }
    }

    // MARK: - Configuration resolution

    /// Returns the daemon configuration if endpoint, bearer, and device token
    /// are all present. Otherwise returns nil (remote push disabled).
    func currentConfiguration() -> DaemonConfiguration? {
        guard let endpoint = resolveEndpoint(), !endpoint.isEmpty else {
            return nil
        }
        guard let bearer = resolveBearer(), !bearer.isEmpty else {
            return nil
        }
        guard let token = deviceTokenHex(), !token.isEmpty else {
            return nil
        }
        return DaemonConfiguration(
            endpoint: endpoint,
            bearerToken: bearer,
            deviceTokens: [token]
        )
    }

    private func resolveEndpoint() -> String? {
        if let stored = defaults.string(forKey: UserDefaultsKeys.pushEndpoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        if let infoValue = bundle.object(forInfoDictionaryKey: InfoPlistKeys.pushEndpoint) as? String {
            let trimmed = infoValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func resolveBearer() -> String? {
        if let stored = defaults.string(forKey: UserDefaultsKeys.pushBearer)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        if let infoValue = bundle.object(forInfoDictionaryKey: InfoPlistKeys.pushBearer) as? String {
            let trimmed = infoValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - Change notifications

    private func observeUserDefaultsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            self?.postDidChange()
        }
    }

    private func postDidChange() {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self
        )
    }
}
