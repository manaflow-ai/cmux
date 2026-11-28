import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// New Group: pick two or more people and Chiefs already in Home, name the
/// group (optional), and Create. The group opens when the owner answers.
@MainActor
final class NewGroupViewController: UIViewController, ComposeScreen, UICollectionViewDelegate {
    enum Section: Hashable, Sendable {
        case name
        case chiefs
        case people
    }

    enum Item: Hashable, Sendable {
        case name
        case person(ParticipantID)
    }

    var onFinish: (@MainActor (ConversationID?) -> Void)?
    /// These screens never raise the keyboard on their own.
    var focusesOnAppear = false

    private let store: HomeStore
    private var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?
    private var people: [ParticipantID: Participant] = [:]
    private var selected: [ParticipantID] = []
    private let nameField = UITextField()
    private lazy var createItem = UIBarButtonItem(title: HomeText.create, style: .done, target: self, action: #selector(create))
    private lazy var observation = StoreObservation { [weak self] in self?.updateCreateState() }
    private var isCreating = false

    init(store: HomeStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = HomeText.newGroup
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var hasUnsavedInput: Bool { !selected.isEmpty || !(nameField.text ?? "").isEmpty }

    /// Everyone in Home other than me who can join a group, Chiefs first.
    static func candidates(rows: [InboxRow], me: ParticipantID?) -> (chiefs: [Participant], people: [Participant]) {
        var seen: [ParticipantID: Participant] = [:]
        for row in rows {
            for person in row.summary.participants where person.id != me && person.membership == .active {
                if person.kind == .agent && !person.isChief { continue }
                seen[person.id] = person
            }
        }
        let sorted = seen.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return (sorted.filter(\.isChief), sorted.filter { !$0.isChief })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = HomePalette.groupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.onFinish?(nil)
        })
        navigationItem.rightBarButtonItem = createItem

        nameField.placeholder = HomeText.groupNamePlaceholder
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.clearButtonMode = .whileEditing
        nameField.autocapitalizationType = .words
        nameField.tintColor = HomePalette.accent
        nameField.accessibilityLabel = HomeText.groupNamePlaceholder

        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: configuration)
        let collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.allowsMultipleSelection = true
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delegate = self
        view.addSubview(collectionView)
        self.collectionView = collectionView
        dataSource = makeDataSource(collectionView)

        let candidates = Self.candidates(rows: store.rows, me: store.me?.id)
        for person in candidates.chiefs + candidates.people { people[person.id] = person }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.name])
        snapshot.appendItems([.name], toSection: .name)
        if !candidates.chiefs.isEmpty {
            snapshot.appendSections([.chiefs])
            snapshot.appendItems(candidates.chiefs.map { .person($0.id) }, toSection: .chiefs)
        }
        if !candidates.people.isEmpty {
            snapshot.appendSections([.people])
            snapshot.appendItems(candidates.people.map { .person($0.id) }, toSection: .people)
        }
        dataSource?.apply(snapshot, animatingDifferences: false)
        observation.start()
    }

    private func makeDataSource(_ collectionView: UICollectionView) -> UICollectionViewDiffableDataSource<Section, Item> {
        let nameRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = nil
            self.nameField.translatesAutoresizingMaskIntoConstraints = false
            if self.nameField.superview !== cell.contentView {
                cell.contentView.addSubview(self.nameField)
                let margins = cell.contentView.layoutMarginsGuide
                NSLayoutConstraint.activate([
                    self.nameField.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                    self.nameField.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                    self.nameField.topAnchor.constraint(equalTo: margins.topAnchor),
                    self.nameField.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
                    self.nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
                ])
            }
        }
        let personRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, ParticipantID> {
            [weak self] cell, _, id in
            guard let self, let person = self.people[id] else { return }
            var content = UIListContentConfiguration.cell()
            content.text = person.displayName
            content.secondaryText = person.isChief ? HomeText.chiefLabel : nil
            content.secondaryTextProperties.color = HomePalette.secondaryText
            content.image = UIImage(systemName: person.isChief ? "sparkles" : "person.crop.circle")
            content.imageProperties.tintColor = HomePalette.secondaryText
            cell.contentConfiguration = content
            cell.tintColor = HomePalette.accent
            cell.configurationUpdateHandler = { cell, state in
                guard let cell = cell as? UICollectionViewListCell else { return }
                cell.accessories = state.isSelected ? [.checkmark()] : []
            }
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            switch self?.dataSource?.sectionIdentifier(for: indexPath.section) {
            case .chiefs: content.text = HomeText.groupSectionChiefs
            case .people: content.text = HomeText.groupSectionPeople
            default: content.text = nil
            }
            header.contentConfiguration = content
        }
        let dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .name:
                collectionView.dequeueConfiguredReusableCell(using: nameRegistration, for: indexPath, item: item)
            case .person(let id):
                collectionView.dequeueConfiguredReusableCell(using: personRegistration, for: indexPath, item: id)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
        return dataSource
    }

    // MARK: Selection

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .person = dataSource?.itemIdentifier(for: indexPath) { return true }
        return false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .person(let id) = dataSource?.itemIdentifier(for: indexPath) else { return }
        if !selected.contains(id) { selected.append(id) }
        updateCreateState()
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard case .person(let id) = dataSource?.itemIdentifier(for: indexPath) else { return }
        selected.removeAll { $0 == id }
        updateCreateState()
    }

    private func updateCreateState() {
        createItem.isEnabled = selected.count >= 2 && store.isOnline && !isCreating
    }

    @objc private func create() {
        guard selected.count >= 2, store.isOnline, !isCreating else { return }
        isCreating = true
        updateCreateState()
        let title = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let participants = selected
        let store = self.store
        Task { [weak self] in
            do {
                let result = try await store.perform(.createGroup(title: title, participants: participants))
                self?.onFinish?(result.conversation)
            } catch let rejection as HomeRejection {
                guard let self else { return }
                self.isCreating = false
                self.updateCreateState()
                let alert = UIAlertController(title: HomeText.createFailedTitle,
                                              message: HomeText.explanation(for: rejection), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: HomeText.ok, style: .default))
                self.present(alert, animated: true)
            } catch {}
        }
    }
}
