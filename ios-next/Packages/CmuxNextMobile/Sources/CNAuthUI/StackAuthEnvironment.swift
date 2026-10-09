import Foundation

/// The Stack Auth project the app signs in against: the production cmux
/// project (the same accounts as cmux iOS) in every build configuration.
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

    public init(name: String, projectId: String, publishableClientKey: String, webAPIBaseURL: URL, magicLinkCallbackURL: String) {
        self.name = name
        self.projectId = projectId
        self.publishableClientKey = publishableClientKey
        self.webAPIBaseURL = webAPIBaseURL
        self.magicLinkCallbackURL = magicLinkCallbackURL
    }

    public static let production = StackAuthEnvironment(
        name: "production",
        projectId: "9790718f-14cd-4f7e-824d-eaf527a82b82",
        publishableClientKey: "",
        webAPIBaseURL: URL(string: "https://cmux.com")!,
        magicLinkCallbackURL: "https://cmux.com/auth/callback"
    )

    /// Production in Debug and Release (the backend accepts only this project).
    public static func current() -> StackAuthEnvironment { .production }
}
