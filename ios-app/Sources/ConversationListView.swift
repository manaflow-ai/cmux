import SwiftUI

struct ConversationListView: View {
    @State private var conversations = fakeConversations
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showNewTask = false
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchActive = false

    var isSearching: Bool {
        isSearchFocused || !searchText.isEmpty || isSearchActive
    }

    var filteredConversations: [Conversation] {
        if searchText.isEmpty {
            return conversations
        }
        return conversations.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredConversations) { conversation in
                    NavigationLink(destination: ChatView(conversation: conversation)) {
                        ConversationRow(conversation: conversation)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            withAnimation {
                                conversations.removeAll { $0.id == conversation.id }
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            // Pin action
                        } label: {
                            Label("Pin", systemImage: "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            // Mark as unread
                        } label: {
                            Label("Unread", systemImage: "message.badge")
                        }
                        .tint(.blue)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Bottom bar: Search + Compose (iOS 26 Liquid Glass)
                GlassEffectContainer {
                    HStack(spacing: 12) {
                        // Search field with glass capsule
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField("Search", text: $searchText)
                                .focused($isSearchFocused)
                                .onChange(of: isSearchFocused) { _, newValue in
                                    if newValue {
                                        isSearchActive = true
                                    } else {
                                        DispatchQueue.main.async {
                                            if !isSearchFocused && searchText.isEmpty {
                                                isSearchActive = false
                                            }
                                        }
                                    }
                                }

                            Image(systemName: "mic.fill")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isSearchFocused = true
                            isSearchActive = true
                        }

                        // Compose or Cancel button with glass circle
                        if isSearching {
                            Button {
                                searchText = ""
                                isSearchFocused = false
                                isSearchActive = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                        } else {
                            Button {
                                showNewTask = true
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .contentShape(Rectangle())
                .onTapGesture {}
                .zIndex(1)
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Edit") {}
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink(destination: SettingsView()) {
                            Label("Settings", systemImage: "gear")
                        }
                        Button {
                            // Select messages
                        } label: {
                            Label("Select Messages", systemImage: "checkmark.circle")
                        }
                        Button {
                            // Edit pins
                        } label: {
                            Label("Edit Pins", systemImage: "pin")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showNewTask) {
                NewTaskSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

struct NewTaskSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var taskDescription = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                InstantFocusTextView(text: $taskDescription, placeholder: "Describe a coding task")
                    .frame(maxWidth: .infinity, minHeight: 200)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        // Create task
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// UITextView that becomes first responder instantly - no focus transfer needed
struct InstantFocusTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.text = text.isEmpty ? placeholder : text
        textView.textColor = text.isEmpty ? .tertiaryLabel : .label
        // Become first responder immediately - keyboard appears with sheet
        textView.becomeFirstResponder()
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Only update if text changed externally
        if uiView.text != text && !text.isEmpty {
            uiView.text = text
            uiView.textColor = .label
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, placeholder: placeholder)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        var placeholder: String

        init(text: Binding<String>, placeholder: String) {
            self._text = text
            self.placeholder = placeholder
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if textView.textColor == .tertiaryLabel {
                textView.text = ""
                textView.textColor = .label
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if textView.text.isEmpty {
                textView.text = placeholder
                textView.textColor = .tertiaryLabel
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.name)
                    .font(.headline)

                Spacer()

                Text(formatTimestamp(conversation.timestamp))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(conversation.lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Spacer()

                if conversation.unreadCount > 0 {
                    Text("\(conversation.unreadCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd/yy"
            return formatter.string(from: date)
        }
    }
}

#Preview {
    ConversationListView()
}
