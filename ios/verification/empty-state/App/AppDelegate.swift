import SwiftUI
import UIKit

/// A focused host for the unmodified production empty row. Transport and auth
/// are excluded; only the Retry callback is replaced with a visible counter.
@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let workspaces = UINavigationController(rootViewController: EmptyStateController())
        workspaces.tabBarItem = UITabBarItem(
            title: "Workspaces", image: UIImage(systemName: "square.stack.fill"), tag: 0
        )
        let notifications = UIViewController()
        notifications.tabBarItem = UITabBarItem(
            title: "Notifications", image: UIImage(systemName: "bell.fill"), tag: 1
        )
        let tabs = UITabBarController()
        tabs.viewControllers = [workspaces, notifications]
        window.rootViewController = tabs
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

@MainActor
final class EmptyStateController: UITableViewController {
    private let emptyCell = UITableViewCell()
    private let sizingCell = UITableViewCell()
    private var measuredSize: CGSize?
    private let countLabel = UILabel()
    private var refreshCount = 0
    private let measuresDisplayedCell = ProcessInfo.processInfo.arguments.contains("--measure-displayed-cell")

    override func loadView() {
        // Use the production table class, including disabled self-sizing
        // invalidation and zero estimated heights. UIKit's defaults can hide
        // the empty-row defect by resizing a row after its initial measurement.
        tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "All Computers"
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        countLabel.accessibilityIdentifier = "ProofRefreshCount"
        countLabel.text = "0"
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: countLabel)
        configure(emptyCell)
        configure(sizingCell)
    }

    private func configure(_ cell: UITableViewCell) {
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentConfiguration = UIHostingConfiguration {
            MobileWorkspaceListEmptyRow(
                retry: { [weak self] in await self?.didRetry() },
                cancelRetry: nil,
                onLayoutChange: nil,
                shouldCancelRetryOnDisappear: nil,
                isRetryOwnerCurrentOnDisappear: nil
            )
        }
        .margins(.all, 0)
        .margins(.top, 8)
        .margins(.bottom, 8)
        .margins(.leading, 12)
        .margins(.trailing, 12)
        .minSize(width: 0, height: 0)
    }

    private func didRetry() {
        refreshCount += 1
        countLabel.text = String(refreshCount)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 1 { return emptyCell }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = "Reconnecting"
        cell.detailTextLabel?.text = "Layout fixture (no live connection)"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.row == 0 { return 64 }
        // Match WorkspaceListTableCoordinator.measure, including its effectively
        // unlimited height proposal and low vertical fitting priority.
        let width = max(tableView.bounds.width, 1)
        if !measuresDisplayedCell, let measuredSize, measuredSize.width == width { return measuredSize.height }
        // The constrained probe deliberately measures the displayed cell as
        // well, preserving the measured SwiftUI view's layout state. This is a
        // component reproducer, not the full coordinator's cell lifecycle.
        let cell = measuresDisplayedCell ? emptyCell : sizingCell
        cell.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        cell.contentView.bounds = cell.bounds
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let fitted = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let scale = max(tableView.traitCollection.displayScale, 1)
        let height = max(1, ceil(fitted * scale) / scale)
        print("EMPTY_STATE_MEASURE displayed=\(measuresDisplayedCell) width=\(width) fitted=\(height)")
        measuredSize = CGSize(width: width, height: height)
        return height
    }
}
