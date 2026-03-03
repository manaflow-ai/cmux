import SwiftUI
import UIKit

private func log(_ message: String) {
    NSLog("[CMUX_CHAT_FIX1] MAIN %@", message)
}

struct ChatFix1MainView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var uiTestMessages: [Message]
    let conversationId: String
    let providerId: String
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @SwiftUI.Environment(\.displayScale) private var displayScale
    @AppStorage(DebugSettingsKeys.showChatInputTuning) private var showTuningPanel = false
    @AppStorage("debug.input.bottomInsetSingleExtra") private var bottomInsetSingleExtra: Double = 0
    @AppStorage("debug.input.bottomInsetMultiExtra") private var bottomInsetMultiExtra: Double = 4
    @AppStorage("debug.input.topInsetMultiExtra") private var topInsetMultiExtra: Double = 4
    @AppStorage("debug.input.micOffset") private var micOffset: Double = -12
    @AppStorage("debug.input.sendOffset") private var sendOffset: Double = -4
    @AppStorage("debug.input.sendXOffset") private var sendXOffset: Double = 1
    @AppStorage("debug.input.barYOffset") private var barYOffset: Double = 34
    @AppStorage("debug.input.bottomMessageGap") private var bottomMessageGap: Double = 10
    @AppStorage("debug.input.isMultiline") private var isMultilineFlag = false

    init(conversationId: String, providerId: String) {
        self.conversationId = conversationId
        self.providerId = providerId
        self._viewModel = StateObject(wrappedValue: ChatViewModel(conversationId: conversationId))
        if UITestConfig.mockDataEnabled {
            let messages = UITestMockData.messages(for: conversationId)
            self._uiTestMessages = State(initialValue: Self.convertMessages(messages))
        } else {
            self._uiTestMessages = State(initialValue: [])
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if UITestConfig.mockDataEnabled {
                Fix1MainViewController_Wrapper(
                    messages: uiTestMessages,
                    isSending: false,
                    onSend: { _ in },
                    inputBarYOffset: CGFloat(barYOffset),
                    bottomMessageGap: CGFloat(bottomMessageGap)
                )
                .ignoresSafeArea()
            } else if viewModel.isLoading {
                ProgressView("Loading messages...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                Fix1MainViewController_Wrapper(
                    messages: Self.convertMessages(viewModel.messages),
                    isSending: viewModel.isSending,
                    onSend: { text in
                        Task {
                            await viewModel.sendMessage(text)
                        }
                    },
                    inputBarYOffset: CGFloat(barYOffset),
                    bottomMessageGap: CGFloat(bottomMessageGap)
                )
                .ignoresSafeArea()
            }
            Color.clear
                .frame(height: topShimHeight)
                .accessibilityHidden(true)
            if showTuningPanel {
                ChatInputTuningPanel(
                    bottomInsetSingleExtra: $bottomInsetSingleExtra,
                    bottomInsetMultiExtra: $bottomInsetMultiExtra,
                    topInsetMultiExtra: $topInsetMultiExtra,
                    micOffset: $micOffset,
                    sendOffset: $sendOffset,
                    sendXOffset: $sendXOffset,
                    barYOffset: $barYOffset,
                    bottomMessageGap: $bottomMessageGap,
                    isMultiline: isMultilineFlag,
                    showPanel: $showTuningPanel
                )
                .padding(.top, 152)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(2)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
        .onAppear {
            viewModel.setViewVisible(true)
            viewModel.setAppActive(scenePhase == .active)
            let clampedGap = min(120, max(-20, bottomMessageGap))
            if bottomMessageGap != clampedGap {
                bottomMessageGap = clampedGap
            }
        }
        .onDisappear {
            viewModel.setViewVisible(false)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.setAppActive(newPhase == .active)
        }
    }

    private var topShimHeight: CGFloat {
        1 / displayScale
    }

    /// Convert Convex messages to the legacy Message format used by Fix1MainViewController
    private static func convertMessages(_ convexMessages: [ConvexMessage]) -> [Message] {
        convexMessages.map { msg in
            Message(
                id: msg._id.rawValue,
                content: msg.textContent,
                timestamp: msg.displayTimestamp,
                isFromMe: msg.isFromUser,
                status: .delivered,
                toolCalls: msg.toolCallItems,
                assistantItems: msg.assistantItems
            )
        }
    }
}

struct ChatFix1MainDebugMockView: View {
    @State private var messages: [Message] = ChatFix1MainDebugMockData.makeMessages()
    @State private var isSending = false
    @SwiftUI.Environment(\.displayScale) private var displayScale
    @AppStorage(DebugSettingsKeys.showChatInputTuning) private var showTuningPanel = false
    @AppStorage("debug.input.bottomInsetSingleExtra") private var bottomInsetSingleExtra: Double = 0
    @AppStorage("debug.input.bottomInsetMultiExtra") private var bottomInsetMultiExtra: Double = 4
    @AppStorage("debug.input.topInsetMultiExtra") private var topInsetMultiExtra: Double = 4
    @AppStorage("debug.input.micOffset") private var micOffset: Double = -12
    @AppStorage("debug.input.sendOffset") private var sendOffset: Double = -4
    @AppStorage("debug.input.sendXOffset") private var sendXOffset: Double = 1
    @AppStorage("debug.input.barYOffset") private var barYOffset: Double = 34
    @AppStorage("debug.input.bottomMessageGap") private var bottomMessageGap: Double = 10
    @AppStorage("debug.input.isMultiline") private var isMultilineFlag = false

    var body: some View {
        ZStack(alignment: .top) {
            Fix1MainViewController_Wrapper(
                messages: messages,
                isSending: isSending,
                onSend: handleSend,
                inputBarYOffset: CGFloat(barYOffset),
                bottomMessageGap: CGFloat(bottomMessageGap)
            )
            .ignoresSafeArea()
            Color.clear
                .frame(height: topShimHeight)
                .accessibilityHidden(true)
            if showTuningPanel {
                ChatInputTuningPanel(
                    bottomInsetSingleExtra: $bottomInsetSingleExtra,
                    bottomInsetMultiExtra: $bottomInsetMultiExtra,
                    topInsetMultiExtra: $topInsetMultiExtra,
                    micOffset: $micOffset,
                    sendOffset: $sendOffset,
                    sendXOffset: $sendXOffset,
                    barYOffset: $barYOffset,
                    bottomMessageGap: $bottomMessageGap,
                    isMultiline: isMultilineFlag,
                    showPanel: $showTuningPanel
                )
                .padding(.top, 152)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(2)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
        .onAppear {
            let clampedGap = min(120, max(-20, bottomMessageGap))
            if bottomMessageGap != clampedGap {
                bottomMessageGap = clampedGap
            }
        }
    }

    private func handleSend(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let userMessage = Message(
            content: trimmed,
            timestamp: .now,
            isFromMe: true,
            status: .sent
        )
        messages.append(userMessage)
        isSending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let assistantMessage = Message(
                content: "Got it. Reviewing caret behavior now.",
                timestamp: .now,
                isFromMe: false,
                status: .delivered
            )
            messages.append(assistantMessage)
            isSending = false
        }
    }

    private var topShimHeight: CGFloat {
        1 / displayScale
    }
}

struct ChatFix1MainJankDebugMenuView: View {
    var body: some View {
        List {
            Section("Keyboard Sync") {
                NavigationLink("Keyboard sync (bottom)") {
                    ChatFix1MainJankScenarioView(
                        title: "Keyboard Sync: Bottom",
                        instructions: "Auto-scrolls to bottom. Open the keyboard and watch for a downward jump after it settles. Keep recording for at least 2 seconds after the keyboard opens.",
                        messages: ChatFix1MainJankDebugData.makeKeyboardSyncMessages(),
                        debugScrollFraction: nil
                    )
                }
                NavigationLink("Keyboard sync (middle)") {
                    ChatFix1MainJankScenarioView(
                        title: "Keyboard Sync: Middle",
                        instructions: "Auto-scrolls to middle. Open the keyboard and watch for a downward jump after it settles. Keep recording for at least 2 seconds after the keyboard opens.",
                        messages: ChatFix1MainJankDebugData.makeKeyboardSyncMessages(),
                        debugScrollFraction: 0.5
                    )
                }
                NavigationLink("Keyboard sync (top)") {
                    ChatFix1MainJankScenarioView(
                        title: "Keyboard Sync: Top",
                        instructions: "Auto-scrolls to top. Open the keyboard and watch for a downward jump after it settles. Keep recording for at least 2 seconds after the keyboard opens.",
                        messages: ChatFix1MainJankDebugData.makeKeyboardSyncMessages(),
                        debugScrollFraction: 0.0
                    )
                }
                NavigationLink("Interactive dismissal (middle)") {
                    ChatFix1MainJankScenarioView(
                        title: "Interactive Dismissal",
                        instructions: "Open the keyboard, then drag the message list down to dismiss. Watch for a downward jump during dismissal or right after the keyboard closes.",
                        messages: ChatFix1MainJankDebugData.makeKeyboardSyncMessages(),
                        debugScrollFraction: 0.5
                    )
                }
            }

            Section("Jank Conversation") {
                NavigationLink("ts79xr7rr98pbr98rb6vssta75800802") {
                    ChatFix1MainJankScenarioView(
                        title: "Jank Conversation",
                        instructions: "Verbatim transcript from conversation ts79xr7rr98pbr98rb6vssta75800802. Open the keyboard and watch for a small downward jump after it settles.",
                        messages: ChatFix1MainJankDebugData.makeJankMessages(),
                        debugScrollFraction: nil
                    )
                }
            }
        }
        .navigationTitle("Jank Debug")
    }
}

struct ChatFix1MainSingleMessageDebugView: View {
    var body: some View {
        ChatFix1MainJankScenarioView(
            title: "Single User Message",
            instructions: "Single user message should start near the top of the viewport (roughly above 3/4 of the scroll view).",
            messages: ChatFix1MainJankDebugData.makeSingleUserMessage(),
            debugScrollFraction: nil
        )
    }
}

private struct ChatFix1MainJankScenarioView: View {
    let title: String
    let instructions: String?
    let messages: [Message]
    let debugScrollFraction: CGFloat?
    let debugScrollDelay: TimeInterval
    @SwiftUI.Environment(\.displayScale) private var displayScale
    @AppStorage(DebugSettingsKeys.showChatInputTuning) private var showTuningPanel = false
    @AppStorage("debug.input.bottomInsetSingleExtra") private var bottomInsetSingleExtra: Double = 0
    @AppStorage("debug.input.bottomInsetMultiExtra") private var bottomInsetMultiExtra: Double = 4
    @AppStorage("debug.input.topInsetMultiExtra") private var topInsetMultiExtra: Double = 4
    @AppStorage("debug.input.micOffset") private var micOffset: Double = -12
    @AppStorage("debug.input.sendOffset") private var sendOffset: Double = -4
    @AppStorage("debug.input.sendXOffset") private var sendXOffset: Double = 1
    @AppStorage("debug.input.barYOffset") private var barYOffset: Double = 34
    @AppStorage("debug.input.bottomMessageGap") private var bottomMessageGap: Double = 10
    @AppStorage("debug.input.isMultiline") private var isMultilineFlag = false

    init(
        title: String,
        instructions: String?,
        messages: [Message],
        debugScrollFraction: CGFloat?,
        debugScrollDelay: TimeInterval = 1.0
    ) {
        self.title = title
        self.instructions = instructions
        self.messages = messages
        self.debugScrollFraction = debugScrollFraction
        self.debugScrollDelay = debugScrollDelay
    }

    var body: some View {
        ZStack(alignment: .top) {
            Fix1MainViewController_Wrapper(
                messages: messages,
                isSending: false,
                onSend: { _ in },
                inputBarYOffset: CGFloat(barYOffset),
                bottomMessageGap: CGFloat(bottomMessageGap),
                debugScrollFraction: debugScrollFraction,
                debugScrollDelay: debugScrollDelay
            )
            .ignoresSafeArea()
            Color.clear
                .frame(height: topShimHeight)
                .accessibilityHidden(true)
            if let instructions {
                Text(instructions)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 8)
                    .padding(.horizontal, 16)
                    .zIndex(2)
            }
            if showTuningPanel {
                ChatInputTuningPanel(
                    bottomInsetSingleExtra: $bottomInsetSingleExtra,
                    bottomInsetMultiExtra: $bottomInsetMultiExtra,
                    topInsetMultiExtra: $topInsetMultiExtra,
                    micOffset: $micOffset,
                    sendOffset: $sendOffset,
                    sendXOffset: $sendXOffset,
                    barYOffset: $barYOffset,
                    bottomMessageGap: $bottomMessageGap,
                    isMultiline: isMultilineFlag,
                    showPanel: $showTuningPanel
                )
                .padding(.top, 152)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .zIndex(3)
            }
        }
        .background(Color.clear)
        .ignoresSafeArea()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let clampedGap = min(120, max(-20, bottomMessageGap))
            if bottomMessageGap != clampedGap {
                bottomMessageGap = clampedGap
            }
        }
    }

    private var topShimHeight: CGFloat {
        1 / displayScale
    }
}

private enum ChatFix1MainJankDebugData {
    private static let jankConversationId = "ts79xr7rr98pbr98rb6vssta75800802"
    private static let jankTranscript: [String] = [
        "optimistic return 1769512215538",
        """
I see you've provided what appears to be a number or identifier: `1769512215538`. Could you please clarify what you'd like me to do with this?

Are you looking to:
- Search for this value in a codebase?
- Convert or interpret this number in some way?
- Something else?

Please provide more context about what task you'd like help with.
"""
    ]

    static func makeJankMessages() -> [Message] {
        let start = Date().addingTimeInterval(-Double(jankTranscript.count) * 1200)
        return jankTranscript.enumerated().map { index, text in
            let isFromMe = index % 2 == 0
            let id = isFromMe ? "\(jankConversationId)_user" : "\(jankConversationId)_assistant"
            let timestamp = start.addingTimeInterval(Double(index) * 1200)
            return Message(
                id: id,
                content: text,
                timestamp: timestamp,
                isFromMe: isFromMe,
                status: .delivered
            )
        }
    }

    static func makeKeyboardSyncMessages(count: Int = 90) -> [Message] {
        let safeCount = min(200, max(20, count))
        let start = Date().addingTimeInterval(-Double(safeCount) * 90)
        return (0..<safeCount).map { index in
            let isAssistant = index % 2 == 0
            let content = isAssistant ? "Assistant message \(index + 1)" : "User message \(index + 1)"
            let timestamp = start.addingTimeInterval(Double(index) * 90)
            return Message(
                id: "debug_sync_\(index + 1)",
                content: content,
                timestamp: timestamp,
                isFromMe: !isAssistant,
                status: .delivered
            )
        }
    }

    static func makeSingleUserMessage() -> [Message] {
        [
            Message(
                id: "debug_single_user_1",
                content: "Single user message for the top pin check.",
                timestamp: .now,
                isFromMe: true,
                status: .delivered
            )
        ]
    }
}

private enum ChatFix1MainDebugMockData {
    private static let userSnippets: [String] = [
        "Can you check the caret drift again?",
        "I pressed Return several times.\nThe cursor moves down.",
        "The baseline strategy looks stable.",
        "Does sizeThatFits change scroll behavior?",
        "Try typing A, Return, A, Return.",
        "Any difference between simulator and device?",
        "The input grows upward in the lab.",
        "We need to match main chat.",
        "Thanks for digging into this.",
    ]

    private static let assistantSnippets: [String] = [
        "Investigating the input bar layout now.",
        "I suspect the text view insets are shifting.",
        "Comparing measurement strategies in the lab.",
        "I will align the scroll logic with baseline.",
        "Let me add more diagnostics.",
        "We can add more long messages to stress layout.",
        "I will reload the app after changes.",
        "Looking at caret rect vs used rect.",
        "Let's test with a longer assistant reply to wrap.",
    ]

    static func makeMessages(count: Int = 80) -> [Message] {
        let safeCount = min(200, max(20, count))
        let start = Date().addingTimeInterval(-Double(safeCount) * 90)
        return (0..<safeCount).map { index in
            let isFromMe = index % 2 == 0
            let base = isFromMe ? userSnippets[index % userSnippets.count] : assistantSnippets[index % assistantSnippets.count]
            let extra = (index % 7 == 0)
                ? " Here is a longer note that wraps across multiple lines to stress the layout engine."
                : ""
            let timestamp = start.addingTimeInterval(Double(index) * 90)
            return Message(
                content: base + extra,
                timestamp: timestamp,
                isFromMe: isFromMe,
                status: .delivered
            )
        }
    }
}

private struct ChatInputTuningPanel: View {
    @Binding var bottomInsetSingleExtra: Double
    @Binding var bottomInsetMultiExtra: Double
    @Binding var topInsetMultiExtra: Double
    @Binding var micOffset: Double
    @Binding var sendOffset: Double
    @Binding var sendXOffset: Double
    @Binding var barYOffset: Double
    @Binding var bottomMessageGap: Double
    let isMultiline: Bool
    @Binding var showPanel: Bool
    @State private var copied = false

    private var summaryText: String {
        "bottomInsetSingleExtra=\(format(bottomInsetSingleExtra)), bottomInsetMultiExtra=\(format(bottomInsetMultiExtra)), topInsetMultiExtra=\(format(topInsetMultiExtra)), micOffset=\(format(micOffset)), sendOffset=\(format(sendOffset)), sendXOffset=\(format(sendXOffset)), barYOffset=\(format(barYOffset)), bottomMessageGap=\(format(bottomMessageGap))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input tuning")
                .font(.caption)
                .foregroundStyle(.secondary)
            tuningRow(label: "Bottom (1 line)", value: $bottomInsetSingleExtra, range: -6...20, step: 1)
            tuningRow(label: "Bottom (multi)", value: $bottomInsetMultiExtra, range: -6...20, step: 1)
            if isMultiline {
                tuningRow(label: "Top (multi)", value: $topInsetMultiExtra, range: -6...20, step: 1)
            }
            tuningRow(label: "Mic Y", value: $micOffset, range: -12...12, step: 1)
            tuningRow(label: "Send Y", value: $sendOffset, range: -12...12, step: 1)
            tuningRow(label: "Send X", value: $sendXOffset, range: -20...20, step: 1)
            tuningRow(label: "Bar Y", value: $barYOffset, range: -40...40, step: 1)
            tuningRow(label: "Bottom gap", value: $bottomMessageGap, range: -20...120, step: 1)
            HStack(spacing: 8) {
                Text(summaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = summaryText
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
                Button("Hide") {
                    showPanel = false
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.1), lineWidth: 1)
        )
        .frame(maxWidth: 260)
    }

    private func tuningRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .frame(width: 90, alignment: .leading)
            Stepper(value: value, in: range, step: step) {
                Text(format(value.wrappedValue))
                    .font(.caption2)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%.0f", value)
    }
}

private struct Fix1MainViewController_Wrapper: UIViewControllerRepresentable {
    let messages: [Message]
    let isSending: Bool
    let onSend: (String) -> Void
    let inputBarYOffset: CGFloat
    let bottomMessageGap: CGFloat
    let debugScrollFraction: CGFloat?
    let debugScrollDelay: TimeInterval

