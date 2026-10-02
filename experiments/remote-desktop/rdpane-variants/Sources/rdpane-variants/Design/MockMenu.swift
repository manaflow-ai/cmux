import AppKit

/// A drawn menu (tab context menu, menu bar item menu). A real NSMenu
/// cannot be screenshotted without activating the app, so the prototype
/// draws one in the same shape.
enum MockMenuItem {
    case header(String)
    case item(String, shortcut: String? = nil, submenu: Bool = false, highlighted: Bool = false, danger: Bool = false)
    case custom(NSView)
    case caption(String)
    case separator
}

final class MockMenu: NSView {
    init(items: [MockMenuItem], width: CGFloat, tokens: Tokens, material: SurfaceMaterial) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let rows = items.map { Self.row(for: $0, width: width, tokens: tokens) }
        let column = UI.vstack(rows, spacing: 0, alignment: .leading, insets: NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5))
        let surface = Surface.make(content: column, material: material, tokens: tokens, cornerRadius: 12)
        addSubview(surface)
        Surface.pin(surface, to: self)
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func row(for item: MockMenuItem, width: CGFloat, tokens: Tokens) -> NSView {
        let inner = width - 10
        switch item {
        case .separator:
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            let line = UI.divider(vertical: false, length: 0, color: tokens.separator.withAlphaComponent(tokens.isDark ? 0.14 : 0.10))
            holder.addSubview(line)
            NSLayoutConstraint.activate([
                holder.widthAnchor.constraint(equalToConstant: inner),
                holder.heightAnchor.constraint(equalToConstant: 9),
                line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 8),
                line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -8),
                line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
            return holder
        case .header(let text):
            return fixedRow(UI.label(text, size: 11, weight: .semibold, color: tokens.textTertiary), width: inner, height: 22, fill: nil)
        case .caption(let text):
            let label = UI.wrapping(text, size: 11, color: tokens.textTertiary, width: inner - 20, centered: false)
            return fixedRow(label, width: inner, height: 34, fill: nil)
        case .custom(let view):
            return fixedRow(view, width: inner, height: nil, fill: nil)
        case .item(let title, let shortcut, let submenu, let highlighted, let danger):
            let color = danger ? tokens.danger : tokens.textPrimary
            var parts: [NSView] = [UI.label(title, size: 13, color: color), UI.spacer()]
            if let shortcut { parts.append(UI.label(shortcut, size: 12, color: tokens.textTertiary)) }
            if submenu { parts.append(UI.symbol("chevron.right", size: 9, weight: .semibold, color: tokens.textTertiary)) }
            let row = UI.hstack(parts, spacing: 6)
            return fixedRow(row, width: inner, height: 24, fill: highlighted ? tokens.selectionFill : nil)
        }
    }

    private static func fixedRow(_ content: NSView, width: CGFloat, height: CGFloat?, fill: NSColor?) -> NSView {
        let holder = FillView(fill: fill ?? .clear, radius: .fixed(7))
        holder.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            holder.widthAnchor.constraint(equalToConstant: width),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
        ]
        if let height {
            constraints.append(holder.heightAnchor.constraint(equalToConstant: height))
            constraints.append(content.centerYAnchor.constraint(equalTo: holder.centerYAnchor))
        } else {
            constraints.append(content.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4))
            constraints.append(content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4))
        }
        NSLayoutConstraint.activate(constraints)
        return holder
    }
}
