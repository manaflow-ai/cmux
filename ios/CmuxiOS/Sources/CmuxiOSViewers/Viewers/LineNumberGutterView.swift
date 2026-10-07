import CmuxiOSViewersCore
import UIKit

/// Line numbers beside a TextKit 2 text view: draws one number per visible
/// paragraph (layout fragment) at its first line, so wrapped lines keep a
/// single number. It sits outside the scroll view and redraws on scroll,
/// so its backing store is one screen tall whatever the file length.
@MainActor
final class LineNumberGutterView: UIView {
    weak var textView: UITextView?
    var lineIndex = LineIndex("")
    var font: UIFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Width for the largest line number.
    func preferredWidth() -> CGFloat {
        let digits = String(repeating: "8", count: max(2, String(lineIndex.lineCount).count))
        return ceil((digits as NSString).size(withAttributes: [.font: font]).width) + 16
    }

    override func draw(_ rect: CGRect) {
        guard let textView, let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ViewerStyle.gutterText]
        let top = textView.contentOffset.y
        let visible = CGRect(x: 0, y: top, width: textView.bounds.width, height: textView.bounds.height)
        let origin = textView.textContainerInset.top
        let documentStart = layout.documentRange.location
        guard let start = layout.textLayoutFragment(for: CGPoint(x: 0, y: max(0, visible.minY - origin)))?.rangeInElement.location
            ?? Optional(documentStart) else { return }
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let y = frame.minY + origin - top
            guard y < self.bounds.height else { return false }
            let offset = content.offset(from: documentStart, to: fragment.rangeInElement.location)
            let number = String(self.lineIndex.line(containing: offset) + 1) as NSString
            let size = number.size(withAttributes: attributes)
            let baselineAdjust = (fragment.textLineFragments.first?.typographicBounds.height ?? size.height) - size.height
            number.draw(at: CGPoint(x: self.bounds.width - size.width - 8, y: y + max(0, baselineAdjust / 2)), withAttributes: attributes)
            return true
        }
    }
}
