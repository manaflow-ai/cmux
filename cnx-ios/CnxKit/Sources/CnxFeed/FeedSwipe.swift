#if os(iOS)
import CnxAgentChat
import CnxDesign
import SwiftUI
import UIKit

/// One swipe action (Mail style: tinted, icon over a short label). Tints
/// come from `FeedSwipeTint`, which reads well in light and dark mode.
struct FeedSwipeAction: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var tint: Color
    /// The action removes the row (Done): it runs while the row is slid out; others run after it slides back.
    var removesRow = false
    var action: () -> Void
}

/// Swipe action fills: UIKit's semantic system colors (the ones Mail and
/// Messages use), which adapt to light and dark mode. White labels stay
/// legible on every one of them in both modes.
enum FeedSwipeTint {
    /// Destructive (Deny, Decline): the system destructive red.
    static var destructive: Color { Color(uiColor: .systemRed) }
    /// Archive-like (Done), as Mail's Archive.
    static var archive: Color { Color(uiColor: .systemPurple) }
    /// Read state, as Mail's Unread.
    static var read: Color { Color(uiColor: .systemBlue) }
    /// Approve (Allow).
    static var approve: Color { Color(uiColor: .systemGreen) }
}

/// Which row's actions are showing, so opening one closes the other and a
/// scroll closes them all (owned by the Feed screen).
@MainActor
@Observable
final class FeedSwipeCoordinator {
    var openID: String?
    /// Demo driver requests: reveal the actions, or perform an action as a full swipe.
    var demoReveal: String?
    var demoPerform: (id: String, action: String)?
    var demoSerial = 0
}

/// Trailing swipe actions on a row outside `List` (iOS Mail conventions): a
/// leftward pan that never fights vertical scrolling, actions revealed under
/// the row, a full swipe past 60 % of the width performs the outermost action
/// with a haptic, rubber banding past the end, tap to close. (iOS 27's
/// `swipeActionsContainer()` covers this in SwiftUI, but the deployment
/// target is iOS 26.)
///
/// There is no leading edge: a rightward pan on a tab root opens the team
/// drawer (SPEC 3.3, swipe rules), so the row's pan does not begin for a
/// rightward drag unless it is closing open actions.
struct FeedSwipeRow<Content: View>: View {
    let id: String
    let actions: [FeedSwipeAction]
    let coordinator: FeedSwipeCoordinator
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var width: CGFloat = 0
    @State private var armed = false

    static var actionWidth: CGFloat { 76 }

    private var isOpen: Bool { offset != 0 }
    private var revealWidth: CGFloat { CGFloat(actions.count) * Self.actionWidth }
    private var fullThreshold: CGFloat { max(width * 0.6, 160) }

    var body: some View {
        content
            .offset(x: offset)
            .overlay {
                // While open, a tap anywhere on the row closes it instead of opening the event.
                if isOpen {
                    Color.clear.contentShape(.rect).onTapGesture { close() }
                        .offset(x: offset)
                }
            }
            .background(alignment: .trailing) {
                if offset < 0 { actionStrip }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(HorizontalPan(isOpen: isOpen, onChange: dragChanged, onEnd: dragEnded))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new }
            .onChange(of: coordinator.openID) { _, open in
                if open != id, isOpen { withAnimation(.cnxSnappy) { offset = 0 } }
            }
            .onChange(of: coordinator.demoSerial) { runDemo() }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.title, action: action.action)
                }
            }
    }

    private var actionStrip: some View {
        let revealed = abs(offset)
        // The outermost action sits at the row's trailing edge and covers the row once a full swipe is armed.
        return HStack(spacing: 0) {
            ForEach(actions.reversed()) { action in
                let isOutermost = action.id == actions.first?.id
                let share = armed ? (isOutermost ? revealed : 0) : revealed / CGFloat(max(actions.count, 1))
                Button {
                    perform(action)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: action.systemImage).font(.system(size: 19, weight: .medium))
                        Text(action.title).font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(.white)
                    .frame(width: max(share, 0), alignment: .center)
                    .frame(maxHeight: .infinity)
                    .background(action.tint)
                    .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.swipe.\(action.id)")
            }
        }
        .frame(width: revealed, alignment: .trailing)
        .animation(.cnxSnappy, value: armed)
    }

    private func dragChanged(_ translation: CGFloat) {
        if dragStart == nil {
            dragStart = offset
            coordinator.openID = id
        }
        var next = min((dragStart ?? 0) + translation, 0)
        if actions.isEmpty { next = 0 }
        // Rubber band past the full-swipe point.
        let limit = width * 0.9
        if abs(next) > limit { next = (next > 0 ? 1 : -1) * (limit + (abs(next) - limit) * 0.25) }
        offset = next
        armed = abs(next) > fullThreshold
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragStart = nil
        if armed, let first = actions.first {
            perform(first)
            return
        }
        let projected = abs(min(offset + velocity * 0.12, 0))
        withAnimation(.cnxSnappy) {
            offset = projected > revealWidth / 2 && (velocity <= 0 || abs(offset) > revealWidth / 2) ? -revealWidth : 0
        }
        if offset == 0, coordinator.openID == id { coordinator.openID = nil }
    }

    /// Mail's full-swipe animation: the row slides out, the action runs, the row comes back (or leaves, if the action removes it).
    private func perform(_ action: FeedSwipeAction) {
        armed = true
        withAnimation(.cnxSnappy) { offset = -width }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if action.removesRow { action.action() }
            armed = false
            withAnimation(.cnxSnappy) { offset = 0 }
            if coordinator.openID == id { coordinator.openID = nil }
            guard !action.removesRow else { return }
            try? await Task.sleep(for: .milliseconds(260))
            action.action()
        }
    }

    private func close() {
        withAnimation(.cnxSnappy) { offset = 0 }
        if coordinator.openID == id { coordinator.openID = nil }
    }

    private func runDemo() {
        if coordinator.demoReveal == id {
            coordinator.openID = id
            withAnimation(.cnxSnappy) { offset = -revealWidth }
        }
        if let request = coordinator.demoPerform, request.id == id,
           let action = actions.first(where: { $0.id == request.action }) {
            perform(action)
        }
    }
}

