import SwiftUI
import UIKit

struct InputStrategyLabView: View {
    private let strategies: [InputStrategy] = [
        InputStrategy(
            id: "baseline",
            title: "Baseline (bottom aligned)",
            detail: "Insets 4/5.3, auto scroll",
            topInsetExtra: 4,
            bottomInsetExtra: 5.333333333333333,
            scrollMode: .automatic,
            pinCaretToBottom: true,
            scrollRangeToVisible: false,
            allowCaretOverflow: false,
            showsActionButton: true,
            alignment: .bottomLeading
        ),
        InputStrategy(
            id: "baseline-scroll-overflow",
            title: "Baseline + scroll + overflow",
            detail: "Insets 4/5.3, always scroll, caret overflow",
            topInsetExtra: 4,
            bottomInsetExtra: 5.333333333333333,
            scrollMode: .always,
            pinCaretToBottom: false,
            scrollRangeToVisible: false,
            allowCaretOverflow: true,
            showsActionButton: true,
            alignment: .bottomLeading
        ),
        InputStrategy(
            id: "no-insets",
            title: "No extra insets",
            detail: "Insets 0/0, auto scroll",
            topInsetExtra: 0,
            bottomInsetExtra: 0,
            scrollMode: .automatic,
            pinCaretToBottom: false,
            scrollRangeToVisible: false,
            allowCaretOverflow: false,
            showsActionButton: false,
            alignment: .bottomLeading
        ),
        InputStrategy(
            id: "top-aligned",
            title: "Top aligned",
            detail: "Insets 0/0, auto scroll",
            topInsetExtra: 0,
            bottomInsetExtra: 0,
            scrollMode: .automatic,
            pinCaretToBottom: false,
            scrollRangeToVisible: false,
            allowCaretOverflow: false,
            showsActionButton: false,
            alignment: .topLeading
        ),
        InputStrategy(
            id: "pin-caret",
            title: "Pin caret to bottom",
            detail: "Insets 0/0, auto scroll + pin caret",
            topInsetExtra: 0,
            bottomInsetExtra: 0,
            scrollMode: .automatic,
            pinCaretToBottom: true,
            scrollRangeToVisible: false,
            allowCaretOverflow: false,
            showsActionButton: false,
            alignment: .bottomLeading
        ),
        InputStrategy(
            id: "scroll-range",
            title: "ScrollRangeToVisible",
            detail: "Insets 0/0, auto scroll + scrollRangeToVisible",
            topInsetExtra: 0,
            bottomInsetExtra: 0,
            scrollMode: .automatic,
            pinCaretToBottom: false,
            scrollRangeToVisible: true,
            allowCaretOverflow: false,
            showsActionButton: false,
            alignment: .bottomLeading
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Type returns (8+) and watch caret delta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(strategies) { strategy in
                    StrategyCard(strategy: strategy)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Input Strategy Lab")
    }
}

private struct StrategyCard: View {
    let strategy: InputStrategy
    @State private var text: String = ""
    @State private var measuredHeight: CGFloat
    @State private var caretFrameInWindow: CGRect = .zero
    @State private var pillFrameInWindow: CGRect = .zero
    @State private var baselineDistance: CGFloat?

    init(strategy: InputStrategy) {
        self.strategy = strategy
        let minHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: 1,
            topInsetExtra: strategy.topInsetExtra,
            bottomInsetExtra: strategy.bottomInsetExtra
        )
        _measuredHeight = State(initialValue: minHeight)
    }

    var body: some View {
        let editorHeight = max(
            DebugInputBarMetrics.editorHeight(
                forLineCount: 1,
                topInsetExtra: strategy.topInsetExtra,
                bottomInsetExtra: strategy.bottomInsetExtra
            ),
            measuredHeight
        )
        let pillHeight = max(DebugInputBarMetrics.inputHeight, editorHeight)
        let railHeight = max(strategy.maxHeight, pillHeight)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(strategy.title)
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    text = ""
                }
                .buttonStyle(.borderless)
            }
            Text(strategy.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: strategy.alignment) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.systemFill))
                    .opacity(0.08)
                InputStrategyPill(
                    strategy: strategy,
                    text: $text,
                    measuredHeight: $measuredHeight,
                    caretFrameInWindow: $caretFrameInWindow,
                    editorHeight: editorHeight,
                    pillHeight: pillHeight
                ) {
                    text = ""
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: PillFramePreferenceKey.self, value: proxy.frame(in: .global))
                    }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: railHeight)
            .onPreferenceChange(PillFramePreferenceKey.self) { frame in
                pillFrameInWindow = frame
            }
            metricsRow
        }
        .onChange(of: text) { _, newValue in
            if newValue.isEmpty {
                baselineDistance = nil
            }
        }
        .onChange(of: caretDistance) { _, newValue in
            if baselineDistance == nil, let newValue {
                baselineDistance = newValue
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(UIColor.separator), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var caretDistance: CGFloat? {
        guard caretFrameInWindow != .zero, pillFrameInWindow != .zero else { return nil }
        return pillFrameInWindow.maxY - caretFrameInWindow.maxY
    }

    private var caretDelta: CGFloat? {
        guard let baselineDistance, let caretDistance else { return nil }
        return caretDistance - baselineDistance
    }

    private var metricsRow: some View {
        let distanceText = formatValue(caretDistance)
        let deltaText = formatValue(caretDelta)
        let lineCount = DebugInputBarMetrics.lineCount(for: text)
        let caretY = formatValue(caretFrameInWindow == .zero ? nil : caretFrameInWindow.maxY)
        let minHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: 1,
            topInsetExtra: strategy.topInsetExtra,
            bottomInsetExtra: strategy.bottomInsetExtra
        )
        let editorHeight = max(minHeight, measuredHeight)
        let pillHeight = max(DebugInputBarMetrics.inputHeight, editorHeight)
        let editorHeightText = formatValue(editorHeight)
        let pillHeightText = formatValue(pillHeight)
        return Text(
            "lines \(lineCount) | dist \(distanceText) | delta \(deltaText) | caretY \(caretY) | height \(editorHeightText) | pill \(pillHeightText)"
        )
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("debug.strategy.\(strategy.id).metrics")
    }

    private func formatValue(_ value: CGFloat?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }
}

