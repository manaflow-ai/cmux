import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The ways to start something from Home.
enum ComposeRoute: Hashable, Sendable {
    case newMessage
    case invite
    case newGroup
    case newChief
}

/// Presents compose screens as full-height sheets (new-message and invite
/// screens need the room), confirms before discarding typed input, and
/// opens the resulting conversation after the sheet closes.
@MainActor
final class ComposeCoordinator: NSObject, UIAdaptivePresentationControllerDelegate {
    var flow: HomeComposeFlow = .inlineTo
    var onOpenConversation: (@MainActor (ConversationID) -> Void)?

    private let store: HomeStore
    private weak var presenter: UIViewController?
    private weak var sheet: UINavigationController?

    init(store: HomeStore, presenter: UIViewController) {
        self.store = store
        self.presenter = presenter
    }

    func start(_ route: ComposeRoute) {
        guard let presenter, presenter.presentedViewController == nil else { return }
        let screen = Self.makeScreen(route, flow: flow, store: store)
        screen.onFinish = { [weak self] id in self?.finish(opening: id) }
        let navigation = UINavigationController(rootViewController: screen)
        navigation.navigationBar.tintColor = HomePalette.accent
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.presentationController?.delegate = self
        sheet = navigation
        presenter.present(navigation, animated: true)
    }

    /// The screen for a route and compose flow (also used by the gallery).
    static func makeScreen(_ route: ComposeRoute, flow: HomeComposeFlow, store: HomeStore) -> any ComposeScreen {
        switch (route, flow) {
        case (.newGroup, _):
            NewGroupViewController(store: store)
        case (.newChief, _):
            NewChiefViewController(store: store)
        case (.newMessage, .inlineTo):
            NewMessageViewController(store: store, mode: .message)
        case (.invite, .inlineTo):
            NewMessageViewController(store: store, mode: .invite)
        case (.newMessage, .inviteSheet):
            InviteSheetViewController(store: store, mode: .message)
        case (.invite, .inviteSheet):
            InviteSheetViewController(store: store, mode: .invite)
        case (.newMessage, .contactsFirst):
            ContactsFirstViewController(store: store, mode: .message)
        case (.invite, .contactsFirst):
            ContactsFirstViewController(store: store, mode: .invite)
        }
    }

    private func finish(opening id: ConversationID?) {
        guard let presenter else { return }
        presenter.dismiss(animated: true) { [weak self] in
            MainActor.assumeIsolated {
                if let id { self?.onOpenConversation?(id) }
            }
        }
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !hasUnsavedInput
    }

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        guard let sheet else { return }
        let confirm = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        confirm.addAction(UIAlertAction(title: HomeText.discardDraft, style: .destructive) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(opening: nil) }
        })
        confirm.addAction(UIAlertAction(title: HomeText.keepEditing, style: .cancel))
        confirm.popoverPresentationController?.sourceView = sheet.view
        sheet.present(confirm, animated: true)
    }

    private var hasUnsavedInput: Bool {
        guard let screen = sheet?.topViewController as? any ComposeScreen else { return false }
        return screen.hasUnsavedInput
    }
}
