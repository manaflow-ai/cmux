import Foundation

/// The answer to one choice question: picked option ids and an optional
/// "other" text.
public struct FeedChoiceSelection: Hashable, Sendable {
    public var selected: [String]
    public var other: String?

    public init(selected: [String] = [], other: String? = nil) {
        self.selected = selected
        self.other = other
    }

    public var isEmpty: Bool {
        selected.isEmpty && (other?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Toggles `option`: single-select questions replace the pick and clear
    /// "other"; multi-select questions add or remove it.
    public func toggling(_ option: String, multi: Bool) -> FeedChoiceSelection {
        var next = self
        if multi {
            if let index = next.selected.firstIndex(of: option) { next.selected.remove(at: index) } else { next.selected.append(option) }
        } else {
            next.selected = next.selected == [option] ? [] : [option]
            next.other = nil
        }
        return next
    }
}
