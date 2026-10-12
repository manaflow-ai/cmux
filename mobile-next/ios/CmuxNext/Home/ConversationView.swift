import CNMProtocol
import SwiftUI

/// A conversation with Chief, laid out and animated like Messages.
struct ConversationView: View {
    let host: HostConnection
    let conversationID: String

    @State private var draft = ""
    @State private var lastSentID: String?
    @State private var reactingTo: ConversationMessage?
    @FocusState private var composerFocused: Bool

    private var info: ConversationInfo? { host.conversations.first { $0.id == conversationID } }
    private var messages: [ConversationMessage] { host.messages[conversationID] ?? [] }
    private var typing: Bool { host.typing.contains(conversationID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ConversationHeaderSpacer()
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        let next = index + 1 < messages.count ? messages[index + 1] : nil
                        if let stamp = Self.timestamp(for: message, after: previous) {
                            Text(stamp)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                        BubbleRow(
                            message: message,
                            isMine: message.sender == "me",
                            tail: next?.sender != message.sender || Self.gap(message, next),
                            groupedAbove: previous?.sender == message.sender && !Self.gap(previous, message),
                            isNewlySent: message.clientID != nil && message.clientID == lastSentID
                        )
                        .id(message.id)
                        .onLongPressGesture(minimumDuration: 0.35) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            reactingTo = message
                        }
                        if message.id == lastDeliveredMineID {
                            Text(deliveryLabel(message))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 20)
                                .padding(.top, 2)
                                .transition(.opacity)
                        }
                    }
                    if typing {
                        TypingBubble()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 12)
                            .padding(.top, 8)
                            .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
                            .id("typing")
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: typing)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageComposer(text: $draft, focused: $composerFocused, placeholder: "Text Chief") { send(proxy) }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: typing) { _, isTyping in
                if isTyping { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Messages (iOS 26): a large avatar with the name in a glass capsule.
                VStack(spacing: -6) {
                    ChiefAvatar(size: 50)
                        .zIndex(0)
                    HStack(spacing: 3) {
                        Text(info?.title ?? "Chief").font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .zIndex(1)
                }
                .padding(.top, 22)
            }
        }
        .task {
            await host.loadMessages(conversationID)
            host.markRead(conversationID)
        }
        .onChange(of: messages.last?.id) { _, _ in host.markRead(conversationID) }
        .overlay {
            if let reactingTo {
                TapbackOverlay(message: reactingTo, isMine: reactingTo.sender == "me") { reaction in
                    if let reaction {
                        let current = reactingTo.reactions["me"]
                        host.react(conversationID, message: reactingTo.id, reaction: current == reaction ? nil : reaction)
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.reactingTo = nil }
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: reactingTo?.id)
    }

    private var lastDeliveredMineID: String? {
        guard let last = messages.last(where: { $0.sender == "me" }) else { return nil }
        return messages.last?.sender == "me" || messages.last(where: { $0.sender != "me" }).map { $0.sentAt < last.sentAt } == true ? last.id : nil
    }

    private func deliveryLabel(_ message: ConversationMessage) -> String {
        if message.id.hasPrefix("pending-") { return String(localized: "Sending…") }
        if let read = message.readAt {
            return String(localized: "Read \(read.formatted(date: .omitted, time: .shortened))")
        }
        return String(localized: "Delivered")
    }

    private func send(_ proxy: ScrollViewProxy) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pending = host.send(text: text, to: conversationID)
        lastSentID = pending.clientID
        draft = ""
    }

    static func gap(_ a: ConversationMessage?, _ b: ConversationMessage?) -> Bool {
        guard let a, let b else { return true }
        return b.sentAt.timeIntervalSince(a.sentAt) > 60 * 60
    }

    static func timestamp(for message: ConversationMessage, after previous: ConversationMessage?) -> String? {
        guard previous == nil || gap(previous, message) else { return nil }
        let date = message.sentAt
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return String(localized: "Today \(time)") }
        if Calendar.current.isDateInYesterday(date) { return String(localized: "Yesterday \(time)") }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) at \(time)"
    }
}

private struct ConversationHeaderSpacer: View {
    var body: some View { Color.clear.frame(height: 10) }
}

struct BubbleRow: View {
    let message: ConversationMessage
    let isMine: Bool
    let tail: Bool
    let groupedAbove: Bool
    let isNewlySent: Bool

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 64) }
            MessageBubble(text: message.text, isMine: isMine, tail: tail)
                .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                    if let reaction = message.reactions.values.first {
                        ReactionBadge(reaction: reaction, isMine: isMine)
                            .offset(x: isMine ? -14 : 14, y: -16)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .padding(.top, message.reactions.isEmpty ? 0 : 14)
            if !isMine { Spacer(minLength: 64) }
        }
        .padding(.horizontal, tail ? 12 : 12)
        .padding(.top, groupedAbove ? 2 : 8)
        .scaleEffect(isNewlySent && !appeared ? 0.86 : 1, anchor: .bottomTrailing)
        .offset(y: isNewlySent && !appeared ? 36 : 0)
        .opacity(isNewlySent && !appeared ? 0.0 : 1)
        .onAppear {
            guard isNewlySent else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { appeared = true }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: message.reactions)
    }
}

