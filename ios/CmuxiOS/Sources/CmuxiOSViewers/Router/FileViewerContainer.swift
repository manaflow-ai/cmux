import CmuxiOSViewersCore
import QuickLook
import UIKit

/// Shows one file: downloads it first when it is still on the Mac, then
/// embeds the viewer its kind needs (text, Markdown, image, PDF, or
/// QuickLook for the rest). The title and Share stay on this controller.
@MainActor
final class FileViewerContainer: UIViewController, QLPreviewControllerDataSource {
    enum Content {
        case local(URL)
        case remote(@Sendable () async throws -> URL)
    }

    private let name: String
    private let mime: String?
    private let content: Content
    private var loaded: URL?
    private var error: ViewerSourceError?
    private var loading: Task<Void, Never>?
    private var child: UIViewController?

    init(name: String, mime: String? = nil, content: Content) {
        self.name = name
        self.mime = mime
        self.content = content
        super.init(nibName: nil, bundle: nil)
        title = name
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "viewers.file"
        load()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed { loading?.cancel() }
    }

    private func load() {
        error = nil
        setNeedsUpdateContentUnavailableConfiguration()
        switch content {
        case .local(let url):
            show(url)
        case .remote(let fetch):
            loading = Task { [weak self] in
                do {
                    let url = try await fetch()
                    self?.show(url)
                } catch is CancellationError {
                    return
                } catch {
                    self?.error = error as? ViewerSourceError ?? .failed(error.localizedDescription)
                    self?.setNeedsUpdateContentUnavailableConfiguration()
                }
            }
        }
    }

    private func show(_ url: URL) {
        loaded = url
        let handle = try? FileHandle(forReadingFrom: url)
        let prefix = try? handle?.read(upToCount: 8000)
        try? handle?.close()
        let kind = ViewerFileKind.classify(name: name, mime: mime, prefix: prefix ?? Data())
        let viewer: UIViewController
        switch kind {
        case .text(let language): viewer = TextFileViewController(url: url, language: language)
        case .markdown: viewer = MarkdownViewController(url: url)
        case .image: viewer = ImageViewController(url: url)
        case .pdf: viewer = PDFViewController(url: url)
        case .other:
            let preview = QLPreviewController()
            preview.dataSource = self
            viewer = preview
        }
        embed(viewer)
        let shareItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"),
                                        primaryAction: UIAction(title: ViewersText.share) { [weak self] _ in self?.share() })
        shareItem.accessibilityLabel = ViewersText.share
        let items = [shareItem] + (viewer.navigationItem.rightBarButtonItems ?? [])
        navigationItem.rightBarButtonItems = items
        setNeedsUpdateContentUnavailableConfiguration()
    }

    private func embed(_ viewer: UIViewController) {
        child?.willMove(toParent: nil)
        child?.view.removeFromSuperview()
        child?.removeFromParent()
        addChild(viewer)
        viewer.view.frame = view.bounds
        viewer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(viewer.view)
        viewer.didMove(toParent: self)
        child = viewer
    }

    private func share() {
        guard let loaded else { return }
        let sheet = UIActivityViewController(activityItems: [loaded], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    override func updateContentUnavailableConfiguration(using state: UIContentUnavailableConfigurationState) {
        if let error {
            contentUnavailableConfiguration = ViewerErrorContent.configuration(error) { [weak self] in self?.load() }
        } else if loaded == nil {
            var loading = UIContentUnavailableConfiguration.loading()
            loading.text = ViewersText.downloading
            contentUnavailableConfiguration = loading
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { (loaded ?? URL(fileURLWithPath: "/dev/null")) as NSURL }
    }
}
