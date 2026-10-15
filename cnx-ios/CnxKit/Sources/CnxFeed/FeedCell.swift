#if os(iOS)
import CmuxAgentQuestion
import CnxAgentChat
import CnxDesign
import CnxMarkdown
import SwiftUI
import UIKit

/// SPEC 8.2 Feed cell: avatar column, header, quote bubble, status chip,
/// web-rendered markdown capped at 8 lines with Show more, inline answer UI,
/// inline reply composer, and the footer actions.
struct FeedCell: View {
    let item: FeedItem
    let store: FeedStore
    let open: () -> Void
    @Binding var expanded: Bool
    @State private var contentHeight: CGFloat?
    @State private var replying = false
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @State private var copied = false
    #if DEBUG
    private let director = DemoDirector.shared
    #endif

    static let collapsedHeight: CGFloat = 224

    init(item: FeedItem, store: FeedStore, open: @escaping () -> Void, expanded: Binding<Bool>) {
        self.item = item
        self.store = store
        self.open = open
        _expanded = expanded
        _contentHeight = State(initialValue: WebMarkdownRenderer.shared.cachedHeight(markdown: item.markdown, style: .body))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(harness: item.harness, size: 40)
                .overlay(alignment: .topTrailing) {
                    if !item.isRead {
                        Circle().fill(Color.primary).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Color.cnxBackground, lineWidth: 2))
                            .offset(x: 2, y: -2)
                            .accessibilityLabel("Unread")
                    }
                }
            VStack(alignment: .leading, spacing: 8) {
                header
                if let quote = item.quote {
                    QuoteBubble(quote: quote)
                        .padding(.bottom, -4)
                }
                statusChip
                bodyView
                inlineAnswer
                if let error = item.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    // The answer was refused (an unpaired phone, or Face ID cancelled): offer the decline.
                    if case .question(let question) = item.kind, question.isPending {
                        Button("Decline", role: .destructive) {
                            withAnimation(.cnxSmooth) { store.decline(item.id) }
                        }
                        .buttonStyle(.bordered)
                        .transition(.opacity)
                    }
                }
                if !item.replies.isEmpty {
                    replies
                }
                if replying {
                    replyComposer
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                footer
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .contextMenu { menuItems }
        #if DEBUG
        .onChange(of: director.serial) { runDemoCommand() }
        #endif
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 4) {
            Text(item.agentName).font(.subheadline.weight(.semibold)).lineLimit(1).layoutPriority(2)
            Text("· \(item.workspaceTitle)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(0)
            Text("· \(relativeTime)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1).fixedSize()
            Spacer(minLength: 4)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 24)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Event actions")
        }
    }

    private var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(item.createdAt))
        switch seconds {
        case ..<45: return "now"
        case ..<3600: return "\(max(1, seconds / 60))m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Section(item.createdAt.formatted(.dateTime.weekday(.wide).hour().minute())) {
            Button("Open tab", systemImage: "arrow.up.right.square", action: open)
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.markdown }
            // Everything the trailing swipe leaves out lives here (SPEC swipe rules).
            if item.isRead {
                Button("Mark as unread", systemImage: "envelope.badge") { store.markUnread(item.id) }
            } else {
                Button("Mark as read", systemImage: "envelope.open") { store.markRead(item.id) }
            }
            Button("Done", systemImage: "checkmark") {
                withAnimation(.cnxSmooth) { store.markDone(item.id) }
            }
            Button("Mute this workspace", systemImage: "bell.slash") {
                withAnimation(.cnxSmooth) { _ = store.mutedWorkspaces.insert(item.workspaceID) }
            }
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        switch item.kind {
        case .permission where item.resolution == nil:
            chip(dot: .cnxWarning, symbol: nil, text: "Needs permission")
        case .question(let question) where question.isPending:
            chip(dot: nil, symbol: "questionmark.bubble", text: "Question")
        case .failed:
            chip(dot: .cnxDanger, symbol: nil, text: "Failed")
        default:
            EmptyView()
        }
    }

    private func chip(dot: Color?, symbol: String?, text: String) -> some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            if let symbol { Image(systemName: symbol).font(.caption) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.cnxFill, in: .capsule)
    }

    private var isOverflowing: Bool { (contentHeight ?? 0) > Self.collapsedHeight + 28 }

    private var bodyView: some View {
        VStack(alignment: .leading, spacing: 6) {
            WebMarkdownView(
                markdown: item.markdown, style: .body,
                collapsedHeight: Self.collapsedHeight, isExpanded: expanded || !isOverflowing
            ) { height in
                contentHeight = height
            }
            .overlay(alignment: .bottom) {
                if isOverflowing, !expanded {
                    LinearGradient(colors: [Color.cnxBackground.opacity(0), Color.cnxBackground], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            if isOverflowing {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.cnxSmooth) { expanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .frame(minHeight: 28)
                .contentTransition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var inlineAnswer: some View {
        switch item.kind {
        case .question(let question):
            QuestionCard(question: question, showsHeader: false) { answer in
                withAnimation(.cnxSmooth) { store.answer(item.id, answer: answer) }
            }
        case .permission(let request):
            if let resolution = item.resolution {
                Label(resolution, systemImage: resolution.hasPrefix("Denied") ? "xmark.circle" : "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if let pending = item.pending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(pending)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("feed.permission.pending")
                .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let command = request.toolCall.command {
                        CodeCard(language: "bash", code: command, title: "Command", maxHeight: 120)
                    }
                    HStack(spacing: 8) {
                        ForEach(request.options) { option in
                            Button {
                                withAnimation(.cnxSmooth) { store.respond(item.id, option: option) }
                            } label: {
                                // An allow is signed after Face ID (verify/phone-approvals.md).
                                if option.isAllow { Label(feedTitle(option), systemImage: "faceid") } else { Text(feedTitle(option)) }
                            }
                            .accessibilityHint(option.isAllow ? "Approve with Face ID" : "")
                            .buttonStyle(CnxCapsuleButtonStyle(option.kind == .allowOnce ? .primary : (option.isAllow ? .secondary : .destructive), size: .compact))
                        }
                    }
                }
                .transition(.opacity)
            }
        default:
            EmptyView()
        }
    }

    private func feedTitle(_ option: ACPPermissionOption) -> String {
        switch option.kind {
        case .allowOnce: "Allow"
        case .allowAlways: "Always"
        case .rejectOnce, .rejectAlways: "Deny"
        }
    }

    private var replies: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("You replied").font(.caption).foregroundStyle(.tertiary)
            ForEach(Array(item.replies.enumerated()), id: \.offset) { _, reply in
                Text(reply)
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.cnxBubble, in: .rect(cornerRadius: 16, style: .continuous))
                    .transition(.offset(y: 12).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var replyComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply to \(item.agentName)", text: $replyText, axis: .vertical)
                .lineLimit(1...5)
                .focused($replyFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            Button {
                sendReply()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(replyText.isEmpty ? Color(uiColor: .tertiaryLabel) : Color.cnxOnAccent)
                    .frame(width: 30, height: 30)
                    .background(replyText.isEmpty ? Color.cnxFill : Color.cnxAccent, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(5)
            .accessibilityLabel("Send reply")
        }
        .background(Color.cnxFill, in: .rect(cornerRadius: 20, style: .continuous))
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.cnxSnappy) {
            store.reply(item.id, text: text)
            replying = false
        }
        replyText = ""
        replyFocused = false
        FeedRouting.shared.sendPrompt?(item, text)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton("bubble.left", "Reply") {
                withAnimation(.cnxSmooth) { replying.toggle() }
                replyFocused = replying
            }
            Spacer()
            footerButton("arrow.up.right.square", "Open", action: open)
            Spacer()
            footerButton(copied ? "checkmark" : "doc.on.doc", "Copy") {
                UIPasteboard.general.string = item.markdown
                withAnimation(.cnxSnap) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.cnxSnap) { copied = false }
                }
            }
            Spacer()
            ShareLink(item: item.markdown) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .labelStyle(FooterLabelStyle())
            }
        }
        .frame(height: 32)
        .padding(.trailing, 8)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: copied) { _, new in new }
    }

    private func footerButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(FooterLabelStyle())
        }
        .buttonStyle(.plain)
    }

    #if DEBUG
    private func runDemoCommand() {
        guard let command = director.command else { return }
        switch command {
        case .feedExpand(let id) where id == item.id:
            withAnimation(.cnxSmooth) { expanded = true }
        case .feedReply(let id, let text) where id == item.id:
            Task {
                withAnimation(.cnxSmooth) { replying = true }
                try? await Task.sleep(for: .milliseconds(500))
                for character in text {
                    replyText.append(character)
                    try? await Task.sleep(for: .milliseconds(35))
                }
                try? await Task.sleep(for: .milliseconds(300))
                sendReply()
            }
        default:
            break
        }
    }
    #endif
}

struct FooterLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 15)).contentTransition(.symbolEffect(.replace))
            configuration.title.font(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: 32)
        .contentShape(.rect)
    }
}

/// SPEC 4.2 agent avatar: the agent glyph on `surfaceRaised`, monochrome.
struct AgentAvatar: View {
    let harness: String
    var size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color.cnxSurfaceRaised, in: .circle)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch harness {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow.rays"
        case "gemini": "sparkles"
        default: "sparkle"
        }
    }
}

/// Where Feed actions that leave the Feed go (Reply sends into the tab's agent).
@MainActor
final class FeedRouting {
    static let shared = FeedRouting()
    var sendPrompt: ((FeedItem, String) -> Void)?
}
#endif
