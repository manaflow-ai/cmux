import SwiftUI

/// The attention feed: every event that needs you, as posts in a timeline.
struct FeedScreen: View {
    let app: AppModel
    @State private var openTerminal: DaemonTab?
    @State private var position = ScrollPosition(edge: .top)
    @State private var scrolledDown = false
    @State private var newPosts = 0
    @State private var topID: String?

    private var store: FeedStore { app.feed }

    var body: some View {
        Group {
            if store.visible.isEmpty {
                if store.items.isEmpty, let connection = app.connection, connection.phase != .connected {
                    if case .offline(let message) = connection.phase {
                        OfflineState(hostName: connection.host.name, message: message) { app.reconnect() }
                    } else {
                        FeedSkeleton()
                    }
                } else {
                    emptyState
                }
            } else {
                timeline
            }
        }
        .background(Theme.background)
        .navigationTitle(String(localized: "Feed"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { filterMenu }
        }
        .navigationDestination(item: $openTerminal) { tab in
            if let connection = app.connection { TerminalScreen(connection: connection, tab: tab) }
        }
    }

    private var timeline: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.visible) { item in
                    FeedPostView(item: item, store: store) { open(item) }
                        .id(item.id)
                    Divider().padding(.leading, 68)
                }
            }
            .padding(.bottom, 24)
            .scrollTargetLayout()
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .refreshable {
            Haptics.soft()
            await app.connection?.refresh()
            await store.backfill()
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 120
        } action: { _, down in
            scrolledDown = down
            if !down { newPosts = 0 }
        }
        .onChange(of: store.visible.first?.id, initial: true) { _, first in
            defer { topID = first }
            guard let previous = topID, let first, first != previous else { return }
            if scrolledDown, let index = store.visible.firstIndex(where: { $0.id == previous }) {
                newPosts += index
                Haptics.soft()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let connection = app.connection, let kind = connection.phase.statusKind(hostName: connection.host.name) {
                    ConnectionStatusCapsule(kind: kind, onRetry: { app.reconnect() })
                        .padding(.vertical, 6)
                }
                if newPosts > 0 && scrolledDown {
                    Button {
                        Haptics.tap()
                        withAnimation(.smooth(duration: 0.4)) { position.scrollTo(edge: .top) }
                        newPosts = 0
                    } label: {
                        Label(newPosts == 1 ? String(localized: "1 new post") : String(localized: "\(newPosts) new posts"),
                              systemImage: "arrow.up")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("feed.newPosts")
                }
            }
            .animation(.smooth(duration: 0.3), value: newPosts > 0 && scrolledDown)
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker(String(localized: "Show"), selection: Bindable(store).filter) {
                ForEach(FeedStore.Filter.allCases) { filter in
                    Label(filter.title, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.inline)
            Section {
                Button { Haptics.success(); store.markAllRead() } label: {
                    Label(String(localized: "Mark All as Read"), systemImage: "checkmark.circle")
                }
                .disabled(store.unreadCount == 0)
            }
        } label: {
            Image(systemName: store.filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(String(localized: "Filter: \(store.filter.title)"))
        .accessibilityIdentifier("feed.filter")
    }

    private func open(_ item: FeedItem) {
        store.markRead(item)
        guard let surface = item.surface, let tab = app.connection?.tab(surface: surface) else { return }
        Haptics.selection()
        openTerminal = tab
    }

    @ViewBuilder
    private var emptyState: some View {
        switch store.filter {
        case .attention:
            StateMessageView(systemImage: "checkmark.bubble", title: String(localized: "Nothing needs you"),
                             message: String(localized: "Questions and permission requests from your agents show up here.")) {
                Button(String(localized: "Show all posts")) { store.filter = .all }
                    .buttonStyle(.primaryCapsule)
            }
        case .done:
            StateMessageView(systemImage: "flag.checkered", title: String(localized: "Nothing finished yet"),
                             message: String(localized: "When an agent finishes a task, it shows up here.")) {
                Button(String(localized: "Show all posts")) { store.filter = .all }
                    .buttonStyle(.primaryCapsule)
            }
        case .all:
            StateMessageView(systemImage: "bell", title: String(localized: "All caught up"),
                             message: String(localized: "When an agent asks a question, needs permission or finishes, it shows up here."))
        }
    }
}

extension FeedStore.Filter {
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .attention: "exclamationmark.bubble"
        case .done: "checkmark.circle"
        }
    }
}

/// Post-shaped placeholders while the feed loads.
struct FeedSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(Color.primary.opacity(0.08)).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 9) {
                        SkeletonBar(width: 140, height: 11)
                        SkeletonBar(height: 10)
                        SkeletonBar(width: [220, 180, 240, 160][index], height: 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                Divider().padding(.leading, 68)
            }
            Spacer()
        }
        .shimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading feed"))
    }
}

