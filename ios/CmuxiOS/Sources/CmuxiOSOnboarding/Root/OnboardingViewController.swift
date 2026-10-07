public import SwiftUI
import UIKit

/// The onboarding screen as a view controller for the app's root flow and
/// the Settings replay.
public final class OnboardingViewController: UIHostingController<OnboardingRootView> {
    public let model: OnboardingModel

    public init(model: OnboardingModel) {
        self.model = model
        super.init(rootView: OnboardingRootView(model: model))
        view.backgroundColor = .systemBackground
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }
}
