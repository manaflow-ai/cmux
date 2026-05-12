import Foundation

enum AuthError: Error, LocalizedError {
    case networkError
    case serverError(Int, String)
    case invalidCode
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .networkError:
            return L10n.string("auth.error.networkError", defaultValue: "Network error. Please check your connection.")
        case .serverError:
            return L10n.string("auth.error.serverError", defaultValue: "Something went wrong. Please try again.")
        case .invalidCode:
            return L10n.string("auth.error.invalidCodeShort", defaultValue: "Invalid code. Please try again.")
        case .unauthorized:
            return L10n.string("auth.error.unauthorized", defaultValue: "Session expired. Please sign in again.")
        }
    }
}
