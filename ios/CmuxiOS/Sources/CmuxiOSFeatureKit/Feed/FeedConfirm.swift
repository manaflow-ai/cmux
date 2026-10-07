import Foundation

public struct FeedConfirm: Hashable, Sendable {
    public var statement: String
    public var confirmLabel: String?
    public var cancelLabel: String?
    public var destructive: Bool

    public init(statement: String, confirmLabel: String? = nil, cancelLabel: String? = nil, destructive: Bool = false) {
        self.statement = statement
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.destructive = destructive
    }
}
