import Foundation

/// One trailing button; running it dismisses the toast.
public struct ToastAction: Sendable {
    public let label: String
    public let handler: @MainActor @Sendable () -> Void

    public init(label: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.label = label
        self.handler = handler
    }
}
