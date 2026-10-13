#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import SwiftUI
import UIKit

/// A navigation value that opens the Chief conversation.
public struct ChiefRoute: Hashable, Sendable {
    public init() {}
}

/// The Chief conversation: CmuxConversation's Messages-style
/// `ConversationViewController` over the shared `ChiefSession` store, pushed
/// on Home's navigation stack. It draws its own glass header (back, avatar,
/// name) and owns the bottom edge, so the SwiftUI navigation bar and the tab
/// bar are hidden while it is up; the header's back button and the system
/// left-edge swipe both pop it.
public struct ChiefConversationScreen: View {
    let session: ChiefSession
    let compose: ChiefComposer?
    @Environment(\.dismiss) private var dismiss

    public init(session: ChiefSession = .shared, compose: ChiefComposer? = nil) {
        self.session = session
        self.compose = compose
    }

    public var body: some View {
        ChiefConversationController(session: session, compose: compose, back: { dismiss() })
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationBarBackButtonHidden()
    }
}

/// Chief's service line in the transcript's start header, replacing
/// Messages' "iMessage / Encrypted".
extension ConversationPresentationOptions {
    public static var chief: ConversationPresentationOptions {
        ConversationPresentationOptions(
            placeholder: String(localized: "Message Chief"),
            serviceTitle: "Chief",
            serviceSubtitle: String(localized: "Runs your agents on your Macs"),
            trailingSymbol: "clock.arrow.circlepath"
        )
    }
}

struct ChiefConversationController: UIViewControllerRepresentable {
    let session: ChiefSession
    let compose: ChiefComposer?
    let back: () -> Void

    func makeUIViewController(context: Context) -> ChiefConversationContainer {
        let conversation = ConversationViewController(store: session.store, options: .chief)
        let container = ChiefConversationContainer(conversation: conversation)
        configure(conversation)
        #if DEBUG
        ChiefDemoHook.shared.controller = conversation
        #endif
        return container
    }

    func updateUIViewController(_ container: ChiefConversationContainer, context: Context) {
        configure(container.conversation)
    }

    private func configure(_ conversation: ConversationViewController) {
        conversation.onBack = back
        // Select mode's Forward opens New Message with the draft, as in the lab.
        conversation.onForward = { [compose] draft in
            compose?.present(forwarding: draft)
        }
    }
}

/// Holds the conversation as a child so the pushed screen keeps the
/// navigation controller's left-edge swipe back. SwiftUI turns the system
/// recognizer off while the bar is hidden; this turns it back on while
/// Chief is up, and makes the transcript's reply swipe wait for it so a drag
/// from the edge pops instead of quoting the bubble under it.
public final class ChiefConversationContainer: UIViewController, UIGestureRecognizerDelegate {
    let conversation: ConversationViewController
    private weak var popRecognizer: UIGestureRecognizer?
    private weak var previousPopDelegate: (any UIGestureRecognizerDelegate)?

    init(conversation: ConversationViewController) {
        self.conversation = conversation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        addChild(conversation)
        conversation.view.frame = view.bounds
        conversation.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(conversation.view)
        conversation.didMove(toParent: self)
    }

    /// The back button's count of other unread conversations, the way the
    /// package's lab host feeds it (`ConversationUnreadBadge`). Setting it
    /// also configures the header from the store; the shared Chief store is
    /// usually connected before this screen exists, so no later store change
    /// would configure it once the header is in a window.
    var backUnreadCount = 0 {
        didSet { if isViewLoaded, view.window != nil { conversation.setBackUnreadCount(backUnreadCount) } }
    }

    public override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        conversation.setBackUnreadCount(backUnreadCount)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let navigation = navigationController, let pop = navigation.interactivePopGestureRecognizer else { return }
        if pop.delegate !== self { previousPopDelegate = pop.delegate }
        pop.isEnabled = true
        pop.delegate = self
        popRecognizer = pop
        for recognizer in conversation.view.allGestureRecognizersInSubtree()
        where recognizer is UIPanGestureRecognizer && recognizer !== pop && !(recognizer.view is UIScrollView && recognizer === (recognizer.view as? UIScrollView)?.panGestureRecognizer) {
            recognizer.require(toFail: pop)
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Hand the recognizer back to UIKit's own delegate for the next screen.
        if let pop = popRecognizer, pop.delegate === self {
            pop.delegate = previousPopDelegate
        }
    }

    public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === popRecognizer else { return true }
        return (navigationController?.viewControllers.count ?? 0) > 1
    }

    public func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}

private extension UIView {
    func allGestureRecognizersInSubtree() -> [UIGestureRecognizer] {
        (gestureRecognizers ?? []) + subviews.flatMap { $0.allGestureRecognizersInSubtree() }
    }
}

#if DEBUG
/// DEBUG: lets the demo driver run CmuxConversation's lab verbs (`send`,
/// `doubletap`, `react`, `timestamps`, ...) on the open Chief conversation,
/// the same paths its gestures take, and scroll its transcript.
@MainActor
public final class ChiefDemoHook {
    public static let shared = ChiefDemoHook()
    weak var controller: ConversationViewController?
    /// The open New Message sheet, if any.
    weak var compose: ConversationComposeViewController?

    @discardableResult
    public func lab(_ line: String) -> String {
        controller?.labCommand(line) ?? "error no conversation"
    }

    /// CmuxConversation's photo lab verbs (`drawer`, `send`, `viewer`, `close`).
    @discardableResult
    public func photoLab(_ line: String) -> String {
        controller?.photoLabCommand(line) ?? "error no conversation"
    }

    /// New Message's lab verbs (`to`, `pick`, `body`, `send`, ...).
    @discardableResult
    public func composeLab(_ line: String) -> String {
        compose?.labCommand(line) ?? "error no compose"
    }

    /// Picks a photo as the composer's attachment, as the Photos drawer does.
    public func attachPhoto(_ image: UIImage) {
        guard let controller, let data = image.jpegData(compressionQuality: 0.85) else { return }
        controller.store.send(text: "", images: [(data: data, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale), mimeType: "image/jpeg")])
    }

    /// Tapbacks the newest incoming message, as picking one in the bar does.
    public func react(_ name: String) {
        guard let reaction = ConversationReaction(rawValue: name), let store = controller?.store,
              let message = store.messages.last(where: { $0.senderID != store.meID && $0.seq != nil }) else { return }
        store.react(messageID: message.id, reaction: reaction)
    }

    /// Scrolls the transcript to the top (true) or the bottom (false).
    public func scroll(toTop: Bool) {
        guard let view = controller?.view,
              let transcript = view.subviews.compactMap({ $0 as? UICollectionView }).first else { return }
        let bottom = max(-transcript.adjustedContentInset.top,
                         transcript.contentSize.height + transcript.adjustedContentInset.bottom - transcript.bounds.height)
        let y = toTop ? -transcript.adjustedContentInset.top : bottom
        UIView.animate(withDuration: 0.9, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            transcript.contentOffset.y = y
        }
    }
}
#endif
#endif
