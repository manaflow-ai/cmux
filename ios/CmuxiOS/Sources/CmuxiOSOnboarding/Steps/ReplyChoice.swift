import Foundation

/// The answer on the reply tour page.
enum ReplyChoice: String, CaseIterable, Identifiable {
    case keep
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: OnboardingText.keep
        case .replace: OnboardingText.replace
        }
    }

    var followUp: String {
        switch self {
        case .keep: OnboardingText.followKeep
        case .replace: OnboardingText.followReplace
        }
    }
}
