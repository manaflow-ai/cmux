import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    @State private var messages: [Message]
    @State private var newMessage = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool

    init(conversation: Conversation) {
        self.conversation = conversation
        self._messages = State(initialValue: conversation.messages)
    }

    var body: some View {
        // Messages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            showTail: shouldShowTail(at: index),
                            showTimestamp: shouldShowTimestamp(at: index)
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollProxy = proxy
                scrollToBottom(animated: false)
            }
            .onChange(of: messages.count) {
                scrollToBottom(animated: true)
            }
            .onTapGesture {
                isInputFocused = false
            }
            .safeAreaInset(edge: .bottom) {
                MessageInputBar(text: $newMessage, onSend: sendMessage)
                    .focused($isInputFocused)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(conversation.name)
                        .font(.headline)
                    if conversation.isOnline {
                        Text("online")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    Button {} label: {
                        Image(systemName: "video")
                    }
                    Button {} label: {
                        Image(systemName: "phone")
                    }
                }
            }
        }
    }

    // Show tail only on last message in a sequence from same sender
    func shouldShowTail(at index: Int) -> Bool {
        if index == messages.count - 1 { return true }
        return messages[index].isFromMe != messages[index + 1].isFromMe
    }

    // Show timestamp when there's a gap or sender changes
    func shouldShowTimestamp(at index: Int) -> Bool {
        if index == 0 { return true }
        let current = messages[index]
        let previous = messages[index - 1]

        // Show if sender changed
        if current.isFromMe != previous.isFromMe { return true }

        // Show if more than 5 minutes gap
        let gap = current.timestamp.timeIntervalSince(previous.timestamp)
        return gap > 300
    }

    func sendMessage() {
        guard !newMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let message = Message(
            content: newMessage,
            timestamp: .now,
            isFromMe: true,
            status: .sent
        )

        withAnimation(.easeInOut(duration: 0.2)) {
            messages.append(message)
        }
        newMessage = ""

        // Simulate reply after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let reply = Message(
                content: generateReply(),
                timestamp: .now,
                isFromMe: false,
                status: .delivered
            )
            withAnimation(.easeInOut(duration: 0.2)) {
                messages.append(reply)
            }
        }
    }

    func scrollToBottom(animated: Bool) {
        guard let lastMessage = messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
            }
        } else {
            scrollProxy?.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }

    func generateReply() -> String {
        let replies = [
            "Got it! 👍",
            "Makes sense, I'll look into that.",
            "Sure thing!",
            "Let me check and get back to you.",
            "Sounds good!",
            "On it! 🚀",
            "Perfect, thanks for letting me know.",
        ]
        return replies.randomElement()!
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

struct MessageInputBar: View {
    @Binding var text: String
    let onSend: () -> Void

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
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: .circle)

                // Text field with glass capsule
                HStack(spacing: 8) {
                    TextField("iMessage", text: $text, axis: .vertical)
                        .lineLimit(1...5)

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
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
    }
}

#Preview {
    NavigationStack {
        ChatView(conversation: fakeConversations[0])
    }
}
