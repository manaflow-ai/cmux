#if os(iOS)
import CnxAgentChat
import CnxDesign
import SwiftUI
import UIKit

/// One swipe action (Mail style: tinted, icon over a short label).
struct FeedSwipeAction: Identifiable {
    var id: String
    var title: String
    var systemImage: String
    var tint: Color
    /// The action removes the row (Done): it runs while the row is slid out; others run after it slides back.
    var removesRow = false
    var action: () -> Void
}

/// Which row's actions are showing, so opening one closes the other and a
/// scroll closes them all (owned by the Feed screen).
@MainActor
@Observable
final class FeedSwipeCoordinator {
    var openID: String?
    /// Demo driver requests: reveal an edge, or perform an action as a full swipe.
    var demoReveal: (id: String, leading: Bool)?
    var demoPerform: (id: String, action: String)?
    var demoSerial = 0
}

/// Leading and trailing swipe actions on a row outside `List` (iOS Mail and
/// Messages conventions): a horizontal pan that never fights vertical
/// scrolling, actions revealed under the row, a full swipe past 60 % of the
/// width performs the outermost action with a haptic, rubber banding past
/// the end, tap to close. (iOS 27's `swipeActionsContainer()` covers this in
/// SwiftUI, but the deployment target is iOS 26.)
struct FeedSwipeRow<Content: View>: View {
    let id: String
    let leading: [FeedSwipeAction]
    let trailing: [FeedSwipeAction]
    let coordinator: FeedSwipeCoordinator
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var dragStart: CGFloat?
    @State private var width: CGFloat = 0
    @State private var armed = false
    @State private var performing: String?

    static var actionWidth: CGFloat { 76 }

    private var isOpen: Bool { offset != 0 }
    private var leadingWidth: CGFloat { CGFloat(leading.count) * Self.actionWidth }
    private var trailingWidth: CGFloat { CGFloat(trailing.count) * Self.actionWidth }
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
            .background(alignment: .leading) {
                if offset > 0 { actions(leading, leadingEdge: true) }
            }
            .background(alignment: .trailing) {
                if offset < 0 { actions(trailing, leadingEdge: false) }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .gesture(HorizontalPan(onChange: dragChanged, onEnd: dragEnded))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, new in new }
            .onChange(of: coordinator.openID) { _, open in
                if open != id, isOpen { withAnimation(.cnxSnappy) { offset = 0 } }
            }
            .onChange(of: coordinator.demoSerial) { runDemo() }
            .accessibilityActions {
                ForEach(leading + trailing) { action in
                    Button(action.title, action: action.action)
                }
            }
    }

    private func actions(_ list: [FeedSwipeAction], leadingEdge: Bool) -> some View {
        let revealed = abs(offset)
        // The outermost action sits at the row's edge and covers the row once a full swipe is armed.
        let ordered = leadingEdge ? list : list.reversed()
        return HStack(spacing: 0) {
            ForEach(ordered) { action in
                let isOutermost = action.id == list.first?.id
                let share = armed ? (isOutermost ? revealed : 0) : revealed / CGFloat(max(list.count, 1))
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
        .frame(width: revealed, alignment: leadingEdge ? .leading : .trailing)
        .animation(.cnxSnappy, value: armed)
    }

    private func dragChanged(_ translation: CGFloat) {
        if dragStart == nil {
            dragStart = offset
            coordinator.openID = id
        }
        var next = (dragStart ?? 0) + translation
        if next > 0, leading.isEmpty { next = 0 }
        if next < 0, trailing.isEmpty { next = 0 }
        // Rubber band past the full-swipe point.
        let limit = width * 0.9
        if abs(next) > limit { next = (next > 0 ? 1 : -1) * (limit + (abs(next) - limit) * 0.25) }
        offset = next
        armed = abs(next) > fullThreshold
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        dragStart = nil
        let list = offset > 0 ? leading : trailing
        if armed, let first = list.first {
            perform(first)
            return
        }
        let reveal = offset > 0 ? leadingWidth : trailingWidth
        let projected = abs(offset + velocity * 0.12)
        withAnimation(.cnxSnappy) {
            offset = projected > reveal / 2 && (velocity == 0 || (velocity > 0) == (offset > 0) || abs(offset) > reveal / 2)
                ? (offset > 0 ? reveal : -reveal) : 0
        }
        if offset == 0, coordinator.openID == id { coordinator.openID = nil }
    }

    /// Mail's full-swipe animation: the row slides out, the action runs, the row comes back (or leaves, if the action removes it).
    private func perform(_ action: FeedSwipeAction) {
        let direction: CGFloat = offset >= 0 && leading.contains(where: { $0.id == action.id }) ? 1 : -1
        armed = true
        withAnimation(.cnxSnappy) { offset = direction * width }
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
        if let reveal = coordinator.demoReveal, reveal.id == id {
            coordinator.openID = id
            withAnimation(.cnxSnappy) { offset = reveal.leading ? leadingWidth : -trailingWidth }
        }
        if let request = coordinator.demoPerform, request.id == id,
           let action = (leading + trailing).first(where: { $0.id == request.action }) {
            perform(action)
        }
    }
}

/// A pan that begins only for mostly horizontal movement, so the Feed keeps scrolling vertically.
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: onChange(translation)
        case .ended, .cancelled, .failed: onEnd(translation, recognizer.velocity(in: recognizer.view).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.3
        }
    }
}

extension FeedItem {
    /// Mail-style actions for this event: answer or allow on the leading edge,
    /// deny or done on the trailing edge, open and read state alongside.
    @MainActor
    func swipeActions(store: FeedStore, open: @escaping () -> Void) -> (leading: [FeedSwipeAction], trailing: [FeedSwipeAction]) {
        let openAction = FeedSwipeAction(id: "open", title: "Open", systemImage: "arrow.up.right.square", tint: Color(uiColor: .systemGray), action: open)
        let read = isRead
            ? FeedSwipeAction(id: "unread", title: "Unread", systemImage: "envelope.badge", tint: .blue) { store.markUnread(id) }
            : FeedSwipeAction(id: "read", title: "Read", systemImage: "envelope.open", tint: .blue) { store.markRead(id) }
        let done = FeedSwipeAction(id: "done", title: "Done", systemImage: "checkmark", tint: .purple, removesRow: true) {
            withAnimation(.cnxSmooth) { store.markDone(id) }
        }
        guard resolution == nil else { return ([read], [done, openAction]) }
        switch kind {
        case .permission(let request):
            let allow = request.options.first(where: { $0.kind == .allowOnce }) ?? request.options.first(where: \.isAllow)
            let deny = request.options.first(where: { $0.kind == .rejectOnce }) ?? request.options.first(where: { !$0.isAllow })
            var leading: [FeedSwipeAction] = []
            if let allow {
                leading.append(FeedSwipeAction(id: "allow", title: "Allow", systemImage: "checkmark.shield", tint: .green) {
                    withAnimation(.cnxSmooth) { store.respond(id, option: allow) }
                })
            }
            var trailing: [FeedSwipeAction] = []
            if let deny {
                trailing.append(FeedSwipeAction(id: "deny", title: "Deny", systemImage: "xmark.shield", tint: .red) {
                    withAnimation(.cnxSmooth) { store.respond(id, option: deny) }
                })
            }
            trailing.append(openAction)
            return (leading, trailing)
        case .question(let question) where question.isPending:
            let answer = FeedSwipeAction(id: "answer", title: "Answer", systemImage: "bubble.left.and.text.bubble.right", tint: .blue, action: open)
            return ([answer], [done, openAction])
        default:
            return ([read], [done, openAction])
        }
    }
}
#endif
