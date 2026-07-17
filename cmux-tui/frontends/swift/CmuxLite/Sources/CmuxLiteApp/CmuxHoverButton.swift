import AppKit

@MainActor
final class CmuxHoverButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private var active = false
    private var normalBackground = NSColor.clear
    private var hoverBackground = CmuxPalette.tui.hoverBackground
    private var activeBackground = CmuxPalette.tui.statusActiveBackground
    private var normalForeground = CmuxPalette.tui.dim
    private var activeForeground = CmuxPalette.tui.activeForeground
    private var titleFont = NSFont.systemFont(ofSize: 11)
    private var horizontalPadding: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(
        title: String,
        active: Bool = false,
        alignment: NSTextAlignment = .center,
        font: NSFont = .systemFont(ofSize: 11),
        normalBackground: NSColor = .clear,
        hoverBackground: NSColor = CmuxPalette.tui.hoverBackground,
        activeBackground: NSColor = CmuxPalette.tui.statusActiveBackground,
        normalForeground: NSColor = CmuxPalette.tui.dim,
        activeForeground: NSColor = CmuxPalette.tui.activeForeground,
        horizontalPadding: CGFloat = 0
    ) {
        self.title = title
        self.active = active
        self.alignment = alignment
        titleFont = font
        self.normalBackground = normalBackground
        self.hoverBackground = hoverBackground
        self.activeBackground = activeBackground
        self.normalForeground = normalForeground
        self.activeForeground = activeForeground
        self.horizontalPadding = horizontalPadding
        refreshAppearance()
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshAppearance()
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        refreshAppearance()
        super.mouseExited(with: event)
    }

    private func refreshAppearance() {
        layer?.backgroundColor = (active
            ? activeBackground
            : (hovered ? hoverBackground : normalBackground)).cgColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.firstLineHeadIndent = horizontalPadding
        paragraph.headIndent = horizontalPadding
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: titleFont,
                .foregroundColor: active ? activeForeground : normalForeground,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