/// X-style compact relative time: "now", "4m", "3h", "2d", then a date.
func compactRelativeTime(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return String(localized: "now")
    case ..<3600: return String(localized: "\(Int(seconds / 60))m")
    case ..<86400: return String(localized: "\(Int(seconds / 3600))h")
    case ..<(7 * 86400): return String(localized: "\(Int(seconds / 86400))d")
    default: return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// One post: avatar, author line, the prompt it answers as an iMessage
/// bubble, the agent's text, one-tap choices, and an inline reply.
struct FeedPostView: View {
    let item: FeedItem
    let store: FeedStore
    let onOpen: () -> Void

    @State private var expanded = false
    @State private var bodyHeight: CGFloat
    @State private var replying = false
    @State private var replyText = ""
    @State private var sending = false
    @State private var replyError: String?
    @FocusState private var replyFocused: Bool

    private let collapsedHeight: CGFloat = 132

    init(item: FeedItem, store: FeedStore, onOpen: @escaping () -> Void) {
        self.item = item
        self.store = store
        self.onOpen = onOpen
        _bodyHeight = State(initialValue: MarkdownHeightCache.height(for: item.body) ?? MarkdownHeightCache.estimate(for: item.body))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(agent: item.agent, unread: !item.read)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                header
                if let quote = item.quote, !quote.isEmpty {
                    QuoteBubble(text: quote)
                }
                if !item.title.isEmpty, item.body.isEmpty || !item.body.contains(item.title) {
                    Text(item.title).font(.body.weight(.medium))
                }
                if !item.body.isEmpty { bodyText }
                if !item.options.isEmpty, item.answered == nil { options }
                if let answered = item.answered { answeredRow(answered) }
                actions
                if replying { replyField }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(item.read ? Color.clear : Color.primary.opacity(0.03))
        .contentShape(.rect)
        .onTapGesture { onOpen() }
        .contextMenu {
            // Timestamp header, like ChatGPT's message menu.
            Section(item.createdAt.formatted(date: .abbreviated, time: .shortened)) {
                Button { UIPasteboard.general.string = item.body.isEmpty ? item.title : item.body } label: {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                }
                if let quote = item.quote, !quote.isEmpty {
                    Button { UIPasteboard.general.string = quote } label: {
                        Label(String(localized: "Copy Prompt"), systemImage: "text.quote")
                    }
                }
                if !item.read {
                    Button { store.markRead(item) } label: { Label(String(localized: "Mark as Read"), systemImage: "checkmark.circle") }
                }
                Button(action: onOpen) { Label(String(localized: "Open Terminal"), systemImage: "terminal") }
            }
        }
        .animation(.smooth(duration: 0.25), value: replying)
        .animation(.smooth(duration: 0.25), value: expanded)
        .accessibilityIdentifier("feed.post")
    }

    private var header: some View {
        HStack(spacing: 4) {
            let author = item.agent.map(FeedStore.displayName) ?? String(localized: "cmux")
            Text(author).font(.subheadline.weight(.semibold))
                // The unread dot sits on the (hidden) avatar.
                .accessibilityLabel(item.read ? author : String(localized: "\(author), unread"))
            if let workspace = item.workspace {
                Text("· \(workspace)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(String(localized: "in \(workspace)"))
            }
            Spacer(minLength: 4)
            if item.needsAttention {
                Text(item.kind == .permission ? String(localized: "Permission") : String(localized: "Question"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.attention.opacity(0.18)))
                    .foregroundStyle(Theme.attention)
            } else if item.kind == .error {
                Text(String(localized: "Error"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.danger.opacity(0.16)))
                    .foregroundStyle(Theme.danger)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(compactRelativeTime(item.createdAt, now: context.date))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityLabel(item.createdAt.formatted(.relative(presentation: .named)))
        }
    }

    private var bodyText: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The page keeps its full height and the post clips it, so Read
            // more only moves the clip: the rest is already painted (growing
            // the web view itself showed blank tiles while it expanded).
            MarkdownWebView(markdown: item.body, contentHeight: $bodyHeight)
                .frame(height: bodyHeight)
                .frame(height: expanded ? bodyHeight : min(bodyHeight, collapsedHeight), alignment: .top)
                .clipped()
                .mask(alignment: .top) {
                    LinearGradient(
                        stops: needsMore && !expanded
                            ? [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)]
                            : [.init(color: .black, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
                .allowsHitTesting(expanded)
            if needsMore {
                Button(expanded ? String(localized: "Show less") : String(localized: "Read more")) {
                    withAnimation(.smooth(duration: 0.3)) { expanded.toggle() }
                }
                .contentTransition(.opacity)
                    .font(.subheadline.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
            }
        }
    }

    private var needsMore: Bool { bodyHeight > collapsedHeight + 8 }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.options) { option in
                Button {
                    Task {
                        do { try await store.answer(item, option: option) } catch { Haptics.warning() }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(option.key).font(.footnote.monospacedDigit().weight(.semibold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                        Text(option.label).font(.subheadline).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bubbleIncoming))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.option.\(option.key)")
            }
        }
    }

    private func answeredRow(_ answer: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            Text(String(localized: "You replied: \(answer)")).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var actions: some View {
        HStack(spacing: 22) {
            Button { replying.toggle(); replyFocused = replying } label: {
                Label(String(localized: "Reply"), systemImage: "arrowshape.turn.up.left")
            }
            .accessibilityIdentifier("feed.reply")
            Button(action: onOpen) { Label(String(localized: "Open"), systemImage: "terminal") }
            if !item.read {
                Button { store.markRead(item) } label: { Label(String(localized: "Read"), systemImage: "checkmark") }
            }
            Spacer()
        }
        .labelStyle(.titleAndIcon)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var canSendReply: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private func sendReply() {
        let text = replyText
        sending = true
        replyError = nil
        Task {
            defer { sending = false }
            do {
                try await store.reply(item, text: text)
                replyText = ""
                replying = false
            } catch {
                // Keep the draft; say why it didn't go.
                replyError = error.localizedDescription
                Haptics.warning()
            }
        }
    }

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Reply to \(item.agent.map(FeedStore.displayName) ?? "agent")"), text: $replyText, axis: .vertical)
                .lineLimit(1...5)
                .focused($replyFocused)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.15)))
                .accessibilityIdentifier("feed.replyField")
                // Hardware Return sends (Shift-Return adds a line), as in
                // the composer.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    if canSendReply { sendReply() }
                    return .handled
                }
            Button(action: sendReply) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .disabled(!canSendReply)
            .opacity(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .accessibilityIdentifier("feed.replySend")
        }
        .overlay(alignment: .bottomLeading) {
            if let replyError {
                Label(replyError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Theme.danger)
                    .alignmentGuide(.bottom) { $0[.top] - 4 }
                    .padding(.leading, 14)
            }
        }
        .padding(.bottom, replyError == nil ? 0 : 20)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The user's prompt as an outgoing iMessage bubble with a tail.
struct QuoteBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .lineLimit(4)
            .padding(.leading, 13)
            .padding(.trailing, 13 + BubbleShape.tailWidth)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(BubbleShape().fill(Theme.bubbleOutgoing))
            // iMessage keeps a bubble to about three quarters of the width.
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.78 }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(String(localized: "You asked: \(text)"))
    }
}

