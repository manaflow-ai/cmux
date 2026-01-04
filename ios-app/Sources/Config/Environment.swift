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

    // MARK: - Stack Auth

    var stackAuthProjectId: String {
        switch self {
        case .development:
            return "1467bed0-8522-45ee-a8d8-055de324118c"
        case .production:
            return "8a877114-b905-47c5-8b64-3a2d90679577"
        }
    }

    var stackAuthPublishableKey: String {
        switch self {
        case .development:
            return "pck_pt4nwry6sdskews2pxk4g2fbe861ak2zvaf3mqendspa0"
        case .production:
            return "pck_8761mjjmyqc84e1e8ga3rn0k1nkggmggwa3pyzzgntv70"
        }
    }

    // MARK: - Convex

    var convexURL: String {
        switch self {
        case .development:
            return "https://polite-canary-804.convex.cloud"
        case .production:
            return "https://adorable-wombat-701.convex.cloud"
        }
    }

    // MARK: - API URLs

    var apiBaseURL: String {
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
