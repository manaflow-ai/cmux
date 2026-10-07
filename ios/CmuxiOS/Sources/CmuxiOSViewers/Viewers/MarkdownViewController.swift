import CmuxiOSViewersCore
import UIKit

/// Markdown rendered (headings, code blocks, quotes, task lists, tables,
/// links) in a read-only TextKit 2 text view with the find bar; "Show
/// Source" swaps in the text viewer. Parsing runs off the main actor.
@MainActor
final class MarkdownViewController: UIViewController {
    private let url: URL
    private var textView: UITextView!
    private var document: MarkdownDocument?
    private var source: TextFileViewController?
    private var toggle: UIBarButtonItem!

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        toggle = UIBarButtonItem(image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
                                 primaryAction: UIAction(title: ViewersText.source) { [weak self] _ in self?.toggleSource() })
        toggle.accessibilityLabel = ViewersText.source
        let find = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction(title: ViewersText.find) { [weak self] _ in
            self?.textView.findInteraction?.presentFindNavigator(showingReplace: false)
        })
        find.accessibilityLabel = ViewersText.find
        navigationItem.rightBarButtonItems = [toggle, find]
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
        textView.dataDetectorTypes = [.link]
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 32, right: 16)
        textView.linkTextAttributes = [.foregroundColor: UIColor.label, .underlineStyle: NSUnderlineStyle.single.rawValue]
        textView.accessibilityIdentifier = "viewers.markdown"
        view.addSubview(textView)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in self.render() }
        let url = url
        Task { [weak self] in
            let document = await Task.detached(priority: .userInitiated) { () -> MarkdownDocument in
                let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
                return MarkdownDocument(parsing: String(decoding: data.prefix(TextFileViewController.displayLimitBytes), as: UTF8.self))
            }.value
            self?.document = document
            self?.render()
        }
    }

    private func render() {
        guard let document else { return }
        let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer(traits: traitCollection).render(document))
        let progress = document.taskProgress
        if progress.total > 0 {
            rendered.insert(NSAttributedString(string: ViewersText.taskProgress(progress.done, progress.total) + "\n\n", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traitCollection),
                .foregroundColor: UIColor.secondaryLabel,
            ]), at: 0)
        }
        textView.attributedText = rendered
    }

    private func toggleSource() {
        if let source {
            source.willMove(toParent: nil)
            source.view.removeFromSuperview()
            source.removeFromParent()
            self.source = nil
            toggle.accessibilityLabel = ViewersText.source
            toggle.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            return
        }
        let text = TextFileViewController(url: url, language: .markdown)
        addChild(text)
        text.view.frame = view.bounds
        text.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(text.view)
        text.didMove(toParent: self)
        source = text
        toggle.accessibilityLabel = ViewersText.rendered
        toggle.image = UIImage(systemName: "doc.richtext")
    }
}
