public import Foundation

/// An App Group the app declares and its container on this device (nil when
/// the system has none, for example a build signed without the group).
public struct AppGroupContainer: Hashable, Sendable {
    public var id: String
    public var url: URL?

    public init(id: String, url: URL?) {
        self.id = id
        self.url = url
    }
}
