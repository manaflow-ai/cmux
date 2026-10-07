import UIKit

/// A small sheet for free text: question replies, "Other" answers and
/// change requests. Send is enabled once the text is not blank.
@MainActor
final class FeedComposerViewController: UIViewController, UITextViewDelegate {
    private let prompt: String?
    private let placeholder: String
    private let initialText: String
    private let onSend: (String) -> Void
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let promptLabel = UILabel()
    private lazy var sendItem = UIBarButtonItem(title: FeedText.send, style: .done, target: self, action: #selector(send))

    init(title: String, prompt: String?, placeholder: String, initialText: String = "", onSend: @escaping (String) -> Void) {
        self.prompt = prompt
        self.placeholder = placeholder
        self.initialText = initialText
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: FeedText.composerCancel, style: .plain, target: self, action: #selector(cancel))
        sendItem.accessibilityIdentifier = "feed.composer.send"
        navigationItem.rightBarButtonItem = sendItem
        promptLabel.text = prompt
        promptLabel.isHidden = prompt?.isEmpty ?? true
        promptLabel.numberOfLines = 0
        promptLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        promptLabel.adjustsFontForContentSizeCategory = true
        promptLabel.textColor = .secondaryLabel
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.text = initialText
        textView.delegate = self
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        textView.accessibilityLabel = placeholder
        textView.accessibilityIdentifier = "feed.composer.text"
        placeholderLabel.text = placeholder
        placeholderLabel.font = textView.font
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        let stack = UIStackView(arrangedSubviews: [promptLabel, textView])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
        ])
        textViewDidChange(textView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        let blank = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendItem.isEnabled = !blank
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    @objc private func send() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dismiss(animated: true)
        onSend(text)
    }

    @objc private func cancel() { dismiss(animated: true) }
}
