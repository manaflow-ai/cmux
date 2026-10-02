// STUB owned by the home-ui helper branch (feat-cmux-next-ios-home-ui), which
// replaces this file. It exists so the app shell builds before that lands.
public import CmuxHomeCore
public import CmuxiOSDesign
public import UIKit

public enum HomeComposeFlow: String, CaseIterable, Sendable {
    case inlineTo, inviteSheet, contactsFirst
}

public struct HomeUIOptions: Sendable, Equatable {
    public var density: HomeListDensity
    public var composeFlow: HomeComposeFlow

    public init(density: HomeListDensity = .comfortable, composeFlow: HomeComposeFlow = .inlineTo) {
        self.density = density
        self.composeFlow = composeFlow
    }
}

@MainActor
public final class HomeViewController: UIViewController {
    private let store: HomeStore
    private var options: HomeUIOptions

    public init(store: HomeStore, options: HomeUIOptions) {
        self.store = store
        self.options = options
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "home.title", defaultValue: "Home", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func apply(_ options: HomeUIOptions) { self.options = options }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        navigationItem.largeTitleDisplayMode = .always
    }
}
