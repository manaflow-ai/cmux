import Foundation

/// The action the sign-in code field should take after its text changes.
enum SignInCodeInputChangeAction: Equatable, Sendable {
    /// Replace the field's value with the normalized string.
    case assign(String)
    /// The code is complete; trigger verification.
    case verify
    /// No action is required.
    case none
}

/// Pure policy normalizing and validating the magic-link sign-in code as the
/// user types. Ported unchanged from cmux iOS `SignInCodeInputPolicy`.
struct SignInCodeInputPolicy {
    private init() {}

    /// The maximum number of characters a sign-in code may contain.
    static let maximumCodeLength = 6

    static func action(for value: String) -> SignInCodeInputChangeAction {
        let normalized = normalizedCode(value)
        guard normalized == value else {
            return .assign(normalized)
        }
        return shouldVerifyAfterChange(normalized) ? .verify : .none
    }

    /// Keeps ASCII letters/digits, uppercases letters, clamps to
    /// ``maximumCodeLength``.
    static func normalizedCode(_ value: String) -> String {
        var normalized = ""
        normalized.reserveCapacity(maximumCodeLength)
        for scalar in value.unicodeScalars {
            guard normalized.count < maximumCodeLength else { break }
            switch scalar.value {
            case 48...57, 65...90:
                normalized.unicodeScalars.append(scalar)
            case 97...122:
                guard let uppercase = UnicodeScalar(scalar.value - 32) else { continue }
                normalized.unicodeScalars.append(uppercase)
            default:
                continue
            }
        }
        return normalized
    }

    static func shouldVerifyAfterChange(_ normalizedCode: String) -> Bool {
        normalizedCode.count == maximumCodeLength
    }
}
