import CmuxiOSWorkspacesCore
import UIKit

/// The list's empty states as content-unavailable configurations.
@MainActor
enum WorkspaceEmptyContent {
    static func configuration(for state: WorkspaceListEmptyState, feature: WorkspacesFeature) -> UIContentConfiguration {
        switch state {
        case .loading:
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = WorkspacesText.loadingTitle
            return loading
        case .noMachines:
            return make(WorkspacesText.noMachinesTitle, WorkspacesText.noMachinesBody, symbol: "desktopcomputer")
        case .allHidden:
            var content = make(WorkspacesText.allHiddenTitle, WorkspacesText.allHiddenBody, symbol: "eye.slash")
            content.button = .plain()
            content.button.title = WorkspacesText.showAll
            content.buttonProperties.primaryAction = UIAction { [weak feature] _ in
                feature?.updatePreferences { $0.hiddenHosts = [] }
            }
            return content
        case .noWorkspaces:
            return make(WorkspacesText.noWorkspacesTitle, WorkspacesText.noWorkspacesBody, symbol: "square.stack.3d.up")
        case .filterEmpty(let filter):
            var content = make(WorkspacesText.filterEmptyTitle,
                               WorkspacesText.format(WorkspacesText.filterEmptyBody, WorkspacesText.filterName(filter)),
                               symbol: "line.3.horizontal.decrease.circle")
            content.button = .plain()
            content.button.title = WorkspacesText.showAll
            content.buttonProperties.primaryAction = UIAction { [weak feature] _ in
                feature?.updatePreferences { $0.filter = .all }
            }
            return content
        }
    }

    private static func make(_ title: String, _ body: String, symbol: String) -> UIContentUnavailableConfiguration {
        var content = UIContentUnavailableConfiguration.empty()
        content.image = UIImage(systemName: symbol)
        content.text = title
        content.secondaryText = body
        return content
    }
}
