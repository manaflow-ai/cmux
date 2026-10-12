import CNMProtocol
import SwiftUI

/// Measured Messages (iOS 26.5) metrics; see docs/IMESSAGE-SPEC.md.
enum Messages {
    static let margin: CGFloat = 16
    static let maxWidthFraction: CGFloat = 0.70
    static let groupSpacing: CGFloat = 4
    static let breakSpacing: CGFloat = 10
    static let tailDrop: CGFloat = 7.45
    static let secondary = Color(light: 0x8A8A8E, dark: 0x8D8D93)
    static let received = Color(light: 0xE9E9EB, dark: 0x262629)
    static let accent = Color(light: 0x0088FF, dark: 0x0091FF)

    /// Sent bubbles take their color from where they sit on screen, lighter
    /// near the top, like the measured SMS green (here in iMessage blue).
    static func sentColor(atScreenFraction t: CGFloat, dark: Bool) -> Color {
        let t = max(0, min(1, t))
        let top: (Double, Double, Double) = dark ? (0x0A, 0x96, 0xFF) : (0x38, 0xA6, 0xFF)
        let bottom: (Double, Double, Double) = dark ? (0x00, 0x91, 0xFF) : (0x00, 0x88, 0xFF)
        func mix(_ a: Double, _ b: Double) -> Double { (a + (b - a) * Double(t)) / 255 }
        return Color(.sRGB, red: mix(top.0, bottom.0), green: mix(top.1, bottom.1), blue: mix(top.2, bottom.2))
    }

    // Springs fitted from 60 fps captures.
    static let sendRise = Animation.spring(response: 0.33, dampingFraction: 0.51)
    static let sendWidth = Animation.spring(response: 0.42, dampingFraction: 0.62)
    static let sendScale = Animation.spring(response: 0.6, dampingFraction: 0.7)
    static let menuIn = Animation.spring(response: 0.32, dampingFraction: 0.80)
    static let menuOut = Animation.spring(response: 0.32, dampingFraction: 0.88)
    static let timestampRelease = Animation.spring(response: 0.36, dampingFraction: 1.28)
}

/// A conversation with Chief, laid out and animated like Messages.
struct ConversationView: View {
    let host: HostConnection
    let conversationID: String

    @State private var draft = ""
    @State private var lastSentID: String?
    /// Client ids whose send animation already ran (the row is rebuilt when
    /// the Mac's confirmed message replaces the pending one).
    @State private var animatedSends: Set<String> = []
    @State private var reactingTo: ConversationMessage?
    @State private var fieldWidth: CGFloat = 318
    @State private var timestampOffset: CGFloat = 0
    @State private var viewWidth: CGFloat = 402
    @FocusState private var composerFocused: Bool

