import AppKit
import CmuxLiteCore

@MainActor
final class CmuxPaneViewController: NSViewController {
    let paneID: UInt64
    private let terminalHost: CmuxTerminalHostViewController
    private let tabBar = NSView()
    private let tabsStack = NSStackView()
    private let focusRail = NSView()
    private var snapshot: CmuxPaneSnapshot
    private var active = false
    var onActivate: ((UInt64) -> Void)?
    var onSelectTab: ((UInt64, Int) -> Void)?
    var onNewTab: ((UInt64) -> Void)?

    init(
        snapshot: CmuxPaneSnapshot,
        frontend: CmuxFrontendSession,
        ghosttyViewConfiguration: CmuxGhosttyViewConfiguration
    ) {
        paneID = snapshot.id
        self.snapshot = snapshot
        terminalHost = CmuxTerminalHostViewController(
            frontend: frontend,
            ghosttyViewConfiguration: ghosttyViewConfiguration
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let palette = CmuxPalette.tui
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = palette.background.cgColor
        root.layer?.borderWidth = 1

        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = palette.statusBackground.cgColor
        tabBar.translatesAutoresizingMaskIntoConstraints = false

        focusRail.wantsLayer = true
        focusRail.translatesAutoresizingMaskIntoConstraints = false

        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = 0
        tabsStack.translatesAutoresizingMaskIntoConstraints = false

        terminalHost.view.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabsStack)
        tabBar.addSubview(focusRail)
        root.addSubview(tabBar)
        root.addSubview(terminalHost.view)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            focusRail.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            focusRail.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            focusRail.topAnchor.constraint(equalTo: tabBar.topAnchor),
            focusRail.heightAnchor.constraint(equalToConstant: 2),
            tabsStack.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabsStack.topAnchor.constraint(equalTo: tabBar.topAnchor),
            tabsStack.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabsStack.trailingAnchor.constraint(lessThanOrEqualTo: tabBar.trailingAnchor),
            terminalHost.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalHost.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalHost.view.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalHost.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.setAccessibilityElement(true)
        root.setAccessibilityLabel(
            String(
                format: String(
                    localized: "pane.accessibility_label",
                    defaultValue: "Pane %lld",
                    bundle: .module
                ),
                Int64(paneID)
            )
        )
        view = root
        rebuildTabs()
        refreshAppearance()
    }

    var surface: UInt64? {
        snapshot.activeSurface
    }

    func update(snapshot: CmuxPaneSnapshot, active: Bool) {
        self.snapshot = snapshot
        self.active = active
        loadViewIfNeeded()
        rebuildTabs()
        refreshAppearance()
        terminalHost.setActive(active)
    }

    func consume(_ event: CmuxAttachEvent) {
        terminalHost.consume(event)
    }

    func focusTerminal() {
        terminalHost.focusTerminal()
    }

    func containsTerminal(pointInWindow: NSPoint) -> Bool {
        let point = view.convert(pointInWindow, from: nil)
        return terminalHost.view.frame.contains(point)
    }

    @objc
    private func tabPressed(_ sender: NSButton) {
        onActivate?(paneID)
        onSelectTab?(paneID, sender.tag)
    }

    @objc
    private func newTabPressed(_: NSButton) {
        onActivate?(paneID)
        onNewTab?(paneID)
    }

    private func rebuildTabs() {
        for view in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, tab) in snapshot.tabs.enumerated() {
            let accessibilityLabel = String(
                format: String(
                    localized: "tabs.unnamed",
                    defaultValue: "Tab %lld",
                    bundle: .module
                ),
                Int64(index + 1)
            )
            let button = CmuxTabButton(frame: .zero)
            button.tag = index
            button.target = self
            button.action = #selector(tabPressed(_:))
            button.setAccessibilityLabel(accessibilityLabel)
            button.toolTip = tab.label
            button.configure(label: String(index + 1), active: snapshot.activeTab == index)
            tabsStack.addArrangedSubview(button)
        }

        let newTab = CmuxHoverButton(frame: .zero)
        newTab.target = self
        newTab.action = #selector(newTabPressed(_:))
        newTab.setAccessibilityLabel(
            String(localized: "tabs.new", defaultValue: "New tab", bundle: .module)
        )
        newTab.configure(
            title: "+",
            font: .systemFont(ofSize: 16),
            normalBackground: CmuxPalette.tui.statusBackground,
            normalForeground: CmuxPalette.tui.dim
        )
        newTab.translatesAutoresizingMaskIntoConstraints = false
        newTab.widthAnchor.constraint(equalToConstant: 34).isActive = true
        tabsStack.addArrangedSubview(newTab)
    }

    private func refreshAppearance() {
        let palette = CmuxPalette.tui
        view.layer?.borderColor = (active ? palette.rail : palette.border).cgColor
        tabBar.layer?.backgroundColor = (active
            ? palette.activeBackground
            : palette.statusBackground).cgColor
        focusRail.layer?.backgroundColor = (active ? palette.rail : palette.border).cgColor
    }
}
