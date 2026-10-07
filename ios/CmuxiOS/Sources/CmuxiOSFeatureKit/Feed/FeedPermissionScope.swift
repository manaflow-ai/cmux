import Foundation

public enum FeedPermissionScope: String, Hashable, Sendable, CaseIterable {
    case once
    case session
    case always
}
