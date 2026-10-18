#if os(iOS)
import CNBackend
import Foundation
import StackAuth

/// Whether an email-code failure should switch to the verify-your-email flow
/// (ported from cmux iOS `SignInEmailCodeFailurePolicy`).
struct SignInEmailCodeFailurePolicy {
    enum Action: Equatable {
        case requestEmailVerification
        case showError
    }

    func action(for error: any Error) -> Action {
        guard let stackError = error as? any StackAuthErrorProtocol,
              stackError.code.uppercased() == "USER_EMAIL_ALREADY_EXISTS",
              wouldWorkIfEmailWasVerified(stackError.details) else {
            return .showError
        }
        return .requestEmailVerification
    }

    private func wouldWorkIfEmailWasVerified(_ details: [String: Any]?) -> Bool {
        let value = details?["would_work_if_email_was_verified"]
        return value as? Bool ?? (value as? NSNumber)?.boolValue ?? false
    }
}

/// User-facing sign-in error text, with the same copy as cmux iOS
/// `SignInErrorPresentation`.
struct SignInErrorPresentation {
    private let emailCodeFailurePolicy = SignInEmailCodeFailurePolicy()

    func message(for error: any Error) -> String {
        if let stackError = error as? any StackAuthErrorProtocol {
            switch stackError.code.uppercased() {
            case "SCHEMA_ERROR":
                return "Please enter a valid email address."
            case "USER_EMAIL_ALREADY_EXISTS":
                if emailCodeFailurePolicy.action(for: error) == .requestEmailVerification {
                    return "Verify this email before requesting a sign-in code."
                }
                return "An account with this email already exists. Try signing in instead."
            case "VERIFICATION_CODE_ERROR", "INVALID_OTP":
                return "Invalid code. Please check and try again."
            case "OTP_EXPIRED":
                return "Code expired. Please request a new one."
            case "RATE_LIMIT", "RATE_LIMITED":
                return "Too many attempts. Please wait a moment and try again."
            case "EMAIL_PASSWORD_MISMATCH":
                return "Incorrect email or password."
            case "USER_NOT_FOUND":
                return "No account found with this email."
            case "PASSKEY_AUTHENTICATION_FAILED", "PASSKEY_WEBAUTHN_ERROR":
                return "Passkey authentication failed. Please try again."
            case "INVALID_TOTP_CODE":
                return "Incorrect verification code. Please try again."
            case "REDIRECT_URL_NOT_WHITELISTED", "INVALID_URL":
                return "Sign in is temporarily unavailable. Please try again later."
            case "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN":
                return "This account is already linked to another sign-in method."
            case "INVALID_APPLE_CREDENTIALS", "APPLE_SIGNIN_NOT_CONFIGURED", "APPLE_SIGNIN_NOT_HANDLED",
                 "APPLE_SIGNIN_INVALID_RESPONSE", "APPLE_SIGNIN_FAILED", "APPLE_SIGNIN_NOT_INTERACTIVE", "APPLE_SIGNIN_ERROR":
                return "Apple Sign In is not available yet. Please use another sign-in method."
            case "OAUTH_ERROR", "MISSING_CODE", "PARSE_ERROR", "INVALID_RESPONSE":
                return "Could not complete browser sign-in. Try again or open sign-in in your browser."
            default:
                break
            }
        }
        if let flowError = error as? SignInFlowError, let text = flowError.errorDescription {
            return text
        }
        if let backendError = error as? BackendError, let text = backendError.errorDescription {
            return text
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Could not connect to the server. Check your internet connection and try again."
        }
        #if DEBUG
        var debug = "\(error.localizedDescription)\n\(String(reflecting: type(of: error)))"
        if let stackError = error as? any StackAuthErrorProtocol {
            debug += "\ncode: \(stackError.code)\nmessage: \(stackError.message)"
        }
        return debug
        #else
        return "Something went wrong. Please try again."
        #endif
    }
}
#endif