    private var info: ConversationInfo? { host.conversations.first { $0.id == conversationID } }
    private var messages: [ConversationMessage] { host.messages[conversationID] ?? [] }
    private var typing: Bool { host.typing.contains(conversationID) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ServiceHeader()
                    ForEach(Array(messages.enumerated()), id: \.element.rowID) { index, message in
                        let previous = index > 0 ? messages[index - 1] : nil
                        let next = index + 1 < messages.count ? messages[index + 1] : nil
                        let mine = message.sender == "me"
                        if let stamp = Self.timestamp(for: message, after: previous) {
                            stamp
                                .padding(.top, index == 0 ? 15 : 18)
                                .padding(.bottom, 7)
                        }
                        let tail = next?.sender != message.sender || Self.gap(message, next)
                        let groupedAbove = previous?.sender == message.sender && !Self.gap(previous, message)
                        BubbleRow(
                            message: message,
                            isMine: mine,
                            tail: tail,
                            isNewlySent: message.clientID != nil && message.clientID == lastSentID
                                && !animatedSends.contains(message.clientID ?? ""),
                            onSendAnimated: { if let id = message.clientID { animatedSends.insert(id) } },
                            fieldWidth: fieldWidth,
                            maxWidth: viewWidth * Messages.maxWidthFraction,
                            timestampOffset: mine ? timestampOffset : 0,
                            reveal: -timestampOffset / 58
                        )
                        .padding(.top, index == 0 || Self.timestamp(for: message, after: previous) != nil ? 0
                                 : (groupedAbove ? Messages.groupSpacing : Messages.breakSpacing))
                        .padding(.bottom, tail ? Messages.tailDrop : 0)
                        .id(message.rowID)
                        .onLongPressGesture(minimumDuration: 0.35) {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            withAnimation(Messages.menuIn) { reactingTo = message }
                        }
                        if message.id == lastDeliveredMineID {
                            Text(deliveryLabel(message))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Messages.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 20)
                                .padding(.top, 5.7 - Messages.tailDrop)
                                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                                .id("delivered-" + message.id)
                        }
                    }
                    if typing {
                        TypingBubble()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, Messages.margin)
                            .padding(.top, Messages.breakSpacing)
                            .padding(.bottom, Messages.tailDrop)
                            .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
                            .id("typing")
                    }
                    Color.clear.frame(height: 10).id("bottom")
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.82), value: typing)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, 44, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .simultaneousGesture(timestampDrag)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MessageComposer(
                    text: $draft, focused: $composerFocused, placeholder: "iMessage",
                    keyboardUp: composerFocused, fieldWidth: $fieldWidth
                ) { send() }
            }
            .onChange(of: messages.count) { _, _ in
                // A send rises after its ~130 ms width phase; the scroll and the
                // bubble share one spring so the overshoot isn't doubled.
                let delay = messages.last?.sender == "me" ? 0.15 : 0
                withAnimation(Messages.sendRise.delay(delay)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: typing) { _, isTyping in
                if isTyping { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .overlay(alignment: .top) {
            // Messages fades the top ~100 pt of the transcript under its header.
            LinearGradient(stops: [
                .init(color: Color(.systemBackground), location: 0),
                .init(color: Color(.systemBackground).opacity(0.92), location: 0.55),
                .init(color: Color(.systemBackground).opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: Self.statusBarHeight + 118)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            ConversationHeader(title: info?.title ?? "Chief")
                .padding(.top, Self.statusBarHeight)
                .ignoresSafeArea(.container, edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }
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
                    withAnimation(Messages.menuOut) { self.reactingTo = nil }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }
        }
    }

    /// Drag left to reveal send times: sent bubbles follow at half the
    /// finger's speed, stop at −58 pt, and spring back on release.
    private var timestampDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.width < 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                timestampOffset = max(-58, value.translation.width * 0.5)
            }
            .onEnded { _ in
                withAnimation(Messages.timestampRelease) { timestampOffset = 0 }
            }
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

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let pending = host.send(text: text, to: conversationID)
        lastSentID = pending.clientID
        draft = ""
    }

    /// Messages puts the nav bar region at y 62 on this phone: the status bar height.
    static var statusBarHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first?.safeAreaInsets.top ?? 62
    }

    static var windowHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return max(scene?.windows.first?.bounds.height ?? 874, 1)
    }

    static func gap(_ a: ConversationMessage?, _ b: ConversationMessage?) -> Bool {
        guard let a, let b else { return true }
        return b.sentAt.timeIntervalSince(a.sentAt) > 5 * 60
    }

    /// "Today 11:27 AM": the day in semibold, the time regular, 11 pt gray.
    static func timestamp(for message: ConversationMessage, after previous: ConversationMessage?) -> Text? {
        guard previous == nil || (previous.map { message.sentAt.timeIntervalSince($0.sentAt) > 60 * 60 } ?? true) else { return nil }
        let date = message.sentAt
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if Calendar.current.isDateInToday(date) { day = String(localized: "Today") }
        else if Calendar.current.isDateInYesterday(date) { day = String(localized: "Yesterday") }
        else { day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return Text("\(Text(day).fontWeight(.semibold)) \(time)")
            .font(.system(size: 11))
            .foregroundStyle(Messages.secondary)
    }
}

extension ConversationMessage {
    /// Stable across the pending → confirmed swap.
    var rowID: String { clientID ?? id }
}

/// The large avatar with the name in a glass pill, floating over the
/// transcript (Messages has no bar background).
struct ConversationHeader: View {
    let title: String

