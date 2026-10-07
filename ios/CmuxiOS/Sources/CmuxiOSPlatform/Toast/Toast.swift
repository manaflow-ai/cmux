public import Foundation

/// A transient notice for `ToastCenter`. Styling, haptics and accessibility
/// derive from `style`, so call sites never encode visuals.
public struct Toast: Identifiable, Sendable {
    public private(set) var id = UUID()
    public let style: ToastStyle
    public let title: String?
    public let message: String
    public let systemImage: String?
    public let dwell: ToastDwell
    public let action: ToastAction?
    /// Toasts with equal keys coalesce instead of stacking. Defaults to
    /// style, title and message.
    public let coalescingKey: String

    public init(_ style: ToastStyle, _ message: String, title: String? = nil, systemImage: String? = nil,
                dwell: ToastDwell? = nil, action: ToastAction? = nil, coalescingKey: String? = nil) {
        self.style = style
        self.title = title
        self.message = message
        self.systemImage = systemImage ?? style.systemImage
        self.dwell = dwell ?? .standard(for: style, hasAction: action != nil)
        self.action = action
        self.coalescingKey = coalescingKey ?? [style.rawValue, title ?? "\u{0}", message].joined(separator: "\u{1F}")
    }

    /// The text VoiceOver reads.
    public var accessibilityText: String {
        [title, message].compactMap { $0 }.joined(separator: ", ")
    }

    /// This content under another toast's identity (a coalesced refresh
    /// updates the visible toast in place).
    func adopting(_ other: Toast) -> Toast {
        var copy = self
        copy.id = other.id
        return copy
    }
}
