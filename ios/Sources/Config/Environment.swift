import Foundation

enum Environment {
    case development
    case production

    static var current: Environment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    // MARK: - Local Config Override

    /// Reads from LocalConfig.plist (gitignored) for per-developer overrides
    private static let localConfig: [String: Any]? = {
        guard let path = Bundle.main.path(forResource: "LocalConfig", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return dict
    }()

    private func localOverride(devKey: String, prodKey: String, legacyKey: String? = nil) -> String? {
        let environmentKey = self == .development ? devKey : prodKey
        if let value = Self.localConfig?[environmentKey] as? String, !value.isEmpty {
            return value
        }
        if let legacyKey,
           let value = Self.localConfig?[legacyKey] as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    // MARK: - Stack Auth

    var stackAuthProjectId: String {
        if let override = localOverride(
            devKey: "STACK_PROJECT_ID_DEV",
            prodKey: "STACK_PROJECT_ID_PROD"
        ) {
            return override
        }

        switch self {
        case .development:
            return "1467bed0-8522-45ee-a8d8-055de324118c"
        case .production:
            return "8a877114-b905-47c5-8b64-3a2d90679577"
        }
    }

    var stackAuthPublishableKey: String {
        if let override = localOverride(
            devKey: "STACK_PUBLISHABLE_CLIENT_KEY_DEV",
            prodKey: "STACK_PUBLISHABLE_CLIENT_KEY_PROD"
        ) {
            return override
        }

        switch self {
        case .development:
            return "pck_pt4nwry6sdskews2pxk4g2fbe861ak2zvaf3mqendspa0"
        case .production:
            return "pck_8761mjjmyqc84e1e8ga3rn0k1nkggmggwa3pyzzgntv70"
        }
    }

    // MARK: - Convex

    var convexURL: String {
        if let override = localOverride(
            devKey: "CONVEX_URL_DEV",
            prodKey: "CONVEX_URL_PROD",
            legacyKey: "CONVEX_URL"
        ) {
            return override
        }

        switch self {
        case .development:
            return "https://polite-canary-804.convex.cloud"
        case .production:
            return "https://adorable-wombat-701.convex.cloud"
        }
    }

    // MARK: - API URLs

    var apiBaseURL: String {
        if let override = localOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            legacyKey: "API_BASE_URL"
        ) {
            return override
        }

        switch self {
        case .development:
            return "http://localhost:3000"
        case .production:
            return "https://cmux.dev"
        }
    }

    // MARK: - Debug Info

    var name: String {
        switch self {
        case .development: return "Development"
        case .production: return "Production"
        }
    }
}