    var body: some View {
        VStack(spacing: -5) {
            ChiefAvatar(size: 60)
            HStack(spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Image(systemName: "chevron.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 32.3)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.top, 0)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "iMessage / 🔒 Encrypted"-style service header above the first message.
private struct ServiceHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Chief")
            Text("\(Image(systemName: "lock.fill")) Peer to peer")
        }
        .font(.system(size: 11))
        .foregroundStyle(Messages.secondary)
        .padding(.top, 13.4)
    }
}

struct BubbleRow: View {
    let message: ConversationMessage
    let isMine: Bool
    let tail: Bool
    let isNewlySent: Bool
    var onSendAnimated: () -> Void = {}
    let fieldWidth: CGFloat
    let maxWidth: CGFloat
    var timestampOffset: CGFloat = 0
    /// 0…1 while the transcript is dragged left; every row shows its time.
    var reveal: CGFloat = 0

    @State private var phase: SendPhase = .settled
    @State private var screenFraction: CGFloat = 0.8
    @Environment(\.colorScheme) private var colorScheme

    /// The measured send: field-sized under the composer → leading edge
    /// slides in → pops out at 79% → rises and grows into place.
    enum SendPhase { case field, shrunk, settled }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 0) }
            MessageBubble(
                text: message.text,
                isMine: isMine,
                tail: tail,
                fill: isMine ? Messages.sentColor(atScreenFraction: screenFraction, dark: colorScheme == .dark) : Messages.received,
                minWidth: phase == .field ? fieldWidth : 0,
                maxWidth: phase == .field ? max(fieldWidth, maxWidth) : maxWidth
            )
            .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                if let reaction = message.reactions.values.first {
                    ReactionBadge(reaction: reaction, onSentBubble: isMine)
                        .offset(x: isMine ? -16 : 16, y: -24)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .scaleEffect(phase == .shrunk ? 0.79 : 1, anchor: .bottomTrailing)
            // The scroll lifts the row by its height; this covers the rest of
            // the way from the composer field to the slot.
            .offset(y: phase == .settled ? 0 : 14)
            .offset(x: timestampOffset)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).midY / ConversationView.windowHeight
            } action: { screenFraction = $0 }
            if !isMine { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Messages.margin)
        .overlay(alignment: .trailing) {
            if reveal > 0 {
                Text(message.sentAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Messages.secondary)
                    .padding(.trailing, 3)
                    .opacity(Double(reveal))
            }
        }
        .padding(.top, message.reactions.isEmpty ? 0 : 14)
        .onAppear {
            guard isNewlySent else { return }
            onSendAnimated()
            phase = .field
            withAnimation(Messages.sendWidth) { phase = .shrunk }
            withAnimation(Messages.sendRise.delay(0.15)) { phase = .settled }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: message.reactions)
    }
}

/// A Messages bubble: 17 pt text, 10/14 pt padding, radius 20, measured tail.
struct MessageBubble: View {
    let text: String
    let isMine: Bool
    let tail: Bool
    var fill: Color = Messages.received
    var minWidth: CGFloat = 0
    var maxWidth: CGFloat = .infinity

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.system(size: 17))
            .foregroundStyle(isMine ? .white : .primary)
            .tint(isMine ? .white : Messages.accent)
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(minWidth: minWidth, alignment: .leading)
            .frame(maxWidth: maxWidth, alignment: isMine ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background { BubbleShape(hasTail: tail, isFromMe: isMine).fill(fill) }
            .contentShape(BubbleShape(hasTail: tail, isFromMe: isMine))
    }
}

/// The Messages bubble outline, fitted to the 3x capture within ~0.12 pt
/// (docs/IMESSAGE-SPEC.md §2.5). `rect` is the body; the tail hangs 7.45 pt
/// below it, 7.9 pt inside the trailing edge.
struct BubbleShape: Shape {
    var hasTail: Bool
    var isFromMe: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(20, h / 2), k: CGFloat = 0.5523
        var p = Path()
        p.move(to: .init(x: r, y: 0))
        p.addLine(to: .init(x: w - r, y: 0))
        p.addCurve(to: .init(x: w, y: r), control1: .init(x: w - r + k * r, y: 0), control2: .init(x: w, y: r - k * r))
        if hasTail {
            p.addLine(to: .init(x: w, y: max(r, h - 18.44)))
            p.addCurve(to: .init(x: w - 10.5, y: h - 1.0),
                       control1: .init(x: w, y: h - 9.82), control2: .init(x: w - 6.62, y: h - 5.0))
            p.addCurve(to: .init(x: w - 7.9, y: h + 7.45),
                       control1: .init(x: w - 10.5, y: h + 4.0), control2: .init(x: w - 8.02, y: h + 3.95))
            p.addCurve(to: .init(x: w - 22.38, y: h),
                       control1: .init(x: w - 10.9, y: h + 7.51), control2: .init(x: w - 20.38, y: h))
        } else {
            p.addLine(to: .init(x: w, y: h - r))
            p.addCurve(to: .init(x: w - r, y: h), control1: .init(x: w, y: h - r + k * r), control2: .init(x: w - r + k * r, y: h))
        }
        p.addLine(to: .init(x: r, y: h))
        p.addCurve(to: .init(x: 0, y: h - r), control1: .init(x: r - k * r, y: h), control2: .init(x: 0, y: h - r + k * r))
        p.addLine(to: .init(x: 0, y: r))
        p.addCurve(to: .init(x: r, y: 0), control1: .init(x: 0, y: r - k * r), control2: .init(x: r - k * r, y: 0))
        p.closeSubpath()
        let placed = p.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        guard !isFromMe else { return placed }
        return p.applying(CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}

struct TypingBubble: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Messages.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(dotOpacity(index))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40.33)
        .background(BubbleShape(hasTail: true, isFromMe: false).fill(Messages.received))
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

