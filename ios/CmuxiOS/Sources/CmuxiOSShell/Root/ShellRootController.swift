public import UIKit
import CmuxiOSDesign

/// The signed-in root: a tab bar on iPhone that adapts into a sidebar on
/// iPad (iOS 18 `UITab` with `.tabSidebar`; iOS 17 keeps the tab bar).
/// Each tab's controller is built once on first use and kept while the tab
/// stays visible, so a flag change never rebuilds Home.
@MainActor
public final class ShellRootController: UITabBarController {
    private let content: (ShellTab) -> UIViewController
    private var controllers: [ShellTab: UIViewController] = [:]
    private var tabObjects: [ShellTab: AnyObject] = [:]
    public private(set) var visibleTabs: [ShellTab] = []
    /// Cmd-K on a hardware keyboard (lane C15). Nil hides the command.
    public var onSearchCommand: (() -> Void)?

    public init(tabs: [ShellTab], sidebar: Bool, content: @escaping (ShellTab) -> UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
        tabBar.tintColor = ShellPalette.selection
        tabBar.unselectedItemTintColor = ShellPalette.unselected
        view.tintColor = ShellPalette.selection
        setTabs(tabs, sidebar: sidebar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The current controller of a tab, if it was built.
    public func controller(for tab: ShellTab) -> UIViewController? { controllers[tab] }

    /// The tab on screen.
    public var selectedShellTab: ShellTab? {
        if #available(iOS 18.0, *), let selected = selectedTab {
            if selected is UISearchTab { return .search }
            return ShellTab(rawValue: selected.identifier)
        }
        guard visibleTabs.indices.contains(selectedIndex) else { return nil }
        return visibleTabs[selectedIndex]
    }

    /// Shows `tab` if it is visible; returns whether it is.
    @discardableResult
    public func select(_ tab: ShellTab) -> Bool {
        guard let index = visibleTabs.firstIndex(of: tab) else { return false }
        // Build the root now so a route can push onto it right after.
        _ = builtController(for: tab)
        if #available(iOS 18.0, *), let object = tabObjects[tab] as? UITab {
            selectedTab = object
        } else {
            selectedIndex = index
        }
        return true
    }

    /// Applies a new tab set (flags changed). Kept tabs keep their controller
    /// and the selection stays when its tab is still visible.
    public func setTabs(_ tabs: [ShellTab], sidebar: Bool) {
        let selected = selectedShellTab
        for removed in Set(visibleTabs).subtracting(tabs) {
            controllers[removed] = nil
            tabObjects[removed] = nil
        }
        visibleTabs = tabs
        if #available(iOS 18.0, *) {
            mode = sidebar ? .tabSidebar : .tabBar
            self.tabs = tabs.map(tabObject(for:))
        } else {
            setViewControllers(tabs.map(controllerWithItem(for:)), animated: false)
        }
        if let selected, tabs.contains(selected) { select(selected) }
    }

    // MARK: Search command

    override public var canBecomeFirstResponder: Bool { onSearchCommand != nil }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Key commands need a responder in the chain when no field has focus.
        if onSearchCommand != nil, !isFirstResponder { becomeFirstResponder() }
    }

    override public var keyCommands: [UIKeyCommand]? {
        guard onSearchCommand != nil else { return super.keyCommands }
        let search = UIKeyCommand(title: ShellText.searchCommand, action: #selector(performSearchCommand),
                                  input: "k", modifierFlags: .command)
        search.discoverabilityTitle = ShellText.searchCommand
        return (super.keyCommands ?? []) + [search]
    }

    /// Screens that hide the tab bar (terminals) own the keyboard, so Cmd-K
    /// reaches them (it clears a terminal) instead of opening search.
    override public func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(performSearchCommand) {
            return onSearchCommand != nil && !selectedScreenHidesTabBar
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func performSearchCommand() { onSearchCommand?() }

    private var selectedScreenHidesTabBar: Bool {
        guard let tab = selectedShellTab, let root = controllers[tab] else { return false }
        let top = (root as? UINavigationController)?.topViewController ?? root
        return top.hidesBottomBarWhenPushed
    }

    @available(iOS 18.0, *)
    private func tabObject(for tab: ShellTab) -> UITab {
        if let existing = tabObjects[tab] as? UITab { return existing }
        if tab == .search {
            // The system places the search tab in its search role (HIG: Tab bars).
            let object = UISearchTab { [weak self] _ in self?.builtController(for: tab) ?? UIViewController() }
            object.accessibilityIdentifier = tab.accessibilityIdentifier
            tabObjects[tab] = object
            return object
        }
        let object = UITab(title: tab.title, image: UIImage(systemName: tab.symbolName), identifier: tab.rawValue) {
            [weak self] _ in
            self?.builtController(for: tab) ?? UIViewController()
        }
        object.accessibilityIdentifier = tab.accessibilityIdentifier
        tabObjects[tab] = object
        return object
    }

    private func controllerWithItem(for tab: ShellTab) -> UIViewController {
        let controller = builtController(for: tab)
        controller.tabBarItem = UITabBarItem(title: tab.title, image: UIImage(systemName: tab.symbolName), tag: 0)
        controller.tabBarItem.accessibilityIdentifier = tab.accessibilityIdentifier
        return controller
    }

    private func builtController(for tab: ShellTab) -> UIViewController {
        if let existing = controllers[tab] { return existing }
        let controller = content(tab)
        controllers[tab] = controller
        return controller
    }
}