    init(
        messages: [Message],
        isSending: Bool,
        onSend: @escaping (String) -> Void,
        inputBarYOffset: CGFloat,
        bottomMessageGap: CGFloat,
        debugScrollFraction: CGFloat? = nil,
        debugScrollDelay: TimeInterval = 1.0
    ) {
        self.messages = messages
        self.isSending = isSending
        self.onSend = onSend
        self.inputBarYOffset = inputBarYOffset
        self.bottomMessageGap = bottomMessageGap
        self.debugScrollFraction = debugScrollFraction
        self.debugScrollDelay = debugScrollDelay
    }

    func makeUIViewController(context: Context) -> Fix1MainViewController {
        let clampedGap = max(-20, min(120, bottomMessageGap))
        return Fix1MainViewController(
            messages: messages,
            onSend: onSend,
            inputBarYOffset: resolvedInputBarYOffset(),
            bottomMessageGap: clampedGap,
            debugScrollFraction: resolvedDebugScrollFraction(),
            debugScrollDelay: resolvedDebugScrollDelay()
        )
    }

    func updateUIViewController(_ uiViewController: Fix1MainViewController, context: Context) {
        let clampedGap = max(-20, min(120, bottomMessageGap))
        uiViewController.updateMessages(messages)
        uiViewController.updateSendingState(isSending)
        uiViewController.updateInputBarYOffset(resolvedInputBarYOffset())
        uiViewController.updateBottomMessageGap(clampedGap)
    }

    private func resolvedInputBarYOffset() -> CGFloat {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_BAR_Y_OFFSET"],
           let value = Double(raw) {
            return CGFloat(value)
        }
#endif
        return inputBarYOffset
    }

    private func resolvedDebugScrollFraction() -> CGFloat? {
        guard let fraction = debugScrollFraction else {
            return nil
        }
        return max(0, min(1, fraction))
    }

    private func resolvedDebugScrollDelay() -> TimeInterval {
        max(0, debugScrollDelay)
    }
}

private final class Fix1MainViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private var scrollView: UIScrollView!
    private var contentStack: UIStackView!
    private var bottomSpacerView: UIView!
    private var extraSpacerView: UIView!
    private var belowPillSpacerView: UIView!
    private var extraSpacerLabel: UILabel!
    private var bottomSpacerLabel: UILabel!
    private var belowPillSpacerLabel: UILabel!
    private var inputBarVC: DebugInputBarViewController!
    private var backgroundView: UIView!
    private var debugYellowOverlay: UIView!
    private var debugRedOverlay: UIView!
    private var debugGreenOverlay: UIView!
    private var debugYellowLabel: UILabel!
    private var debugRedLabel: UILabel!
    private var debugGreenLabel: UILabel!
    private var debugMessageLine: UIView!
    private var debugPillLine: UIView!
    private var debugInfoLabel: UILabel!
    private var debugSettingsObserver: NSObjectProtocol?
    private var isHandlingInputBarLayout = false

    private var messages: [Message]
    private var onSend: ((String) -> Void)?
    private var isSending = false
    private var lastAppliedTopInset: CGFloat = 0
    private var lastAppliedBottomInset: CGFloat?
    private var lastAppliedPillTopY: CGFloat?
    private var lastContentHeight: CGFloat = 0
    private var lastMeasuredNaturalHeight: CGFloat = 0
    private var hasUserScrolled = false
    private var didInitialScrollToBottom = false
    private var isInputBarMeasuring = false
    private var inputBarYOffset: CGFloat
    private var bottomMessageGap: CGFloat
    private var inputBarBottomConstraint: NSLayoutConstraint!
    private var contentStackBottomConstraint: NSLayoutConstraint!
    private var contentStackTopConstraint: NSLayoutConstraint!
    private var contentStackMinHeightConstraint: NSLayoutConstraint!
    private var bottomSpacerHeightConstraint: NSLayoutConstraint!
    private var extraSpacerHeightConstraint: NSLayoutConstraint!
    private var belowPillSpacerHeightConstraint: NSLayoutConstraint!
    private var lastGeometryLogSignature: String?
    private var lastVisibleSignature: String?
    private var topFadeView: TopFadeView!
    private var topFadeHeightConstraint: NSLayoutConstraint!
    private var bottomFadeView: BottomFadeView!
    private var didLogGeometryOnce = false
    private var isKeyboardVisible = false
    private var isKeyboardAnimating = false
    private var keyboardAnimationEndWorkItem: DispatchWorkItem?
    private var keyboardAnimationDuration: TimeInterval = 0.25
    private var keyboardAnimationOptions: UIView.AnimationOptions = [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    private var isUpdatingBottomInsets = false
    private var pendingBottomInsetsUpdate = false
    private var keyboardOpenOffsetFloor: CGFloat?
    private var keyboardBaselineOffsetY: CGFloat?
    private var toolCallSheetKeyboardOverlap: CGFloat?
    private var toolCallSheetHoldKeyboardOverlap = false
    private var toolCallSheetIsPresented = false
    private var toolCallSheetPinnedInputBarConstant: CGFloat?
    private var toolCallSheetPinnedPillBottomY: CGFloat?
    private var toolCallSheetReleaseWorkItem: DispatchWorkItem?
    private var shouldRestoreKeyboardAfterToolCallSheet = false
#if DEBUG
    private let uiTestTrackMessagePositions: Bool = UITestConfig.mockDataEnabled
    private let uiTestUnderreportContentSize: Bool = {
        UITestConfig.mockDataEnabled
            && ProcessInfo.processInfo.environment["CMUX_UITEST_UNDEREPORT_CONTENT_SIZE"] == "1"
    }()
    private var uiTestAssistantBottomMarker: UIView?
    private var uiTestAssistantTextBottomMarker: UIView?
    private var uiTestBottomInsetMarker: UIView?
    private var uiTestContentFitsMarker: UIView?
    private var uiTestKeyboardOverlapMarker: UIView?
    private var uiTestToolCallHoldMarker: UIView?
    private var uiTestInputBarConstantMarker: UIView?
    private let uiTestJankMonitorEnabled: Bool = {
        UITestConfig.mockDataEnabled &&
            ProcessInfo.processInfo.environment["CMUX_UITEST_JANK_MONITOR"] == "1"
    }()
    private let uiTestJankMessageIdentifiers: [String] = {
        let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_JANK_MESSAGE_IDS"] ?? ""
        let entries = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return entries.map { entry in
            if entry.hasPrefix("chat.") {
                return String(entry)
            }
            return "chat.message.\(entry)"
        }
    }()
    private var uiTestJankUseAnchors: Bool {
        uiTestTrackMessagePositions
    }
    private let uiTestJankLogEvery: Int = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_JANK_LOG_EVERY"],
              let value = Int(raw) else {
            return 1
        }
        return max(0, value)
    }()
    private let uiTestJankAutoStart: Bool = {
        let value = ProcessInfo.processInfo.environment["CMUX_UITEST_JANK_AUTO_START"] ?? "0"
        return value == "1" || value.lowercased() == "true"
    }()
    private let uiTestJankAutoStartDelay: TimeInterval = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_JANK_AUTO_START_DELAY"],
              let value = Double(raw) else {
            return 0.2
        }
        return max(0, value)
    }()
    private let uiTestJankAutoStartDuration: TimeInterval = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_JANK_WINDOW_SECONDS"],
              let value = Double(raw) else {
            return 4.0
        }
        return max(0.5, value)
    }()
    private var uiTestJankDisplayLink: CADisplayLink?
    private var uiTestJankLastMinY: [String: CGFloat] = [:]
    private var uiTestJankLastContentOffsetY: CGFloat?
    private var uiTestJankMaxDownwardDelta: CGFloat = 0
    private var uiTestJankSampleCount: Int = 0
    private var uiTestJankMonitoringUntil: TimeInterval?
    private var uiTestJankMonitoringActive = false
    private var uiTestJankMaxDownMarker: UIView?
    private var uiTestJankMaxSourceMarker: UIView?
    private var uiTestJankSampleCountMarker: UIView?
    private var uiTestJankStartButton: UIButton?
    private var uiTestJankDidLogMissingMessages = false
    private var uiTestJankCachedViews: [String: UIView] = [:]
    private var uiTestJankCachedAccessibilityElements: [String: UIAccessibilityElement] = [:]
    private var uiTestJankLastLookup: [String: TimeInterval] = [:]
    private var uiTestJankLastAssistantMinY: CGFloat?
    private var uiTestJankLastMessageMinY: CGFloat?
    private var uiTestJankLastAnchorMinY: CGFloat?
    private var uiTestJankLastAnchorIndex: Int?
    private var uiTestJankLastScrollMinY: CGFloat?
    private var uiTestJankLastContentStackMinY: CGFloat?
    private var uiTestJankMaxDownwardSource: String = ""
#endif
    private let debugAutoFocusInput: Bool = {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["CMUX_DEBUG_AUTOFOCUS"] {
            return value == "1" || value.lowercased() == "true"
        }
        return false
        #else
        return false
        #endif
    }()
    private let uiTestScrollFraction: CGFloat? = {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment["CMUX_UITEST_SCROLL_FRACTION"] else {
            return nil
        }
        if let fraction = Double(value) {
            return CGFloat(max(0, min(1, fraction)))
        }
        return nil
        #else
        return nil
        #endif
    }()
    private let debugScrollFraction: CGFloat?
    private let debugScrollDelay: TimeInterval
    private var didDebugScroll = false
    private let uiTestDisableShortThreadPin: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_DISABLE_SHORT_THREAD_PIN"] == "1"
        #else
        return false
        #endif
    }()
    private let debugAutoScrollToMiddle: Bool = {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["CMUX_DEBUG_AUTOSCROLL_MIDDLE"] {
            return value == "1" || value.lowercased() == "true"
        }
        return false
        #else
        return false
        #endif
    }()
    private let debugAutoScrollDelay: TimeInterval = 8.0
    private let debugAutoFocusDelay: TimeInterval = {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["CMUX_DEBUG_AUTOFOCUS_DELAY"],
           let delay = Double(value) {
            return max(0, delay)
        }
        return 0
        #else
        return 0
        #endif
    }()
    private var didAutoScrollToMiddle = false
    private var lastKeyboardShiftSummary: String?
    private var pendingKeyboardSample: DebugShiftSample?
    private var lastOffsetDebug: String?
    private var lastGapDebug: String?
    private var lastAnchorIndexUsed: Int?
    private var lastLayoutPillTopY: CGFloat?
    private var previousLayoutPillTopY: CGFloat?
    private var lastPillShiftDebug: String?
    private var lastPillTopYClosed: CGFloat?
    private var lastPillTopYOpen: CGFloat?
    private var pendingKeyboardTransition: KeyboardTransition?
    private var interactiveDismissalAnchor: InteractiveDismissalAnchor?
    private var isInteractiveDismissalActive = false
    private var pendingInteractiveDismissal = false
    private var pendingInteractiveDismissalStartOverlap: CGFloat?
    private var interactiveDismissalStartOverlap: CGFloat?
    private var pendingInteractiveDismissalAnchor: InteractiveDismissalAnchor?
    private let interactiveDismissalActivationDelta: CGFloat = 0
    private var lastKeyboardOverlap: CGFloat?
    private var lockedKeyboardOverlap: CGFloat?
    private var lockedPillBottomY: CGFloat?
    private var didConfigureInteractivePopGesture = false
#if DEBUG
    private let uiTestFakeKeyboardEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD"] ?? "0"
        return value == "1" || value.lowercased() == "true"
    }()
    private let uiTestFakeKeyboardAutoOpenDelay: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_AUTO_OPEN_DELAY"],
              let value = Double(raw) else {
            return nil
        }
        return max(0, value)
    }()
    private let uiTestFakeKeyboardAutoCloseDelay: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_AUTO_CLOSE_DELAY"],
              let value = Double(raw) else {
            return nil
        }
        return max(0, value)
    }()
    private var uiTestKeyboardVisibilityOverride: Bool?
    private let uiTestFakeKeyboardInitialOverlap: CGFloat? = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_INITIAL_OVERLAP"],
              let value = Double(raw) else {
            return nil
        }
        return CGFloat(max(0, value))
    }()
    private let uiTestFakeKeyboardOpenOverlap: CGFloat = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_OPEN_OVERLAP"],
              let value = Double(raw) else {
            return 335
        }
        return CGFloat(max(0, value))
    }()
    private let uiTestFakeKeyboardClosedOverlap: CGFloat? = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_CLOSED_OVERLAP"],
              let value = Double(raw) else {
            return nil
        }
        return CGFloat(max(0, value))
    }()
    private var uiTestKeyboardOverlap: CGFloat?
    private var uiTestInteractiveDismissalActive = false
    private let uiTestKeyboardStep: CGFloat = 24
    private var uiTestKeyboardStepDownButton: UIButton?
    private var uiTestKeyboardStepUpButton: UIButton?
    private var uiTestLastDismissTranslation: CGFloat = 0
    private var uiTestDismissalStartOffsetY: CGFloat?
    private var uiTestKeyboardFocusButton: UIButton?
    private var uiTestKeyboardDismissButton: UIButton?
    private var didScheduleUiTestKeyboardAutoCycle = false
