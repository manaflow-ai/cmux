import Foundation

/// Decides at launch whether onboarding runs, from the environment.
///
/// DEBUG builds skip onboarding for automated launches (the dogfood readiness
/// receipt, launcher sign-in credentials, Home, terminal and gallery
/// previews, a forced shell tab) unless `CMUX_IOS_ONBOARDING=1` asks for it.
/// `CMUX_IOS_ONBOARDING=0` skips it; `CMUX_IOS_ONBOARDING_STEP=<step>` starts
/// at a step for screenshots. Release builds ignore the environment.
public struct OnboardingLaunchPolicy: Hashable, Sendable {
    public var decision: OnboardingLaunch

    public init(environment: [String: String], isDebug: Bool) {
        guard isDebug else {
            decision = .stored(start: nil)
            return
        }
        let start = environment["CMUX_IOS_ONBOARDING_STEP"].flatMap(OnboardingStep.init(rawValue:))
        switch environment["CMUX_IOS_ONBOARDING"] {
        case "1", "fresh":
            decision = .fresh(start: start)
        case "0", "skip":
            decision = .skip
        default:
            decision = Self.isAutomated(environment) ? .skip : .stored(start: start)
        }
    }

    /// Whether to present onboarding once auth has restored. An install with
    /// no stored progress that is already signed in predates this onboarding
    /// (an update from the earlier app), so it is treated as onboarded.
    public func shouldPresent(stored: OnboardingProgress?, isSignedIn: Bool) -> Bool {
        switch decision {
        case .skip: false
        case .fresh: true
        case .stored:
            if let stored { !stored.finished } else { !isSignedIn }
        }
    }

    private static func isAutomated(_ environment: [String: String]) -> Bool {
        let present: (String) -> Bool = { !(environment[$0] ?? "").isEmpty }
        return present("CMUX_DOGFOOD_READINESS_NONCE")
            || present("CMUX_UITEST_STACK_EMAIL")
            || present("CMUX_IOS_SHELL_TAB")
            || environment["CMUX_IOS_HOME_PREVIEW"] == "1"
            || environment["CMUX_IOS_TERMINAL_PREVIEW"] == "1"
            || environment["CMUX_IOS_GALLERY"] == "1"
    }
}
