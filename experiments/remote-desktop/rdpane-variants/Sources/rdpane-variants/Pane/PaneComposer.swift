import AppKit

enum ChromeVariant {
    /// A: floating glass pill at the top center, shown on hover.
    case hoverToolbar
    /// B: plain always-visible strip under the image.
    case statusStrip
    /// C: a corner path badge only; actions in the tab menu and palette.
    case noChrome
}

enum PaneState {
    case live
    case connecting
    case highLatency
    case consentWait
    case disconnectedBy(String)
    case hostStopped

    var showsFrame: Bool {
        switch self {
        case .live, .highLatency, .disconnectedBy, .hostStopped: true
        case .connecting, .consentWait: false
        }
    }

    var ended: Bool {
        switch self {
        case .disconnectedBy, .hostStopped: true
        default: false
        }
    }

    func model() -> SessionModel {
        var model = SessionModel()
        switch self {
        case .live:
            break
        case .connecting:
            model.path = .connecting
            model.sessionControls = false
        case .highLatency:
            model.path = .relayed(rttMs: 142)
            model.mode = .view
            model.controlAvailable = false
        case .consentWait:
            model.path = .direct(rttMs: 6)
            model.sessionControls = false
        case .disconnectedBy, .hostStopped:
            model.path = .ended
            model.sessionControls = false
        }
        return model
    }
}

/// Builds one remote desktop pane: tab strip, the 1:1 image area, chrome
/// and the state overlay.
@MainActor
enum PaneComposer {
    /// `remoteDesktop.interactiveMaxRttMs` default (plan section 16).
    static let interactiveMaxRttMs = 80

    static func make(chrome: ChromeVariant, state: PaneState, tokens: Tokens, material: SurfaceMaterial) -> NSView {
        let model = state.model()
        let root = FillView(fill: tokens.windowBackground)
        let strip = MockTabStrip(host: model.host, tokens: tokens)
        let image = imageArea(state: state, tokens: tokens)
        root.addSubview(strip)
        root.addSubview(image)
        var constraints = [
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            image.topAnchor.constraint(equalTo: strip.bottomAnchor),
            image.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ]

        switch chrome {
        case .hoverToolbar:
            constraints.append(image.bottomAnchor.constraint(equalTo: root.bottomAnchor))
            let toolbar = HoverToolbar(model: model, tokens: tokens, material: material)
            root.addSubview(toolbar)
            constraints += [
                toolbar.centerXAnchor.constraint(equalTo: image.centerXAnchor),
                toolbar.topAnchor.constraint(equalTo: image.topAnchor, constant: 10),
            ]
            // Rendered in the shown state; hover uses `setRevealed`.
            if case .highLatency = state, case .relayed(let rtt) = model.path {
                let banner = LatencyBanner(rttMs: rtt, path: L10n.pathRelayed, limitMs: interactiveMaxRttMs, tokens: tokens, material: material)
                root.addSubview(banner)
                constraints += [
                    banner.centerXAnchor.constraint(equalTo: image.centerXAnchor),
                    banner.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
                ]
            }
        case .statusStrip:
            let status = StatusStrip(model: model, tokens: tokens)
            root.addSubview(status)
            constraints += [
                image.bottomAnchor.constraint(equalTo: status.topAnchor),
                status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ]
        case .noChrome:
            constraints.append(image.bottomAnchor.constraint(equalTo: root.bottomAnchor))
            let badge = CornerBadge(model: model, tokens: tokens, material: material)
            root.addSubview(badge)
            constraints += [
                badge.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -10),
                badge.bottomAnchor.constraint(equalTo: image.bottomAnchor, constant: -10),
            ]
            let menu = tabMenu(tokens: tokens, material: material)
            root.addSubview(menu)
            constraints += [
                menu.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6 + MockTabStrip.tabWidth + 4 + 70),
                menu.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: -6),
            ]
        }

        if let card = stateCard(state: state, model: model, tokens: tokens, material: material) {
            root.addSubview(card)
            constraints += [
                card.centerXAnchor.constraint(equalTo: image.centerXAnchor),
                card.centerYAnchor.constraint(equalTo: image.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }

    private static func imageArea(state: PaneState, tokens: Tokens) -> NSView {
        let area = FillView(fill: tokens.isDark ? NSColor(hex: 0x1B1D21) : NSColor(hex: 0xE4E4E6))
        if state.showsFrame {
            let desktop = SyntheticDesktopView()
            desktop.translatesAutoresizingMaskIntoConstraints = false
            desktop.desaturated = state.ended
            area.addSubview(desktop)
            Surface.pin(desktop, to: area)
            if state.ended {
                let dim = FillView(fill: NSColor.black.withAlphaComponent(tokens.isDark ? 0.5 : 0.35))
                area.addSubview(dim)
                Surface.pin(dim, to: area)
            }
        }
        return area
    }

    private static func stateCard(state: PaneState, model: SessionModel, tokens: Tokens, material: SurfaceMaterial) -> NSView? {
        switch state {
        case .live, .highLatency:
            return nil
        case .connecting:
            return StateCard(icon: .spinner, title: L10n.connectingTitle(model.host), detail: L10n.connectingDetail,
                             buttons: [ChromeButton(title: L10n.cancel, style: .neutral, tokens: tokens, height: 26)],
                             tokens: tokens, material: material)
        case .consentWait:
            return StateCard(icon: .symbol("hand.raised", tokens.textSecondary), title: L10n.consentTitle(model.host),
                             detail: L10n.consentDetail(host: model.host, seconds: 24),
                             buttons: [ChromeButton(title: L10n.cancel, style: .neutral, tokens: tokens, height: 26)],
                             tokens: tokens, material: material)
        case .disconnectedBy(let name):
            return StateCard(icon: .symbol("person.crop.circle.badge.xmark", tokens.textSecondary), title: L10n.kickedTitle(name),
                             detail: L10n.kickedDetail(name: name, host: model.host),
                             buttons: [ChromeButton(title: L10n.reconnect, style: .neutral, tokens: tokens, height: 26),
                                       ChromeButton(title: L10n.close, style: .subtle, tokens: tokens, height: 26)],
                             tokens: tokens, material: material)
        case .hostStopped:
            return StateCard(icon: .symbol("rectangle.on.rectangle.slash", tokens.textSecondary), title: L10n.stoppedTitle,
                             detail: L10n.stoppedDetail(model.host),
                             buttons: [ChromeButton(title: L10n.reconnect, style: .neutral, tokens: tokens, height: 26),
                                       ChromeButton(title: L10n.close, style: .subtle, tokens: tokens, height: 26)],
                             tokens: tokens, material: material)
        }
    }

    /// Variant C keeps every action in the tab's context menu (and the
    /// palette); this is that menu, open.
    private static func tabMenu(tokens: Tokens, material: SurfaceMaterial) -> NSView {
        MockMenu(items: [
            .item(L10n.menuSwitchToView, highlighted: true),
            .item(L10n.menuDisplay, submenu: true),
            .item(L10n.menuQuality, submenu: true),
            .item(L10n.menuFillWindow),
            .item(L10n.menuReleaseKeyboard, shortcut: "⌃⌥⎋"),
            .separator,
            .item(L10n.menuCopyHost),
            .item(L10n.menuStopSession, danger: true),
            .separator,
            .caption(L10n.menuPaletteHint),
        ], width: 260, tokens: tokens, material: material)
    }
}
