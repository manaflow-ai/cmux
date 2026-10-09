import CmuxiOSViewersCore
import UIKit

/// Text and code: a read-only TextKit 2 text view with syntax colors, line
/// numbers and the system find bar. The file is read and highlighted off
/// the main actor; files above 2 MiB show without colors, and only the
/// first 8 MiB are shown.
@MainActor
final class TextFileViewController: UIViewController, UITextViewDelegate {
    nonisolated static let highlightLimit = 2 << 20
    nonisolated static let displayLimit = 8 << 20
    nonisolated static var displayLimitBytes: Int { displayLimit }

    private let url: URL
    private let language: SyntaxLanguage
    private var textView: UITextView!
    private let gutter = LineNumberGutterView()
    private let noticeLabel = UILabel()
    private var text = ""
    private var tokens: [SyntaxToken] = []
    private var notice: String?
    private var loaded = false

    init(url: URL, language: SyntaxLanguage) {
        self.url = url
        self.language = language
        super.init(nibName: nil, bundle: nil)
        navigationItem.rightBarButtonItems = [UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            primaryAction: UIAction(title: ViewersText.find) { [weak self] _ in
                self?.textView.findInteraction?.presentFindNavigator(showingReplace: false)
            })]
        navigationItem.rightBarButtonItems?.first?.accessibilityLabel = ViewersText.find
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView = UITextView(usingTextLayoutManager: true)
        textView.frame = view.bounds
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isFindInteractionEnabled = true
        textView.dataDetectorTypes = []
        textView.backgroundColor = .systemBackground
        textView.alwaysBounceVertical = true
        textView.delegate = self
        textView.accessibilityIdentifier = "viewers.text"
        view.addSubview(textView)
        noticeLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.numberOfLines = 0
        textView.addSubview(noticeLabel)
        gutter.textView = textView
        view.addSubview(gutter)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.render() }
        load()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGutter()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        gutter.setNeedsDisplay()
    }

    private func load() {
        let url = url
        let language = language
        let displayLimit = Self.displayLimit
        let highlightLimit = Self.highlightLimit
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (String, [SyntaxToken], Bool, Bool) in
                let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
                let clipped = data.count > displayLimit
                let text = String(decoding: data.prefix(displayLimit), as: UTF8.self)
                let plain = text.utf16.count > highlightLimit
                let tokens = plain ? [] : SyntaxHighlighter(language: language).highlight(text)
                return (text, tokens, plain, clipped)
            }.value
            guard let self else { return }
            text = result.0
            tokens = result.1
            notice = result.3 ? ViewersText.truncated : (result.2 ? ViewersText.highlightingSkipped : nil)
            loaded = true
            gutter.lineIndex = LineIndex(text)
            render()
        }
    }

    private func render() {
        guard loaded else { return }
        let style = ViewerStyle(traits: traitCollection)
        textView.attributedText = style.highlighted(text, tokens: tokens)
        noticeLabel.text = notice
        noticeLabel.isHidden = notice == nil
        gutter.font = style.gutter
        layoutGutter()
    }

    private func layoutGutter() {
        guard let textView else { return }
        let width = gutter.preferredWidth()
        gutter.frame = CGRect(x: view.safeAreaInsets.left, y: textView.frame.minY, width: width, height: textView.bounds.height)
        var top: CGFloat = 12
        if !noticeLabel.isHidden {
            let fit = noticeLabel.sizeThatFits(CGSize(width: textView.bounds.width - width - 12, height: .greatestFiniteMagnitude))
            noticeLabel.frame = CGRect(x: width, y: 8, width: textView.bounds.width - width - 12, height: fit.height)
            top += fit.height + 8
        }
        textView.textContainerInset = UIEdgeInsets(top: top, left: width, bottom: 24, right: 12)
        gutter.setNeedsDisplay()
    }
}