#endif

    init(
        messages: [Message],
        onSend: ((String) -> Void)? = nil,
        inputBarYOffset: CGFloat = 0,
        bottomMessageGap: CGFloat = 10,
        debugScrollFraction: CGFloat? = nil,
        debugScrollDelay: TimeInterval = 1.0
    ) {
        self.messages = messages
        self.onSend = onSend
        self.inputBarYOffset = inputBarYOffset
        self.bottomMessageGap = max(-20, min(120, bottomMessageGap))
        self.debugScrollFraction = debugScrollFraction.map { max(0, min(1, $0)) }
        self.debugScrollDelay = max(0, debugScrollDelay)
        super.init(nibName: nil, bundle: nil)
    }

    /// Update sending state from SwiftUI
    func updateSendingState(_ sending: Bool) {
        isSending = sending
        // Optionally disable input while sending
        inputBarVC?.setEnabled(!sending)
    }

    func updateInputBarYOffset(_ offset: CGFloat) {
        if abs(inputBarYOffset - offset) < 0.5 {
            return
        }
        inputBarYOffset = offset
        guard isViewLoaded else { return }
        updateBottomInsetsForKeyboard()
        view.setNeedsLayout()
    }

    func updateBottomMessageGap(_ gap: CGFloat) {
        let clampedGap = max(-20, min(120, gap))
        if abs(bottomMessageGap - clampedGap) < 0.5 {
            return
        }
        bottomMessageGap = clampedGap
        guard isViewLoaded else { return }
        updateBottomInsetsForKeyboard()
        view.setNeedsLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Update messages from SwiftUI when subscription updates
    func updateMessages(_ newMessages: [Message]) {
        guard newMessages != messages else { return }

        // Check if this is an append-only update (most common case)
        let isAppendOnly = newMessages.count > messages.count &&
            zip(messages, newMessages).allSatisfy { $0.id == $1.id }

        if isAppendOnly {
            // Only add new messages - no need to rebuild everything
            let newCount = newMessages.count - messages.count
            let newMessagesToAdd = Array(newMessages.suffix(newCount))

            // Update the last message's tail (remove it since it's no longer last)
            // The tail is visual only, so we can skip this optimization for now

            messages = newMessages

            for (index, message) in newMessagesToAdd.enumerated() {
                let isLast = index == newMessagesToAdd.count - 1
                addMessageBubble(message, showTail: isLast, showTimestamp: false)
            }

            // Scroll to bottom for new messages
            DispatchQueue.main.async {
                self.scrollToBottom(animated: true)
            }
        } else {
            // Full rebuild needed - disable animations to prevent jank
            UIView.performWithoutAnimation {
                // Clear existing message views
                for view in messageArrangedViews() {
                    view.removeFromSuperview()
                    if let host = children.first(where: { $0.view === view }) {
                        host.willMove(toParent: nil)
                        host.removeFromParent()
                    }
                }

                // Update messages array
                messages = newMessages

                // Re-populate
                populateMessages()

                // Force layout immediately
                view.layoutIfNeeded()
            }

            // Scroll to bottom after layout settles
            DispatchQueue.main.async {
                self.scrollToBottom(animated: false)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolCallSheetWillPresent),
            name: .toolCallSheetWillPresent,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolCallSheetDidDismiss),
            name: .toolCallSheetDidDismiss,
            object: nil
        )

        setupBackground()
        setupScrollView()
        setupInputBar()
        setupDebugOverlay()
        setupUiTestMarkers()
        observeDebugSettingsChanges()
        setupTopFade()
        setupBottomFade()
        setupConstraints()
        populateMessages()

        applyFix1()
        #if DEBUG
        setupUiTestKeyboardControlsIfNeeded()
        #endif

        log("🚀 viewDidLoad complete")

        DispatchQueue.main.async {
            log("viewDidLoad - second async scrollToBottom")
            self.scrollToBottom(animated: false)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableInteractivePopGesture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableInteractivePopGesture()
        #if DEBUG
        scheduleUiTestKeyboardAutoCycleIfNeeded()
        startUiTestJankMonitorIfNeeded()
        if uiTestJankMonitorEnabled && uiTestJankAutoStart {
            let delay = uiTestJankAutoStartDelay
            let duration = uiTestJankAutoStartDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.startUiTestJankWindow(reason: "auto_start", duration: duration)
            }
        }
        if debugAutoFocusInput {
            let focusWork: () -> Void = { [weak self] in
                self?.inputBarVC.setFocused(true)
            }
            if debugAutoFocusDelay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + debugAutoFocusDelay, execute: focusWork)
            } else {
                DispatchQueue.main.async(execute: focusWork)
            }
        }
        if debugAutoScrollToMiddle && !didAutoScrollToMiddle {
            didAutoScrollToMiddle = true
            DispatchQueue.main.asyncAfter(deadline: .now() + debugAutoScrollDelay) { [weak self] in
                guard let self else { return }
                self.view.layoutIfNeeded()
                let maxOffsetY = max(0, self.scrollView.contentSize.height - self.scrollView.bounds.height)
                guard maxOffsetY > 1 else { return }
                self.hasUserScrolled = true
                let targetOffsetY = maxOffsetY * 0.5
                self.scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
            }
        }
        if let fraction = debugScrollFraction, !didDebugScroll {
            didDebugScroll = true
            DispatchQueue.main.asyncAfter(deadline: .now() + debugScrollDelay) { [weak self] in
                guard let self else { return }
                self.view.layoutIfNeeded()
                let maxOffsetY = max(
                    0,
                    self.scrollView.contentSize.height - self.scrollView.bounds.height + self.scrollView.contentInset.bottom
                )
                let minOffsetY = -self.scrollView.contentInset.top
                let targetOffsetY = max(minOffsetY, min(maxOffsetY, maxOffsetY * fraction))
                self.hasUserScrolled = true
                self.scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
            }
        } else if let fraction = uiTestScrollFraction {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.view.layoutIfNeeded()
                let maxOffsetY = max(
                    0,
                    self.scrollView.contentSize.height - self.scrollView.bounds.height + self.scrollView.contentInset.bottom
                )
                let minOffsetY = -self.scrollView.contentInset.top
                let targetOffsetY = max(minOffsetY, min(maxOffsetY, maxOffsetY * fraction))
                self.hasUserScrolled = true
                self.scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
            }
        }
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if DEBUG
        stopUiTestJankMonitor()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let debugSettingsObserver {
            NotificationCenter.default.removeObserver(debugSettingsObserver)
        }
    }

    private func applyFix1() {
        log("🔧 applyFix1 called")

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset.top = 0
        scrollView.verticalScrollIndicatorInsets.top = 0
        contentStackBottomConstraint.constant = 0

        log("applyFix1 - before updateScrollViewInsets")
        log("  view.window: \(String(describing: view.window))")
        log("  view.safeAreaInsets: \(view.safeAreaInsets)")
        log("  inputBarVC.view.bounds: \(inputBarVC.view.bounds)")

        updateTopInsetIfNeeded()
        updateBottomInsetsForKeyboard()
        view.layoutIfNeeded()

        log("applyFix1 - after layoutIfNeeded")
        log("  scrollView.contentInset: \(scrollView.contentInset)")
        log("  scrollView.contentSize: \(scrollView.contentSize)")
        log("  scrollView.bounds: \(scrollView.bounds)")
        logContentGeometry(reason: "applyFix1-after-layout")

        DispatchQueue.main.async {
            log("applyFix1 - first async scrollToBottom")
            log("  scrollView.contentInset: \(self.scrollView.contentInset)")
            log("  scrollView.contentSize: \(self.scrollView.contentSize)")
            self.scrollToBottom(animated: false)
        }
    }

    private func setupScrollView() {
        scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .none
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.delegate = self
        scrollView.accessibilityIdentifier = "chat.scroll"

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)

        view.addSubview(scrollView)

        contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        extraSpacerView = UIView()
        extraSpacerView.translatesAutoresizingMaskIntoConstraints = false
        extraSpacerView.backgroundColor = UIColor.yellow.withAlphaComponent(0.35)
        extraSpacerView.layer.borderWidth = 1
        extraSpacerView.layer.borderColor = UIColor.yellow.cgColor
        extraSpacerView.isUserInteractionEnabled = false
        extraSpacerLabel = makeSpacerLabel(color: .yellow)
        extraSpacerView.addSubview(extraSpacerLabel)
        NSLayoutConstraint.activate([
            extraSpacerLabel.leadingAnchor.constraint(equalTo: extraSpacerView.leadingAnchor, constant: 4),
            extraSpacerLabel.topAnchor.constraint(equalTo: extraSpacerView.topAnchor, constant: 2)
        ])
        contentStack.addArrangedSubview(extraSpacerView)
        extraSpacerHeightConstraint = extraSpacerView.heightAnchor.constraint(equalToConstant: 0)
        extraSpacerHeightConstraint.isActive = true

        bottomSpacerView = UIView()
        bottomSpacerView.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacerView.backgroundColor = UIColor.red.withAlphaComponent(0.25)
        bottomSpacerView.layer.borderWidth = 1
        bottomSpacerView.layer.borderColor = UIColor.red.cgColor
        bottomSpacerView.isUserInteractionEnabled = false
        bottomSpacerLabel = makeSpacerLabel(color: .red)
        bottomSpacerView.addSubview(bottomSpacerLabel)
        NSLayoutConstraint.activate([
            bottomSpacerLabel.leadingAnchor.constraint(equalTo: bottomSpacerView.leadingAnchor, constant: 4),
            bottomSpacerLabel.topAnchor.constraint(equalTo: bottomSpacerView.topAnchor, constant: 2)
        ])
        contentStack.addArrangedSubview(bottomSpacerView)
        bottomSpacerHeightConstraint = bottomSpacerView.heightAnchor.constraint(equalToConstant: 0)
        bottomSpacerHeightConstraint.isActive = true

        belowPillSpacerView = UIView()
        belowPillSpacerView.translatesAutoresizingMaskIntoConstraints = false
        belowPillSpacerView.backgroundColor = UIColor.green.withAlphaComponent(0.2)
        belowPillSpacerView.isUserInteractionEnabled = false
        belowPillSpacerLabel = makeSpacerLabel(color: .green)
        belowPillSpacerView.addSubview(belowPillSpacerLabel)
        NSLayoutConstraint.activate([
            belowPillSpacerLabel.leadingAnchor.constraint(equalTo: belowPillSpacerView.leadingAnchor, constant: 4),
            belowPillSpacerLabel.topAnchor.constraint(equalTo: belowPillSpacerView.topAnchor, constant: 2)
        ])
        contentStack.addArrangedSubview(belowPillSpacerView)
        belowPillSpacerHeightConstraint = belowPillSpacerView.heightAnchor.constraint(equalToConstant: 0)
        belowPillSpacerHeightConstraint.isActive = true

        contentStack.setCustomSpacing(0, after: extraSpacerView)
        contentStack.setCustomSpacing(0, after: bottomSpacerView)
        contentStack.setCustomSpacing(0, after: belowPillSpacerView)
    }

    private func setupBackground() {
        backgroundView = UIView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = .systemBackground
        view.addSubview(backgroundView)
    }

    private func setupInputBar() {
        inputBarVC = DebugInputBarViewController()
        inputBarVC.view.translatesAutoresizingMaskIntoConstraints = false
        inputBarVC.onSend = { [weak self] in
            self?.sendMessage()
        }
        inputBarVC.onLayoutChange = { [weak self] in
            guard let self else { return }
            if self.isHandlingInputBarLayout {
                return
            }
            self.isHandlingInputBarLayout = true
            defer { self.isHandlingInputBarLayout = false }
            self.updateBottomInsetsForKeyboard(animateHeightChanges: false)
        }
        inputBarVC.view.setContentCompressionResistancePriority(.required, for: .vertical)
        inputBarVC.view.setContentHuggingPriority(.required, for: .vertical)

        addChild(inputBarVC)
        view.addSubview(inputBarVC.view)
        inputBarVC.didMove(toParent: self)

#if DEBUG
        isInputBarMeasuring = true
        inputBarVC.view.alpha = 0
#endif
    }

    private func setupDebugOverlay() {
#if DEBUG
        debugYellowOverlay = makeDebugOverlayView(color: .yellow)
        debugRedOverlay = makeDebugOverlayView(color: .red)
        debugGreenOverlay = makeDebugOverlayView(color: .green)
        debugYellowLabel = makeDebugOverlayLabel(color: .yellow)
        debugRedLabel = makeDebugOverlayLabel(color: .red)
        debugGreenLabel = makeDebugOverlayLabel(color: .green)
        debugMessageLine = makeDebugLineView(color: .cyan)
        debugPillLine = makeDebugLineView(color: .magenta)
        debugInfoLabel = UILabel()
        debugInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        debugInfoLabel.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        debugInfoLabel.textColor = .black
        debugInfoLabel.backgroundColor = UIColor.white.withAlphaComponent(0.7)
        debugInfoLabel.numberOfLines = 0
        debugInfoLabel.layer.cornerRadius = 6
        debugInfoLabel.layer.masksToBounds = true
        debugInfoLabel.isUserInteractionEnabled = false

        debugYellowOverlay.translatesAutoresizingMaskIntoConstraints = true
        debugRedOverlay.translatesAutoresizingMaskIntoConstraints = true
        debugGreenOverlay.translatesAutoresizingMaskIntoConstraints = true

        debugYellowOverlay.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]
        debugRedOverlay.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]
        debugGreenOverlay.autoresizingMask = [.flexibleWidth, .flexibleTopMargin, .flexibleBottomMargin]

        view.addSubview(debugYellowOverlay)
        view.addSubview(debugRedOverlay)
        view.addSubview(debugGreenOverlay)
        view.addSubview(debugMessageLine)
        view.addSubview(debugPillLine)
        view.addSubview(debugYellowLabel)
        view.addSubview(debugRedLabel)
        view.addSubview(debugGreenLabel)
        view.addSubview(debugInfoLabel)
        updateDebugOverlayVisibility()
