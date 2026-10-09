import CmuxiOSViewersCore
import CmuxMobileWire
import UIKit

/// One file's diff: a virtualized list of rows (only visible rows are
/// highlighted and laid out), unified or side by side (side by side by
/// default on regular width), previous/next change from the toolbar or
/// `[` / `]` on a hardware keyboard, and Open File for the full text.
@MainActor
final class DiffViewController: UIViewController, UICollectionViewDataSource {
    private let model: ChangesModel
    private let file: GitChangedFile
    private let openFile: ((GitChangedFile) -> Void)?
    private var collectionView: UICollectionView!
    private var renderer: DiffRowRenderer
    private var document: DiffDocument?
    private var rows = DiffRows(DiffDocument(), layout: .unified)
    private var layout: DiffLayout = .unified
    private var error: ViewerSourceError?
    private var loading: Task<Void, Never>?
    private let positionLabel = UILabel()
    private var previousItem: UIBarButtonItem!
    private var nextItem: UIBarButtonItem!
    private var gutterWidth: CGFloat = 32

    init(model: ChangesModel, file: GitChangedFile, openFile: ((GitChangedFile) -> Void)?) {
        self.model = model
        self.file = file
        self.openFile = openFile
        renderer = DiffRowRenderer(language: SyntaxLanguage.detect(fileName: file.path), traits: UITraitCollection.current)
        super.init(nibName: nil, bundle: nil)
        title = (file.path as NSString).lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "viewers.diff"
        layout = traitCollection.horizontalSizeClass == .regular ? .split : .unified
        renderer.traitsChanged(traitCollection)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: Self.makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColor = .systemBackground
        collectionView.register(DiffLineCell.self, forCellWithReuseIdentifier: DiffLineCell.reuse)
        collectionView.register(DiffHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                                withReuseIdentifier: DiffHeaderView.reuse)
        collectionView.register(DiffHeaderView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
                                withReuseIdentifier: DiffHeaderView.reuse)
        view.addSubview(collectionView)
        configureBars()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.renderer.traitsChanged(self.traitCollection)
            self.measureGutter()
            self.collectionView.reloadData()
        }
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        if isMovingFromParent { loading?.cancel() }
    }

    private static func makeLayout() -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(22))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        let boundary = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(56))
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(layoutSize: boundary, elementKind: UICollectionView.elementKindSectionHeader,
                                                        alignment: .top),
            NSCollectionLayoutBoundarySupplementaryItem(layoutSize: boundary, elementKind: UICollectionView.elementKindSectionFooter,
                                                        alignment: .bottom),
        ]
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func configureBars() {
        let layoutMenu = UIMenu(options: .singleSelection, children: DiffLayout.allCases.map { option in
            UIAction(title: option == .unified ? ViewersText.unified : ViewersText.split,
                     image: UIImage(systemName: option == .unified ? "rectangle" : "rectangle.split.2x1"),
                     state: option == layout ? .on : .off) { [weak self] _ in self?.setLayout(option) }
        })
        var items = [UIBarButtonItem(image: UIImage(systemName: "rectangle.split.2x1"), menu: layoutMenu)]
        items[0].accessibilityLabel = ViewersText.split
        if openFile != nil, file.status != .deleted {
            let open = UIBarButtonItem(image: UIImage(systemName: "doc.text"), primaryAction: UIAction(title: ViewersText.openFile) { [weak self] _ in
                guard let self else { return }
                self.openFile?(self.file)
            })
            open.accessibilityLabel = ViewersText.openFile
            items.append(open)
        }
        navigationItem.rightBarButtonItems = items
        previousItem = UIBarButtonItem(image: UIImage(systemName: "chevron.up"), primaryAction: UIAction(title: ViewersText.previousHunk) { [weak self] _ in
            self?.jump(forward: false)
        })
        previousItem.accessibilityLabel = ViewersText.previousHunk
        nextItem = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction(title: ViewersText.nextHunk) { [weak self] _ in
            self?.jump(forward: true)
        })
        nextItem.accessibilityLabel = ViewersText.nextHunk
        positionLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        positionLabel.adjustsFontForContentSizeCategory = true
        positionLabel.textColor = .secondaryLabel
        toolbarItems = [previousItem, .flexibleSpace(), UIBarButtonItem(customView: positionLabel), .flexibleSpace(), nextItem]
        updatePosition()
    }

    private func setLayout(_ layout: DiffLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        if let document { rows = DiffRows(document, layout: layout) }
        collectionView.reloadData()
        configureBars()
    }

    private func load() {
        error = nil
        setNeedsUpdateContentUnavailableConfiguration()
        loading = Task { [weak self, model, file] in
            do {
                let document = try await model.document(for: file)
                guard let self else { return }
                self.document = document
                self.rows = DiffRows(document, layout: self.layout)
                self.measureGutter()
                self.collectionView.reloadData()
                self.updatePosition()
            } catch is CancellationError {
                return
            } catch {
                self?.error = error as? ViewerSourceError ?? .failed(error.localizedDescription)
            }
            self?.setNeedsUpdateContentUnavailableConfiguration()
        }
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        if let error {
            contentUnavailableConfiguration = ViewerErrorContent.configuration(error) { [weak self] in self?.load() }
        } else if let document {
            if document.isBinary {
                var content = UIContentUnavailableConfiguration.empty()
                content.image = UIImage(systemName: "doc.zipper")
                content.text = ViewersText.binaryFile
                content.secondaryText = ViewersText.binaryBody
                contentUnavailableConfiguration = content
            } else if document.isEmpty {
                var content = UIContentUnavailableConfiguration.empty()
                content.image = UIImage(systemName: "doc.text")
                content.secondaryText = ViewersText.noTextChanges
                contentUnavailableConfiguration = content
            } else {
                contentUnavailableConfiguration = nil
            }
        } else {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
    }

    /// Wide enough for the largest line number of the document.
    private func measureGutter() {
        let largest = document?.hunks.last.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) } ?? 0
        let digits = CGFloat(max(3, String(largest).count))
        gutterWidth = ceil(("8" as NSString).size(withAttributes: [.font: renderer.gutterFont]).width * digits) + 8
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: Hunks

    private var topRow: Int {
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        return visible.first { path in
            (collectionView.layoutAttributesForItem(at: path)?.frame.maxY ?? 0) > top + 1
        }?.item ?? 0
    }

    private func jump(forward: Bool) {
        let current = topRow
        let target = forward ? rows.nextHunk(after: current) : rows.previousHunk(before: current)
        guard let target else { return }
        collectionView.scrollToItem(at: IndexPath(item: target, section: 0), at: .top,
                                    animated: !UIAccessibility.isReduceMotionEnabled)
        updatePosition(at: target)
        if let index = rows.hunkRows.firstIndex(of: target) {
            UIAccessibility.post(notification: .announcement, argument: ViewersText.hunkLabel(index + 1, rows.hunkRows.count))
        }
    }

    private func updatePosition(at row: Int? = nil) {
        let count = rows.hunkRows.count
        let current = rows.hunkRows.lastIndex { $0 <= (row ?? topRow) } ?? 0
        positionLabel.text = count > 0 ? ViewersText.hunkLabel(current + 1, count) : nil
        positionLabel.sizeToFit()
        previousItem?.isEnabled = count > 1
        nextItem?.isEnabled = count > 1
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: ViewersText.previousHunk, action: #selector(previousHunkCommand), input: "["),
            UIKeyCommand(title: ViewersText.nextHunk, action: #selector(nextHunkCommand), input: "]"),
        ]
    }

    @objc private func previousHunkCommand() { jump(forward: false) }
    @objc private func nextHunkCommand() { jump(forward: true) }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        rows.rows.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: DiffLineCell.reuse, for: indexPath) as! DiffLineCell
        cell.configure(rows.rows[indexPath.item], renderer: renderer, gutterWidth: gutterWidth)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: DiffHeaderView.reuse, for: indexPath)
            as! DiffHeaderView
        if kind == UICollectionView.elementKindSectionHeader {
            view.configure(file: file)
        } else {
            view.configure(notice: document?.isTruncated == true ? ViewersText.truncated : "")
        }
        return view
    }
}

extension DiffViewController: UICollectionViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updatePosition() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updatePosition() }
    }
}
