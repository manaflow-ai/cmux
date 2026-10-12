import SwiftUI

/// The attention feed: every event that needs you, as posts in a timeline.
struct FeedScreen: View {
    let app: AppModel
    @State private var openTerminal: DaemonTab?

    private var store: FeedStore { app.feed }

    var body: some View {
        Group {
            if store.visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.visible) { item in
                            FeedPostView(item: item, store: store) { open(item) }
                            Divider().padding(.leading, 68)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
                .refreshable { await app.connection?.refresh(); await store.backfill() }
            }
        }
        .background(Theme.background)
        .navigationTitle(String(localized: "Feed"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(String(localized: "Show"), selection: Bindable(store).filter) {
                        ForEach(FeedStore.Filter.allCases) { filter in Text(filter.title).tag(filter) }
                    }
                    Divider()
                    Button { store.markAllRead() } label: { Label(String(localized: "Mark All as Read"), systemImage: "checkmark.circle") }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityIdentifier("feed.filter")
            }
        }
        .navigationDestination(item: $openTerminal) { tab in
            if let connection = app.connection { TerminalScreen(connection: connection, tab: tab) }
        }
    }

    private func open(_ item: FeedItem) {
        store.markRead(item)
        guard let surface = item.surface, let tab = app.connection?.tab(surface: surface) else { return }
        openTerminal = tab
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.badge").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(store.filter == .attention ? String(localized: "Nothing needs you") : String(localized: "All caught up"))
                .font(.headline)
            Text(String(localized: "When an agent asks a question, needs permission or finishes, it shows up here."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One post: avatar, author line, the prompt it answers as an iMessage
/// bubble, the agent's text, one-tap choices, and an inline reply.
struct FeedPostView: View {
    let item: FeedItem
    let store: FeedStore
    let onOpen: () -> Void

    @State private var expanded = false
    @State private var bodyHeight: CGFloat = 20
    @State private var replying = false
    @State private var replyText = ""
    @State private var sending = false
    @FocusState private var replyFocused: Bool

    private let collapsedHeight: CGFloat = 132

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(agent: item.agent, unread: !item.read)
            VStack(alignment: .leading, spacing: 8) {
                header
                if let quote = item.quote, !quote.isEmpty {
                    QuoteBubble(text: quote).frame(maxWidth: .infinity, alignment: .trailing)
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
        .padding(.vertical, 14)
        .contentShape(.rect)
        .onTapGesture { onOpen() }
        .contextMenu {
            Button { UIPasteboard.general.string = item.body } label: { Label(String(localized: "Copy"), systemImage: "doc.on.doc") }
            Button { store.markRead(item) } label: { Label(String(localized: "Mark as Read"), systemImage: "checkmark.circle") }
            Button(action: onOpen) { Label(String(localized: "Open Terminal"), systemImage: "terminal") }
        }
        .animation(.smooth(duration: 0.25), value: replying)
        .animation(.smooth(duration: 0.25), value: expanded)
        .accessibilityIdentifier("feed.post")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(item.agent.map(FeedStore.displayName) ?? String(localized: "cmux")).font(.subheadline.weight(.semibold))
            if let workspace = item.workspace {
                Text("· \(workspace)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.needsAttention {
                Text(item.kind == .permission ? String(localized: "Permission") : String(localized: "Question"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.attention.opacity(0.18)))
                    .foregroundStyle(Theme.attention)
            }
            Text(item.createdAt, format: .relative(presentation: .named, unitsStyle: .narrow))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var bodyText: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownWebView(markdown: item.body, contentHeight: $bodyHeight)
                .frame(height: expanded ? bodyHeight : min(bodyHeight, collapsedHeight))
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
                Button(expanded ? String(localized: "Show less") : String(localized: "Read more")) { expanded.toggle() }
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
                    Task { try? await store.answer(item, option: option) }
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

    private var replyField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Reply to \(item.agent.map(FeedStore.displayName) ?? "agent")"), text: $replyText, axis: .vertical)
                .lineLimit(1...5)
                .focused($replyFocused)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.15)))
                .accessibilityIdentifier("feed.replyField")
            Button {
                let text = replyText
                sending = true
                Task {
                    defer { sending = false }
                    try? await store.reply(item, text: text)
                    replyText = ""
                    replying = false
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            .opacity(replyText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            .accessibilityIdentifier("feed.replySend")
        }
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
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(.primary)
            .background(BubbleShape().fill(Theme.bubbleOutgoing))
            .padding(.trailing, 2)
            .frame(maxWidth: 300, alignment: .trailing)
            .accessibilityLabel(String(localized: "You asked: \(text)"))
    }
}

/// iMessage bubble: rounded rect with a curled tail at the bottom right.
struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = min(18, rect.height / 2)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), cornerSize: CGSize(width: r, height: r), style: .continuous)
        // Tail.
        let x = rect.maxX, y = rect.maxY
        path.move(to: CGPoint(x: x - 10, y: y - 6))
        path.addCurve(to: CGPoint(x: x + 5, y: y), control1: CGPoint(x: x - 4, y: y - 1), control2: CGPoint(x: x + 1, y: y))
        path.addCurve(to: CGPoint(x: x - 2, y: y - 12), control1: CGPoint(x: x - 2, y: y - 3), control2: CGPoint(x: x - 2, y: y - 8))
        path.closeSubpath()
        return path
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
