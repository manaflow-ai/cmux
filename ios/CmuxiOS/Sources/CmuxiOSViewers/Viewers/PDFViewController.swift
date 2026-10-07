import PDFKit
import UIKit

/// A PDF in PDFKit: continuous pages fitted to the width, the find bar.
@MainActor
final class PDFViewController: UIViewController {
    private let url: URL
    private let pdfView = PDFView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        let find = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction(title: ViewersText.find) { [weak self] _ in
            self?.pdfView.findInteraction.presentFindNavigator(showingReplace: false)
        })
        find.accessibilityLabel = ViewersText.find
        navigationItem.rightBarButtonItems = [find]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.isFindInteractionEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.accessibilityIdentifier = "viewers.pdf"
        view.addSubview(pdfView)
        let url = url
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
            guard let self else { return }
            if let data, let document = PDFDocument(data: data) {
                pdfView.document = document
            } else {
                var content = UIContentUnavailableConfiguration.empty()
                content.image = UIImage(systemName: "doc")
                content.text = ViewersText.errorTitle(.failed(""))
                contentUnavailableConfiguration = content
            }
        }
    }
}
