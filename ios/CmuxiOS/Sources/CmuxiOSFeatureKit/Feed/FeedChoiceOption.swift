import Foundation

public struct FeedChoiceOption: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?

    public init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}
