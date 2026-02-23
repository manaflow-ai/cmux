import Foundation

enum AuthError: Error, LocalizedError {
    case networkError
    case serverError(Int, String)
    case invalidCode
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .networkError:
            return "Network error. Please check your connection."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .invalidCode:
            return "Invalid code. Please try again."
        case .unauthorized:
            return "Session expired. Please sign in again."
        }
    }
}
