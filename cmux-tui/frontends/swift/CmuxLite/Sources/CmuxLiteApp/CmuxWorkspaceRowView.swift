import AppKit

@MainActor
final class CmuxWorkspaceRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux-workspace-row")

    private let rail = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        wantsLayer = true

        rail.wantsLayer = true
        rail.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rail)
        addSubview(nameLabel)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func configure(name: String, subtitle: String, active: Bool) {
        nameLabel.stringValue = name
        subtitleLabel.stringValue = subtitle
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
            ? palette.activeBackground
            : (hovered ? palette.hoverBackground : palette.background)).cgColor
        rail.layer?.backgroundColor = (active ? palette.rail : .clear).cgColor
        nameLabel.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        nameLabel.textColor = active ? palette.activeForeground : palette.foreground
        subtitleLabel.textColor = active ? palette.dim : palette.sidebarDim
    }
}
