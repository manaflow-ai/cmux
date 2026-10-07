public import CmuxiOSFeatureKit
import Foundation

/// File names for `@` mentions (C4 `files.list` under the workspace's root).
/// Until C4 lands, `NoFileSuggestions` answers nothing and mentions stay text.
public protocol ComposerFileSuggesting: Sendable {
    func suggestions(for query: String, target: ComposerTarget, limit: Int) async -> [String]
}
