import SwiftUI
import UIKit

private func log(_ message: String) {
    NSLog("[CMUX_CHAT_FIX1] MAIN %@", message)
}

/// Main chat container that mirrors Fix 1: .never behavior verbatim.
struct ChatKeyboardContainer: UIViewControllerRepresentable {
    let messages: [Message]

    func makeUIViewController(context: Context) -> ChatFix1ViewController {
        ChatFix1ViewController(messages: messages)
    }

    func updateUIViewController(_ uiViewController: ChatFix1ViewController, context: Context) {}
}

final class ChatFix1ViewController: UIViewController, UIScrollViewDelegate {
    private var scrollView: UIScrollView!
    private var contentStack: UIStackView!
    private var inputBarVC: DebugInputBarViewController!

    private var messages: [Message]
    private var inputBarBottomConstraint: NSLayoutConstraint!
    private var contentStackBottomConstraint: NSLayoutConstraint!
    private var lastAppliedBottomInset: CGFloat = -1

    init(messages: [Message]) {
        self.messages = messages
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        setupScrollView()
        setupInputBar()
        setupConstraints()
        populateMessages()

        log("✅ MAIN VERBATIM FIX1 ACTIVE")
        log("  inputBarVC: \(String(describing: inputBarVC))")
        log("  parent: \(String(describing: parent))")
        log("  navigationController: \(String(describing: navigationController))")

        applyFix1()

        log("🚀 viewDidLoad complete")

        DispatchQueue.main.async {
            log("viewDidLoad - second async scrollToBottom")
            self.scrollToBottom(animated: false)
        }
    }

    private func applyFix1() {
        log("🔧 applyFix1 called")

        scrollView.contentInsetAdjustmentBehavior = .never
        contentStackBottomConstraint.constant = -8

        log("applyFix1 - before updateScrollViewInsets")
        log("  view.window: \(String(describing: view.window))")
        log("  view.safeAreaInsets: \(view.safeAreaInsets)")
        log("  inputBarVC.view.bounds: \(inputBarVC.view.bounds)")

        updateBottomInsetsForKeyboard()
        view.layoutIfNeeded()

        log("applyFix1 - after layoutIfNeeded")
        log("  scrollView.contentInset: \(scrollView.contentInset)")
        log("  scrollView.contentSize: \(scrollView.contentSize)")
        log("  scrollView.bounds: \(scrollView.bounds)")

        DispatchQueue.main.async {
            log("applyFix1 - first async scrollToBottom")
            log("  scrollView.contentInset: \(self.scrollView.contentInset)")
            log("  scrollView.contentSize: \(self.scrollView.contentSize)")
            self.scrollToBottom(animated: false)
        }
    }

    private func setupScrollView() {
        scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsVerticalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)

        view.addSubview(scrollView)

        contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
    }

    private func setupInputBar() {
        inputBarVC = DebugInputBarViewController()
        inputBarVC.view.translatesAutoresizingMaskIntoConstraints = false
        inputBarVC.onSend = { [weak self] in
            self?.sendMessage()
        }

        addChild(inputBarVC)
        view.addSubview(inputBarVC.view)
        inputBarVC.didMove(toParent: self)
    }

    private func setupConstraints() {
        inputBarBottomConstraint = inputBarVC.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: 0)
        contentStackBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -8)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStackBottomConstraint,
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),

            inputBarVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBarVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottomConstraint
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomInsetsForKeyboard()
    }

    private func updateBottomInsetsForKeyboard() {
        let inputBarHeight = inputBarVC.view.bounds.height
        let keyboardFrame = view.keyboardLayoutGuide.layoutFrame
        let keyboardOverlap = max(0, view.bounds.maxY - keyboardFrame.minY)
        let safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        let extraSafeGap = max(0, safeBottom - keyboardOverlap)
        let newInputBarConstant = -extraSafeGap
        if inputBarBottomConstraint.constant != newInputBarConstant {
            inputBarBottomConstraint.constant = newInputBarConstant
        }
        let contentBottomPadding = max(0, -contentStackBottomConstraint.constant)
        let newBottomInset = max(0, inputBarHeight + max(keyboardOverlap, safeBottom) - contentBottomPadding)

        if newBottomInset == lastAppliedBottomInset {
            return
        }

        let oldBottomInset = scrollView.contentInset.bottom
        let oldMaxOffsetY = scrollView.contentSize.height - scrollView.bounds.height + oldBottomInset
        let distanceFromBottom = max(0, oldMaxOffsetY - scrollView.contentOffset.y)
        lastAppliedBottomInset = newBottomInset

        log("updateScrollViewInsets:")
        log("  inputBarHeight: \(inputBarHeight)")
        log("  safeBottom: \(safeBottom)")
        log("  newBottomInset: \(newBottomInset)")

        scrollView.contentInset.bottom = newBottomInset
        scrollView.verticalScrollIndicatorInsets.bottom = newBottomInset

        let newMaxOffsetY = scrollView.contentSize.height - scrollView.bounds.height + newBottomInset
        var targetOffsetY = newMaxOffsetY - distanceFromBottom
        let minY: CGFloat = 0
        let maxY = max(0, newMaxOffsetY)
        targetOffsetY = min(max(targetOffsetY, minY), maxY)
        scrollView.contentOffset.y = targetOffsetY
    }

    private func populateMessages() {
        for (index, message) in messages.enumerated() {
            let bubble = MessageBubble(
                message: message,
                showTail: index == messages.count - 1,
                showTimestamp: index == 0
            )
            let host = UIHostingController(rootView: bubble)
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false

            addChild(host)
            contentStack.addArrangedSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    private func scrollToBottom(animated: Bool) {
        let visibleHeight = scrollView.bounds.height - scrollView.contentInset.bottom
        let bottomOffset = CGPoint(
            x: 0,
            y: max(0, scrollView.contentSize.height - visibleHeight)
        )
        log("scrollToBottom:")
        log("  scrollView.bounds: \(scrollView.bounds)")
        log("  scrollView.contentInset.bottom: \(scrollView.contentInset.bottom)")
        log("  visibleHeight: \(visibleHeight)")
        log("  scrollView.contentSize: \(scrollView.contentSize)")
        log("  bottomOffset: \(bottomOffset)")
        scrollView.setContentOffset(bottomOffset, animated: animated)
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func sendMessage() {
        guard !inputBarVC.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let message = Message(content: inputBarVC.text, timestamp: .now, isFromMe: true, status: .sent)
        messages.append(message)
        inputBarVC.clearText()

        let bubble = MessageBubble(message: message, showTail: true, showTimestamp: false)
        let host = UIHostingController(rootView: bubble)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        contentStack.addArrangedSubview(host.view)
        host.didMove(toParent: self)

        DispatchQueue.main.async {
            self.scrollToBottom(animated: true)
        }
    }
}
