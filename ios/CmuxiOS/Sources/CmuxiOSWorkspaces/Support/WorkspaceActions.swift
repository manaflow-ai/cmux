import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
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
