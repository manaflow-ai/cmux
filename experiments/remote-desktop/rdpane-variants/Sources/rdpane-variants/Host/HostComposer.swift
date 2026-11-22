import AppKit

enum HostVariant {
    /// I1: screen-edge border plus the pill.
    case borderAndPill
    /// I2: the pill only.
    case pillOnly
    /// I3: a menu bar item only (shown with its menu open).
    case menuBarOnly
    /// The consent sheet before any session exists.
    case consent
}

/// Builds the mock host screen with one indicator variant.
@MainActor
enum HostComposer {
    static let contentSize = NSSize(width: 1100, height: 720)

    static func make(_ variant: HostVariant, tokens: Tokens, material: SurfaceMaterial) -> NSView {
        let screen = HostScreenView(dark: tokens.isDark, showsIndicatorItem: variant == .menuBarOnly, consentLayout: variant == .consent)
        var constraints: [NSLayoutConstraint] = []
        switch variant {
        case .borderAndPill, .pillOnly:
            if variant == .borderAndPill {
                let border = EdgeBorderView(color: tokens.controlIndicator)
                screen.addSubview(border)
                Surface.pin(border, to: screen)
            }
            let pill = IndicatorPill(viewer: "Lawrence", tokens: tokens, material: material)
            screen.addSubview(pill)
            constraints += [
                pill.centerXAnchor.constraint(equalTo: screen.centerXAnchor),
                pill.topAnchor.constraint(equalTo: screen.topAnchor, constant: HostScreenView.menuBarHeight + 10),
            ]
        case .menuBarOnly:
            let menu = HostMenu.make(tokens: tokens, material: material)
            screen.addSubview(menu)
            let item = screen.indicatorItemFrame(width: contentSize.width)
            let leading = min(item.minX - 4, contentSize.width - 330 - 8)
            constraints += [
                menu.leadingAnchor.constraint(equalTo: screen.leadingAnchor, constant: leading),
                menu.topAnchor.constraint(equalTo: screen.topAnchor, constant: HostScreenView.menuBarHeight + 3),
            ]
        case .consent:
            let sheet = ConsentSheet.make(requester: "Sam", seconds: 26, total: 30, tokens: tokens, material: material)
            screen.addSubview(sheet)
            let window = screen.cmuxWindowFrame
            constraints += [
                sheet.centerXAnchor.constraint(equalTo: screen.leadingAnchor, constant: window.midX),
                sheet.topAnchor.constraint(equalTo: screen.topAnchor, constant: window.minY + 34),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return screen
    }
}
