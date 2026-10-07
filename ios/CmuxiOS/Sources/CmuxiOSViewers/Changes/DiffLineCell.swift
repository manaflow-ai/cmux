import CmuxiOSViewersCore
import UIKit

/// One diff row: a hunk header, a unified line (old and new numbers, then
/// the text) or a split row (old half, new half). Manual layout and
/// self-sizing, so long lines wrap and reuse stays cheap.
@MainActor
final class DiffLineCell: UICollectionViewCell {
    static let reuse = "DiffLineCell"
    private let oldGutter = UILabel()
    private let newGutter = UILabel()
    private let leftText = UILabel()
    private let rightText = UILabel()
    private let leftBackground = UIView()
    private let rightBackground = UIView()
    private var isSplit = false
    private var isHeader = false
    private var gutterWidth: CGFloat = 32

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [leftBackground, rightBackground] { contentView.addSubview(view) }
        for label in [oldGutter, newGutter] {
            label.textAlignment = .right
            label.textColor = ViewerStyle.gutterText
            contentView.addSubview(label)
        }
        for label in [leftText, rightText] {
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            contentView.addSubview(label)
        }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: DiffRow, renderer: DiffRowRenderer, gutterWidth: CGFloat) {
        self.gutterWidth = gutterWidth
        oldGutter.font = renderer.gutterFont
        newGutter.font = renderer.gutterFont
        switch row {
        case .hunk(_, let header, _):
            isHeader = true
            isSplit = false
            leftText.attributedText = NSAttributedString(string: header, attributes: [
                .font: renderer.gutterFont, .foregroundColor: UIColor.secondaryLabel,
            ])
            rightText.attributedText = nil
            oldGutter.text = nil
            newGutter.text = nil
            leftBackground.backgroundColor = ViewerStyle.hunkBackground
            rightBackground.backgroundColor = .clear
            accessibilityLabel = header
            accessibilityTraits = .header
        case .line(let line):
            isHeader = false
            isSplit = false
            leftText.attributedText = renderer.text(line)
            rightText.attributedText = nil
            oldGutter.text = line.oldNumber.map(String.init)
            newGutter.text = line.newNumber.map(String.init)
            leftBackground.backgroundColor = DiffRowRenderer.background(line)
            rightBackground.backgroundColor = .clear
            accessibilityLabel = DiffRowRenderer.accessibility(line)
            accessibilityTraits = .staticText
        case .split(let old, let new):
            isHeader = false
            isSplit = true
            leftText.attributedText = old.map(renderer.text)
            rightText.attributedText = new.map(renderer.text)
            oldGutter.text = old?.oldNumber.map(String.init)
            newGutter.text = new?.newNumber.map(String.init)
            leftBackground.backgroundColor = DiffRowRenderer.background(old)
            rightBackground.backgroundColor = DiffRowRenderer.background(new)
            accessibilityLabel = old == new ? DiffRowRenderer.accessibility(old)
                : DiffRowRenderer.accessibility(old) + "; " + DiffRowRenderer.accessibility(new)
            accessibilityTraits = .staticText
        }
        setNeedsLayout()
    }

    private struct Frames {
        var oldGutter: CGRect = .zero
        var newGutter: CGRect = .zero
        var left: CGRect = .zero
        var right: CGRect = .zero
        var leftBackground: CGRect = .zero
        var rightBackground: CGRect = .zero
        var height: CGFloat = 0
    }

    private func frames(width: CGFloat) -> Frames {
        var f = Frames()
        let pad: CGFloat = 6
        let vertical: CGFloat = isHeader ? 6 : 2
        func height(_ label: UILabel, _ width: CGFloat) -> CGFloat {
            guard label.attributedText?.length ?? 0 > 0 else { return label.font.lineHeight }
            return ceil(label.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height)
        }
        if isHeader {
            let textWidth = width - 2 * pad - 8
            f.height = height(leftText, textWidth) + 2 * vertical
            f.left = CGRect(x: pad + 8, y: vertical, width: textWidth, height: f.height - 2 * vertical)
            f.leftBackground = CGRect(x: 0, y: 0, width: width, height: f.height)
        } else if isSplit {
            let half = floor(width / 2)
            let textWidth = half - gutterWidth - 2 * pad
            let content = max(height(leftText, textWidth), height(rightText, textWidth))
            f.height = content + 2 * vertical
            f.oldGutter = CGRect(x: 0, y: vertical, width: gutterWidth, height: oldGutter.font.lineHeight)
            f.left = CGRect(x: gutterWidth + pad, y: vertical, width: textWidth, height: content)
            f.newGutter = CGRect(x: half, y: vertical, width: gutterWidth, height: newGutter.font.lineHeight)
            f.right = CGRect(x: half + gutterWidth + pad, y: vertical, width: textWidth, height: content)
            f.leftBackground = CGRect(x: 0, y: 0, width: half - 0.5, height: f.height)
            f.rightBackground = CGRect(x: half + 0.5, y: 0, width: width - half - 0.5, height: f.height)
        } else {
            let textWidth = width - 2 * gutterWidth - 2 * pad
            let content = height(leftText, textWidth)
            f.height = content + 2 * vertical
            f.oldGutter = CGRect(x: 0, y: vertical, width: gutterWidth, height: oldGutter.font.lineHeight)
            f.newGutter = CGRect(x: gutterWidth, y: vertical, width: gutterWidth, height: newGutter.font.lineHeight)
            f.left = CGRect(x: 2 * gutterWidth + pad, y: vertical, width: textWidth, height: content)
            f.leftBackground = CGRect(x: 0, y: 0, width: width, height: f.height)
        }
        return f
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let f = frames(width: contentView.bounds.width)
        oldGutter.frame = f.oldGutter
        newGutter.frame = f.newGutter
        leftText.frame = f.left
        rightText.frame = f.right
        leftBackground.frame = f.leftBackground
        rightBackground.frame = f.rightBackground
        rightText.isHidden = !isSplit
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        attributes.frame.size.height = frames(width: layoutAttributes.frame.width).height
        return attributes
    }
}
