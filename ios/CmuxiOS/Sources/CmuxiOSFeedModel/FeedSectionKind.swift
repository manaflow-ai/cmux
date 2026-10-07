public import CmuxiOSFeatureKit
import Foundation

/// What a section groups; the screen localizes its title.
public enum FeedSectionKind: Hashable, Sendable {
    case needsInput
    case earlier
    /// `label` is the workspace's display name when known (nil: no workspace).
    case workspace(id: WorkspaceSummary.ID?, label: String?)
    /// `agent` is the poster's harness (nil: other posters).
    case agent(String?)
}
