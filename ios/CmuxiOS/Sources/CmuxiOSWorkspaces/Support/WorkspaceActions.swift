import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import SwiftUI
import UIKit

/// Row and detail actions as intents: each tap mints one `IntentKey`, so a
/// double tap or a resend never applies twice at the owner. Refusals and
/// offline results show an alert; nothing queues.
@MainActor
struct WorkspaceActions {
    let source: any WorkspaceSource

    /// The workspace an action targets, with what the list knows about it.
    struct Target {
        var workspaceID: WorkspaceSummary.ID
        var title: String
        var machineName: String
        var unreadCount: Int
        var isReachable: Bool
        var capabilities: WorkspaceCapabilities
        var color: String? = nil
        var icon: String? = nil
        var groupID: String? = nil
    }

    func canMarkRead(_ target: Target) -> Bool {
        target.isReachable && target.capabilities.contains(.markRead) && target.unreadCount > 0
    }

    func canRename(_ target: Target) -> Bool { target.isReachable && target.capabilities.contains(.rename) }
    func canClose(_ target: Target) -> Bool { target.isReachable && target.capabilities.contains(.close) }

    func markRead(_ target: Target, from presenter: UIViewController) {
        perform(.markRead(workspaceID: target.workspaceID), target: target, from: presenter)
    }

    func rename(_ target: Target, from presenter: UIViewController) {
        let alert = UIAlertController(title: WorkspacesText.renameTitle, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = target.title
            field.placeholder = WorkspacesText.renamePlaceholder
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .none
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: WorkspacesText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: WorkspacesText.rename, style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != target.title else { return }
            perform(.rename(workspaceID: target.workspaceID, title: String(name.prefix(200))), target: target, from: presenter)
        })
        presenter.present(alert, animated: true)
    }

    func close(_ target: Target, from presenter: UIViewController, sourceView: UIView? = nil, then: (() -> Void)? = nil) {
        let alert = UIAlertController(
            title: WorkspacesText.format(WorkspacesText.closeTitle, target.title),
            message: WorkspacesText.format(WorkspacesText.closeBody, target.machineName),
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: WorkspacesText.close, style: .destructive) { _ in
            perform(.close(workspaceID: target.workspaceID), target: target, from: presenter)
            then?()
        })
        alert.addAction(UIAlertAction(title: WorkspacesText.cancel, style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView ?? presenter.view
            if sourceView == nil {
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            }
        }
        presenter.present(alert, animated: true)
    }

    func canCustomize(_ target: Target) -> Bool {
        target.isReachable && (target.capabilities.contains(.customize) || target.capabilities.contains(.rename))
    }

    func canMove(_ target: Target) -> Bool { target.isReachable && target.capabilities.contains(.move) }

    /// The customize sheet (name, color, icon); Save sends a rename and a
    /// customize intent for what changed.
    func customize(_ target: Target, from presenter: UIViewController) {
        let model = WorkspaceCustomizeModel(
            title: target.title, color: target.color, icon: target.icon,
            canRename: target.capabilities.contains(.rename), canCustomize: target.capabilities.contains(.customize))
        let hosting = UIHostingController(rootView: NavigationStack { WorkspaceCustomizeView(model: model) })
        if let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        model.cancel = { [weak hosting] in hosting?.dismiss(animated: true) }
        model.save = { [weak hosting, weak presenter] model in
            hosting?.dismiss(animated: true)
            guard let presenter else { return }
            if let title = model.newTitle {
                perform(.rename(workspaceID: target.workspaceID, title: title), target: target, from: presenter)
            }
            if model.canCustomize, model.colorChange != .unchanged || model.iconChange != .unchanged {
                perform(.customize(workspaceID: target.workspaceID, color: model.colorChange, icon: model.iconChange),
                        target: target, from: presenter)
            }
        }
        presenter.present(hosting, animated: true)
    }

    /// Files the workspace at the end of `group` (nil: no group).
    func move(_ target: Target, toGroup group: String?, from presenter: UIViewController) {
        guard group != target.groupID else { return }
        let placement: WorkspaceGroupPlacement = group.map(WorkspaceGroupPlacement.group) ?? .ungrouped
        // The owner clamps the index to the section's end (the wire's maximum).
        perform(.move(workspaceID: target.workspaceID, group: placement, index: 100_000), target: target, from: presenter)
    }

    /// A drag reorder the list resolved (`WorkspaceReorder`).
    func perform(reorder intent: WorkspaceIntent, target: Target, from presenter: UIViewController) {
        perform(intent, target: target, from: presenter)
    }

    func renameGroup(host: HostID, group: WorkspaceGroup, machineName: String, from presenter: UIViewController) {
        let alert = UIAlertController(title: WorkspacesText.renameGroupTitle, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = group.name
            field.placeholder = WorkspacesText.renamePlaceholder
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: WorkspacesText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: WorkspacesText.rename, style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != group.name else { return }
            let target = Target(workspaceID: "", title: group.name, machineName: machineName, unreadCount: 0,
                                isReachable: true, capabilities: [.renameGroup])
            perform(.renameGroup(hostID: host, groupID: group.id, name: String(name.prefix(200))), target: target, from: presenter)
        })
        presenter.present(alert, animated: true)
    }

    private func perform(_ intent: WorkspaceIntent, target: Target, from presenter: UIViewController) {
        let source = self.source
        let key = IntentKey()
        Task { @MainActor [weak presenter] in
            do {
                let receipt = try await source.perform(intent, key: key)
                if case .refused(_, let reason) = receipt {
                    presenter?.presentNotice(title: WorkspacesText.refusedTitle, message: reason)
                }
            } catch {
                presenter?.presentNotice(title: WorkspacesText.offlineTitle,
                                         message: WorkspacesText.format(WorkspacesText.offlineBody, target.machineName))
            }
        }
    }
}