private struct PillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

struct InputStrategy: Identifiable {
    let id: String
    let title: String
    let detail: String
    let topInsetExtra: CGFloat
    let bottomInsetExtra: CGFloat
    let scrollMode: InputScrollMode
    let pinCaretToBottom: Bool
    let scrollRangeToVisible: Bool
    let allowCaretOverflow: Bool
    let showsActionButton: Bool
    let alignment: Alignment
    let maxHeight: CGFloat

    init(
        id: String,
        title: String,
        detail: String,
        topInsetExtra: CGFloat,
        bottomInsetExtra: CGFloat,
        scrollMode: InputScrollMode,
        pinCaretToBottom: Bool,
        scrollRangeToVisible: Bool,
        allowCaretOverflow: Bool,
        showsActionButton: Bool,
        alignment: Alignment,
        maxHeight: CGFloat = DebugInputBarMetrics.maxInputHeight
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.topInsetExtra = topInsetExtra
        self.bottomInsetExtra = bottomInsetExtra
        self.scrollMode = scrollMode
        self.pinCaretToBottom = pinCaretToBottom
        self.scrollRangeToVisible = scrollRangeToVisible
        self.allowCaretOverflow = allowCaretOverflow
        self.showsActionButton = showsActionButton
        self.alignment = alignment
        self.maxHeight = maxHeight
    }
}

enum InputScrollMode {
    case automatic
    case always
    case never
}

