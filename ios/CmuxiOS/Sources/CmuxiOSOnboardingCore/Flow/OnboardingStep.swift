import Foundation

/// One screen of first-run onboarding, in display order
/// (plans/cmux-next/ios-next/c10-onboarding.md section 2).
public enum OnboardingStep: String, CaseIterable, Codable, CodingKeyRepresentable, Hashable, Sendable {
    case welcome
    case approve
    case reply
    case signIn
    case notifications
    case installMac
    case localNetwork
    case pair
    case sshHost
    case celebrate

    public var phase: OnboardingPhase {
        switch self {
        case .welcome, .approve, .reply, .signIn: .intro
        case .notifications, .installMac, .localNetwork, .pair, .sshHost, .celebrate: .setup
        }
    }

    /// Setup steps act on the account, so they need a signed-in user.
    public var requiresSignIn: Bool { phase == .setup }

    /// The product tour pages the header's Skip passes over.
    public var isIntroPage: Bool { self == .welcome || self == .approve || self == .reply }

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
