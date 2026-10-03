public import CmuxHomeCore
import CmuxiOSDesign
public import UIKit

/// Home: the conversation list with the Chief pinned at the top, pull-down
/// search over Home messages, compose (New Message, New Group, New Chief)
/// at the top leading edge and Invite at the top trailing edge. Lives inside
/// a `UINavigationController`; conversations push onto it.
@MainActor
public final class HomeViewController: UIViewController {
    private let store: HomeStore
    private(set) var options: HomeUIOptions
    private let performer: HomeRowActionPerformer
    private let list: HomeListController
    private let searchResults: HomeSearchResultsController
    private lazy var searchController = UISearchController(searchResultsController: searchResults)
    private lazy var compose = ComposeCoordinator(store: store, presenter: self)
    private lazy var observation = StoreObservation { [weak self] in self?.render() }
    private let composeItem = UIBarButtonItem()
    private let inviteItem = UIBarButtonItem()

    public init(store: HomeStore, options: HomeUIOptions) {
        self.store = store
        self.options = options
        performer = HomeRowActionPerformer(store: store)
        list = HomeListController(performer: performer)
        searchResults = HomeSearchResultsController(store: store)
        super.init(nibName: nil, bundle: nil)
        title = HomeText.homeTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Applies new presentation options while Home is on screen.
    public func apply(_ options: HomeUIOptions) {
        guard options != self.options else { return }
        self.options = options
        compose.flow = options.composeFlow
        observation.renderNow()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.background
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.backButtonDisplayMode = .minimal

        list.collectionView.frame = view.bounds
        list.collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(list.collectionView)
        list.onSelect = { [weak self] id in self?.openConversation(id, focus: nil) }
        performer.onFailure = { [weak self] rejection in self?.showFailure(rejection) }

        configureBarItems()
        configureSearch()
        compose.flow = options.composeFlow
        compose.onOpenConversation = { [weak self] id in self?.openConversation(id, focus: nil) }

        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged),
                                               name: UIApplication.significantTimeChangeNotification, object: nil)
        observation.start()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        list.refreshVisibleContent()
    }

    // MARK: Rendering

    /// Reads every store property Home depends on; `StoreObservation`
    /// re-runs it after any of them change, once per main-actor turn.
    private func render() {
        let isOnline = store.isOnline
        list.update(rows: store.rows, me: store.me?.id, isOnline: isOnline, density: options.density)
        composeItem.isEnabled = isOnline
        inviteItem.isEnabled = isOnline
        searchResults.isOnline = isOnline
    }

    @objc private func clockChanged() {
        list.refreshVisibleContent()
    }

    // MARK: Chrome

    private func configureBarItems() {
        composeItem.image = UIImage(systemName: "square.and.pencil")
        composeItem.accessibilityLabel = HomeText.composeButton
        composeItem.menu = UIMenu(children: [
            UIAction(title: HomeText.newMessage, image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.compose.start(.newMessage)
            },
            UIAction(title: HomeText.newGroup, image: UIImage(systemName: "person.2")) { [weak self] _ in
                self?.compose.start(.newGroup)
            },
            UIAction(title: HomeText.newChief, image: UIImage(systemName: "sparkles")) { [weak self] _ in
                self?.compose.start(.newChief)
            },
        ])
        navigationItem.leftBarButtonItem = composeItem

        inviteItem.title = HomeText.inviteButton
        inviteItem.style = .plain
        inviteItem.primaryAction = UIAction(title: HomeText.inviteButton) { [weak self] _ in
            self?.compose.start(.invite)
        }
        inviteItem.accessibilityHint = HomeText.inviteHint
        navigationItem.rightBarButtonItem = inviteItem
        navigationController?.navigationBar.tintColor = HomePalette.accent
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = searchResults
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = HomeText.searchPlaceholder
        searchController.searchBar.tintColor = HomePalette.accent
        searchResults.onOpen = { [weak self] conversation, key in
            self?.openConversation(conversation, focus: key)
        }
        navigationItem.searchController = searchController
        // Pull down to reveal; the list owns the screen until then.
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true
    }

    // MARK: Navigation

    /// Pushes a conversation. `focus` scrolls to that message when it is loaded.
    func openConversation(_ id: ConversationID, focus: IdempotencyKey?) {
        guard let navigationController else { return }
        if searchController.isActive { searchController.isActive = false }
        let screen = ConversationViewController(store: store, conversation: id, focus: focus)
        if navigationController.topViewController !== self {
            navigationController.popToViewController(self, animated: false)
        }
        navigationController.pushViewController(screen, animated: !HomeMotion.reduceMotion)
    }

    #if DEBUG
    /// DEBUG ONLY (simulator screenshots): opens the first conversation whose
    /// kind's name is `kind` (`chief`, `group`, `direct`) once the inbox has it.
    public func debugOpenFirstConversation(kind: String) {
        let store = self.store
        Task { @MainActor [weak self] in
            await HomeGallery.waitUntil(store) { store in store.rows.contains { "\($0.kind)" == kind } }
            guard let id = store.rows.first(where: { "\($0.kind)" == kind })?.id else { return }
            self?.openConversation(id, focus: nil)
        }
    }
    #endif

    private func showFailure(_ rejection: HomeRejection) {
        let alert = UIAlertController(title: HomeText.actionFailedTitle, message: HomeText.explanation(for: rejection),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: HomeText.ok, style: .default))
        present(alert, animated: true)
    }
}
