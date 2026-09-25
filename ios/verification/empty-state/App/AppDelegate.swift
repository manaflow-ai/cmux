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
    private let countLabel = UILabel()
    private var refreshCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "All Computers"
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemBackground
        countLabel.accessibilityIdentifier = "ProofRefreshCount"
        countLabel.text = "0"
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: countLabel)
        emptyCell.selectionStyle = .none
        emptyCell.backgroundColor = .clear
        emptyCell.contentConfiguration = UIHostingConfiguration {
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
        emptyCell.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        emptyCell.contentView.bounds = emptyCell.bounds
        emptyCell.setNeedsLayout()
        emptyCell.layoutIfNeeded()
        let fitted = emptyCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let scale = max(tableView.traitCollection.displayScale, 1)
        return max(1, ceil(fitted * scale) / scale)
    }
}
