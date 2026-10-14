#if os(iOS)
import CmuxConversationCore
import CmuxConversationUI
import SwiftUI
import UIKit

/// A navigation value that opens the Chief conversation.
public struct ChiefRoute: Hashable, Sendable {
    /// Home's compose button: the keyboard rises once the push settles.
    public var focusesComposer: Bool

    public init(focusesComposer: Bool = false) {
        self.focusesComposer = focusesComposer
    }
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
    let focusesComposer: Bool
    @Environment(\.dismiss) private var dismiss

    public init(session: ChiefSession = .shared, compose: ChiefComposer? = nil, focusesComposer: Bool = false) {
        self.session = session
        self.compose = compose
        self.focusesComposer = focusesComposer
    }

    public var body: some View {
        ChiefConversationController(session: session, compose: compose, focusesComposer: focusesComposer, back: { dismiss() })
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
            // The header's trailing button opens Chief's settings (model, alerts).
            trailingSymbol: "slider.horizontal.3"
        )
    }
}

struct ChiefConversationController: UIViewControllerRepresentable {
    let session: ChiefSession
    let compose: ChiefComposer?
    let focusesComposer: Bool
    let back: () -> Void

    func makeUIViewController(context: Context) -> ChiefConversationContainer {
        let conversation = ConversationViewController(store: session.store, options: .chief)
        let container = ChiefConversationContainer(conversation: conversation, session: session)
        container.focusesComposerOnAppear = focusesComposer
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
    let session: ChiefSession
    private var popRecognizers: [UIGestureRecognizer] = []
    private var previousPopDelegates: [ObjectIdentifier: WeakDelegate] = [:]
    private struct WeakDelegate { weak var value: (any UIGestureRecognizerDelegate)? }

    init(conversation: ConversationViewController, session: ChiefSession) {
        self.conversation = conversation
        self.session = session
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
        takeOverHeader()
    }

    // MARK: Chief settings in place of contact details

    /// The header's avatar and name open Messages' contact details in the
    /// package (Call, FaceTime and Mail; Hide Alerts and Send Read Receipts
    /// on a table that reloads under the switch). CmuxConversation has no
    /// hook to replace or trim them (verify/imsg-upstream-requests.md), so
    /// Chief retargets those two controls, and the trailing button, to
    /// ``ChiefSettingsView``: the Mac Chief's settings with this phone's
    /// alert and receipt switches. Found by the package's own accessibility
    /// markers; a later package that renames them shows its details again.
    private(set) var headerTakenOver = false
    private var trailingWasAction = false

    private func takeOverHeader() {
        // The header: the view that holds the name button, up to the
        // package's header class. Only its controls are touched.
        guard let name = conversation.view.subviewsOfType(UIButton.self).first(where: { $0.accessibilityIdentifier == "conversation.header.name" }) else {
            return
        }
        var header: UIView = name
        while let parent = header.superview, parent !== conversation.view,
              !String(describing: type(of: header)).contains("HeaderView") {
            header = parent
        }
        for button in header.subviewsOfType(UIButton.self) {
            switch button.accessibilityIdentifier {
            case "conversation.header.name":
                retarget(button)
            case "conversation.header.trailing":
                // The package's own action (leaving reply, edit or select
                // mode, which show an xmark) runs first; settings open only
                // from the plain state.
                button.addAction(UIAction { [weak self, weak button] _ in
                    self?.trailingWasAction = !(button?.currentImage.map(Self.isXmark) ?? true)
                }, for: .touchDown)
                button.addAction(UIAction { [weak self] _ in
                    guard let self, self.trailingWasAction else { return }
                    self.presentSettings()
                }, for: .touchUpInside)
                trailingButton = button
            default:
                // The avatar's tap target: the one header button with a hint.
                if button.accessibilityHint != nil, button.buttonType == .custom {
                    retarget(button)
                    button.accessibilityLabel = String(localized: "Chief")
                    button.accessibilityHint = String(localized: "Opens Chief's settings")
                }
            }
        }
        headerTakenOver = true
    }

    private weak var trailingButton: UIButton?

    private func retarget(_ button: UIButton) {
        var actions: [UIAction] = []
        button.enumerateEventHandlers { action, _, event, _ in
            if event == .touchUpInside, let action { actions.append(action) }
        }
        for action in actions { button.removeAction(action, for: .touchUpInside) }
        button.addAction(UIAction { [weak self] _ in self?.presentSettings() }, for: .touchUpInside)
    }

    static func isXmark(_ image: UIImage) -> Bool {
        String(describing: image).contains("xmark")
    }

    /// The trailing glyph speaks as "Call" in the package; here it is settings.
    private func labelTrailing() {
        guard let trailingButton, let image = trailingButton.currentImage, !Self.isXmark(image) else { return }
        trailingButton.accessibilityLabel = String(localized: "Chief Settings")
    }

    /// Messages written before Chief connected are not in the transcript
    /// yet; say so, with why, instead of showing nothing.
    private func showOutboxIfWaiting() {
        guard !session.outbox.isEmpty, !session.isConnected, presentedViewController == nil else { return }
        let count = session.outbox.count
        let reason = session.unavailableReason ?? String(localized: "Chief isn't connected yet.")
        let alert = UIAlertController(
            title: count == 1 ? String(localized: "Message Not Sent Yet") : String(localized: "\(count) Messages Not Sent Yet"),
            message: String(localized: "\(reason) It will send when Chief connects."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            self?.session.discardOutbox()
        })
        present(alert, animated: true)
    }

    public func presentSettings() {
        guard presentedViewController == nil, conversation.presentedViewController == nil else { return }
        view.endEditing(true)
        let host = UIHostingController(rootView: ChiefSettingsView(session: session))
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.prefersGrabberVisible = true
        present(host, animated: true)
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

    /// SwiftUI turns the edge pop off again whenever it updates the hidden
    /// bar (appear and layout), as the workspace screen found
    /// (verify/navigation.md), so it is re-enabled on every layout.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.window != nil { enableEdgePop() }
        labelTrailing()
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

    /// Home's compose pushed this screen: focus the composer once the push
    /// has settled, in the same turn as `viewDidAppear` (no delay).
    var focusesComposerOnAppear = false

    /// The package's composer field, found by its accessibility marker
    /// (CmuxConversation has no public focus call). A later package that
    /// renames it opens without the keyboard, never wrongly.
    private func focusComposer() {
        let field = conversation.view.firstSubview { $0.accessibilityIdentifier == "conversation.composer.text" }
        field?.becomeFirstResponder()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableEdgePop()
        ChiefAlerts.shared.conversationVisible = true
        session.markSeen()
        showOutboxIfWaiting()
        if focusesComposerOnAppear {
            focusesComposerOnAppear = false
            // Not under the waiting-outbox alert.
            if presentedViewController == nil { focusComposer() }
        }
        #if DEBUG
        ChiefDemoHook.shared.container = self
        #endif
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A sheet over Chief keeps it on screen.
        if presentedViewController == nil { ChiefAlerts.shared.conversationVisible = false }
    }

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

    func firstSubview(where match: (UIView) -> Bool) -> UIView? {
        for view in subviews {
            if match(view) { return view }
            if let found = view.firstSubview(where: match) { return found }
        }
        return nil
    }

    func subviewsOfType<T: UIView>(_ type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in
            if let match = view as? T { return [match] }
            return view.subviewsOfType(type)
        }
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
    weak var container: ChiefConversationContainer?
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

    /// Opens Chief's settings, as the header's avatar does.
    public func openSettings() {
        container?.presentSettings()
    }

    /// The header controls Chief took over (avatar, name, trailing).
    public var headerTakenOver: Bool { container?.headerTakenOver ?? false }

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
