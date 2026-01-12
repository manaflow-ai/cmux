import SwiftUI
import UIKit

struct ChatView: View {
    let conversation: Conversation

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    var body: some View {
        ChatFix1MainView(conversation: conversation)
            .navigationTitle(conversation.name)
            .navigationBarTitleDisplayMode(.inline)
    }

}

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

    var body: some View {
        VStack(spacing: 4) {
            if showTimestamp {
                Text(formatTimestamp(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            HStack(alignment: .bottom, spacing: 4) {
                if message.isFromMe { Spacer(minLength: 60) }

                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isFromMe ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(message.isFromMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if !message.isFromMe { Spacer(minLength: 60) }
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

// MARK: - Message Input Bar

struct MessageInputBar: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    private let inputHeight: CGFloat = 42

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
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
                HStack(spacing: 8) {
                    TextField("iMessage", text: $text, axis: .vertical)
                        .lineLimit(1...5)
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
                .frame(height: inputHeight)
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
        ChatView(conversation: fakeConversations[0])
    }
}
