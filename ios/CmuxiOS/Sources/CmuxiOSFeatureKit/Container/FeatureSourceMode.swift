import Foundation

/// Which implementation backs a seam. `.real` falls back to the mock while
/// the lane has not registered a real implementation.
public enum FeatureSourceMode: String, CaseIterable, Hashable, Sendable {
    case mock
    case real
}
