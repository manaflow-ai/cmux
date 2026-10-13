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

/// Holds the conversation as a child, as the package's lab host does with
/// its navigation controller (bar hidden; the package draws the header,
/// backdrop and composer and owns safe areas and the keyboard), and keeps the
/// left-edge swipe back that SwiftUI turns off while the bar is hidden. The
/// transcript's pans wait for that swipe, so a drag from the edge pops
/// instead of replying to the bubble under it or opening the send times.
public final class ChiefConversationContainer: UIViewController, UIGestureRecognizerDelegate {
    let conversation: ConversationViewController
    private var popRecognizers: [UIGestureRecognizer] = []
    private var previousPopDelegates: [ObjectIdentifier: WeakDelegate] = [:]
    private struct WeakDelegate { weak var value: (any UIGestureRecognizerDelegate)? }

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
        enableEdgePop()
    }

    /// SwiftUI turns the edge pop off again whenever it updates the hidden
    /// bar (appear and layout), as the workspace screen found
    /// (verify/navigation.md), so it is re-enabled on every layout.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.window != nil { enableEdgePop() }
    }

    /// The back swipe from the left edge, as in Messages. On iOS 26 and later
    /// UIKit drives that swipe with the content pop recognizer, which also
    /// takes a rightward drag anywhere; Chief limits it to the edge strip,
    /// because a rightward drag on a bubble replies to it and a leftward
    /// drag on the transcript reveals send times.
    private func enableEdgePop() {
        guard let navigation = navigationController else { return }
        var recognizers: [UIGestureRecognizer] = []
        if let pop = navigation.interactivePopGestureRecognizer { recognizers.append(pop) }
        if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer { recognizers.append(content) }
        for recognizer in recognizers {
            if recognizer.delegate !== self { previousPopDelegates[ObjectIdentifier(recognizer)] = WeakDelegate(value: recognizer.delegate) }
            recognizer.isEnabled = true
            recognizer.delegate = self
        }
        guard popRecognizers.map(ObjectIdentifier.init) != recognizers.map(ObjectIdentifier.init) else { return }
        popRecognizers = recognizers
        // Every pan of the transcript waits for the back swipe to fail: the
        // reply swipe, the composer swipe, and the transcript's scroll pan,
        // which also tracks sideways drags (the send-time drawer) and would
        // otherwise take an edge swipe before the pop could begin. The pops
        // fail as soon as a drag starts outside the edge strip.
        for recognizer in conversation.view.allGestureRecognizersInSubtree()
        where recognizer is UIPanGestureRecognizer && !recognizers.contains(recognizer) {
            for pop in recognizers { recognizer.require(toFail: pop) }
        }
    }

    /// The strip along the left edge where a back swipe may start.
    static let backSwipeEdgeWidth: CGFloat = 16
    /// How far the finger has moved when the content pop asks to begin.
    static let contentPopSlop: CGFloat = 30

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Hand the recognizers back to their own delegates for the next screen.
        for recognizer in popRecognizers where recognizer.delegate === self {
            recognizer.delegate = previousPopDelegates[ObjectIdentifier(recognizer)]?.value
        }
        popRecognizers = []
    }

    public func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard popRecognizers.contains(recognizer) else { return true }
        guard let navigation = navigationController, navigation.viewControllers.count > 1 else { return false }
        // UIKit already limits the edge pop to the screen edge.
        if recognizer === navigation.interactivePopGestureRecognizer { return true }
        // On iOS 26 and later the content pop drives the edge swipe too, and
        // it would take a rightward drag anywhere: only from the edge strip
        // here. UIKit asks once the finger has travelled its slop (measured:
        // a drag from x = 1 is asked at x = 31, with no translation yet).
        return recognizer.location(in: view).x <= Self.backSwipeEdgeWidth + Self.contentPopSlop
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
