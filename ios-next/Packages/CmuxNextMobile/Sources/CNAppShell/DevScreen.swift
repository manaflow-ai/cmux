import Foundation

/// DEBUG launch hook: `CMUX_NEXT_DEV_SCREEN=<screen>` starts the app straight
/// into one root backed by the in-process mock host, skipping sign-in.
/// `CMUX_NEXT_MOCK=1` runs the whole app (both shells) on the mock host.
public enum DevScreen: String, Sendable, CaseIterable {
    case conversations, agents, terminal, browser, settings, signin, onboarding, drawer, tabs

    public static let environmentKey = "CMUX_NEXT_DEV_SCREEN"
    public static let mockKey = "CMUX_NEXT_MOCK"

    public static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DevScreen? {
        #if DEBUG
        environment[environmentKey].flatMap { DevScreen(rawValue: $0.lowercased()) }
        #else
        nil
        #endif
    }

    public static func mockEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        environment[mockKey] == "1" || current(environment) != nil
        #else
        false
        #endif
    }
}
