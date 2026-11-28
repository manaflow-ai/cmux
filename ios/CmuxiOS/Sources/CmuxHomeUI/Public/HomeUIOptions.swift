public import CmuxiOSDesign

/// How someone starts a conversation with a new person (prototype variants
/// behind a DEV switch; one ships).
public enum HomeComposeFlow: String, CaseIterable, Sendable {
    /// A new-message screen with an inline To: field and the first message.
    case inlineTo
    /// A dedicated invite sheet: one large email or phone field and a
    /// share-ready preview of what the person receives.
    case inviteSheet
    /// The system contact picker first, with manual entry as the fallback.
    case contactsFirst
}

/// Presentation options for Home. They can change while Home is on screen
/// (`HomeViewController.apply(_:)`).
public struct HomeUIOptions: Sendable, Equatable {
    public var density: HomeListDensity
    public var composeFlow: HomeComposeFlow

    public init(density: HomeListDensity = .comfortable, composeFlow: HomeComposeFlow = .inlineTo) {
        self.density = density
        self.composeFlow = composeFlow
    }
}