struct InputStrategyPill: View {
    let strategy: InputStrategy
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var caretFrameInWindow: CGRect
    let editorHeight: CGFloat
    let pillHeight: CGFloat
    let onSend: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                StrategyTextView(
                    text: $text,
                    measuredHeight: $measuredHeight,
                    caretFrameInWindow: $caretFrameInWindow,
                    strategy: strategy
                )
                if text.isEmpty {
                    let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
                    Text("Message")
                        .foregroundStyle(.secondary)
                        .font(.body)
                        .padding(.top, verticalInset + strategy.topInsetExtra)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: editorHeight)
            if strategy.showsActionButton {
                if text.isEmpty {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .offset(y: -12)
                        .padding(.trailing, 8)
                } else {
                    Button(action: { onSend?() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .offset(x: 1, y: -4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.sendButton")
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: pillHeight, alignment: .bottom)
        .background(
            RoundedRectangle(cornerRadius: DebugInputBarMetrics.pillCornerRadius)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }
}

struct StrategyTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var caretFrameInWindow: CGRect
    let strategy: InputStrategy
    let isFocused: Binding<Bool>?
    let programmaticChangeToken: Binding<Int>?

    init(
        text: Binding<String>,
        measuredHeight: Binding<CGFloat>,
        caretFrameInWindow: Binding<CGRect>,
        strategy: InputStrategy,
        isFocused: Binding<Bool>? = nil,
        programmaticChangeToken: Binding<Int>? = nil
    ) {
        self._text = text
        self._measuredHeight = measuredHeight
        self._caretFrameInWindow = caretFrameInWindow
        self.strategy = strategy
        self.isFocused = isFocused
        self.programmaticChangeToken = programmaticChangeToken
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isScrollEnabled = strategy.scrollMode == .always
        textView.clipsToBounds = !strategy.allowCaretOverflow
        textView.backgroundColor = .clear
        textView.contentInsetAdjustmentBehavior = .never
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset + strategy.topInsetExtra,
            left: 0,
            bottom: verticalInset + strategy.bottomInsetExtra,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.returnKeyType = .default
        textView.text = text
        textView.accessibilityIdentifier = "debug.strategy.\(strategy.id)"
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize {
        let targetWidth = proposal.width ?? uiView.bounds.width
        let width = max(1, targetWidth)
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: size.height)
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let programmaticChanged: Bool
        if let programmaticChangeToken {
            if context.coordinator.lastProgrammaticToken != programmaticChangeToken.wrappedValue {
                context.coordinator.lastProgrammaticToken = programmaticChangeToken.wrappedValue
                programmaticChanged = true
            } else {
                programmaticChanged = false
            }
        } else {
            programmaticChanged = false
        }
        if uiView.text != text {
            var shouldApplyText = true
            if uiView.isFirstResponder {
                let isComposing = uiView.markedTextRange != nil
                if programmaticChangeToken != nil {
                    shouldApplyText = programmaticChanged && !isComposing
                } else {
                    shouldApplyText = text.isEmpty && !isComposing
                }
            }
            if shouldApplyText {
                uiView.text = text
            }
        }
        let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
        let targetInset = UIEdgeInsets(
            top: verticalInset + strategy.topInsetExtra,
            left: 0,
            bottom: verticalInset + strategy.bottomInsetExtra,
            right: 0
        )
        if uiView.textContainerInset != targetInset {
            uiView.textContainerInset = targetInset
        }
        context.coordinator.scheduleMeasurement(textView: uiView)
        context.coordinator.scheduleCaretUpdate(textView: uiView)
        if let isFocused {
            if isFocused.wrappedValue && !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            } else if !isFocused.wrappedValue && uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: StrategyTextView
        private var lastMeasuredWidth: CGFloat = 0
        private var pendingMeasurement = false
        private var pendingCaretUpdate = false
        var lastProgrammaticToken = 0

        init(parent: StrategyTextView) {
            self.parent = parent
            self.lastProgrammaticToken = parent.programmaticChangeToken?.wrappedValue ?? 0
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if textView.bounds.width > 0 {
                applyMeasurement(textView: textView)
                applyScrollBehavior(textView: textView)
                updateCaretFrame(textView: textView)
            } else {
                scheduleMeasurement(textView: textView)
                scheduleCaretUpdate(textView: textView)
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if let isFocused = parent.isFocused, !isFocused.wrappedValue {
                isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if let isFocused = parent.isFocused, isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            scheduleCaretUpdate(textView: textView)
        }

        func scheduleMeasurement(textView: UITextView) {
            let width = textView.bounds.width
            guard width > 0 else { return }
            if abs(width - lastMeasuredWidth) <= 0.5, pendingMeasurement {
                return
            }
            lastMeasuredWidth = width
            guard !pendingMeasurement else { return }
            pendingMeasurement = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingMeasurement = false
                self.applyMeasurement(textView: textView)
                self.applyScrollBehavior(textView: textView)
            }
        }

        private func applyMeasurement(textView: UITextView) {
            textView.layoutIfNeeded()
            let width = max(1, textView.bounds.width)
            let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let includesTrailingLine = textView.text.isEmpty || textView.text.hasSuffix("\n")
            let sizeHeight = size.height
            var contentHeight = sizeHeight
            let fallbackLineCount = DebugInputBarMetrics.lineCount(for: textView.text)
            let expectedHeight = DebugInputBarMetrics.editorHeight(
                forLineCount: fallbackLineCount,
                topInsetExtra: parent.strategy.topInsetExtra,
                bottomInsetExtra: parent.strategy.bottomInsetExtra
            )
            let lineHeight = textView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let insets = textView.textContainerInset
            let rawCount = (sizeHeight - insets.top - insets.bottom) / lineHeight
            let fittedLineCount = max(1, Int(round(rawCount)))
            let wrapsBeyondFallback = fittedLineCount > fallbackLineCount
                && sizeHeight - expectedHeight > lineHeight * 0.75
            if !includesTrailingLine {
                let extra = sizeHeight - expectedHeight
                if !wrapsBeyondFallback {
                    if abs(extra) <= lineHeight * 0.5 {
                        contentHeight = expectedHeight
                    } else if extra > lineHeight * 0.5, extra < lineHeight * 1.5 {
                        contentHeight = max(0, sizeHeight - lineHeight)
                    }
                }
            }
            let minHeight = DebugInputBarMetrics.editorHeight(
                forLineCount: 1,
                topInsetExtra: parent.strategy.topInsetExtra,
                bottomInsetExtra: parent.strategy.bottomInsetExtra
            )
            let rawHeight = max(minHeight, contentHeight)
            let scale = max(1, textView.traitCollection.displayScale)
            let alignedHeight = (rawHeight * scale).rounded(.up) / scale
            let clampedHeight = min(parent.strategy.maxHeight, alignedHeight)
            if abs(parent.measuredHeight - clampedHeight) > 0.5 {
                parent.measuredHeight = clampedHeight
            }
        }

        private func applyScrollBehavior(textView: UITextView) {
            let shouldScroll: Bool
            switch parent.strategy.scrollMode {
            case .always:
                shouldScroll = true
            case .never:
                shouldScroll = false
            case .automatic:
                shouldScroll = parent.measuredHeight >= parent.strategy.maxHeight - 0.5
            }
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
            }
            if !shouldScroll {
                let minOffset = -textView.adjustedContentInset.top
                if abs(textView.contentOffset.y - minOffset) > 0.5 {
                    textView.setContentOffset(CGPoint(x: 0, y: minOffset), animated: false)
                }
            }
            if parent.strategy.scrollRangeToVisible {
                let endRange = NSRange(location: textView.text.count, length: 0)
                textView.scrollRangeToVisible(endRange)
            }
            if parent.strategy.pinCaretToBottom {
                pinCaretToBottomIfNeeded(textView: textView)
            }
        }

        private func pinCaretToBottomIfNeeded(textView: UITextView) {
            guard textView.isScrollEnabled else { return }
            let selectedRange = textView.selectedRange
            guard selectedRange.length == 0 else { return }
            guard selectedRange.location == textView.text.count else { return }
            let visibleHeight = textView.bounds.height
            guard visibleHeight > 1 else { return }
            guard textView.contentSize.height > visibleHeight + 1 else { return }
            let bottomInset = textView.textContainerInset.bottom
            let targetBottom = visibleHeight - bottomInset
            let caretPosition = textView.selectedTextRange?.end ?? textView.endOfDocument
            let caretRect = textView.caretRect(for: caretPosition)
            let delta = caretRect.maxY - targetBottom
            guard abs(delta) > 0.5 else { return }
            var targetOffset = textView.contentOffset
            targetOffset.y += delta
            let minOffset = -textView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                textView.contentSize.height - visibleHeight + textView.adjustedContentInset.bottom
            )
            targetOffset.y = min(max(targetOffset.y, minOffset), maxOffset)
            if abs(targetOffset.y - textView.contentOffset.y) > 0.5 {
                textView.setContentOffset(targetOffset, animated: false)
            }
        }

        func scheduleCaretUpdate(textView: UITextView) {
            guard !pendingCaretUpdate else { return }
            pendingCaretUpdate = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingCaretUpdate = false
                self.updateCaretFrame(textView: textView)
            }
        }

        private func updateCaretFrame(textView: UITextView) {
            textView.layoutIfNeeded()
            let caretPosition = textView.selectedTextRange?.end ?? textView.endOfDocument
            let caretRect = textView.caretRect(for: caretPosition)
            guard caretRect.height > 0 else { return }
            guard let window = textView.window else { return }
            let frameInWindow = textView.convert(caretRect, to: window)
            if parent.caretFrameInWindow != frameInWindow {
                parent.caretFrameInWindow = frameInWindow
            }
        }
    }
}

#Preview {
    NavigationStack {
        InputStrategyLabView()
    }
}
