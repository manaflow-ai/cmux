import CmuxiOSWorkspacesCore
import UIKit

extension WorkspaceListViewController {
    /// Filter, sort, grouping and the machines sheet. Choices are client
    /// view state and apply at once.
    func makeViewMenu() -> UIMenu {
        let preferences = feature.preferences
        let filter = UIMenu(title: WorkspacesText.filter, options: .displayInline, children: WorkspaceListFilter.allCases.map { value in
            UIAction(title: WorkspacesText.filterName(value), state: preferences.filter == value ? .on : .off) { [weak self] _ in
                self?.feature.updatePreferences { $0.filter = value }
            }
        })
        let sort = UIMenu(title: WorkspacesText.sort, options: .displayInline, children: WorkspaceListSort.allCases.map { value in
            UIAction(title: WorkspacesText.sortName(value), state: preferences.sort == value ? .on : .off) { [weak self] _ in
                self?.feature.updatePreferences { $0.sort = value }
            }
        })
        let grouping = UIMenu(title: WorkspacesText.grouping, options: .displayInline,
                              children: WorkspaceListGrouping.allCases.map { value in
            UIAction(title: WorkspacesText.groupingName(value), state: preferences.grouping == value ? .on : .off) { [weak self] _ in
                self?.feature.updatePreferences { $0.grouping = value }
            }
        })
        let machines = UIAction(title: WorkspacesText.machines, image: UIImage(systemName: "desktopcomputer")) { [weak self] _ in
            guard let self else { return }
            self.feature.showMachines(self.hosts ?? [], from: self)
        }
        return UIMenu(title: WorkspacesText.viewOptions, children: [filter, sort, grouping, machines])
    }
}
