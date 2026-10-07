import Foundation

/// Where a flag's value came from, highest precedence first.
public enum FlagLayer: String, Sendable, CaseIterable {
    case environment
    case deviceOverride
    case remote
    case buildDefault
}
