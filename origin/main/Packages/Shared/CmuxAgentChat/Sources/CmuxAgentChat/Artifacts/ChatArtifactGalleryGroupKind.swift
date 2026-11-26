/// The fixed provenance group organization of the artifact gallery.
public enum ChatArtifactGalleryGroupKind: String, CaseIterable, Sendable, Equatable {
    /// Files created by the agent.
    case created
    /// Files attached by the user.
    case attached
    /// Other files referenced by the session.
    case referenced
}
