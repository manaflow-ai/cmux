import UIKit

/// The round compose button over Feed and Workspaces (parity: the shipping
/// app's floating compose button). It belongs to one navigation controller
/// and shows only while that controller's root screen is on top.
@MainActor
final class FloatingComposeButton: UIButton, UINavigationControllerDelegate {
    private var action: (() -> Void)?

    static func install(on navigation: UINavigationController, action: @escaping @MainActor () -> Void) {
        let button = FloatingComposeButton(type: .system)
        button.action = action
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "square.and.pencil",
                                      withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3, scale: .medium))
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .label
        configuration.baseForegroundColor = .systemBackground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        button.configuration = configuration
        button.accessibilityLabel = ComposerText.composeButton
        button.accessibilityIdentifier = "composer.floating"
        button.largeContentTitle = ComposerText.composeButton
        button.showsLargeContentViewer = true
        button.addInteraction(UILargeContentViewerInteraction())
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 3)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak button] _ in button?.action?() }, for: .primaryActionTriggered)
        navigation.view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: navigation.view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            button.bottomAnchor.constraint(equalTo: navigation.view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
        // The navigation controller holds its delegate weakly; the button (owned by its view) keeps itself alive.
        if navigation.delegate == nil { navigation.delegate = button }
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController,
                              animated: Bool) {
        let atRoot = viewController === navigationController.viewControllers.first
        let change = { self.alpha = atRoot ? 1 : 0 }
        if animated, let coordinator = navigationController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in change() }, completion: { [weak self, weak navigationController] _ in
                // A cancelled swipe-back leaves the old top: settle on whatever is on top now.
                guard let self, let navigationController else { return }
                let rootOnTop = navigationController.topViewController === navigationController.viewControllers.first
                self.alpha = rootOnTop ? 1 : 0
                self.isHidden = !rootOnTop
            })
            isHidden = false
        } else {
            change()
            isHidden = !atRoot
        }
        navigationController.view.bringSubviewToFront(self)
    }
}
