import Foundation

/// The Stack Auth project the app signs in against: the same projects (and
/// accounts) as cmux iOS. Debug builds use the development project, Release
/// builds the production project; `CMUX_NEXT_STACK_ENV=prod|dev` overrides it
/// in Debug.
public struct StackAuthEnvironment: Sendable, Hashable {
    public var name: String
    public var projectId: String
    /// Production sends no publishable key (the project does not require one),
    /// matching cmux iOS `AuthConfig`.
    public var publishableClientKey: String
    /// cmux web API used for email-verification and billing recovery.
    public var webAPIBaseURL: URL
    /// Where the magic-link email points (cmux iOS `AuthConfig`).
    public var magicLinkCallbackURL: String
    /// Whether the cmux iOS DEBUG `42` dogfood password shortcut is enabled.
    public var allowsDevShortcut: Bool

    public init(name: String, projectId: String, publishableClientKey: String, webAPIBaseURL: URL,
                magicLinkCallbackURL: String, allowsDevShortcut: Bool) {
        self.name = name
        self.projectId = projectId
        self.publishableClientKey = publishableClientKey
        self.webAPIBaseURL = webAPIBaseURL
        self.magicLinkCallbackURL = magicLinkCallbackURL
        self.allowsDevShortcut = allowsDevShortcut
    }

    public static let production = StackAuthEnvironment(
        name: "production",
        projectId: "9790718f-14cd-4f7e-824d-eaf527a82b82",
        publishableClientKey: "",
        webAPIBaseURL: URL(string: "https://cmux.com")!,
        magicLinkCallbackURL: "https://cmux.com/auth/callback",
        allowsDevShortcut: false
    )

    public static let development = StackAuthEnvironment(
        name: "development",
        projectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
        publishableClientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
        webAPIBaseURL: URL(string: "https://cmux.com")!,
        magicLinkCallbackURL: "http://localhost:3000/auth/callback",
        allowsDevShortcut: true
    )

    public static let environmentKey = "CMUX_NEXT_STACK_ENV"

    /// Development for Debug builds, production for Release.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> StackAuthEnvironment {
        #if DEBUG
        switch environment[environmentKey]?.lowercased() {
        case "prod", "production": return .production
        default: return .development
        }
        #else
        return .production
        #endif
    }
}