#endif
    }

    private func setupUiTestMarkers() {
#if DEBUG
        guard uiTestTrackMessagePositions else { return }
        let marker = UIView()
        marker.translatesAutoresizingMaskIntoConstraints = true
        marker.backgroundColor = .clear
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = "chat.lastAssistantMessageBottom"
        view.addSubview(marker)
        uiTestAssistantBottomMarker = marker
        let textMarker = UIView()
        textMarker.translatesAutoresizingMaskIntoConstraints = true
        textMarker.backgroundColor = .clear
        textMarker.isUserInteractionEnabled = false
        textMarker.isAccessibilityElement = true
        textMarker.accessibilityIdentifier = "chat.lastAssistantTextBottom"
        view.addSubview(textMarker)
        uiTestAssistantTextBottomMarker = textMarker
        let insetMarker = UIView()
        insetMarker.translatesAutoresizingMaskIntoConstraints = true
        insetMarker.backgroundColor = .clear
        insetMarker.isUserInteractionEnabled = false
        insetMarker.isAccessibilityElement = true
        insetMarker.accessibilityIdentifier = "chat.bottomInsetValue"
        view.addSubview(insetMarker)
        uiTestBottomInsetMarker = insetMarker
        let fitsMarker = UIView()
        fitsMarker.translatesAutoresizingMaskIntoConstraints = true
        fitsMarker.backgroundColor = .clear
        fitsMarker.isUserInteractionEnabled = false
        fitsMarker.isAccessibilityElement = true
        fitsMarker.accessibilityIdentifier = "chat.contentFitsValue"
        view.addSubview(fitsMarker)
        uiTestContentFitsMarker = fitsMarker
        let overlapMarker = UIView()
        overlapMarker.translatesAutoresizingMaskIntoConstraints = true
        overlapMarker.backgroundColor = .clear
        overlapMarker.isUserInteractionEnabled = false
        overlapMarker.isAccessibilityElement = true
        overlapMarker.accessibilityIdentifier = "chat.keyboardOverlapValue"
        view.addSubview(overlapMarker)
        uiTestKeyboardOverlapMarker = overlapMarker
        let holdMarker = UIView()
        holdMarker.translatesAutoresizingMaskIntoConstraints = true
        holdMarker.backgroundColor = .clear
        holdMarker.isUserInteractionEnabled = false
        holdMarker.isAccessibilityElement = true
        holdMarker.accessibilityIdentifier = "chat.toolCallHoldValue"
        holdMarker.accessibilityValue = "0"
        view.addSubview(holdMarker)
        uiTestToolCallHoldMarker = holdMarker
        let inputBarMarker = UIView()
        inputBarMarker.translatesAutoresizingMaskIntoConstraints = true
        inputBarMarker.backgroundColor = .clear
        inputBarMarker.isUserInteractionEnabled = false
        inputBarMarker.isAccessibilityElement = true
        inputBarMarker.accessibilityIdentifier = "chat.inputBarConstantValue"
        inputBarMarker.accessibilityValue = "0"
        view.addSubview(inputBarMarker)
        uiTestInputBarConstantMarker = inputBarMarker
        let focusButton = UIButton(type: .custom)
        focusButton.translatesAutoresizingMaskIntoConstraints = false
        focusButton.alpha = 0.2
        focusButton.isAccessibilityElement = true
        focusButton.accessibilityIdentifier = "chat.keyboard.focus"
        focusButton.addTarget(self, action: #selector(handleUiTestKeyboardFocus), for: .touchUpInside)
        view.addSubview(focusButton)
        uiTestKeyboardFocusButton = focusButton
        let dismissButton = UIButton(type: .custom)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.alpha = 0.2
        dismissButton.isAccessibilityElement = true
        dismissButton.accessibilityIdentifier = "chat.keyboard.dismiss"
        dismissButton.addTarget(self, action: #selector(handleUiTestKeyboardDismiss), for: .touchUpInside)
        view.addSubview(dismissButton)
        uiTestKeyboardDismissButton = dismissButton
        setupUiTestJankMarkers()
        NSLayoutConstraint.activate([
            focusButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            focusButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            focusButton.widthAnchor.constraint(equalToConstant: 44),
            focusButton.heightAnchor.constraint(equalToConstant: 44),
            dismissButton.topAnchor.constraint(equalTo: focusButton.bottomAnchor, constant: 8),
            dismissButton.trailingAnchor.constraint(equalTo: focusButton.trailingAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 44),
            dismissButton.heightAnchor.constraint(equalToConstant: 44)
        ])
#endif
    }

#if DEBUG
    private func setupUiTestJankMarkers() {
        guard uiTestJankMonitorEnabled else { return }
        let maxMarker = UIView()
        maxMarker.translatesAutoresizingMaskIntoConstraints = true
        maxMarker.backgroundColor = .clear
        maxMarker.isUserInteractionEnabled = false
        maxMarker.isAccessibilityElement = true
        maxMarker.accessibilityIdentifier = "chat.jank.maxDownwardDelta"
        maxMarker.accessibilityValue = "0"
        view.addSubview(maxMarker)
        uiTestJankMaxDownMarker = maxMarker

        let sampleMarker = UIView()
        sampleMarker.translatesAutoresizingMaskIntoConstraints = true
        sampleMarker.backgroundColor = .clear
        sampleMarker.isUserInteractionEnabled = false
        sampleMarker.isAccessibilityElement = true
        sampleMarker.accessibilityIdentifier = "chat.jank.sampleCount"
        sampleMarker.accessibilityValue = "0"
        view.addSubview(sampleMarker)
        uiTestJankSampleCountMarker = sampleMarker

        let sourceMarker = UIView()
        sourceMarker.translatesAutoresizingMaskIntoConstraints = true
        sourceMarker.backgroundColor = .clear
        sourceMarker.isUserInteractionEnabled = false
        sourceMarker.isAccessibilityElement = true
        sourceMarker.accessibilityIdentifier = "chat.jank.maxDownwardSource"
        sourceMarker.accessibilityValue = ""
        view.addSubview(sourceMarker)
        uiTestJankMaxSourceMarker = sourceMarker

        let startButton = UIButton(type: .custom)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.alpha = 0.2
        startButton.isAccessibilityElement = true
        startButton.accessibilityIdentifier = "chat.jank.start"
        startButton.addTarget(self, action: #selector(handleUiTestJankStart), for: .touchUpInside)
        view.addSubview(startButton)
        uiTestJankStartButton = startButton
        NSLayoutConstraint.activate([
            startButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            startButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            startButton.widthAnchor.constraint(equalToConstant: 44),
            startButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
#endif

    private func observeDebugSettingsChanges() {
#if DEBUG
        debugSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDebugOverlayVisibility()
        }
#endif
    }

    private func updateDebugOverlayVisibility() {
#if DEBUG
        let isVisible = DebugSettings.showChatOverlays
        if isVisible {
            debugYellowOverlay.isHidden = false
            debugRedOverlay.isHidden = false
            debugGreenOverlay.isHidden = false
            debugYellowLabel.isHidden = false
            debugRedLabel.isHidden = false
            debugGreenLabel.isHidden = false
            debugPillLine.isHidden = false
            debugInfoLabel.isHidden = false
            extraSpacerView.isHidden = false
            bottomSpacerView.isHidden = false
            belowPillSpacerView.isHidden = false
            extraSpacerLabel.isHidden = false
            bottomSpacerLabel.isHidden = false
            belowPillSpacerLabel.isHidden = false
        } else {
            debugYellowOverlay.isHidden = true
            debugRedOverlay.isHidden = true
            debugGreenOverlay.isHidden = true
            debugYellowLabel.isHidden = true
            debugRedLabel.isHidden = true
            debugGreenLabel.isHidden = true
            debugMessageLine.isHidden = true
            debugPillLine.isHidden = true
            debugInfoLabel.isHidden = true
            extraSpacerView.isHidden = true
            bottomSpacerView.isHidden = true
            belowPillSpacerView.isHidden = true
            extraSpacerLabel.isHidden = true
            bottomSpacerLabel.isHidden = true
            belowPillSpacerLabel.isHidden = true
        }
#endif
    }

    private func updateUiTestMarkers() {
#if DEBUG
        guard let marker = uiTestAssistantBottomMarker else { return }
        let frame = lastAssistantMessageFrameInView()
        if frame == .zero {
            marker.frame = .zero
            uiTestAssistantTextBottomMarker?.frame = .zero
            if let insetMarker = uiTestBottomInsetMarker {
                insetMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                insetMarker.accessibilityValue = "0"
            }
            if let overlapMarker = uiTestKeyboardOverlapMarker {
                overlapMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                overlapMarker.accessibilityValue = "0"
            }
            if let holdMarker = uiTestToolCallHoldMarker {
                holdMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                holdMarker.accessibilityValue = "0"
            }
            if let inputBarMarker = uiTestInputBarConstantMarker {
                inputBarMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                inputBarMarker.accessibilityValue = "0"
            }
            return
        }
        let scale = max(1, view.traitCollection.displayScale)
        let bottomY = pixelAlign(frame.maxY, scale: scale)
        let assistantTextBottom = max(
            0,
            pixelAlign(
                frame.maxY - MarkdownLayoutConfig.default.assistantMessageBottomPadding,
                scale: scale
            )
        )
        let clampedX = max(0, min(frame.minX, view.bounds.maxX - 1))
        marker.frame = CGRect(x: clampedX, y: bottomY - 1, width: 1, height: 1)
        if let textMarker = uiTestAssistantTextBottomMarker {
            textMarker.frame = CGRect(x: clampedX, y: assistantTextBottom - 1, width: 1, height: 1)
        }
            if let insetMarker = uiTestBottomInsetMarker {
                let insetHeight = pixelAlign(scrollView.contentInset.bottom, scale: scale)
                insetMarker.frame = CGRect(x: 0, y: 0, width: 1, height: insetHeight)
                insetMarker.accessibilityValue = String(format: "%.1f", insetHeight)
            }
            if let fitsMarker = uiTestContentFitsMarker {
                let contentHeight = naturalContentHeight()
                let fits = contentFitsAboveInput(
                    contentHeight: contentHeight,
                    boundsHeight: scrollView.bounds.height,
                    topInset: scrollView.adjustedContentInset.top,
                    bottomInset: scrollView.contentInset.bottom
                )
                fitsMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                fitsMarker.accessibilityValue = fits ? "1" : "0"
            }
            if let overlapMarker = uiTestKeyboardOverlapMarker {
                let overlap = pixelAlign(currentKeyboardOverlap(), scale: scale)
                let overlapHeight = max(1, overlap)
                overlapMarker.frame = CGRect(x: 0, y: 0, width: 1, height: overlapHeight)
                overlapMarker.accessibilityValue = String(format: "%.1f", overlap)
            }
            if let holdMarker = uiTestToolCallHoldMarker {
                holdMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                holdMarker.accessibilityValue = toolCallSheetHoldKeyboardOverlap ? "1" : "0"
            }
            if let inputBarMarker = uiTestInputBarConstantMarker {
                inputBarMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                inputBarMarker.accessibilityValue = String(format: "%.1f", inputBarBottomConstraint.constant)
            }
        updateUiTestJankMarkers()
#endif
    }

#if DEBUG
    private func updateUiTestJankMarkers() {
        guard uiTestJankMonitorEnabled else { return }
        if let maxMarker = uiTestJankMaxDownMarker {
            maxMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            maxMarker.accessibilityValue = String(format: "%.3f", uiTestJankMaxDownwardDelta)
        }
        if let sourceMarker = uiTestJankMaxSourceMarker {
            sourceMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            sourceMarker.accessibilityValue = uiTestJankMaxDownwardSource
        }
        if let sampleMarker = uiTestJankSampleCountMarker {
            sampleMarker.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            sampleMarker.accessibilityValue = "\(uiTestJankSampleCount)"
        }
    }
#endif

    private func setupTopFade() {
        topFadeView = TopFadeView()
        topFadeView.translatesAutoresizingMaskIntoConstraints = false
        topFadeView.isUserInteractionEnabled = false
        view.addSubview(topFadeView)
    }

    private func setupBottomFade() {
        bottomFadeView = BottomFadeView()
        bottomFadeView.translatesAutoresizingMaskIntoConstraints = false
        bottomFadeView.isUserInteractionEnabled = false
        view.insertSubview(bottomFadeView, belowSubview: inputBarVC.view)
    }

    private func setupConstraints() {
        inputBarBottomConstraint = inputBarVC.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: 0)
        contentStackBottomConstraint = contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: 0)
        contentStackTopConstraint = contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 0)
        contentStackMinHeightConstraint = contentStack.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor, constant: 0)
        contentStackMinHeightConstraint.priority = .defaultLow
        topFadeHeightConstraint = topFadeView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStackTopConstraint,
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStackBottomConstraint,
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
            contentStackMinHeightConstraint,

            inputBarVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBarVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBarBottomConstraint,

            topFadeView.topAnchor.constraint(equalTo: view.topAnchor),
            topFadeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topFadeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topFadeHeightConstraint,

            bottomFadeView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomFadeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFadeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomFadeView.topAnchor.constraint(equalTo: inputBarVC.view.topAnchor)
        ])

    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if shouldLogChatGeometry {
            log("  view.window: \(String(describing: view.window))")
            log("  inputBarVC.view.bounds: \(inputBarVC.view.bounds)")
        }
        if isInputBarMeasuring, inputBarVC.view.bounds.height > 1 {
            isInputBarMeasuring = false
            inputBarVC.view.alpha = 1
        }
        guard view.window != nil,
              view.bounds.width > 1,
              view.bounds.height > 1 else {
            return
        }
        updateTopFadeHeightIfNeeded()
        updateTopInsetIfNeeded()
        let keyboardAnimating = isKeyboardAnimating
        updateBottomInsetsForKeyboard(animated: keyboardAnimating)
        updateContentMinHeightIfNeeded()
        if !keyboardAnimating {
            clampContentOffsetIfNeeded(keyboardOverlap: currentKeyboardOverlap())
        }
        maybeScrollToBottomIfNeeded()
        alignShortThreadToTopIfNeeded(reason: "layout")
        let scale = max(1, view.traitCollection.displayScale)
        let pillTopY = currentPillTopY(scale: scale)
        previousLayoutPillTopY = lastLayoutPillTopY
        lastLayoutPillTopY = pillTopY
        logContentGeometry(reason: "viewDidLayoutSubviews")
        logVisibleMessages(reason: "viewDidLayoutSubviews")
        updateUiTestMarkers()
        if !didLogGeometryOnce, view.window != nil {
            didLogGeometryOnce = true
            logContentGeometry(reason: "layoutOnce")
            logVisibleMessages(reason: "layoutOnce")
        }
    }

    private func updateTopInsetIfNeeded() {
        let safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top

        // Safe area already accounts for the navigation bar; add a small padding below it.
        let newTopInset = safeTop + 46

        log("updateScrollViewInsets:")
        log("  safeTop: \(safeTop)")
        log("  newTopInset: \(newTopInset)")

        if abs(lastAppliedTopInset - newTopInset) > 0.5 {
            scrollView.contentInset.top = newTopInset
            scrollView.verticalScrollIndicatorInsets.top = newTopInset
            lastAppliedTopInset = newTopInset
            alignShortThreadToTopIfNeeded(reason: "topInset")
        }
    }

    private func updateContentMinHeightIfNeeded() {
        let contentHeight = naturalContentHeight()
        let boundsHeight = scrollView.bounds.height
        let topInset = scrollView.adjustedContentInset.top
        let desiredGap = max(-20, min(120, bottomMessageGap))
        let scale = max(1, view.traitCollection.displayScale)
        let pillTopY = currentPillTopY(scale: scale)
        let keyboardOverlap = currentKeyboardOverlap()
        let viewBottomY = pixelAlign(view.bounds.maxY, scale: scale)
        let messageCount = messageArrangedViews().count
        let fits = messageCount <= 3 || shortThreadFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            pillTopY: pillTopY,
            keyboardOverlap: keyboardOverlap,
            desiredGap: desiredGap,
            viewBottomY: viewBottomY,
            scale: scale
        )
        if fits {
            if contentStackMinHeightConstraint.isActive {
                contentStackMinHeightConstraint.isActive = false
            }
        } else {
            let targetConstant: CGFloat = lastAppliedTopInset
            if !contentStackMinHeightConstraint.isActive {
                contentStackMinHeightConstraint.isActive = true
            }
            if abs(contentStackMinHeightConstraint.constant - targetConstant) > 0.5 {
                contentStackMinHeightConstraint.constant = targetConstant
            }
        }
    }

    private func naturalContentHeight() -> CGFloat {
        let targetWidth = max(1, scrollView.bounds.width - 32)
        let wasActive = contentStackMinHeightConstraint.isActive
        if wasActive {
            contentStackMinHeightConstraint.isActive = false
        }
        let size = contentStack.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        if wasActive {
            contentStackMinHeightConstraint.isActive = true
        }
        lastMeasuredNaturalHeight = size.height
        return size.height
    }

    private func scrollableContentHeight() -> CGFloat {
        var contentSizeHeight = scrollView.contentSize.height
#if DEBUG
        if uiTestUnderreportContentSize, contentSizeHeight > 1 {
            contentSizeHeight = max(1, contentSizeHeight * 0.2)
        }
#endif
        let cachedNaturalHeight = lastMeasuredNaturalHeight
        if contentSizeHeight > 1 {
            if cachedNaturalHeight > 1 {
                return max(contentSizeHeight, cachedNaturalHeight)
            }
            return contentSizeHeight
        }
        if cachedNaturalHeight > 1 {
            return cachedNaturalHeight
        }
        return naturalContentHeight()
    }

    private func effectiveContentHeight() -> CGFloat {
        let naturalHeight = naturalContentHeight()
        let contentSizeHeight = scrollView.contentSize.height
        if contentSizeHeight > 1 {
            return max(naturalHeight, contentSizeHeight)
        }
        return naturalHeight
    }

    private func updateBottomInsetsForKeyboard(
        animated: Bool = false,
        animateHeightChanges _: Bool = false,
        force: Bool = false
    ) {
        if !force {
            if isUpdatingBottomInsets {
                pendingBottomInsetsUpdate = true
                return
            }
            if isKeyboardAnimating && !animated {
                pendingBottomInsetsUpdate = true
                return
            }
        }
        isUpdatingBottomInsets = true
        defer {
            isUpdatingBottomInsets = false
            if pendingBottomInsetsUpdate {
                if !isKeyboardAnimating {
                    pendingBottomInsetsUpdate = false
                    DispatchQueue.main.async { [weak self] in
                        self?.updateBottomInsetsForKeyboard()
                    }
                }
            }
        }
        let scale = max(1, view.traitCollection.displayScale)
        view.layoutIfNeeded()
        let naturalHeight = naturalContentHeight()
        let contentHeightForOffset = scrollableContentHeight()
        let oldPillFrame = computedPillFrameInView()
        let currentPillTopY = pixelAlign(inputBarVC.view.frame.minY + oldPillFrame.minY, scale: scale)
        let fallbackOldPillTopY = lastLayoutPillTopY ?? currentPillTopY
        let liveOldPillTopY = animated ? currentPillTopY : (lastAppliedPillTopY ?? fallbackOldPillTopY)
        let liveOldOffsetY = scrollView.contentOffset.y
        let oldBottomInset = lastAppliedBottomInset ?? scrollView.contentInset.bottom
        let liveOldMaxOffsetY = max(0, contentHeightForOffset - scrollView.bounds.height + oldBottomInset)
        let liveDistanceFromBottom = max(0, liveOldMaxOffsetY - liveOldOffsetY)
        let desiredGap: CGFloat = max(-20, min(120, bottomMessageGap))
        let bottomAnchorTolerance = max(2, desiredGap)
        let liveIsAtBottom = liveDistanceFromBottom <= bottomAnchorTolerance
        let transitionSnapshot = pendingKeyboardTransition
        let useTransitionSnapshot = transitionSnapshot?.applied == false
        let oldPillTopY = useTransitionSnapshot ? (transitionSnapshot?.oldPillTopY ?? liveOldPillTopY) : liveOldPillTopY
        let oldOffsetY = useTransitionSnapshot ? (transitionSnapshot?.oldOffsetY ?? liveOldOffsetY) : liveOldOffsetY
        let rawDistanceFromBottom = useTransitionSnapshot ? (transitionSnapshot?.distanceFromBottom ?? liveDistanceFromBottom) : liveDistanceFromBottom
        let isScrollIdle = !scrollView.isDragging && !scrollView.isDecelerating
        let shouldAssumeBottom = !hasUserScrolled && isScrollIdle
        let lastMessageIndex = messageArrangedViews().count - 1
        let messageCount = max(0, lastMessageIndex + 1)
        let lastMessageGap = lastMessageIndex >= 0
            ? anchorSample(index: lastMessageIndex, pillTopY: oldPillTopY)?.gap
            : nil
        let gapAnchored = lastMessageGap.map { gap in
            gap >= 0 && abs(gap - desiredGap) <= bottomAnchorTolerance
        } ?? false
        let wasAnchoredToBottom = isScrollIdle
            && ((useTransitionSnapshot ? (transitionSnapshot?.wasAtBottom ?? liveIsAtBottom) : liveIsAtBottom)
                || gapAnchored
                || shouldAssumeBottom)
        let visibleAnchorIndex = {
            let anchor = visibleMessageAnchor()
            return anchor.index >= 0 ? anchor.index : nil
        }()
        let anchorIndex = visibleAnchorIndex ?? anchorCandidateIndex(pillTopY: oldPillTopY)
        let oldAnchorSample = anchorIndex.flatMap { anchorSample(index: $0, pillTopY: oldPillTopY) }
        lastAnchorIndexUsed = oldAnchorSample?.index

        let applyUpdates = { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            var measuredOverlap: CGFloat
            var guideVisible: Bool
            #if DEBUG
            if let uiTestKeyboardOverlap = self.uiTestKeyboardOverlap {
                measuredOverlap = uiTestKeyboardOverlap
                if let visibilityOverride = self.uiTestKeyboardVisibilityOverride {
                    guideVisible = visibilityOverride
                } else {
                    guideVisible = uiTestKeyboardOverlap > 1
                }
            } else {
                let resolved = self.keyboardOverlapFromLayoutGuide()
                measuredOverlap = resolved.overlap
                guideVisible = resolved.isVisible
            }
            #else
            let resolved = self.keyboardOverlapFromLayoutGuide()
            measuredOverlap = resolved.overlap
            guideVisible = resolved.isVisible
            #endif
            if self.toolCallSheetHoldKeyboardOverlap {
                if measuredOverlap > 1 && !self.toolCallSheetIsPresented {
                    self.toolCallSheetHoldKeyboardOverlap = false
                    self.toolCallSheetKeyboardOverlap = nil
                    self.toolCallSheetPinnedInputBarConstant = nil
                    self.toolCallSheetPinnedPillBottomY = nil
                    self.toolCallSheetReleaseWorkItem?.cancel()
                    self.toolCallSheetReleaseWorkItem = nil
                } else if measuredOverlap <= 1 {
                    let fallbackOverlap = abs(self.toolCallSheetPinnedInputBarConstant ?? self.inputBarBottomConstraint.constant)
                    let lockedOverlap = self.toolCallSheetKeyboardOverlap ?? max(2, fallbackOverlap)
                    measuredOverlap = lockedOverlap
                    guideVisible = true
                }
            }
            let keyboardOverlap: CGFloat
            let shouldUseLockedOverlap = !animated
                && guideVisible
                && self.lockedKeyboardOverlap != nil
                && !self.scrollView.isTracking
                && !self.scrollView.isDecelerating
            if shouldUseLockedOverlap, let lockedOverlap = self.lockedKeyboardOverlap {
                keyboardOverlap = lockedOverlap
            } else {
                keyboardOverlap = measuredOverlap
            }
            let keyboardVisible = guideVisible && keyboardOverlap > 1
            let previousKeyboardOverlap = self.lastKeyboardOverlap
            let wasKeyboardVisible = (previousKeyboardOverlap ?? 0) > 1
            let isOpeningKeyboard = keyboardVisible && !wasKeyboardVisible
            let isClosingKeyboard = !keyboardVisible && wasKeyboardVisible
            let effectiveBarYOffset = keyboardVisible ? min(0, self.inputBarYOffset) : self.inputBarYOffset
            var adjustedInputBarConstant = effectiveBarYOffset
            if self.toolCallSheetHoldKeyboardOverlap,
               let pinnedConstant = self.toolCallSheetPinnedInputBarConstant,
               adjustedInputBarConstant > pinnedConstant {
                adjustedInputBarConstant = pinnedConstant
            }
            let keyboardIsMovingDown = self.keyboardIsMovingDown(current: keyboardOverlap)
            let gestureIsDismissing = self.isDismissingKeyboardGesture()
            if !animated {
                if keyboardVisible, self.lockedKeyboardOverlap == nil {
                    self.lockedKeyboardOverlap = keyboardOverlap
                    #if DEBUG
                    DebugLog.addDedup("keyboard.lock", "Locked keyboard overlap \(String(format: "%.1f", keyboardOverlap))")
                    #endif
                } else if !keyboardVisible {
                    self.lockedKeyboardOverlap = nil
                    #if DEBUG
                    DebugLog.addDedup("keyboard.lock", "Cleared keyboard overlap lock")
                    #endif
                }
            }
            #if DEBUG
            if keyboardVisible != self.isKeyboardVisible {
                DebugLog.addDedup("keyboard.visibility", "Keyboard visibility change target=\(keyboardVisible) measured=\(String(format: "%.1f", measuredOverlap)) overlap=\(String(format: "%.1f", keyboardOverlap)) adjustedConst=\(String(format: "%.1f", adjustedInputBarConstant)) barYOffset=\(String(format: "%.1f", self.inputBarYOffset))")
            }
            #endif
            self.updateInteractiveDismissalAnchorIfNeeded(
                keyboardOverlap: keyboardOverlap,
                keyboardIsMovingDown: keyboardIsMovingDown,
                gestureIsDismissing: gestureIsDismissing
            )
            self.lastKeyboardOverlap = keyboardOverlap

            if isOpeningKeyboard {
                self.keyboardBaselineOffsetY = oldOffsetY
            }

            let shouldFreezeKeyboard = keyboardOverlap > 1
                && self.scrollView.keyboardDismissMode == .interactive
                && !self.scrollView.isTracking
                && !self.scrollView.isDecelerating
            let previousDismissMode = self.scrollView.keyboardDismissMode
            if shouldFreezeKeyboard {
                self.scrollView.keyboardDismissMode = .none
            }
            defer {
                if shouldFreezeKeyboard {
                    self.scrollView.keyboardDismissMode = previousDismissMode
                }
            }

            var needsLayout = false
            if keyboardVisible != self.isKeyboardVisible {
                self.isKeyboardVisible = keyboardVisible
                let horizontalPadding: CGFloat = keyboardVisible ? 12 : 20
                let bottomPadding: CGFloat = keyboardVisible ? 8 : 28
                let animationDuration = animated ? self.keyboardAnimationDuration : 0
                self.inputBarVC.updateLayout(
                    horizontalPadding: horizontalPadding,
                    bottomPadding: bottomPadding,
                    animationDuration: animationDuration
                )
                self.lockedKeyboardOverlap = keyboardVisible ? keyboardOverlap : nil
                needsLayout = true
            }

            if abs(self.inputBarBottomConstraint.constant - adjustedInputBarConstant) > 0.5 {
                #if DEBUG
                DebugLog.addDedup("keyboard.bottom", "InputBar bottom constant \(String(format: "%.1f", self.inputBarBottomConstraint.constant)) -> \(String(format: "%.1f", adjustedInputBarConstant)) keyboardVisible=\(keyboardVisible)")
                #endif
                self.inputBarBottomConstraint.constant = adjustedInputBarConstant
                needsLayout = true
            }

            if needsLayout {
                self.view.layoutIfNeeded()
            }

            let isInteractiveDismissal = keyboardOverlap > 1
                && self.isInteractiveDismissalActive
                && self.interactiveDismissalAnchor != nil

            var pillFrame = self.computedPillFrameInView()
            var pillTopY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
            var pillBottomY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.maxY, scale: scale)
            let deltaPill = pillTopY - oldPillTopY
            let shouldLockPillBottom = !animated
                && keyboardVisible
                && keyboardOverlap > 1
                && !self.keyboardIsMoving(current: keyboardOverlap)
                && !self.scrollView.isTracking
                && !self.scrollView.isDecelerating
                && !isInteractiveDismissal
                && !gestureIsDismissing
            if shouldLockPillBottom {
                if let lockedBottom = self.lockedPillBottomY {
                    let delta = self.pixelAlign(lockedBottom - pillBottomY, scale: scale)
                    if abs(delta) > 0.1 {
                        self.inputBarBottomConstraint.constant += delta
                        self.view.layoutIfNeeded()
                        pillFrame = self.computedPillFrameInView()
                        pillTopY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
                        pillBottomY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.maxY, scale: scale)
                    }
                } else {
                    self.lockedPillBottomY = pillBottomY
                }
            } else {
                self.lockedPillBottomY = nil
            }
            if self.toolCallSheetHoldKeyboardOverlap, let pinnedBottom = self.toolCallSheetPinnedPillBottomY {
                let maxBottomY = pinnedBottom + 0.5
                if pillBottomY > maxBottomY {
                    let delta = self.pixelAlign(maxBottomY - pillBottomY, scale: scale)
                    if abs(delta) > 0.1 {
                        self.inputBarBottomConstraint.constant += delta
                        self.view.layoutIfNeeded()
                        pillFrame = self.computedPillFrameInView()
                        pillTopY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
                        pillBottomY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.maxY, scale: scale)
                    }
                }
            }
            let viewBottomY = self.pixelAlign(self.view.bounds.maxY, scale: scale)
            if pillBottomY > viewBottomY {
                let delta = self.pixelAlign(viewBottomY - pillBottomY, scale: scale)
                if abs(delta) > 0.1 {
                    self.inputBarBottomConstraint.constant += delta
                    self.view.layoutIfNeeded()
                    pillFrame = self.computedPillFrameInView()
                    pillTopY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
                    pillBottomY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.maxY, scale: scale)
                }
            }
            #if DEBUG
            let keyboardFrame = self.view.keyboardLayoutGuide.layoutFrame
            #endif
            let belowPillGap = max(0, viewBottomY - pillBottomY)
            let targetExtraSpacerHeight = self.pixelAlign(desiredGap, scale: scale)
            let targetBottomSpacerHeight = self.pixelAlign(pillFrame.height, scale: scale)
            let targetBelowPillHeight = self.pixelAlign(belowPillGap, scale: scale)
            var targetBottomInset = self.pixelAlign(max(0, viewBottomY - pillTopY + desiredGap), scale: scale)
            var fitsAboveInput = self.contentFitsAboveInput(
                contentHeight: naturalHeight,
                boundsHeight: self.scrollView.bounds.height,
                topInset: self.scrollView.adjustedContentInset.top,
                bottomInset: targetBottomInset
            )
            let shortThreadFits = messageCount <= 3 || self.shortThreadFitsAboveInput(
                contentHeight: naturalHeight,
                boundsHeight: self.scrollView.bounds.height,
                topInset: self.scrollView.adjustedContentInset.top,
                pillTopY: pillTopY,
                keyboardOverlap: keyboardOverlap,
                desiredGap: desiredGap,
                viewBottomY: viewBottomY,
                scale: scale
            )
