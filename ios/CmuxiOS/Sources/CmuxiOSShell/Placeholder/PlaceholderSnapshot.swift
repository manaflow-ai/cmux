public import CmuxiOSFeatureKit
import Foundation

/// Everything a placeholder screen shows at one revision.
public struct PlaceholderSnapshot: Hashable, Sendable {
    public var connection: SourceConnection
    public var isMock: Bool
    public var sections: [PlaceholderSection]

    public init(connection: SourceConnection, isMock: Bool, sections: [PlaceholderSection]) {
        self.connection = connection
        self.isMock = isMock
        self.sections = sections
    }
}
