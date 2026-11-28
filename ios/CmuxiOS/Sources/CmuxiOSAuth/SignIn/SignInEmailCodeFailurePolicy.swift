import Foundation
import StackAuth

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