/// iMessage outgoing bubble: one continuous outline, rounded corners and a
/// tail that flicks out of the bottom-right corner and curls back under.
/// (The old shape added the tail as a second subpath winding the other way,
/// which punched a white notch into the corner.)
struct BubbleShape: Shape {
    static let tailWidth: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let right = w - Self.tailWidth
        let r = min(17, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: r, y: 0))
        p.addLine(to: CGPoint(x: right - r, y: 0))
        p.addArc(tangent1End: CGPoint(x: right, y: 0), tangent2End: CGPoint(x: right, y: h), radius: r)
        p.addLine(to: CGPoint(x: right, y: max(r, h - 10)))
        // Tail: out to the tip at the bottom-right corner…
        p.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: right, y: h - 3), control2: CGPoint(x: w - 1.5, y: h))
        // …and back under the bubble.
        p.addCurve(to: CGPoint(x: right - 7, y: h - 3), control1: CGPoint(x: w - 4, y: h + 0.4), control2: CGPoint(x: right - 3.5, y: h - 1))
        p.addCurve(to: CGPoint(x: right - min(r, 16), y: h), control1: CGPoint(x: right - 10, y: h - 0.5), control2: CGPoint(x: right - 13, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: 0), radius: r)
        p.addLine(to: CGPoint(x: 0, y: r))
        p.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: w, y: 0), radius: r)
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A circular agent avatar with an unread dot.
struct AgentAvatar: View {
    let agent: String?
    var unread = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(background)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            if unread {
                Circle().fill(Color.primary).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Theme.background, lineWidth: 2))
            }
        }
    }

    private var symbol: String {
        switch agent?.lowercased() {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "sparkle"
        default: "terminal"
        }
    }

    private var background: Color {
        switch agent?.lowercased() {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": Color(white: 0.22)
        case "gemini": Color(red: 0.30, green: 0.45, blue: 0.85)
        default: Color(white: 0.3)
        }
    }
}
