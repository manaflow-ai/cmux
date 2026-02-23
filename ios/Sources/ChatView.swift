import SwiftUI
import UIKit

extension Notification.Name {
    static let toolCallSheetWillPresent = Notification.Name("cmux.toolCallSheetWillPresent")
    static let toolCallSheetDidDismiss = Notification.Name("cmux.toolCallSheetDidDismiss")
}

struct ChatView: View {
    let conversation: ConvexConversation
    #if DEBUG
    @State private var didCopyLogs = false
    @State private var didCopyMetadata = false
    #endif

    init(conversation: ConvexConversation) {
        self.conversation = conversation
    }

    var body: some View {
        ChatFix1MainView(conversationId: conversation._id.rawValue, providerId: conversation.providerId)
            .navigationTitle(conversation.providerDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Copy Logs") {
                            UIPasteboard.general.string = DebugLog.read()
                            didCopyLogs = true
                        }
                        .accessibilityIdentifier("chat.copyLogs")

                        Button("Copy Metadata") {
                            UIPasteboard.general.string = buildMetadataString(
                                conversationId: conversation._id.rawValue,
                                providerId: conversation.providerId,
                                providerName: conversation.providerDisplayName
                            )
                            didCopyMetadata = true
                        }
                        .accessibilityIdentifier("chat.copyMetadata")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("chat.menu")
                }
            }
            .alert("Logs copied", isPresented: $didCopyLogs) {
                Button("OK", role: .cancel) {}
            }
            .alert("Metadata copied", isPresented: $didCopyMetadata) {
                Button("OK", role: .cancel) {}
            }
            #endif
    }
}

/// ChatView that takes only a conversation ID (for navigation from new task creation)
struct ChatViewById: View {
    let conversationId: String
    var providerId: String = "claude"
    #if DEBUG
    @State private var didCopyLogs = false
    @State private var didCopyMetadata = false
    #endif

    var body: some View {
        ChatFix1MainView(conversationId: conversationId, providerId: providerId)
            .navigationTitle("Task")
            .navigationBarTitleDisplayMode(.inline)
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Copy Logs") {
                            UIPasteboard.general.string = DebugLog.read()
                            didCopyLogs = true
                        }
                        .accessibilityIdentifier("chat.copyLogs")

                        Button("Copy Metadata") {
                            UIPasteboard.general.string = buildMetadataString(
                                conversationId: conversationId,
                                providerId: providerId,
                                providerName: ""
                            )
                            didCopyMetadata = true
                        }
                        .accessibilityIdentifier("chat.copyMetadata")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("chat.menu")
                }
            }
            .alert("Logs copied", isPresented: $didCopyLogs) {
                Button("OK", role: .cancel) {}
            }
            .alert("Metadata copied", isPresented: $didCopyMetadata) {
                Button("OK", role: .cancel) {}
            }
            #endif
    }
}

#if DEBUG
private func buildMetadataString(conversationId: String, providerId: String, providerName: String) -> String {
    var lines = [String]()
    lines.append("Conversation ID: \(conversationId)")
    lines.append("Provider ID: \(providerId)")
    if !providerName.isEmpty {
        lines.append("Provider Name: \(providerName)")
    }
    return lines.joined(separator: "\n")
}
#endif

// MARK: - Message Bubble

struct ChatMessageRow: Identifiable {
    let id: Message.ID
    let message: Message
    let showTail: Bool
    let showTimestamp: Bool

    init(message: Message, showTail: Bool, showTimestamp: Bool) {
        self.id = message.id
        self.message = message
        self.showTail = showTail
        self.showTimestamp = showTimestamp
    }
}

struct MessageBubble: View {
    let message: Message
    let showTail: Bool
    let showTimestamp: Bool
    let markdownLayout: MarkdownLayoutConfig

    init(
        message: Message,
        showTail: Bool,
        showTimestamp: Bool,
        markdownLayout: MarkdownLayoutConfig = .default
    ) {
        self.message = message
        self.showTail = showTail
        self.showTimestamp = showTimestamp
        self.markdownLayout = markdownLayout
    }