/// A pan that begins only for mostly horizontal movement, so the Feed keeps
/// scrolling vertically, and only leftward unless the row is open, so a
/// rightward pan falls through to the team drawer.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var isOpen: Bool
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: onChange(translation)
        case .ended, .cancelled, .failed: onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen = false

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }
            return velocity.x < 0 || isOpen
        }
    }
}

extension FeedItem {
    /// Mail-style trailing actions for this event, outermost (full swipe)
    /// first. At most three: the decision the event asks for, then read state
    /// or Open. Everything else is in the cell's context menu.
    @MainActor
    func swipeActions(store: FeedStore, open: @escaping () -> Void) -> [FeedSwipeAction] {
        let read = isRead
            ? FeedSwipeAction(id: "unread", title: "Unread", systemImage: "envelope.badge", tint: FeedSwipeTint.read) { store.markUnread(id) }
            : FeedSwipeAction(id: "read", title: "Read", systemImage: "envelope.open", tint: FeedSwipeTint.read) { store.markRead(id) }
        let done = FeedSwipeAction(id: "done", title: "Done", systemImage: "checkmark", tint: FeedSwipeTint.archive, removesRow: true) {
            withAnimation(.cnxSmooth) { store.markDone(id) }
        }
        guard resolution == nil else { return [done, read] }
        switch kind {
        case .permission(let request):
            // A full swipe denies, never allows: granting a permission takes a deliberate tap.
            let allow = request.options.first(where: { $0.kind == .allowOnce }) ?? request.options.first(where: \.isAllow)
            let deny = request.options.first(where: { $0.kind == .rejectOnce }) ?? request.options.first(where: { !$0.isAllow })
            var actions: [FeedSwipeAction] = []
            if let deny {
                actions.append(FeedSwipeAction(id: "deny", title: "Deny", systemImage: "xmark.shield", tint: FeedSwipeTint.destructive) {
                    withAnimation(.cnxSmooth) { store.respond(id, option: deny) }
                })
            }
            if let allow {
                // The allow asks for Face ID before it is sent (verify/phone-approvals.md).
                actions.append(FeedSwipeAction(id: "allow", title: "Allow", systemImage: "faceid", tint: FeedSwipeTint.approve) {
                    withAnimation(.cnxSmooth) { store.respond(id, option: allow) }
                })
            }
            return actions
        case .question(let question) where question.isPending:
            let answer = FeedSwipeAction(id: "answer", title: "Answer", systemImage: "arrowshape.turn.up.left", tint: FeedSwipeTint.read, action: open)
            let decline = FeedSwipeAction(id: "decline", title: "Decline", systemImage: "xmark", tint: FeedSwipeTint.destructive) {
                withAnimation(.cnxSmooth) { store.decline(id) }
            }
            return [decline, answer]
        default:
            return [done, read]
        }
    }
}
#endif
