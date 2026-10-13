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
/// `ConversationViewController` over the shared `ChiefSession` store. It
/// draws its own glass header (back, avatar, name) and owns the bottom edge,
/// so the SwiftUI navigation bar and the tab bar are hidden while it is up.
public struct ChiefConversationScreen: View {
    let session: ChiefSession
    @Environment(\.dismiss) private var dismiss

    public init(session: ChiefSession = .shared) {
        self.session = session
    }

    public var body: some View {
        ChiefConversationController(session: session, back: { dismiss() })
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
    let back: () -> Void

    func makeUIViewController(context: Context) -> ConversationViewController {
        let controller = ConversationViewController(store: session.store, options: .chief)
        controller.onBack = back
        #if DEBUG
        ChiefDemoHook.shared.controller = controller
        #endif
        return controller
    }

    func updateUIViewController(_ controller: ConversationViewController, context: Context) {
        controller.onBack = back
    }
}

#if DEBUG
/// DEBUG: lets the demo driver run CmuxConversation's lab verbs (`send`,
/// `doubletap`, `react`, ...) on the open Chief conversation, the same
/// paths its gestures take, and scroll its transcript.
@MainActor
public final class ChiefDemoHook {
    public static let shared = ChiefDemoHook()
    weak var controller: ConversationViewController?

    @discardableResult
    public func lab(_ line: String) -> String {
        controller?.labCommand(line) ?? "error no conversation"
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
