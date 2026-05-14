import Foundation

/// Base protocol for all Stack Auth errors
public protocol StackAuthErrorProtocol: Error, CustomStringConvertible {
    var code: String { get }
    var message: String { get }
    var details: [String: Any]? { get }
}

/// Standard Stack Auth API error
public struct StackAuthError: StackAuthErrorProtocol {
    public let code: String
    public let message: String
    public let details: [String: Any]?
    
    public var description: String {
        "StackAuthError(\(code)): \(message)"
    }
    
    public init(code: String, message: String, details: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

// MARK: - Specific Error Types

public struct EmailPasswordMismatchError: StackAuthErrorProtocol {
    public let code = "EMAIL_PASSWORD_MISMATCH"
    public let message = "The email and password combination is incorrect."
    public let details: [String: Any]? = nil
    public var description: String { "EmailPasswordMismatchError: \(message)" }
}

public struct UserWithEmailAlreadyExistsError: StackAuthErrorProtocol {
    public let code = "USER_EMAIL_ALREADY_EXISTS"
    public let message = "A user with this email address already exists."
    public let details: [String: Any]? = nil
    public var description: String { "UserWithEmailAlreadyExistsError: \(message)" }
}

public struct PasswordRequirementsNotMetError: StackAuthErrorProtocol {
    public let code = "PASSWORD_REQUIREMENTS_NOT_MET"
    public let message = "The password does not meet the project's requirements."
    public let details: [String: Any]? = nil
    public var description: String { "PasswordRequirementsNotMetError: \(message)" }
}

public struct UserNotFoundError: StackAuthErrorProtocol {
    public let code = "USER_NOT_FOUND"
    public let message = "No user with this email address was found."
    public let details: [String: Any]? = nil
    public var description: String { "UserNotFoundError: \(message)" }
}

public struct VerificationCodeError: StackAuthErrorProtocol {
    public let code = "VERIFICATION_CODE_ERROR"
    public let message = "The verification code is invalid or expired."
    public let details: [String: Any]? = nil
    public var description: String { "VerificationCodeError: \(message)" }
}

public struct InvalidTotpCodeError: StackAuthErrorProtocol {
    public let code = "INVALID_TOTP_CODE"
    public let message = "The MFA code is incorrect."
    public let details: [String: Any]? = nil
    public var description: String { "InvalidTotpCodeError: \(message)" }
}

public struct RedirectUrlNotWhitelistedError: StackAuthErrorProtocol {
    public let code = "REDIRECT_URL_NOT_WHITELISTED"
    public let message = "The callback URL is not in the project's trusted domains list."
    public let details: [String: Any]? = nil
    public var description: String { "RedirectUrlNotWhitelistedError: \(message)" }
}

public struct PasskeyAuthenticationFailedError: StackAuthErrorProtocol {
    public let code = "PASSKEY_AUTHENTICATION_FAILED"
    public let message = "Passkey authentication failed. Please try again."
    public let details: [String: Any]? = nil
    public var description: String { "PasskeyAuthenticationFailedError: \(message)" }
}

public struct PasskeyWebAuthnError: StackAuthErrorProtocol {
    public let code = "PASSKEY_WEBAUTHN_ERROR"
    public let message: String
    public let details: [String: Any]? = nil
    public var description: String { "PasskeyWebAuthnError: \(message)" }
    
    public init(errorName: String) {
        self.message = "WebAuthn error: \(errorName)."
    }
}

public struct MultiFactorAuthenticationRequiredError: StackAuthErrorProtocol {
    public let code = "MULTI_FACTOR_AUTHENTICATION_REQUIRED"
    public let message = "Multi-factor authentication is required."
    public let attemptCode: String
    public var details: [String: Any]? { ["attempt_code": attemptCode] }
    public var description: String { "MultiFactorAuthenticationRequiredError: \(message)" }
    
    public init(attemptCode: String) {
        self.attemptCode = attemptCode
    }
}

public struct UserNotSignedInError: StackAuthErrorProtocol {
    public let code = "USER_NOT_SIGNED_IN"
    public let message = "User is not signed in."
    public let details: [String: Any]? = nil
    public var description: String { "UserNotSignedInError: \(message)" }
}

public struct OAuthError: StackAuthErrorProtocol {
    public let code: String
    public let message: String
    public let details: [String: Any]?
    public var description: String { "OAuthError(\(code)): \(message)" }
    
    public init(code: String, message: String, details: [String: Any]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct PasswordConfirmationMismatchError: StackAuthErrorProtocol {
    public let code = "PASSWORD_CONFIRMATION_MISMATCH"
    public let message = "The current password is incorrect."
    public let details: [String: Any]? = nil
    public var description: String { "PasswordConfirmationMismatchError: \(message)" }
}

public struct OAuthProviderAccountIdAlreadyUsedError: StackAuthErrorProtocol {
    public let code = "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN"
    public let message = "This OAuth account is already linked to another user for sign-in."
    public let details: [String: Any]? = nil
    public var description: String { "OAuthProviderAccountIdAlreadyUsedError: \(message)" }
}

// MARK: - Error Parsing

extension StackAuthError {
    /// Parse error from API response
    /// Error codes from the API are UPPERCASE_WITH_UNDERSCORES
    static func from(code: String, message: String, details: [String: Any]? = nil) -> any StackAuthErrorProtocol {
        switch code {
        case "EMAIL_PASSWORD_MISMATCH":
            return EmailPasswordMismatchError()
        case "USER_EMAIL_ALREADY_EXISTS":
            return UserWithEmailAlreadyExistsError()
        case "PASSWORD_REQUIREMENTS_NOT_MET":
            return PasswordRequirementsNotMetError()
        case "USER_NOT_FOUND":
            return UserNotFoundError()
        case "VERIFICATION_CODE_ERROR":
            return VerificationCodeError()
        case "INVALID_TOTP_CODE":
            return InvalidTotpCodeError()
        case "REDIRECT_URL_NOT_WHITELISTED":
            return RedirectUrlNotWhitelistedError()
        case "PASSKEY_AUTHENTICATION_FAILED":
            return PasskeyAuthenticationFailedError()
        case "MULTI_FACTOR_AUTHENTICATION_REQUIRED":
            if let attemptCode = details?["attempt_code"] as? String {
                return MultiFactorAuthenticationRequiredError(attemptCode: attemptCode)
            }
            return StackAuthError(code: code, message: message, details: details)
        case "PASSWORD_CONFIRMATION_MISMATCH":
            return PasswordConfirmationMismatchError()
        case "OAUTH_PROVIDER_ACCOUNT_ID_ALREADY_USED_FOR_SIGN_IN":
            return OAuthProviderAccountIdAlreadyUsedError()
        default:
            return StackAuthError(code: code, message: message, details: details)
        }
    }
}
