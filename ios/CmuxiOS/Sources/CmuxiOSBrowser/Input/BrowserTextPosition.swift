import UIKit

/// A UTF-16 offset in the composition buffer of `BrowserTextInputView`.
final class BrowserTextPosition: UITextPosition {
    let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }
}