    var body: some View {
        VStack(spacing: 4) {
            if showTimestamp {
                Text(formatTimestamp(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            if message.isFromMe {
                HStack(alignment: .bottom, spacing: 4) {
                    Spacer(minLength: 60)
                    Text(message.content)
                        .accessibilityIdentifier("chat.messageBody.\(message.id)")
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            } else {
                AssistantMessageContentView(
                    message: message,
                    markdownLayout: markdownLayout
                )
            }

            // Delivery status for sent messages (only on last message)
            if message.isFromMe && showTail {
                HStack {
                    Spacer()
                    Text(statusText(message.status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("chat.message.\(message.id)")
        .accessibilityLabel(message.content)
    }

    func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "h:mm a"
            return "Yesterday " + formatter.string(from: date)
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }

    func statusText(_ status: MessageStatus) -> String {
        switch status {
        case .sending: return "Sending..."
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
        }
    }
}

// MARK: - Tool Calls

private struct AssistantMessageContentView: View {
    let message: Message
    let markdownLayout: MarkdownLayoutConfig
    @State private var selectedToolCall: MessageToolCall?

    var body: some View {
        let items = resolvedItems()
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                switch item.kind {
                case .text(let text):
                    AssistantMarkdownView(text: text, layout: markdownLayout)
                        .accessibilityIdentifier("chat.messageBody.\(message.id)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .toolCall(let toolCall):
                    Button {
                        if selectedToolCall == nil {
                            NotificationCenter.default.post(name: .toolCallSheetWillPresent, object: nil)
                        }
                        selectedToolCall = toolCall
                    } label: {
                        ToolCallRow(toolCall: toolCall)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.toolCall.\(toolCall.id)")
                }
            }
        }
        .padding(.top, markdownLayout.assistantMessageTopPadding)
        .padding(.bottom, markdownLayout.assistantMessageBottomPadding)
        .sheet(item: $selectedToolCall) { toolCall in
            ToolCallDetailSheet(toolCall: toolCall)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: selectedToolCall) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                NotificationCenter.default.post(name: .toolCallSheetDidDismiss, object: nil)
            }
        }
    }

    private func resolvedItems() -> [AssistantMessageItem] {
        if !message.assistantItems.isEmpty {
            return message.assistantItems
        }
        if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message.toolCalls.map { toolCall in
                AssistantMessageItem(id: "\(message.id)-tool-\(toolCall.id)", kind: .toolCall(toolCall))
            }
        }
        var items = [AssistantMessageItem]()
        items.append(AssistantMessageItem(id: "\(message.id)-text", kind: .text(message.content)))
        items.append(contentsOf: message.toolCalls.map { toolCall in
            AssistantMessageItem(id: "\(message.id)-tool-\(toolCall.id)", kind: .toolCall(toolCall))
        })
        return items
    }
}

private struct ToolCallRow: View {
    let toolCall: MessageToolCall

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toolCall.status.symbolName)
                .foregroundStyle(toolCall.status.tintColor)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolCall.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(toolCall.status.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }
}

private struct ToolCallDetailSheet: View {
    let toolCall: MessageToolCall

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailRow(title: "Tool", value: toolCall.name)
                    detailRow(title: "Status", value: toolCall.status.label)
                    detailRow(title: "ID", value: toolCall.id)

                    payloadSection(
                        title: "Arguments",
                        value: ToolCallPayloadFormatter.prettify(toolCall.arguments)
                    )

                    if let result = toolCall.result, !result.isEmpty {
                        payloadSection(
                            title: "Result",
                            value: ToolCallPayloadFormatter.prettify(result)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("Tool Call")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private func payloadSection(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(value.isEmpty ? " " : value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 1)
            )
        }
    }
}

private extension MessageToolCallStatus {
    var symbolName: String {
        switch self {
        case .pending:
            return "clock"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var tintColor: Color {
        switch self {
        case .pending:
            return .orange
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}

// MARK: - Message Input Bar

struct MessageInputBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    private let inputHeight: CGFloat = 42
    private let maxInputHeight: CGFloat = 120

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 12) {
                // Plus button with glass circle
                Button {} label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(width: inputHeight, height: inputHeight)
                .glassEffect(.regular.interactive(), in: .circle)

                // Text field with glass capsule
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("iMessage", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused(isFocused)

                    // Fixed size container to prevent layout shift
                    ZStack {
                        if text.isEmpty {
                            Image(systemName: "mic.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        } else {
                            Button(action: onSend) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: inputHeight, maxHeight: maxInputHeight, alignment: .bottom)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(Rectangle())
                .onTapGesture {
                    isFocused.wrappedValue = true
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}

#Preview {
    NavigationStack {
        // Preview with mock data
        ChatFix1MainView(conversationId: "preview", providerId: "claude")
            .navigationTitle("Claude")
            .navigationBarTitleDisplayMode(.inline)
    }
}
