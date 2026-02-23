import SwiftUI

struct ConversationListView: View {
    @StateObject private var viewModel = ConversationsViewModel()
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showNewTask = false
    @State private var navigationPath = NavigationPath()
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchActive = false
    @State private var didAutoOpenConversation = false
    private let uiTestAutoOpenConversation: Bool = {
        #if DEBUG
        return UITestConfig.mockDataEnabled &&
            ProcessInfo.processInfo.environment["CMUX_UITEST_AUTO_OPEN_CONVERSATION"] == "1"
        #else
        return false
        #endif
    }()

    var isSearching: Bool {
        isSearchFocused || !searchText.isEmpty || isSearchActive
    }

    var filteredConversations: [ConvexConversation] {
        if searchText.isEmpty {
            return viewModel.conversations
        }
        return viewModel.conversations.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.providerDisplayName.localizedCaseInsensitiveContains(searchText) ||
            $0.cwd.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.isLoading {
                    ProgressView("Loading conversations...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.error {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.loadConversations() }
                        }
                    }
                } else if filteredConversations.isEmpty {
                    ContentUnavailableView {
                        Label("No Tasks", systemImage: "tray")
                    } description: {
                        Text("Create a new task to get started")
                    }
                } else {
                    conversationsList
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
                                Task {
                                    await viewModel.prewarmSandbox()
                                }
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
                            .accessibilityLabel("More")
                            .accessibilityIdentifier("conversation.menu")
                    }
                }
            }
            .sheet(isPresented: $showNewTask) {
                NewTaskSheet(viewModel: viewModel) { conversationId in
                    // Navigate to the new conversation
                    navigationPath.append(conversationId)
                }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .navigationDestination(for: String.self) { conversationId in
                // Navigate by conversation ID (from new task creation)
                ChatViewById(conversationId: conversationId)
            }
            .onChange(of: filteredConversations.count) { _, _ in
                guard uiTestAutoOpenConversation, !didAutoOpenConversation, let first = filteredConversations.first else { return }
                didAutoOpenConversation = true
                navigationPath.append(first._id.rawValue)
            }
        }
    }

    private var dotLeadingPadding: CGFloat { 12 }
    private var dotOffset: CGFloat { -5 }

    private var conversationsList: some View {
        List {
            ForEach(filteredConversations) { conversation in
                NavigationLink(destination: ChatView(conversation: conversation)) {
                    ConversationRow(
                        conversation: conversation,
                        dotLeadingPadding: dotLeadingPadding,
                        dotOffset: dotOffset
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.deleteConversation(conversation)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        Task {
                            await viewModel.togglePin(conversation)
                        }
                    } label: {
                        Label(
                            conversation.conversation.pinned == true ? "Unpin" : "Pin",
                            systemImage: conversation.conversation.pinned == true ? "pin.slash" : "pin"
                        )
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        Task {
                            if conversation.unread {
                                await viewModel.markRead(conversation)
                            } else {
                                await viewModel.markUnread(conversation)
                            }
                        }
                    } label: {
                        Label(
                            conversation.unread ? "Read" : "Unread",
                            systemImage: conversation.unread ? "message" : "message.badge"
                        )
                    }
                    .tint(.blue)
                }
            }

            if viewModel.hasMore {
                HStack {
                    Spacer()
                    if viewModel.isLoadingMore {
                        ProgressView()
                    } else {
                        Text("Loading more...")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .onAppear {
                    Task { await viewModel.loadMore() }
                }
            }
        }
    }
}

struct NewTaskSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ConversationsViewModel
    let onCreated: (String) -> Void

    @State private var taskDescription = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                InstantFocusTextView(text: $taskDescription, placeholder: "Describe a coding task")
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .disabled(isCreating)

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

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
                    .disabled(isCreating)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isCreating {
                        ProgressView()
                    } else {
                        Button("Create") {
                            createTask()
                        }
                        .fontWeight(.semibold)
                        .disabled(taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func createTask() {
        isCreating = true
        error = nil

        Task {
            do {
                let conversationId = try await viewModel.createConversation(initialMessage: taskDescription)
                await MainActor.run {
                    dismiss()
                    onCreated(conversationId)
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isCreating = false
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
    let conversation: ConvexConversation
    let dotLeadingPadding: CGFloat
    let dotOffset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.displayName)
                    .font(.headline)

                Spacer()

                Text(formatTimestamp(conversation.displayTimestamp))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(conversation.previewSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, dotLeadingPadding)
        .overlay(alignment: .leading) {
            Circle()
                .fill(Color(uiColor: .systemBlue))
                .frame(width: 8, height: 8)
                .opacity(conversation.unread ? 1 : 0)
                .offset(x: dotOffset)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.row.\(conversation.displayName)")
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
            let days = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if days < 7 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                return formatter.string(from: date)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d/yy"
                return formatter.string(from: date)
            }
        }
    }
}

#Preview {
    ConversationListView()
}
