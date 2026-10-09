import Foundation

/// One line of a What's New page.
public struct WhatsNewItem: Hashable, Sendable, Identifiable {
    public var id: String { systemImage + title }
    public let systemImage: String
    public let title: String
    public let detail: String

    public init(systemImage: String, title: String, detail: String) {
        self.systemImage = systemImage
        self.title = title
        self.detail = detail
    }
}
