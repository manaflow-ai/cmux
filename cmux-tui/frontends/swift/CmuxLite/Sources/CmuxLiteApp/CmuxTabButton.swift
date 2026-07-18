import AppKit

@MainActor
final class CmuxTabButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private var active = false
    private var label = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(34, ceil(attributedTitle.size().width)), height: 28)
    }

    func configure(label: String, active: Bool) {
        self.label = label
        self.active = active
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
        let palette = CmuxPalette.tui
        layer?.backgroundColor = (active
            ? palette.statusActiveBackground
            : (hovered ? palette.hoverBackground : palette.statusBackground)).cgColor

        let value = label
        let text = NSMutableAttributedString(
            string: value,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
                .foregroundColor: active || hovered
                    ? palette.activeForeground
                    : palette.tabInactive,
            ]
        )
        attributedTitle = text
        invalidateIntrinsicContentSize()
    }
}