#if DEBUG
            if self.uiTestFakeKeyboardEnabled && !shortThreadFits {
                let minInsetForScroll = max(0, self.scrollView.bounds.height - naturalHeight + keyboardOverlap)
                if targetBottomInset < minInsetForScroll {
                    targetBottomInset = minInsetForScroll
                }
                fitsAboveInput = self.contentFitsAboveInput(
                    contentHeight: naturalHeight,
                    boundsHeight: self.scrollView.bounds.height,
                    topInset: self.scrollView.adjustedContentInset.top,
                    bottomInset: targetBottomInset
                )
            }
#endif
            let preferTopAnchor = shortThreadFits
            let shouldAnchorToBottom = !hasUserScrolled
                && wasAnchoredToBottom
                && !preferTopAnchor
                && (!fitsAboveInput || gapAnchored || keyboardVisible || useTransitionSnapshot)
            let restoreBaselineOffsetY = isClosingKeyboard
                ? self.keyboardBaselineOffsetY
                : nil
            if isClosingKeyboard {
                self.keyboardBaselineOffsetY = nil
            }
            let shouldKeepOffsetFloor = shouldAnchorToBottom
                && keyboardVisible
                && !keyboardIsMovingDown
                && !isInteractiveDismissal
                && !gestureIsDismissing
                && !self.scrollView.isTracking
                && !self.scrollView.isDecelerating
            if shouldKeepOffsetFloor {
                let baseline = self.keyboardOpenOffsetFloor ?? oldOffsetY
                self.keyboardOpenOffsetFloor = max(baseline, oldOffsetY)
            } else if !keyboardVisible
                        || keyboardIsMovingDown
                        || isInteractiveDismissal
                        || gestureIsDismissing
                        || self.scrollView.isTracking
                        || self.scrollView.isDecelerating
                        || !shouldAnchorToBottom {
                self.keyboardOpenOffsetFloor = nil
            }
            if self.extraSpacerHeightConstraint.constant != 0 {
                self.extraSpacerHeightConstraint.constant = 0
            }
            if self.bottomSpacerHeightConstraint.constant != 0 {
                self.bottomSpacerHeightConstraint.constant = 0
            }
            if self.belowPillSpacerHeightConstraint.constant != 0 {
                self.belowPillSpacerHeightConstraint.constant = 0
            }

            #if DEBUG
            log("CMUX_CHAT_SPACER keyboard=\(keyboardVisible) pillTop=\(pillTopY) pillBottom=\(pillBottomY) belowGap=\(belowPillGap) extra=\(targetExtraSpacerHeight) red=\(targetBottomSpacerHeight) green=\(targetBelowPillHeight) inputBarFrame=\(self.inputBarVC.view.frame)")
            #endif
            if self.scrollView.contentInset.bottom != targetBottomInset {
                self.scrollView.contentInset.bottom = targetBottomInset
                self.scrollView.verticalScrollIndicatorInsets.bottom = targetBottomInset
            }
            self.lastAppliedBottomInset = targetBottomInset
            self.lastAppliedPillTopY = pillTopY

            self.view.layoutIfNeeded()
            self.scrollView.layoutIfNeeded()

            let maxOffsetYForInset: (CGFloat) -> CGFloat = { inset in
                max(0, contentHeightForOffset - self.scrollView.bounds.height + inset)
            }
            var newMaxOffsetY = maxOffsetYForInset(targetBottomInset)
            var deltaInset = targetBottomInset - oldBottomInset
            let shouldAdjustOffset = animated || abs(deltaPill) > 0.5 || oldAnchorSample != nil || useTransitionSnapshot
            if shouldAdjustOffset {
                let adjustedTop = self.scrollView.adjustedContentInset.top
                var minY = -adjustedTop
                var maxY = max(minY, newMaxOffsetY)
                if let offsetFloor = self.keyboardOpenOffsetFloor,
                   shouldAnchorToBottom,
                   keyboardVisible,
                   !keyboardIsMovingDown {
                    maxY = max(maxY, offsetFloor)
                }
                if isInteractiveDismissal {
                    let slack = self.interactiveDismissalSlack(currentOverlap: keyboardOverlap)
                    if slack > 0.5 {
                        minY -= slack
                        maxY += slack
                    }
                }

                var targetOffsetY = oldOffsetY - deltaPill
                if isInteractiveDismissal {
                    if self.isInteractiveDismissalActive, let anchor = self.interactiveDismissalAnchor {
                        if anchor.anchorIndex >= 0,
                           let anchorGap = anchor.anchorGap,
                           let anchorContentBottom = self.anchorBottomContentY(index: anchor.anchorIndex) {
                            let desiredAnchorBottomY = pillTopY - anchorGap
                            targetOffsetY = anchorContentBottom - desiredAnchorBottomY
                        } else {
                            let deltaFromStart = pillTopY - anchor.startPillTopY
                            targetOffsetY = anchor.startOffsetY - deltaFromStart
                        }
                    }
                }
                if !isInteractiveDismissal,
                   !shouldAnchorToBottom,
                   let oldAnchorSample,
                   let anchorContentBottom = self.anchorBottomContentY(index: oldAnchorSample.index) {
                    let desiredAnchorBottomY = pillTopY - oldAnchorSample.gap
                    targetOffsetY = anchorContentBottom - desiredAnchorBottomY
                }
                if !isInteractiveDismissal, self.hasUserScrolled {
                    targetOffsetY = oldOffsetY - deltaPill
                }
                if !isInteractiveDismissal {
                    if shouldAnchorToBottom {
                        targetOffsetY = newMaxOffsetY
                    } else if (fitsAboveInput || preferTopAnchor)
                                && !self.hasUserScrolled
                                && !keyboardVisible
                                && !wasKeyboardVisible {
                        targetOffsetY = minY
                    }
                }
                if let restoreBaselineOffsetY, !self.hasUserScrolled {
                    targetOffsetY = restoreBaselineOffsetY
                }
                if let offsetFloor = self.keyboardOpenOffsetFloor,
                   shouldAnchorToBottom,
                   keyboardVisible,
                   !keyboardIsMovingDown {
                    targetOffsetY = max(targetOffsetY, offsetFloor)
                }

                let desiredSyncOffsetY = oldOffsetY - deltaPill
                if keyboardVisible {
                    let requiredOffsetY = isInteractiveDismissal
                        ? targetOffsetY
                        : max(targetOffsetY, desiredSyncOffsetY)
                    if requiredOffsetY > maxY + 0.5 {
                        let requiredInset = requiredOffsetY - (contentHeightForOffset - self.scrollView.bounds.height)
                        let clampedInset = max(0, requiredInset)
                        if clampedInset > targetBottomInset + 0.5 {
                            targetBottomInset = self.pixelAlign(clampedInset, scale: scale)
                            self.scrollView.contentInset.bottom = targetBottomInset
                            self.scrollView.verticalScrollIndicatorInsets.bottom = targetBottomInset
                            self.lastAppliedBottomInset = targetBottomInset
                            newMaxOffsetY = maxOffsetYForInset(targetBottomInset)
                            deltaInset = targetBottomInset - oldBottomInset
                            maxY = max(minY, newMaxOffsetY)
                        }
                    }
                }
                targetOffsetY = min(max(targetOffsetY, minY), maxY)
                targetOffsetY = self.pixelAlign(targetOffsetY, scale: scale)
                if useTransitionSnapshot, var transition = self.pendingKeyboardTransition, !transition.applied {
                    transition.applied = true
                    self.pendingKeyboardTransition = transition
                }
                self.scrollView.contentOffset.y = targetOffsetY
                self.lastOffsetDebug = String(format: "off=%.1f->%.1f", oldOffsetY, targetOffsetY)
                self.lastPillShiftDebug = String(format: "Δpill=%.1f Δinset=%.1f", deltaPill, deltaInset)

                var gapDelta: CGFloat = 0
                if !shouldAnchorToBottom,
                   let oldAnchorSample,
                   let newAnchorSample = self.anchorSample(index: oldAnchorSample.index, pillTopY: pillTopY) {
                    gapDelta = newAnchorSample.gap - oldAnchorSample.gap
                }
                let gapIndex = oldAnchorSample?.index ?? -1
                self.lastGapDebug = String(format: "gapΔ=%.1f idx=%d", gapDelta, gapIndex)
            }

            if preferTopAnchor {
                self.alignShortThreadToTopIfNeeded(reason: "bottomInsets")
            }

            #if DEBUG
            if DebugSettings.showChatOverlays {
                let overlayWidth = self.view.bounds.width
                let redTop = pillTopY
                self.debugYellowOverlay.frame = CGRect(
                    x: 0,
                    y: redTop - targetExtraSpacerHeight,
                    width: overlayWidth,
                    height: targetExtraSpacerHeight
                )
                self.debugRedOverlay.frame = CGRect(
                    x: 0,
                    y: redTop,
                    width: overlayWidth,
                    height: targetBottomSpacerHeight
                )
                self.debugGreenOverlay.frame = CGRect(
                    x: 0,
                    y: redTop + targetBottomSpacerHeight,
                    width: overlayWidth,
                    height: targetBelowPillHeight
                )
                let overlayLabelWidth: CGFloat = 140
                let overlayLabelHeight: CGFloat = 18
                self.debugYellowLabel.text = String(format: "yellow=%.1f", targetExtraSpacerHeight)
                self.debugYellowLabel.frame = CGRect(
                    x: 8,
                    y: max(0, redTop - targetExtraSpacerHeight - overlayLabelHeight),
                    width: overlayLabelWidth,
                    height: overlayLabelHeight
                )
                self.debugRedLabel.text = String(format: "red=%.1f", targetBottomSpacerHeight)
                self.debugRedLabel.frame = CGRect(
                    x: 8,
                    y: redTop + 2,
                    width: overlayLabelWidth,
                    height: overlayLabelHeight
                )
                self.debugGreenLabel.text = String(format: "green=%.1f", targetBelowPillHeight)
                self.debugGreenLabel.frame = CGRect(
                    x: 8,
                    y: redTop + targetBottomSpacerHeight + 2,
                    width: overlayLabelWidth,
                    height: overlayLabelHeight
                )
                let lastMessageFrame = self.lastMessageFrameInView()
                let lastAssistantFrame = self.lastAssistantMessageFrameInView()
                let gapToPill = lastMessageFrame == .zero ? 0 : (pillTopY - lastMessageFrame.maxY)
                let expectedHeight = self.inputBarVC.contentTopInset + self.inputBarVC.contentBottomInset + DebugInputBarMetrics.inputHeight
                let extra = max(0, self.inputBarVC.view.bounds.height - expectedHeight)
                let measured = self.inputBarVC.pillMeasuredFrame
                let shiftSummary = self.lastKeyboardShiftSummary ?? "Δmsg=-- Δpill=-- Δgap=-- Δanch=-- Δvis=--"
                let offsetDebug = self.lastOffsetDebug ?? "off=--"
                let gapDebug = self.lastGapDebug ?? "gapΔ=--"
                let pillShiftDebug = self.lastPillShiftDebug ?? "Δpill=--"
                let pillTopClosed = self.lastPillTopYClosed ?? 0
                let pillTopOpen = self.lastPillTopYOpen ?? 0
                let pillDelta = self.lastPillTopYClosed == nil || self.lastPillTopYOpen == nil ? 0 : (pillTopOpen - pillTopClosed)
                let anchorIndex = self.lastAnchorIndexUsed ?? (self.anchorCandidateIndex(pillTopY: pillTopY) ?? -1)
                let anchorGap = self.anchorSample(index: anchorIndex, pillTopY: pillTopY)?.gap ?? 0
                let lastMessageBottom = lastMessageFrame == .zero ? 0 : self.pixelAlign(lastMessageFrame.maxY, scale: scale)
                let lastAssistantBottom = lastAssistantFrame == .zero ? 0 : self.pixelAlign(lastAssistantFrame.maxY, scale: scale)
                let assistantGapToPill = lastAssistantFrame == .zero ? 0 : (pillTopY - lastAssistantBottom)
                DebugLog.addDedup(
                    "chat.position",
                    String(
                        format: "Chat position pillTop=%.1f pillBottom=%.1f lastMsgBottom=%.1f lastAsstBottom=%.1f gapAsst=%.1f bottomInset=%.1f contentH=%.1f boundsH=%.1f inputBarY=%.1f inputBarH=%.1f",
                        pillTopY,
                        pillBottomY,
                        lastMessageBottom,
                        lastAssistantBottom,
                        assistantGapToPill,
                        self.scrollView.contentInset.bottom,
                        self.scrollView.contentSize.height,
                        self.scrollView.bounds.height,
                        self.inputBarVC.view.frame.minY,
                        self.inputBarVC.view.bounds.height
                    )
                )
                self.debugInfoLabel.text = String(
                    format: "barH=%.1f pillY=%.1f pillH=%.1f gap=%.1f\nmeasY=%.1f measH=%.1f extra=%.1f below=%.1f\nkbdH=%.1f kbdMinY=%.1f kbdVis=%@ dist=%.1f anchor=%@ idx=%ld aGap=%.1f %@ %@ %@ pΔ=%.1f",
                    self.inputBarVC.view.bounds.height,
                    pillTopY,
                    self.inputBarVC.pillHeight,
                    gapToPill,
                    measured.minY,
                    measured.height,
                    extra,
                    belowPillGap,
                    keyboardOverlap,
                    keyboardFrame.minY,
                    keyboardVisible ? "1" : "0",
                    rawDistanceFromBottom,
                    shouldAnchorToBottom ? "1" : "0",
                    anchorIndex,
                    anchorGap,
                    offsetDebug,
                    gapDebug,
                    pillShiftDebug,
                    shiftSummary,
                    pillDelta
                )
                self.extraSpacerLabel.text = String(format: "h=%.1f c=%.1f", self.extraSpacerView.bounds.height, 0.0)
                self.bottomSpacerLabel.text = String(format: "h=%.1f c=%.1f", self.bottomSpacerView.bounds.height, 0.0)
                self.belowPillSpacerLabel.text = String(format: "h=%.1f c=%.1f", self.belowPillSpacerView.bounds.height, 0.0)
                let labelWidth = self.view.bounds.width - 16
                self.debugInfoLabel.frame = CGRect(x: 8, y: 8, width: labelWidth, height: 60)
                self.debugInfoLabel.sizeToFit()
                let labelHeight = min(60, max(36, self.debugInfoLabel.bounds.height + 8))
                self.debugInfoLabel.frame = CGRect(x: 8, y: 8, width: labelWidth, height: labelHeight)
                self.view.bringSubviewToFront(self.debugYellowOverlay)
                self.view.bringSubviewToFront(self.debugRedOverlay)
                self.view.bringSubviewToFront(self.debugGreenOverlay)
                if lastMessageFrame != .zero {
                    self.debugMessageLine.isHidden = false
                    self.debugMessageLine.frame = CGRect(
                        x: 0,
                        y: lastMessageFrame.maxY,
                        width: overlayWidth,
                        height: 1
                    )
                } else {
                    self.debugMessageLine.isHidden = true
                }
                self.debugPillLine.frame = CGRect(
                    x: 0,
                    y: pillTopY,
                    width: overlayWidth,
                    height: 1
                )
                self.view.bringSubviewToFront(self.debugMessageLine)
                self.view.bringSubviewToFront(self.debugPillLine)
                self.view.bringSubviewToFront(self.debugYellowLabel)
                self.view.bringSubviewToFront(self.debugRedLabel)
                self.view.bringSubviewToFront(self.debugGreenLabel)
                self.view.bringSubviewToFront(self.debugInfoLabel)
                self.updateDebugOverlayVisibility()
            }
            #endif
            self.updateUiTestMarkers()
        }

        if animated {
            UIView.animate(
                withDuration: keyboardAnimationDuration,
                delay: 0,
                options: keyboardAnimationOptions,
                animations: applyUpdates
            )
        } else {
            applyUpdates()
        }
    }

    private func clampContentOffsetIfNeeded(keyboardOverlap: CGFloat? = nil) {
        let overlap = keyboardOverlap ?? currentKeyboardOverlap()
        let bounds = contentOffsetBounds(keyboardOverlap: overlap)
        let minY = bounds.minY
        var maxY = bounds.maxY
        if isKeyboardVisible,
           !keyboardIsMovingDown(current: overlap),
           let offsetFloor = keyboardOpenOffsetFloor,
           maxY < offsetFloor {
            maxY = offsetFloor
        }
        let currentY = scrollView.contentOffset.y
        if currentY < minY || currentY > maxY {
            let clampedY = min(max(currentY, minY), maxY)
            if abs(clampedY - currentY) > 0.5 {
                scrollView.contentOffset.y = clampedY
            }
        }
    }

    private func contentOffsetBounds(keyboardOverlap: CGFloat? = nil) -> (minY: CGFloat, maxY: CGFloat) {
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.contentInset.bottom
        let contentHeight = effectiveContentHeight()
        let contentHeightForOffset = scrollableContentHeight()
        let boundsHeight = scrollView.bounds.height
        var minY = -topInset
        let maxYRaw = contentHeightForOffset - boundsHeight + bottomInset
        let fits = contentFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        let allowBottomAnchor = (keyboardOverlap ?? 0) > 1 || isKeyboardVisible
        var maxY = fits && !allowBottomAnchor ? minY : maxYRaw
        if shouldPinShortThreadToTop() {
            maxY = minY
        }
        if maxY < minY {
            maxY = minY
        }
        if let keyboardOverlap, isInteractiveDismissalActive {
            let slack = interactiveDismissalSlack(currentOverlap: keyboardOverlap)
            if slack > 0.5 {
                minY -= slack
                maxY += slack
            }
        }
        return (minY: minY, maxY: maxY)
    }

    private func contentFitsAboveInput(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        let availableHeight = boundsHeight - bottomInset
        return contentHeight + topInset <= availableHeight + 1
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let rawDuration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let endValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        let endFrame = endValue?.cgRectValue ?? .zero
        let endInView = view.convert(endFrame, from: nil)
        let viewMaxY = view.bounds.maxY
        let endTop = min(viewMaxY, endInView.minY)
        let willBeVisible = endTop < viewMaxY - 1
        if toolCallSheetHoldKeyboardOverlap && !willBeVisible {
            return
        }
        let isInteractiveDismiss = isDismissingKeyboardGesture()
            || scrollView.isTracking
            || scrollView.isDecelerating
        let visibilityChanged = willBeVisible != isKeyboardVisible
        if !visibilityChanged && !isInteractiveDismiss {
            return
        }
        let duration: Double
        if rawDuration > 0 {
            duration = rawDuration
        } else if !willBeVisible && !isInteractiveDismiss {
            duration = 0.25
        } else {
            duration = 0
        }
        let curveRaw = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        keyboardAnimationDuration = duration
        keyboardAnimationOptions = [curve, .beginFromCurrentState, .allowUserInteraction]
#if DEBUG
        if willBeVisible {
            startUiTestJankWindow(reason: "system_open", duration: duration + 2.2)
        }
#endif
        if duration > 0 {
            isKeyboardAnimating = true
            keyboardAnimationEndWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isKeyboardAnimating = false
                if self.pendingBottomInsetsUpdate {
                    self.pendingBottomInsetsUpdate = false
                    self.updateBottomInsetsForKeyboard()
                }
            }
            keyboardAnimationEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.01, execute: workItem)
        } else {
            isKeyboardAnimating = false
            keyboardAnimationEndWorkItem?.cancel()
            keyboardAnimationEndWorkItem = nil
        }
        pendingKeyboardWillChange(userInfo)
        prepareKeyboardTransitionSnapshot()

        #if DEBUG
        let before = captureDebugSample()
        pendingKeyboardSample = before
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
            guard let self else { return }
            guard let start = self.pendingKeyboardSample else { return }
            let after = self.captureDebugSample(anchorIndexOverride: start.anchorIndex)
            let deltaMsg = after.messageBottomY - start.messageBottomY
            let deltaPill = after.pillTopY - start.pillTopY
            let deltaGap = after.gap - start.gap
            let deltaVis = after.visibleAnchorY - start.visibleAnchorY
            let deltaAnchorGap = after.anchorGap - start.anchorGap
            let syncOk = abs(deltaAnchorGap) <= 1
                && abs(deltaVis - deltaPill) <= 1
            self.lastKeyboardShiftSummary = String(
                format: "Δmsg=%.1f Δpill=%.1f Δgap=%.1f Δanch=%.1f Δvis=%.1f %@",
                deltaMsg,
                deltaPill,
                deltaGap,
                deltaAnchorGap,
                deltaVis,
                syncOk ? "OK" : "OFF"
            )
            self.pendingKeyboardTransition = nil
        }
        #endif

        updateBottomInsetsForKeyboard(animated: true)
        pendingKeyboardTransition = nil
    }

    private func pendingKeyboardWillChange(_ userInfo: [AnyHashable: Any]) {
        guard let endValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let endFrame = endValue.cgRectValue
        let endInView = view.convert(endFrame, from: nil)
        let viewMaxY = view.bounds.maxY
        let endTop = min(viewMaxY, endInView.minY)
        let willBeVisible = endTop < viewMaxY - 1
        let scale = max(1, view.traitCollection.displayScale)
        let pillFrame = inputBarVC.pillFrameInView
        let pillTopY = pixelAlign(inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
        if willBeVisible {
            lastPillTopYOpen = pillTopY
        } else {
            lastPillTopYClosed = pillTopY
        }
    }

    private func prepareKeyboardTransitionSnapshot() {
        view.layoutIfNeeded()
        let scale = max(1, view.traitCollection.displayScale)
        let currentPillTopY = self.currentPillTopY(scale: scale)
        let previousPillTopY = lastAppliedPillTopY ?? previousLayoutPillTopY
        let oldPillTopY: CGFloat
        if let previousPillTopY, abs(currentPillTopY - previousPillTopY) > 1 {
            oldPillTopY = previousPillTopY
        } else {
            oldPillTopY = currentPillTopY
        }
        let oldOffsetY = scrollView.contentOffset.y
        let effectiveBottomInset = lastAppliedBottomInset ?? scrollView.contentInset.bottom
        let oldMaxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + effectiveBottomInset)
        let distanceFromBottom = max(0, oldMaxOffsetY - oldOffsetY)
        let desiredGap = max(-20, min(120, bottomMessageGap))
        let bottomAnchorTolerance = max(2, desiredGap)
        let lastMessageIndex = messageArrangedViews().count - 1
        let lastMessageGap = lastMessageIndex >= 0
            ? anchorSample(index: lastMessageIndex, pillTopY: oldPillTopY)?.gap
            : nil
        let gapAnchored = lastMessageGap.map { gap in
            gap >= 0 && abs(gap - desiredGap) <= bottomAnchorTolerance
        } ?? false
        let wasAtBottom = distanceFromBottom <= bottomAnchorTolerance || gapAnchored
        pendingKeyboardTransition = KeyboardTransition(
            oldPillTopY: oldPillTopY,
            oldOffsetY: oldOffsetY,
            distanceFromBottom: distanceFromBottom,
            wasAtBottom: wasAtBottom,
            applied: false
        )
    }

    private func makeDebugOverlayView(color: UIColor) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = color.withAlphaComponent(0.2)
        view.layer.borderWidth = 1
        view.layer.borderColor = color.cgColor
        view.isUserInteractionEnabled = false
        return view
    }

    private func makeDebugOverlayLabel(color: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = true
        label.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .black
        label.backgroundColor = color.withAlphaComponent(0.25)
        label.textAlignment = .left
        label.layer.borderWidth = 1
        label.layer.borderColor = color.cgColor
        label.layer.cornerRadius = 4
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        return label
    }

    private func makeDebugLineView(color: UIColor) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.backgroundColor = color
        view.layer.borderWidth = 0
        view.isUserInteractionEnabled = false
        return view
    }

    private func makeSpacerLabel(color: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .black
        label.backgroundColor = color.withAlphaComponent(0.2)
        label.layer.borderWidth = 1
        label.layer.borderColor = color.cgColor
        label.layer.cornerRadius = 3
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        return label
    }

    private func pixelAlign(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scaled = (value * scale).rounded()
        return scaled / scale
    }

    private func currentPillTopY(scale: CGFloat) -> CGFloat {
        let pillFrame = computedPillFrameInView()
        return pixelAlign(inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
    }

    #if DEBUG
    private func startUiTestJankMonitorIfNeeded() {
        guard uiTestJankMonitorEnabled else { return }
        guard uiTestJankDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleUiTestJankDisplayLink(_:)))
        displayLink.add(to: .main, forMode: .common)
        uiTestJankDisplayLink = displayLink
    }

    private func stopUiTestJankMonitor() {
        uiTestJankDisplayLink?.invalidate()
        uiTestJankDisplayLink = nil
    }

    private func startUiTestJankWindow(reason: String, duration: TimeInterval) {
        guard uiTestJankMonitorEnabled else { return }
        guard !uiTestJankMessageIdentifiers.isEmpty || uiTestJankUseAnchors else { return }
        let clampedDuration = max(0.2, duration)
        uiTestJankMonitoringActive = true
        uiTestJankMonitoringUntil = CACurrentMediaTime() + clampedDuration
        uiTestJankLastMinY.removeAll()
        uiTestJankLastContentOffsetY = nil
        uiTestJankMaxDownwardDelta = 0
        uiTestJankMaxDownwardSource = ""
        uiTestJankSampleCount = 0
        uiTestJankDidLogMissingMessages = false
        uiTestJankCachedViews.removeAll()
        uiTestJankCachedAccessibilityElements.removeAll()
        uiTestJankLastLookup.removeAll()
        uiTestJankLastAssistantMinY = nil
        uiTestJankLastMessageMinY = nil
        uiTestJankLastAnchorMinY = nil
        uiTestJankLastAnchorIndex = nil
        uiTestJankLastScrollMinY = nil
        uiTestJankLastContentStackMinY = nil
        updateUiTestJankMarkers()
        log("JANK window start reason=\(reason) duration=\(String(format: "%.2f", clampedDuration))")
    }

    @objc private func handleUiTestJankStart() {
        startUiTestJankWindow(reason: "manual_start", duration: uiTestJankAutoStartDuration)
    }

    @objc private func handleUiTestJankDisplayLink(_ link: CADisplayLink) {
        guard uiTestJankMonitorEnabled else { return }
        guard uiTestJankMonitoringActive else { return }
        if let until = uiTestJankMonitoringUntil, CACurrentMediaTime() > until {
            uiTestJankMonitoringActive = false
            uiTestJankMonitoringUntil = nil
            return
        }
        let scale = max(1, view.traitCollection.displayScale)
        let shouldLogSample = uiTestJankLogEvery > 0
            && (uiTestJankSampleCount + 1) % uiTestJankLogEvery == 0
        var sampleLogParts: [String] = []
        var foundAny = false
        let offsetY: CGFloat
        if let presentation = scrollView.layer.presentation() {
            offsetY = presentation.bounds.origin.y
        } else {
            offsetY = scrollView.contentOffset.y
        }
        let alignedOffsetY = pixelAlign(offsetY, scale: scale)
        if let lastOffset = uiTestJankLastContentOffsetY {
            let downDelta = lastOffset - alignedOffsetY
            updateUiTestJankMaxDownward(delta: downDelta, label: "offset")
        }
        uiTestJankLastContentOffsetY = alignedOffsetY
        if shouldLogSample {
            sampleLogParts.append(String(format: "offset=%.2f", alignedOffsetY))
        }
        for identifier in uiTestJankMessageIdentifiers {
            guard let frame = frameForJankMessage(identifier: identifier) else { continue }
            foundAny = true
            let minY = pixelAlign(frame.minY, scale: scale)
            let maxY = pixelAlign(frame.maxY, scale: scale)
            let lastMinY = uiTestJankLastMinY[identifier]
            if let lastMinY {
                let delta = minY - lastMinY
                updateUiTestJankMaxDownward(delta: delta, label: "message:\(identifier)")
            }
            uiTestJankLastMinY[identifier] = minY
            if shouldLogSample {
                let formatted = String(
                    format: "%@ min=%.2f max=%.2f",
                    identifier,
                    minY,
                    maxY
                )
                sampleLogParts.append(formatted)
            }
        }

        if uiTestJankUseAnchors {
            let assistantFrame = lastAssistantMessageFrameInView()
            if assistantFrame != .zero {
                let minY = pixelAlign(assistantFrame.minY, scale: scale)
                if let lastMinY = uiTestJankLastAssistantMinY {
                    let delta = minY - lastMinY
                    updateUiTestJankMaxDownward(delta: delta, label: "assistant.min")
                }
                uiTestJankLastAssistantMinY = minY
                foundAny = true
                if shouldLogSample {
                    sampleLogParts.append(String(format: "assistant.min=%.2f", minY))
                }
            }
            let lastFrame = lastMessageFrameInView()
            if lastFrame != .zero {
                let minY = pixelAlign(lastFrame.minY, scale: scale)
                if let lastMinY = uiTestJankLastMessageMinY {
                    let delta = minY - lastMinY
                    updateUiTestJankMaxDownward(delta: delta, label: "last.min")
                }
                uiTestJankLastMessageMinY = minY
                foundAny = true
                if shouldLogSample {
                    sampleLogParts.append(String(format: "last.min=%.2f", minY))
                }
            }
            let anchor = visibleMessageAnchor()
            if anchor.index >= 0 {
                if uiTestJankLastAnchorIndex == anchor.index,
                   let lastMinY = uiTestJankLastAnchorMinY {
                    let delta = anchor.y - lastMinY
                    updateUiTestJankMaxDownward(delta: delta, label: "anchor[\(anchor.index)]")
                }
                uiTestJankLastAnchorIndex = anchor.index
                uiTestJankLastAnchorMinY = anchor.y
                foundAny = true
                if shouldLogSample {
                    sampleLogParts.append(String(format: "anchor[%d]=%.2f", anchor.index, anchor.y))
                }
            }
        }

        let scrollFrame = scrollView.layer.presentation()?.frame ?? scrollView.frame
        let scrollMinY = pixelAlign(scrollFrame.minY, scale: scale)
        if let lastScrollMinY = uiTestJankLastScrollMinY {
            let delta = scrollMinY - lastScrollMinY
            updateUiTestJankMaxDownward(delta: delta, label: "scroll.min")
        }
        uiTestJankLastScrollMinY = scrollMinY
        if shouldLogSample {
            sampleLogParts.append(String(format: "scroll.min=%.2f", scrollMinY))
        }

        let stackFrame = contentStack.layer.presentation()?.frame ?? contentStack.frame
        let stackMinY = pixelAlign(stackFrame.minY, scale: scale)
        if let lastStackMinY = uiTestJankLastContentStackMinY {
            let delta = stackMinY - lastStackMinY
            updateUiTestJankMaxDownward(delta: delta, label: "stack.min")
        }
        uiTestJankLastContentStackMinY = stackMinY
        if shouldLogSample {
            sampleLogParts.append(String(format: "stack.min=%.2f", stackMinY))
        }

        if !foundAny {
            if !uiTestJankDidLogMissingMessages {
                uiTestJankDidLogMissingMessages = true
                log("JANK missing message views: \(uiTestJankMessageIdentifiers.joined(separator: ", "))")
            }
            return
        }

        uiTestJankSampleCount += 1
        updateUiTestJankMarkers()
        if shouldLogSample {
            let logLine = sampleLogParts.joined(separator: " | ")
            log("JANK sample \(uiTestJankSampleCount) maxDown=\(String(format: "%.2f", uiTestJankMaxDownwardDelta)) \(logLine)")
        }
    }

    private func updateUiTestJankMaxDownward(delta: CGFloat, label: String) {
        guard delta > uiTestJankMaxDownwardDelta else { return }
        uiTestJankMaxDownwardDelta = delta
        uiTestJankMaxDownwardSource = label
        log("JANK maxDown=\(String(format: "%.2f", delta)) source=\(label)")
    }

    private func frameForJankMessage(identifier: String) -> CGRect? {
        if let cachedView = uiTestJankCachedViews[identifier] {
            return frameInRootView(cachedView)
        }
        if let cachedAccessibility = uiTestJankCachedAccessibilityElements[identifier] {
            return cachedAccessibility.accessibilityFrame
        }
        if let target = findView(with: identifier, in: view) {
            uiTestJankCachedViews[identifier] = target
            return frameInRootView(target)
        }
        let now = CACurrentMediaTime()
        if let lastLookup = uiTestJankLastLookup[identifier], now - lastLookup < 0.5 {
            return nil
        }
        uiTestJankLastLookup[identifier] = now
        guard let accessibility = findAccessibilityElement(identifier, in: view) else {
            return nil
        }
        uiTestJankCachedAccessibilityElements[identifier] = accessibility
        return accessibility.accessibilityFrame
    }

    private func findAccessibilityElement(_ identifier: String, in root: UIView) -> UIAccessibilityElement? {
        if let elements = root.accessibilityElements {
            for element in elements {
                if let view = element as? UIView {
                    if let found = findAccessibilityElement(identifier, in: view) {
                        return found
                    }
                    continue
                }
                if let accessibility = element as? UIAccessibilityElement {
                    if accessibility.accessibilityIdentifier == identifier {
                        return accessibility
                    }
                    if let container = accessibility.accessibilityContainer as? UIView,
                       let found = findAccessibilityElement(identifier, in: container) {
                        return found
                    }
                }
            }
        }
        for subview in root.subviews {
            if let found = findAccessibilityElement(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func frameInRootView(_ target: UIView) -> CGRect {
        let targetFrame = target.layer.presentation()?.frame ?? target.frame
        var origin = targetFrame.origin
        var current = target.superview
        while let view = current, view !== self.view {
            let frame = view.layer.presentation()?.frame ?? view.frame
            origin.x += frame.minX
            origin.y += frame.minY
            if let scroll = view as? UIScrollView {
                let bounds = scroll.layer.presentation()?.bounds ?? scroll.bounds
                origin.x -= bounds.origin.x
                origin.y -= bounds.origin.y
            }
            current = view.superview
        }
        return CGRect(origin: origin, size: targetFrame.size)
    }

    private func findView(with identifier: String, in root: UIView) -> UIView? {
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if view.accessibilityIdentifier == identifier {
                return view
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func setupUiTestKeyboardControlsIfNeeded() {
        guard uiTestFakeKeyboardEnabled else { return }
        let stepDown = UIButton(type: .custom)
        stepDown.translatesAutoresizingMaskIntoConstraints = false
        stepDown.alpha = 0.2
        stepDown.isAccessibilityElement = true
        stepDown.accessibilityIdentifier = "chat.fakeKeyboard.stepDown"
        stepDown.addTarget(self, action: #selector(handleUiTestKeyboardStepDown), for: .touchUpInside)
        view.addSubview(stepDown)
        let stepUp = UIButton(type: .custom)
        stepUp.translatesAutoresizingMaskIntoConstraints = false
        stepUp.alpha = 0.2
        stepUp.isAccessibilityElement = true
        stepUp.accessibilityIdentifier = "chat.fakeKeyboard.stepUp"
        stepUp.addTarget(self, action: #selector(handleUiTestKeyboardStepUp), for: .touchUpInside)
        view.addSubview(stepUp)
        let snapOpen = UIButton(type: .custom)
        snapOpen.translatesAutoresizingMaskIntoConstraints = false
        snapOpen.alpha = 0.2
        snapOpen.isAccessibilityElement = true
        snapOpen.accessibilityIdentifier = "chat.fakeKeyboard.snapOpen"
        snapOpen.addTarget(self, action: #selector(handleUiTestKeyboardSnapOpen), for: .touchUpInside)
        view.addSubview(snapOpen)
        let snapZero = UIButton(type: .custom)
        snapZero.translatesAutoresizingMaskIntoConstraints = false
        snapZero.alpha = 0.2
        snapZero.isAccessibilityElement = true
        snapZero.accessibilityIdentifier = "chat.fakeKeyboard.snapZero"
        snapZero.addTarget(self, action: #selector(handleUiTestKeyboardSnapZero), for: .touchUpInside)
        view.addSubview(snapZero)
        let snapClosed = UIButton(type: .custom)
        snapClosed.translatesAutoresizingMaskIntoConstraints = false
        snapClosed.alpha = 0.2
        snapClosed.isAccessibilityElement = true
        snapClosed.accessibilityIdentifier = "chat.fakeKeyboard.snapClosed"
        snapClosed.addTarget(self, action: #selector(handleUiTestKeyboardSnapClosed), for: .touchUpInside)
        view.addSubview(snapClosed)
        uiTestKeyboardStepDownButton = stepDown
        uiTestKeyboardStepUpButton = stepUp

        NSLayoutConstraint.activate([
            stepDown.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stepDown.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stepDown.widthAnchor.constraint(equalToConstant: 44),
            stepDown.heightAnchor.constraint(equalToConstant: 44),
            stepUp.topAnchor.constraint(equalTo: stepDown.bottomAnchor, constant: 8),
            stepUp.leadingAnchor.constraint(equalTo: stepDown.leadingAnchor),
            stepUp.widthAnchor.constraint(equalToConstant: 44),
            stepUp.heightAnchor.constraint(equalToConstant: 44),
            snapOpen.topAnchor.constraint(equalTo: stepUp.bottomAnchor, constant: 8),
            snapOpen.leadingAnchor.constraint(equalTo: stepDown.leadingAnchor),
            snapOpen.widthAnchor.constraint(equalToConstant: 44),
            snapOpen.heightAnchor.constraint(equalToConstant: 44),
            snapZero.topAnchor.constraint(equalTo: snapOpen.bottomAnchor, constant: 8),
            snapZero.leadingAnchor.constraint(equalTo: stepDown.leadingAnchor),
            snapZero.widthAnchor.constraint(equalToConstant: 44),
            snapZero.heightAnchor.constraint(equalToConstant: 44),
            snapClosed.topAnchor.constraint(equalTo: snapZero.bottomAnchor, constant: 8),
            snapClosed.leadingAnchor.constraint(equalTo: stepDown.leadingAnchor),
            snapClosed.widthAnchor.constraint(equalToConstant: 44),
            snapClosed.heightAnchor.constraint(equalToConstant: 44)
        ])

        if let initialOverlap = uiTestFakeKeyboardInitialOverlap {
            uiTestKeyboardOverlap = initialOverlap
            uiTestKeyboardVisibilityOverride = nil
            DispatchQueue.main.async { [weak self] in
                self?.applyUiTestKeyboardOverlap(animated: true)
            }
        }
    }

    @objc private func handleUiTestKeyboardStepDown() {
        let current = uiTestKeyboardOverlap ?? 0
        uiTestKeyboardVisibilityOverride = nil
        uiTestKeyboardOverlap = max(0, current - uiTestKeyboardStep)
        applyUiTestKeyboardOverlap(animated: true)
    }

    @objc private func handleUiTestKeyboardStepUp() {
        let current = uiTestKeyboardOverlap ?? 0
        uiTestKeyboardVisibilityOverride = nil
        uiTestKeyboardOverlap = current + uiTestKeyboardStep
        applyUiTestKeyboardOverlap(animated: true)
    }

    @objc private func handleUiTestKeyboardSnapOpen() {
        uiTestKeyboardVisibilityOverride = true
        uiTestKeyboardOverlap = uiTestFakeKeyboardOpenOverlap
        print("uiTest snapOpen overlap=\(uiTestFakeKeyboardOpenOverlap)")
        applyUiTestKeyboardOverlap(animated: false)
    }

    @objc private func handleUiTestKeyboardFocus() {
        inputBarVC.setFocused(true)
    }

    @objc private func handleUiTestKeyboardDismiss() {
        dismissKeyboard()
    }

    @objc private func handleUiTestKeyboardSnapZero() {
        uiTestKeyboardVisibilityOverride = false
        uiTestKeyboardOverlap = 0
        print("uiTest snapZero overlap=0")
        applyUiTestKeyboardOverlap(animated: false)
    }

    @objc private func handleUiTestKeyboardSnapClosed() {
        uiTestKeyboardVisibilityOverride = false
        let targetOverlap = uiTestFakeKeyboardClosedOverlap ?? 0
        uiTestKeyboardOverlap = max(0, targetOverlap)
        print("uiTest snapClosed overlap=\(uiTestKeyboardOverlap ?? 0)")
        applyUiTestKeyboardOverlap(animated: false)
    }

    private func applyUiTestKeyboardOverlap(
        animated: Bool,
        treatAsInteractiveDismissal: Bool = false
    ) {
        lockedKeyboardOverlap = nil
        if !treatAsInteractiveDismissal {
            prepareKeyboardTransitionSnapshot()
        }
        uiTestInteractiveDismissalActive = treatAsInteractiveDismissal
#if DEBUG
        let uiTestKeyboardIsVisible = uiTestKeyboardVisibilityOverride
            ?? ((uiTestKeyboardOverlap ?? 0) > 1)
        if uiTestJankMonitorEnabled,
           uiTestKeyboardIsVisible,
           let overlap = uiTestKeyboardOverlap,
           overlap > 1,
           !uiTestJankMonitoringActive {
            startUiTestJankWindow(reason: "fake_open", duration: 2.2)
        }
#endif
        updateBottomInsetsForKeyboard(animated: animated, force: true)
        uiTestInteractiveDismissalActive = false
#if DEBUG
        applyUiTestAnchorCorrectionIfNeeded()
#endif
        if animated {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateBottomInsetsForKeyboard(animated: true, force: true)
#if DEBUG
                self.applyUiTestAnchorCorrectionIfNeeded()
#endif
            }
        }
    }

#if DEBUG
    private func applyUiTestAnchorCorrectionIfNeeded() {
        guard uiTestFakeKeyboardEnabled else { return }
        let messageCount = messageArrangedViews().count
        if messageCount <= 2 {
            return
        }
        view.layoutIfNeeded()
        let scale = max(1, view.traitCollection.displayScale)
        let pillFrame = computedPillFrameInView()
        let pillTopY = pixelAlign(inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
        guard let anchorIndex = anchorCandidateIndex(pillTopY: pillTopY),
              let sample = anchorSample(index: anchorIndex, pillTopY: pillTopY),
              let contentBottom = anchorBottomContentY(index: anchorIndex) else { return }
        let desiredAnchorBottomY = pillTopY - sample.gap
        let targetOffsetY = contentBottom - desiredAnchorBottomY
        let bounds = contentOffsetBounds(keyboardOverlap: uiTestKeyboardOverlap)
        let clamped = min(max(targetOffsetY, bounds.minY), bounds.maxY)
        if abs(scrollView.contentOffset.y - clamped) > 0.5 {
            scrollView.contentOffset.y = clamped
        }
    }
#endif

    private func applyUiTestKeyboardDragIfNeeded() {
        guard scrollView != nil, scrollView.isTracking else { return }
        guard let overlap = uiTestKeyboardOverlap else { return }
        let translation = scrollView.panGestureRecognizer.translation(in: view)
        guard translation.y > 0.1 else { return }
        let delta = translation.y - uiTestLastDismissTranslation
        guard abs(delta) > 0.1 else { return }
        uiTestLastDismissTranslation = translation.y
        lastKeyboardOverlap = overlap
        uiTestKeyboardOverlap = max(0, overlap - delta)
        applyUiTestKeyboardOverlap(animated: false, treatAsInteractiveDismissal: true)
        if let startOffset = uiTestDismissalStartOffsetY {
            let bounds = contentOffsetBounds(keyboardOverlap: uiTestKeyboardOverlap)
            let clamped = min(max(startOffset, bounds.minY), bounds.maxY)
            if abs(scrollView.contentOffset.y - clamped) > 0.5 {
                scrollView.contentOffset.y = clamped
            }
        }
        uiTestLastDismissTranslation = 0
        scrollView.panGestureRecognizer.setTranslation(.zero, in: view)
    }

    private func scheduleUiTestKeyboardAutoCycleIfNeeded() {
        guard uiTestFakeKeyboardEnabled, !didScheduleUiTestKeyboardAutoCycle else { return }
        guard uiTestFakeKeyboardAutoOpenDelay != nil || uiTestFakeKeyboardAutoCloseDelay != nil else { return }
        didScheduleUiTestKeyboardAutoCycle = true
        if let openDelay = uiTestFakeKeyboardAutoOpenDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + openDelay) { [weak self] in
                self?.handleUiTestKeyboardSnapOpen()
            }
        }
        if let closeDelay = uiTestFakeKeyboardAutoCloseDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay) { [weak self] in
                self?.handleUiTestKeyboardSnapClosed()
            }
        }
    }
    #endif

    private func currentKeyboardOverlap() -> CGFloat {
        #if DEBUG
        if let uiTestKeyboardOverlap {
            return uiTestKeyboardOverlap
        }
        #endif
        let resolved = keyboardOverlapFromLayoutGuide()
        return resolved.overlap
    }

    private func keyboardOverlapFromLayoutGuide() -> (overlap: CGFloat, isVisible: Bool) {
        let keyboardFrame = view.keyboardLayoutGuide.layoutFrame
        let safeBottom = view.safeAreaInsets.bottom
        let viewMaxY = view.bounds.maxY
        let isVisible = keyboardFrame.minY < viewMaxY - safeBottom - 1
        let height = max(0, keyboardFrame.height)
        return (overlap: height, isVisible: isVisible)
    }

    private func resolvedKeyboardVisibility() -> Bool {
        #if DEBUG
        if let visibilityOverride = uiTestKeyboardVisibilityOverride {
            return visibilityOverride
        }
        if let uiTestKeyboardOverlap {
            return uiTestKeyboardOverlap > 1
        }
        #endif
        return keyboardOverlapFromLayoutGuide().isVisible
    }

    private func isDismissingKeyboardGesture() -> Bool {
        guard scrollView != nil else { return false }
        #if DEBUG
        if uiTestInteractiveDismissalActive {
            return true
        }
        #endif
        let translation = scrollView.panGestureRecognizer.translation(in: view)
        return scrollView.isTracking && translation.y > 0.5
    }

    private func keyboardIsMoving(current: CGFloat) -> Bool {
        guard let lastKeyboardOverlap else { return false }
        return abs(current - lastKeyboardOverlap) > 0.5
    }

    private func keyboardIsMovingDown(current: CGFloat) -> Bool {
        guard let lastKeyboardOverlap else { return false }
        return current < lastKeyboardOverlap - 0.5
    }

    private func interactiveDismissalSlack(currentOverlap: CGFloat) -> CGFloat {
        guard isInteractiveDismissalActive else { return 0 }
        let startOverlap = interactiveDismissalStartOverlap ?? currentOverlap
        return max(0, startOverlap - currentOverlap)
    }

    private func makeInteractiveDismissalAnchor(pillTopY: CGFloat) -> InteractiveDismissalAnchor {
        let visibleAnchor = visibleMessageAnchor()
        let anchorIndex = anchorCandidateIndex(pillTopY: pillTopY)
            ?? (visibleAnchor.index >= 0 ? visibleAnchor.index : -1)
        let anchorGap = anchorIndex >= 0 ? anchorSample(index: anchorIndex, pillTopY: pillTopY)?.gap : nil
        return InteractiveDismissalAnchor(
            startOffsetY: scrollView.contentOffset.y,
            startPillTopY: pillTopY,
            anchorIndex: anchorIndex,
            anchorGap: anchorGap
        )
    }

    private func updateInteractiveDismissalAnchorIfNeeded(
        keyboardOverlap: CGFloat,
        keyboardIsMovingDown: Bool,
        gestureIsDismissing: Bool
    ) {
        if keyboardOverlap <= 1 {
            interactiveDismissalAnchor = nil
            isInteractiveDismissalActive = false
            pendingInteractiveDismissal = false
            pendingInteractiveDismissalStartOverlap = nil
            interactiveDismissalStartOverlap = nil
            pendingInteractiveDismissalAnchor = nil
            return
        }
        let keyboardIsChanging = keyboardIsMoving(current: keyboardOverlap)
        if gestureIsDismissing {
            pendingInteractiveDismissal = true
            if pendingInteractiveDismissalStartOverlap == nil {
                pendingInteractiveDismissalStartOverlap = lastKeyboardOverlap ?? keyboardOverlap
            }
            if interactiveDismissalAnchor == nil {
                let scale = max(1, view.traitCollection.displayScale)
                let pillTopY = currentPillTopY(scale: scale)
                pendingInteractiveDismissalAnchor = makeInteractiveDismissalAnchor(pillTopY: pillTopY)
            }
        }
        let isTrackingForDismiss = scrollView.isTracking || scrollView.isDecelerating || gestureIsDismissing
        if interactiveDismissalAnchor == nil,
           keyboardIsMovingDown,
           (pendingInteractiveDismissal || gestureIsDismissing || isTrackingForDismiss) {
            let startOverlap = pendingInteractiveDismissalStartOverlap ?? keyboardOverlap
            let overlapDelta = startOverlap - keyboardOverlap
            if overlapDelta >= interactiveDismissalActivationDelta {
                if let pendingAnchor = pendingInteractiveDismissalAnchor {
                    interactiveDismissalAnchor = pendingAnchor
                } else {
                    let scale = max(1, view.traitCollection.displayScale)
                    let pillTopY = currentPillTopY(scale: scale)
                    interactiveDismissalAnchor = makeInteractiveDismissalAnchor(pillTopY: pillTopY)
                }
                interactiveDismissalStartOverlap = keyboardOverlap
                pendingInteractiveDismissal = false
                pendingInteractiveDismissalAnchor = nil
                pendingInteractiveDismissalStartOverlap = nil
            }
        }
        if let startOverlap = interactiveDismissalStartOverlap,
           !keyboardIsChanging,
           !gestureIsDismissing,
           !scrollView.isTracking,
           !scrollView.isDecelerating,
           keyboardOverlap >= startOverlap - 0.5 {
            interactiveDismissalAnchor = nil
            interactiveDismissalStartOverlap = nil
            pendingInteractiveDismissal = false
            pendingInteractiveDismissalAnchor = nil
            pendingInteractiveDismissalStartOverlap = nil
        } else if !gestureIsDismissing,
                  !scrollView.isTracking,
                  !scrollView.isDecelerating,
                  !keyboardIsMovingDown {
            pendingInteractiveDismissal = false
            pendingInteractiveDismissalAnchor = nil
            pendingInteractiveDismissalStartOverlap = nil
        }
        isInteractiveDismissalActive = interactiveDismissalAnchor != nil
    }

    private func applyInteractiveDismissalOffsetIfNeeded(
        keyboardOverlap: CGFloat
    ) {
        guard keyboardOverlap > 1,
              isInteractiveDismissalActive,
              let anchor = interactiveDismissalAnchor else { return }
        let scale = max(1, view.traitCollection.displayScale)
        let pillTopY = currentPillTopY(scale: scale)
        if anchor.anchorIndex >= 0,
           let anchorGap = anchor.anchorGap,
           let anchorContentBottom = anchorBottomContentY(index: anchor.anchorIndex) {
            let desiredAnchorBottomY = pillTopY - anchorGap
            let targetOffsetY = anchorContentBottom - desiredAnchorBottomY
            let bounds = contentOffsetBounds(keyboardOverlap: keyboardOverlap)
            let clamped = min(max(targetOffsetY, bounds.minY), bounds.maxY)
            if abs(scrollView.contentOffset.y - clamped) > 0.5 {
                scrollView.contentOffset.y = clamped
            }
            return
        }

        let deltaFromStart = pillTopY - anchor.startPillTopY
        let fallbackOffsetY = anchor.startOffsetY - deltaFromStart
        if abs(scrollView.contentOffset.y - fallbackOffsetY) > 0.5 {
            scrollView.contentOffset.y = fallbackOffsetY
        }
    }

    private func computedPillFrameInView() -> CGRect {
        inputBarVC.pillFrameInView
    }

    private func maybeScrollToBottomIfNeeded() {
        let contentHeight = scrollableContentHeight()
        if abs(contentHeight - lastContentHeight) > 1 {
            lastContentHeight = contentHeight
        }
        guard !hasUserScrolled, scrollView.bounds.height > 1 else { return }
        let bottomInset = scrollView.contentInset.bottom
        let maxOffsetY = max(0, contentHeight - scrollView.bounds.height + bottomInset)
        let distanceFromBottom = maxOffsetY - scrollView.contentOffset.y
        let tolerance = max(2, abs(bottomMessageGap))
        let pinToTop = shouldPinShortThreadToTop()
        if didInitialScrollToBottom == false || (!pinToTop && distanceFromBottom > tolerance) {
            didInitialScrollToBottom = true
            scrollToBottom(animated: false)
            alignShortThreadToTopIfNeeded(reason: "scrollToBottom")
        }
    }

    private func baselinePillTopYIgnoringKeyboard(
        pillTopY: CGFloat,
        keyboardOverlap: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        guard keyboardOverlap > 1 else { return pillTopY }
        let offsetAdjustment = keyboardOverlap + max(0, inputBarYOffset)
        return pixelAlign(pillTopY + offsetAdjustment, scale: scale)
    }

    private func baselineBottomInsetIgnoringKeyboard(
        pillTopY: CGFloat,
        keyboardOverlap: CGFloat,
        desiredGap: CGFloat,
        viewBottomY: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let baselinePillTopY = baselinePillTopYIgnoringKeyboard(
            pillTopY: pillTopY,
            keyboardOverlap: keyboardOverlap,
            scale: scale
        )
        return pixelAlign(max(0, viewBottomY - baselinePillTopY + desiredGap), scale: scale)
    }

    private func shortThreadFitsAboveInput(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        topInset: CGFloat,
        pillTopY: CGFloat,
        keyboardOverlap: CGFloat,
        desiredGap: CGFloat,
        viewBottomY: CGFloat,
        scale: CGFloat
    ) -> Bool {
        let baselineBottomInset = baselineBottomInsetIgnoringKeyboard(
            pillTopY: pillTopY,
            keyboardOverlap: keyboardOverlap,
            desiredGap: desiredGap,
            viewBottomY: viewBottomY,
            scale: scale
        )
        return contentFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: baselineBottomInset
        )
    }

    private func shouldPinShortThreadToTop() -> Bool {
        let contentHeight = effectiveContentHeight()
        let messageCount = messageArrangedViews().count
        if uiTestDisableShortThreadPin {
            return false
        }
        if messageCount == 0 {
            return false
        }
        let keyboardOverlap = currentKeyboardOverlap()
        let keyboardVisible = isKeyboardVisible || keyboardOverlap > 1
        let boundsHeight = scrollView.bounds.height
        let topInset = scrollView.adjustedContentInset.top
        let desiredGap = max(-20, min(120, bottomMessageGap))
        let scale = max(1, view.traitCollection.displayScale)
        let pillTopY = currentPillTopY(scale: scale)
        let viewBottomY = pixelAlign(view.bounds.maxY, scale: scale)
        let baselineFits = shortThreadFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            pillTopY: pillTopY,
            keyboardOverlap: keyboardOverlap,
            desiredGap: desiredGap,
            viewBottomY: viewBottomY,
            scale: scale
        )
        let keyboardBottomInset = pixelAlign(max(0, viewBottomY - pillTopY + desiredGap), scale: scale)
        let keyboardFits = contentFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: keyboardBottomInset
        )
        if keyboardVisible {
            return messageCount <= 3 && keyboardFits
        }
        if messageCount <= 3 {
            let fallbackBottomInset = min(scrollView.contentInset.bottom, boundsHeight * 0.5)
            let fallbackFits = contentFitsAboveInput(
                contentHeight: contentHeight,
                boundsHeight: boundsHeight,
                topInset: topInset,
                bottomInset: fallbackBottomInset
            )
            return baselineFits || fallbackFits
        }
        return baselineFits
    }

    private func alignShortThreadToTopIfNeeded(reason: String) {
        guard shouldPinShortThreadToTop(),
              !isInteractiveDismissalActive else { return }
        let scale = max(1, view.traitCollection.displayScale)
        let topOffset = -scrollView.adjustedContentInset.top
        let alignedTop = pixelAlign(topOffset, scale: scale)
        if abs(scrollView.contentOffset.y - alignedTop) > 0.5 {
            scrollView.contentOffset.y = alignedTop
        }
        DebugLog.addDedup("shortThread.topAlign", "shortThread top align reason=\(reason)")
    }

    private func logContentGeometry(reason: String) {
        guard shouldLogChatGeometry else { return }
        let safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        let insetTop = scrollView.contentInset.top
        let insetBottom = scrollView.contentInset.bottom
        let adjustedTop = scrollView.adjustedContentInset.top
        let adjustedBottom = scrollView.adjustedContentInset.bottom
        let offset = scrollView.contentOffset
        let contentSize = scrollView.contentSize
        let stackFrame = contentStack.frame
        let firstFrame = contentStack.arrangedSubviews.first?.frame ?? .zero
        let lastFrame = contentStack.arrangedSubviews.last?.frame ?? .zero
        let signature = String(
            format: "safeTop=%.1f insetTop=%.1f insetBottom=%.1f adjustedTop=%.1f adjustedBottom=%.1f offset=(%.1f,%.1f) content=(%.1f,%.1f) stackY=%.1f stackH=%.1f firstY=%.1f lastMaxY=%.1f topConst=%.1f",
            safeTop,
            insetTop,
            insetBottom,
            adjustedTop,
            adjustedBottom,
            offset.x,
            offset.y,
            contentSize.width,
            contentSize.height,
            stackFrame.minY,
            stackFrame.height,
            firstFrame.minY,
            lastFrame.maxY,
            contentStackTopConstraint.constant
        )
        if signature != lastGeometryLogSignature {
            log("CMUX_CHAT_GEOM \(reason) \(signature)")
            lastGeometryLogSignature = signature
        }
    }

    private func updateTopFadeHeightIfNeeded() {
        let safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        // Extend gradient a bit below the navigation bar for a smooth fade into content.
        let targetHeight = safeTop + 24
        if abs(topFadeHeightConstraint.constant - targetHeight) > 0.5 {
            topFadeHeightConstraint.constant = targetHeight
            topFadeView.updateColors()
        }
    }

    private func enableInteractivePopGesture() {
        guard let nav = navigationController,
              let edgePan = nav.interactivePopGestureRecognizer else { return }
        edgePan.isEnabled = true
        if !didConfigureInteractivePopGesture {
            didConfigureInteractivePopGesture = true
            scrollView.panGestureRecognizer.require(toFail: edgePan)
            edgePan.delegate = self
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let edgePan = navigationController?.interactivePopGestureRecognizer else { return false }
        let isEdgePan = gestureRecognizer === edgePan || otherGestureRecognizer === edgePan
        let isScrollPan = gestureRecognizer === scrollView.panGestureRecognizer
            || otherGestureRecognizer === scrollView.panGestureRecognizer
        return isEdgePan && isScrollPan
    }

    private func addMessageBubble(_ message: Message, showTail: Bool, showTimestamp: Bool) {
        let bubble = MessageBubble(
            message: message,
            showTail: showTail,
            showTimestamp: showTimestamp
        )
        let host = UIHostingController(rootView: bubble)
        host.view.isAccessibilityElement = true
        host.view.accessibilityIdentifier = "chat.message.\(message.id)"
        host.view.accessibilityLabel = message.content
        host.view.accessibilityTraits = .staticText
        if #available(iOS 16.0, *) {
            host.safeAreaRegions = []
        }
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        if let previousLast = messageArrangedViews().last {
            contentStack.setCustomSpacing(contentStack.spacing, after: previousLast)
        }
        let insertIndex = max(contentStack.arrangedSubviews.count - 3, 0)
        contentStack.insertArrangedSubview(host.view, at: insertIndex)
        contentStack.setCustomSpacing(0, after: host.view)
        host.didMove(toParent: self)
    }

    private func populateMessages() {
        for (index, message) in messages.enumerated() {
            addMessageBubble(
                message,
                showTail: index == messages.count - 1,
                showTimestamp: index == 0
            )
        }
    }

    private func messageArrangedViews() -> [UIView] {
        let arranged = contentStack.arrangedSubviews
        guard arranged.count >= 3 else { return [] }
        return Array(arranged.dropLast(3))
    }

    private func scrollToBottom(animated: Bool) {
        let contentHeight = scrollableContentHeight()
        let boundsHeight = scrollView.bounds.height
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.contentInset.bottom

        // Max offset: bottom of content aligns with visible area above input bar
        let maxOffsetY = contentHeight - boundsHeight + bottomInset
        // Min offset: content starts below header
        let minOffsetY = -topInset
        let effectiveMaxOffsetY = max(maxOffsetY, minOffsetY)
        let targetOffsetY = shouldPinShortThreadToTop() ? minOffsetY : effectiveMaxOffsetY

        log("scrollToBottom:")
        log("  contentHeight: \(contentHeight), boundsHeight: \(boundsHeight)")
        log("  topInset: \(topInset), bottomInset: \(bottomInset)")
        log("  maxOffsetY: \(maxOffsetY), minOffsetY: \(minOffsetY)")
        log("  targetOffsetY: \(targetOffsetY)")
        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: animated)
    }

    @objc private func dismissKeyboard() {
        inputBarVC.setFocused(false)
        view.endEditing(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
#if DEBUG
        if uiTestFakeKeyboardEnabled {
            uiTestLastDismissTranslation = 0
            if !decelerate {
                uiTestDismissalStartOffsetY = nil
            }
        }
#endif
        let keyboardOverlap = currentKeyboardOverlap()
        let keyboardIsMovingDown = keyboardIsMovingDown(current: keyboardOverlap)
        let gestureIsDismissing = isDismissingKeyboardGesture()
        updateInteractiveDismissalAnchorIfNeeded(
            keyboardOverlap: keyboardOverlap,
            keyboardIsMovingDown: keyboardIsMovingDown,
            gestureIsDismissing: gestureIsDismissing
        )
        lastKeyboardOverlap = keyboardOverlap
        if !decelerate {
            clampContentOffsetIfNeeded(keyboardOverlap: keyboardOverlap)
            logContentGeometry(reason: "scrollEndDrag")
            logVisibleMessages(reason: "scrollEndDrag")
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
#if DEBUG
        if uiTestFakeKeyboardEnabled {
            applyUiTestKeyboardDragIfNeeded()
        }
#endif
        let keyboardOverlap = currentKeyboardOverlap()
        let keyboardIsMovingDown = keyboardIsMovingDown(current: keyboardOverlap)
        let gestureIsDismissing = isDismissingKeyboardGesture()
        updateInteractiveDismissalAnchorIfNeeded(
            keyboardOverlap: keyboardOverlap,
            keyboardIsMovingDown: keyboardIsMovingDown,
            gestureIsDismissing: gestureIsDismissing
        )
        applyInteractiveDismissalOffsetIfNeeded(
            keyboardOverlap: keyboardOverlap
        )
        lastKeyboardOverlap = keyboardOverlap
        logVisibleMessages(reason: "scroll")
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
#if DEBUG
        if uiTestFakeKeyboardEnabled {
            uiTestLastDismissTranslation = 0
            uiTestDismissalStartOffsetY = nil
        }
#endif
        let keyboardOverlap = currentKeyboardOverlap()
        let keyboardIsMovingDown = keyboardIsMovingDown(current: keyboardOverlap)
        let gestureIsDismissing = isDismissingKeyboardGesture()
        updateInteractiveDismissalAnchorIfNeeded(
            keyboardOverlap: keyboardOverlap,
            keyboardIsMovingDown: keyboardIsMovingDown,
            gestureIsDismissing: gestureIsDismissing
        )
        lastKeyboardOverlap = keyboardOverlap
        clampContentOffsetIfNeeded(keyboardOverlap: keyboardOverlap)
        logContentGeometry(reason: "scrollEndDecel")
        logVisibleMessages(reason: "scrollEndDecel")
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        hasUserScrolled = true
#if DEBUG
        if uiTestFakeKeyboardEnabled {
            uiTestLastDismissTranslation = 0
            uiTestDismissalStartOffsetY = scrollView.contentOffset.y
        }
#endif
        let keyboardOverlap = currentKeyboardOverlap()
        let keyboardIsMovingDown = keyboardIsMovingDown(current: keyboardOverlap)
        let gestureIsDismissing = isDismissingKeyboardGesture()
        updateInteractiveDismissalAnchorIfNeeded(
            keyboardOverlap: keyboardOverlap,
            keyboardIsMovingDown: keyboardIsMovingDown,
            gestureIsDismissing: gestureIsDismissing
        )
        lastKeyboardOverlap = keyboardOverlap
    }

    private func sendMessage() {
        let text = inputBarVC.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isSending else { return }

        #if DEBUG
        DebugLog.addDedup("sendMessage.start", "sendMessage start rawLen=\(inputBarVC.text.count) trimmedLen=\(text.count) keyboardVisible=\(isKeyboardVisible) overlap=\(String(format: "%.1f", currentKeyboardOverlap())) inputBarConst=\(String(format: "%.1f", inputBarBottomConstraint.constant))")
        #endif

        // Clear input immediately for better UX
        inputBarVC.clearText()
        #if DEBUG
        DebugLog.addDedup("sendMessage.cleared", "sendMessage cleared input keyboardVisible=\(isKeyboardVisible) inputBarConst=\(String(format: "%.1f", inputBarBottomConstraint.constant))")
        #endif

        // Call the onSend callback to send via Convex
        // The message will appear via subscription update
        if let onSend {
            log("Sending message via Convex: \(text.prefix(50))...")
            onSend(text)
        } else {
            // Fallback: add local message (for preview/testing)
            let message = Message(content: text, timestamp: .now, isFromMe: true, status: .sent)
            messages.append(message)
            addMessageBubble(message, showTail: true, showTimestamp: false)
        }

        DispatchQueue.main.async {
            self.scrollToBottom(animated: true)
            #if DEBUG
            DebugLog.addDedup("sendMessage.scroll", "sendMessage scrollToBottom complete keyboardVisible=\(self.isKeyboardVisible) inputBarConst=\(String(format: "%.1f", self.inputBarBottomConstraint.constant))")
            #endif
        }
    }

    private func logVisibleMessages(reason: String) {
        guard shouldLogChatGeometry else { return }
        let messageViews = messageArrangedViews()
        guard !messageViews.isEmpty else { return }

        let visibleRect = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        var visibleItems: [(Int, CGRect)] = []
        visibleItems.reserveCapacity(messageViews.count)

        for (index, subview) in messageViews.enumerated() {
            let frameInScroll = contentStack.convert(subview.frame, to: scrollView)
            if frameInScroll.intersects(visibleRect) {
                visibleItems.append((index, frameInScroll))
            }
        }

        let signature = visibleItems
            .map { item in
                String(
                    format: "%d:%.1f:%.1f:%.1f:%.1f",
                    item.0,
                    item.1.origin.x,
                    item.1.origin.y,
                    item.1.size.width,
                    item.1.size.height
                )
            }
            .joined(separator: "|")

        guard signature != lastVisibleSignature else { return }
        lastVisibleSignature = signature

        log("CMUX_CHAT_MSG \(reason) count=\(visibleItems.count)")
        for (index, frame) in visibleItems {
            log("CMUX_CHAT_MSG \(reason)   [\(index)] frame: \(frame)")
        }
    }

    private var shouldLogChatGeometry: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["CMUX_DEBUG_CHAT_LOGS"] == "1" {
            return true
        }
        return DebugSettings.showChatOverlays
        #else
        return false
        #endif
    }

    @objc private func handleToolCallSheetWillPresent() {
        toolCallSheetReleaseWorkItem?.cancel()
        toolCallSheetReleaseWorkItem = nil
        toolCallSheetIsPresented = true
        let overlap = max(currentKeyboardOverlap(), lastKeyboardOverlap ?? 0)
        let keyboardWasVisible = resolvedKeyboardVisibility() || isKeyboardVisible
        let inputBarIsRaised = inputBarBottomConstraint.constant < -1
        let shouldHold = inputBarIsRaised && !keyboardWasVisible
        if keyboardWasVisible {
            dismissKeyboard()
            #if DEBUG
            if uiTestFakeKeyboardEnabled {
                handleUiTestKeyboardSnapClosed()
            }
            #endif
        }
        if shouldHold {
            view.layoutIfNeeded()
            let scale = max(1, view.traitCollection.displayScale)
            let pillFrame = computedPillFrameInView()
            let baselineTop = lastAppliedPillTopY ?? pixelAlign(
                inputBarVC.view.frame.minY + pillFrame.minY,
                scale: scale
            )
            let baselineBottom = baselineTop + pillFrame.height
            toolCallSheetPinnedPillBottomY = lockedPillBottomY ?? baselineBottom
            toolCallSheetPinnedInputBarConstant = inputBarBottomConstraint.constant
            let overlapCandidate = max(overlap, abs(inputBarBottomConstraint.constant))
            toolCallSheetKeyboardOverlap = max(2, overlapCandidate)
            toolCallSheetHoldKeyboardOverlap = true
            shouldRestoreKeyboardAfterToolCallSheet = keyboardWasVisible
            updateBottomInsetsForKeyboard(force: true)
        } else {
            toolCallSheetKeyboardOverlap = nil
            toolCallSheetHoldKeyboardOverlap = false
            toolCallSheetPinnedInputBarConstant = nil
            toolCallSheetPinnedPillBottomY = nil
            shouldRestoreKeyboardAfterToolCallSheet = keyboardWasVisible
        }
    }

    @objc private func handleToolCallSheetDidDismiss() {
        toolCallSheetIsPresented = false
        guard shouldRestoreKeyboardAfterToolCallSheet else {
            toolCallSheetHoldKeyboardOverlap = false
            toolCallSheetKeyboardOverlap = nil
            toolCallSheetPinnedInputBarConstant = nil
            toolCallSheetPinnedPillBottomY = nil
            return
        }
        shouldRestoreKeyboardAfterToolCallSheet = false
        toolCallSheetReleaseWorkItem?.cancel()
        let releaseWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.toolCallSheetHoldKeyboardOverlap {
                self.toolCallSheetHoldKeyboardOverlap = false
                self.toolCallSheetKeyboardOverlap = nil
                self.toolCallSheetPinnedInputBarConstant = nil
                self.toolCallSheetPinnedPillBottomY = nil
                self.updateBottomInsetsForKeyboard()
            }
        }
        toolCallSheetReleaseWorkItem = releaseWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: releaseWorkItem)
        DispatchQueue.main.async { [weak self] in
            #if DEBUG
            if let self, self.uiTestFakeKeyboardEnabled {
                self.handleUiTestKeyboardSnapOpen()
            } else {
                self?.inputBarVC.setFocused(true)
            }
            #else
            self?.inputBarVC.setFocused(true)
            #endif
        }
    }

    private func lastMessageFrameInView() -> CGRect {
        let messageViews = messageArrangedViews()
        guard let lastMessageView = messageViews.last else { return .zero }
        return contentStack.convert(lastMessageView.frame, to: view)
    }

    private func lastAssistantMessageFrameInView() -> CGRect {
        let messageViews = messageArrangedViews()
        guard let index = messages.lastIndex(where: { !$0.isFromMe }),
              index >= 0,
              index < messageViews.count else {
            return .zero
        }
        let messageView = messageViews[index]
        return contentStack.convert(messageView.frame, to: view)
    }

    private struct DebugShiftSample {
        let messageBottomY: CGFloat
        let visibleAnchorY: CGFloat
        let visibleAnchorIndex: Int
        let pillTopY: CGFloat
        let gap: CGFloat
        let contentOffsetY: CGFloat
        let anchorIndex: Int
        let anchorGap: CGFloat
    }

    private func captureDebugSample(anchorIndexOverride: Int? = nil) -> DebugShiftSample {
        let scale = max(1, view.traitCollection.displayScale)
        let pillFrame = inputBarVC.pillFrameInView
        let pillTopY = pixelAlign(inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
        let lastFrame = lastMessageFrameInView()
        let messageBottom = lastFrame == .zero ? 0 : pixelAlign(lastFrame.maxY, scale: scale)
        let gap = lastFrame == .zero ? 0 : (pillTopY - messageBottom)
        let visibleAnchor = visibleMessageAnchor()
        let anchorIndex = anchorIndexOverride ?? (anchorCandidateIndex(pillTopY: pillTopY) ?? -1)
        let anchorGap = anchorSample(index: anchorIndex, pillTopY: pillTopY)?.gap ?? 0
        return DebugShiftSample(
            messageBottomY: messageBottom,
            visibleAnchorY: visibleAnchor.y,
            visibleAnchorIndex: visibleAnchor.index,
            pillTopY: pillTopY,
            gap: gap,
            contentOffsetY: scrollView.contentOffset.y,
            anchorIndex: anchorIndex,
            anchorGap: anchorGap
        )
    }

    private func visibleMessageAnchor() -> (index: Int, y: CGFloat) {
        let messageViews = messageArrangedViews()
        guard !messageViews.isEmpty else { return (index: -1, y: 0) }
        let visibleRect = view.bounds
        var bestIndex: Int = -1
        var bestY: CGFloat = 0
        for (index, subview) in messageViews.enumerated() {
            let frame = contentStack.convert(subview.frame, to: view)
            if frame.intersects(visibleRect) {
                bestIndex = index
                bestY = frame.minY
                break
            }
        }
        if bestIndex == -1, let last = messageViews.last {
            let frame = contentStack.convert(last.frame, to: view)
            bestIndex = messageViews.count - 1
            bestY = frame.minY
        }
        let scale = max(1, view.traitCollection.displayScale)
        return (index: bestIndex, y: pixelAlign(bestY, scale: scale))
    }

    private func anchorCandidateIndex(pillTopY: CGFloat) -> Int? {
        let messageViews = messageArrangedViews()
        guard !messageViews.isEmpty else { return nil }
        var bestIndex: Int?
        var bestMaxY: CGFloat = -.greatestFiniteMagnitude
        for (index, subview) in messageViews.enumerated() {
            let frame = contentStack.convert(subview.frame, to: view)
            guard frame.maxY <= pillTopY - 1 else { continue }
            if frame.maxY > bestMaxY {
                bestMaxY = frame.maxY
                bestIndex = index
            }
        }
        if let bestIndex {
            return bestIndex
        }
        return messageViews.count - 1
    }

    private func anchorSample(index: Int, pillTopY: CGFloat) -> AnchorSample? {
        let messageViews = messageArrangedViews()
        guard index >= 0, index < messageViews.count else { return nil }
        let frame = contentStack.convert(messageViews[index].frame, to: view)
        let scale = max(1, view.traitCollection.displayScale)
        let bottomY = pixelAlign(frame.maxY, scale: scale)
        let gap = pillTopY - bottomY
        return AnchorSample(index: index, bottomY: bottomY, gap: gap)
    }

    private func anchorBottomContentY(index: Int) -> CGFloat? {
        let messageViews = messageArrangedViews()
        guard index >= 0, index < messageViews.count else { return nil }
        let frame = messageViews[index].frame
        let contentY = frame.maxY + contentStack.frame.minY
        let scale = max(1, view.traitCollection.displayScale)
        return pixelAlign(contentY, scale: scale)
    }

    private struct AnchorSample {
        let index: Int
        let bottomY: CGFloat
        let gap: CGFloat
    }

    private struct InteractiveDismissalAnchor {
        let startOffsetY: CGFloat
        let startPillTopY: CGFloat
        let anchorIndex: Int
        let anchorGap: CGFloat?
    }

    private struct KeyboardTransition {
        let oldPillTopY: CGFloat
        let oldOffsetY: CGFloat
        let distanceFromBottom: CGFloat
        let wasAtBottom: Bool
        var applied: Bool
    }

}

private final class TopFadeView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    private var gradientLayer: CAGradientLayer {
        layer as? CAGradientLayer ?? CAGradientLayer()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: TopFadeView, previousTraitCollection: UITraitCollection) in
            guard let self else { return }
            if previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle {
                self.updateColors()
            }
        }
    }

    func updateColors() {
        let base = UIColor.systemBackground
        // Gradient from solid at top to transparent at bottom
        // Use multiple stops with easing for a smooth falloff (no hard line)
        gradientLayer.colors = [
            base.withAlphaComponent(1.0).cgColor,
            base.withAlphaComponent(0.8).cgColor,
            base.withAlphaComponent(0.4).cgColor,
            base.withAlphaComponent(0.0).cgColor
        ]
        // Ease-out curve: fast initial fade, then gradual
        gradientLayer.locations = [0.0, 0.3, 0.6, 1.0]
    }
}

private final class BottomFadeView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    private var gradientLayer: CAGradientLayer {
        layer as? CAGradientLayer ?? CAGradientLayer()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: BottomFadeView, previousTraitCollection: UITraitCollection) in
            guard let self else { return }
            if previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle {
                self.updateColors()
            }
        }
    }

    func updateColors() {
        let base = UIColor.systemBackground
        // Gradient from transparent at top to solid at bottom
        gradientLayer.colors = [
            base.withAlphaComponent(0.0).cgColor,
            base.withAlphaComponent(0.4).cgColor,
            base.withAlphaComponent(0.8).cgColor,
            base.withAlphaComponent(1.0).cgColor
        ]
        // Ease-in curve: gradual start, then fast fade to solid
        gradientLayer.locations = [0.0, 0.4, 0.7, 1.0]
    }
}