/// A bubble with the Messages tail on its outer bottom corner.
struct MessageBubble: View {
    let text: String
    let isMine: Bool
    let tail: Bool

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 17))
            .foregroundStyle(isMine ? .white : .primary)
            .tint(isMine ? .white : Color(.systemBlue))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                BubbleShape(tail: tail, mine: isMine)
                    .fill(isMine ? Color(.systemBlue) : Color(.systemGray5))
            }
            .padding(isMine ? .trailing : .leading, tail ? 0 : 0)
            .textSelection(.enabled)
    }
}

/// Rounded rectangle (radius 18) with a curled tail at the bottom outer
/// corner, mirrored for received messages.
struct BubbleShape: Shape {
    let tail: Bool
    let mine: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = min(18, rect.height / 2)
        let r = rect
        guard tail else {
            return Path(roundedRect: r, cornerRadius: radius, style: .continuous)
        }
        // Drawn for "mine" (tail bottom-right), then mirrored.
        path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 6))
        // Tail: sweep out past the edge and curl back under the bubble.
        path.addCurve(
            to: CGPoint(x: r.maxX + 5, y: r.maxY),
            control1: CGPoint(x: r.maxX, y: r.maxY - 2),
            control2: CGPoint(x: r.maxX + 2.5, y: r.maxY)
        )
        path.addCurve(
            to: CGPoint(x: r.maxX - 9, y: r.maxY - 3.5),
            control1: CGPoint(x: r.maxX - 1, y: r.maxY + 0.6),
            control2: CGPoint(x: r.maxX - 5.5, y: r.maxY - 1)
        )
        path.addQuadCurve(to: CGPoint(x: r.maxX - radius - 4, y: r.maxY), control: CGPoint(x: r.maxX - 13, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        path.closeSubpath()
        if mine { return path }
        return path.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -r.maxX - r.minX, y: 0))
    }
}

struct TypingBubble: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color(.secondaryLabel))
                    .frame(width: 8, height: 8)
                    .opacity(dotOpacity(index))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(BubbleShape(tail: true, mine: false).fill(Color(.systemGray5)))
        .task {
            while !Task.isCancelled {
                withAnimation(.linear(duration: 1.2)) { phase += 1 }
                try? await Task.sleep(for: .seconds(1.2))
            }
        }
        .accessibilityLabel("Chief is typing")
    }

    private func dotOpacity(_ index: Int) -> Double {
        let t = (phase.truncatingRemainder(dividingBy: 1) * 3 - Double(index) + 3).truncatingRemainder(dividingBy: 3)
        return t < 1 ? 1 - t * 0.6 : 0.4
    }
}

struct ReactionBadge: View {
    let reaction: String
    let isMine: Bool

    var body: some View {
        Image(systemName: Tapback.symbol(reaction))
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color(.systemBlue))
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color(.systemGray5)))
            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
    }
}

enum Tapback: String, CaseIterable {
    case love, like, dislike, laugh, emphasize, question

    static func symbol(_ raw: String) -> String {
        switch Tapback(rawValue: raw) {
        case .love: "heart.fill"
        case .like: "hand.thumbsup.fill"
        case .dislike: "hand.thumbsdown.fill"
        case .laugh: "face.smiling.inverse"
        case .emphasize: "exclamationmark.2"
        case .question: "questionmark"
        case nil: "heart.fill"
        }
    }
}

/// Long-press menu: tapbacks over a lifted copy of the bubble, actions below.
struct TapbackOverlay: View {
    let message: ConversationMessage
    let isMine: Bool
    let done: (String?) -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture { done(nil) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(Tapback.allCases, id: \.self) { tapback in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            done(tapback.rawValue)
                        } label: {
                            Image(systemName: Tapback.symbol(tapback.rawValue))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(message.reactions["me"] == tapback.rawValue ? .white : Color(.secondaryLabel))
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(message.reactions["me"] == tapback.rawValue ? Color(.systemBlue) : .clear))
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(shown ? 1 : 0.3)
                        .animation(.spring(response: 0.32, dampingFraction: 0.62).delay(Double(Tapback.allCases.firstIndex(of: tapback)!) * 0.02), value: shown)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                MessageBubble(text: message.text, isMine: isMine, tail: true)
                    .scaleEffect(shown ? 1.0 : 0.96)
                VStack(spacing: 0) {
                    menuButton("Copy", "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                        done(nil)
                    }
                }
                .frame(width: 220)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .scaleEffect(shown ? 1 : 0.6, anchor: isMine ? .topTrailing : .topLeading)
                .opacity(shown ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        }
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { shown = true } }
    }

    private func menuButton(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: symbol)
            }
            .font(.system(size: 17))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The Messages composer: a round "+" and a capsule field whose send arrow
/// appears once there is text.
struct MessageComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: LocalizedStringKey
    let send: () -> Void

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attachments")

            HStack(alignment: .bottom, spacing: 4) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(1...6)
                    .focused(focused)
                    .padding(.leading, 14)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("conversation.field")
                ZStack {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(.tertiary)
                        .opacity(hasText ? 0 : 1)
                        .accessibilityHidden(true)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 29))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(.systemBlue))
                    }
                    .buttonStyle(.plain)
                    .opacity(hasText ? 1 : 0)
                    .scaleEffect(hasText ? 1 : 0.5)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("conversation.send")
                    .disabled(!hasText)
                }
                .frame(width: 30, height: 30)
                .padding(.trailing, 3)
                .padding(.bottom, 3)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hasText)
            }
            .frame(minHeight: 36)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }
}