/// The tapback badge: a ~32 pt blue circle with a 2 pt background ring and
/// two "thought" dots toward the bubble.
struct ReactionBadge: View {
    let reaction: String
    /// Sent bubbles carry the badge top-leading with the dots trailing toward
    /// the bubble; received bubbles mirror it.
    var onSentBubble = true

    var body: some View {
        let side: CGFloat = onSentBubble ? 1 : -1
        ZStack(alignment: onSentBubble ? .bottomTrailing : .bottomLeading) {
            Circle().fill(Messages.accent).frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                .offset(x: 6 * side, y: 8)
            Circle().fill(Messages.accent).frame(width: 5, height: 5).offset(x: 11 * side, y: 14)
            Image(systemName: Tapback.symbol(reaction))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(LinearGradient(colors: [Color(hex: 0x5AB4FF), Messages.accent], startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
        }
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

/// Long-press: the backdrop dims ~19% and blurs, a glass tapback capsule and
/// a glass action menu grow out of the pressed bubble.
struct TapbackOverlay: View {
    let message: ConversationMessage
    let isMine: Bool
    let done: (String?) -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            // Messages blurs and darkens the backdrop ~19% (measured lum 245.6 → 198.5).
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                .overlay(Color.black.opacity(0.32).ignoresSafeArea())
                .onTapGesture { done(nil) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(Array(Tapback.allCases.enumerated()), id: \.element) { index, tapback in
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            done(tapback.rawValue)
                        } label: {
                            Image(systemName: Tapback.symbol(tapback.rawValue))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(message.reactions["me"] == tapback.rawValue ? .white : Color(.secondaryLabel))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(message.reactions["me"] == tapback.rawValue ? Messages.accent : .clear))
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tapback.\(tapback.rawValue)")
                        .scaleEffect(shown ? 1 : 0.2)
                        .animation(Messages.menuIn.delay(Double(index) * 0.015), value: shown)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .glassEffect(.regular, in: .capsule)
                MessageBubble(
                    text: message.text, isMine: isMine, tail: true,
                    fill: isMine ? Messages.accent : Messages.received,
                    maxWidth: 281
                )
                .scaleEffect(shown ? 1.02 : 1)
                VStack(spacing: 0) {
                    menuButton("Copy", "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                        done(nil)
                    }
                }
                .frame(width: 250)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .scaleEffect(shown ? 1 : 0.2, anchor: isMine ? .topTrailing : .topLeading)
                .opacity(shown ? 1 : 0)
                .padding(.top, 20)
            }
            .padding(.horizontal, Messages.margin)
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        }
        .onAppear { withAnimation(Messages.menuIn) { shown = true } }
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
            .frame(height: 42)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The Messages composer: a 40 pt glass "+" and a 40.33 pt glass capsule
/// whose mic turns into a 38×28 blue send capsule once there is text. The
/// bar sits 28 pt from the edges at rest and 16 pt with the keyboard up.
struct MessageComposer: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: LocalizedStringKey
    var keyboardUp = false
    @Binding var fieldWidth: CGFloat
    let send: () -> Void

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Button {} label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attachments")

            HStack(alignment: .bottom, spacing: 4) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(1...8)
                    .focused(focused)
                    .padding(.leading, 11)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("conversation.field")
                ZStack {
                    Image(systemName: "mic")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(light: 0xB4B8BF, dark: 0x636466))
                        .opacity(hasText ? 0 : 1)
                        .accessibilityHidden(true)
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 28)
                            .background(Capsule().fill(Messages.accent))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .opacity(hasText ? 1 : 0)
                    .scaleEffect(hasText ? 1 : 0.6)
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("conversation.send")
                    .disabled(!hasText)
                }
                .frame(width: 38, height: 28)
                .padding(.trailing, 6.3)
                .padding(.bottom, 6.2)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasText)
            }
            .frame(minHeight: 40.33)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20.17))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
        }
        .padding(.horizontal, keyboardUp ? 16 : 28)
        .padding(.top, 6)
        .padding(.bottom, keyboardUp ? 6 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 1.0), value: keyboardUp)
    }
}
