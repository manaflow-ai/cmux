import CmuxiOSViewersCore
import Observation
import UIKit

/// The workspace's todo list (e4-compose.md 5): the Markdown file in its
/// folder rendered by the Markdown viewer (task items as checkboxes, done
/// of total on top), read only, with Refresh. Without a file it names the
/// files it looks for.
@MainActor
final class TodoSurfaceViewController: UIViewController {
    private let model: TodoSurfaceModel
    private var child: MarkdownViewController?
    private var loading: Task<Void, Never>?
    private lazy var refreshItem = UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        primaryAction: UIAction(title: ViewersText.refresh) { [weak self] _ in self?.reload() })

    init(model: TodoSurfaceModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        title = ViewersText.todo
        navigationItem.largeTitleDisplayMode = .never
        refreshItem.accessibilityLabel = ViewersText.refresh
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "viewers.todo"
        navigationItem.rightBarButtonItems = [refreshItem]
        observe()
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed { loading?.cancel() }
    }

    private func reload() {
        loading?.cancel()
        let model = model
        loading = Task { await model.load() }
    }

    private func observe() {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observe()
            }
        }
        render()
    }

    private func render() {
        refreshItem.isEnabled = model.state != .loading
        if case .loaded(let url, let path, _, _) = model.state {
            navigationItem.prompt = nil
            show(url, path: path)
        } else if model.state != .loading {
            removeChild()
        }
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func show(_ url: URL, path: String) {
        // A refresh downloads a new copy; replace the viewer so it re-reads.
        removeChild()
        let markdown = MarkdownViewController(url: url)
        addChild(markdown)
        markdown.view.frame = view.bounds
        markdown.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(markdown.view)
        markdown.didMove(toParent: self)
        child = markdown
        title = (path as NSString).lastPathComponent
        navigationItem.rightBarButtonItems = [refreshItem] + (markdown.navigationItem.rightBarButtonItems ?? [])
    }

    private func removeChild() {
        guard let child else { return }
        child.willMove(toParent: nil)
        child.view.removeFromSuperview()
        child.removeFromParent()
        self.child = nil
        title = ViewersText.todo
        navigationItem.rightBarButtonItems = [refreshItem]
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        switch model.state {
        case .idle, .loading:
            contentUnavailableConfiguration = child == nil ? UIContentUnavailableConfiguration.loading() : nil
        case .missing:
            var content = UIContentUnavailableConfiguration.empty()
            content.image = UIImage(systemName: "checklist")
            content.text = ViewersText.noTodo
            content.secondaryText = ViewersText.noTodoBody(model.locator.candidates.joined(separator: ", "))
            contentUnavailableConfiguration = content
        case .loaded:
            contentUnavailableConfiguration = nil
        case .failed(let error):
            contentUnavailableConfiguration = ViewerErrorContent.configuration(error) { [weak self] in self?.reload() }
        }
    }
}
