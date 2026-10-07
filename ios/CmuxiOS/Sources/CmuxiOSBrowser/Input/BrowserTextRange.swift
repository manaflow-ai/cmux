import UIKit

/// A range of UTF-16 offsets in the composition buffer.
final class BrowserTextRange: UITextRange {
    let lower: Int
    let upper: Int

    init(_ lower: Int, _ upper: Int) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    override var start: UITextPosition { BrowserTextPosition(lower) }
    override var end: UITextPosition { BrowserTextPosition(upper) }
    override var isEmpty: Bool { lower == upper }
}
