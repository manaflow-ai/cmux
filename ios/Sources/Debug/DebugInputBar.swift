import Combine
import SwiftUI
import UIKit

enum DebugInputBarMetrics {
    static let inputHeight: CGFloat = 42
    static let maxInputHeight: CGFloat = 120
    static let topPadding: CGFloat = 8
    static let textVerticalPadding: CGFloat = 8
    static let pillCornerRadius: CGFloat = 18
    static let singleLineTolerance: CGFloat = 8
    static let minStableMeasureWidth: CGFloat = 120

    static var singleLineEditorHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight + textVerticalPadding
    }

    static func lineCount(for text: String) -> Int {
        max(1, text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count)
    }

    static func editorHeight(
        for text: String,
        topInsetExtra: CGFloat = 0,
        bottomInsetExtra: CGFloat = 0
    ) -> CGFloat {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let lineCount = lineCount(for: text)
        let insetExtra = topInsetExtra + bottomInsetExtra
        let rawHeight = lineHeight * CGFloat(lineCount) + textVerticalPadding + insetExtra
        let minHeight = lineHeight + textVerticalPadding + insetExtra
        return min(maxInputHeight, max(minHeight, rawHeight))
    }

    static func editorHeight(
        forLineCount lineCount: Int,
        topInsetExtra: CGFloat = 0,
        bottomInsetExtra: CGFloat = 0
    ) -> CGFloat {
        let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        let safeLineCount = max(1, lineCount)
        let insetExtra = topInsetExtra + bottomInsetExtra
        let rawHeight = lineHeight * CGFloat(safeLineCount) + textVerticalPadding + insetExtra
        let minHeight = lineHeight + textVerticalPadding + insetExtra
        return min(maxInputHeight, max(minHeight, rawHeight))
    }

    static func pillHeight(for text: String) -> CGFloat {
        max(inputHeight, editorHeight(for: text))
    }
}

final class InputBarContainerView: UIView {
    var preferredHeightProvider: (() -> CGFloat)?

    override var intrinsicContentSize: CGSize {
        let height = preferredHeightProvider?() ?? UIView.noIntrinsicMetric
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
}

/// Shared floating glass input bar for all debug approaches
struct DebugInputBar: View {
    @Binding var text: String
    @Binding var programmaticChangeToken: Int
    let onSend: () -> Void
    @Binding var isFocused: Bool
    @ObservedObject var layout: InputBarLayoutModel
    @ObservedObject var geometry: InputBarGeometryModel

    @State private var textFieldFocused = false
    @State private var measuredTextHeight = DebugInputBarMetrics.singleLineEditorHeight
    @State private var measuredLineCount = 1
    @State private var textViewIsEmpty = true
    @State private var baselineCaretDistanceToBottom: CGFloat?
    @State private var baselineCandidateDistance: CGFloat?
    @State private var baselineCandidateCount = 0
    @State private var didEnterMultiline = false
    @State private var isScrollEnabled = false
    @SwiftUI.Environment(\.displayScale) private var displayScale
    @AppStorage("debug.input.bottomInsetSingleExtra") private var bottomInsetSingleExtra: Double = 0
    @AppStorage("debug.input.bottomInsetMultiExtra") private var bottomInsetMultiExtra: Double = 5.333333333333333
    @AppStorage("debug.input.topInsetMultiExtra") private var topInsetMultiExtra: Double = 4
    @AppStorage("debug.input.micOffset") private var micOffset: Double = -12
    @AppStorage("debug.input.sendOffset") private var sendOffset: Double = -4
    @AppStorage("debug.input.sendXOffset") private var sendXOffset: Double = 1
    @AppStorage("debug.input.isMultiline") private var isMultilineFlag = false

    init(
        text: Binding<String>,
        programmaticChangeToken: Binding<Int>,
        isFocused: Binding<Bool> = .constant(false),
        geometry: InputBarGeometryModel,
        layout: InputBarLayoutModel,
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self._programmaticChangeToken = programmaticChangeToken
        self._isFocused = isFocused
        self._textViewIsEmpty = State(initialValue: text.wrappedValue.isEmpty)
        self.geometry = geometry
        self.layout = layout
        self.onSend = onSend
    }

    var body: some View {
        let scale = max(1, displayScale)
        func pixelAlign(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        let isTextEmpty = textViewIsEmpty
        let effectiveLineCount = max(1, measuredLineCount, DebugInputBarMetrics.lineCount(for: text))
        let isSingleLine = effectiveLineCount <= 1
        let baselineBottomInsetExtra: CGFloat = 5.333333333333333
        let baselineTopInsetExtra: CGFloat = 4
        let candidateBottomInsetExtra = alignToPixel(baselineBottomInsetExtra)
        let candidateTopInsetExtra = alignToPixel(baselineTopInsetExtra)
#if DEBUG
        if UITestConfig.mockDataEnabled {
            DebugLog.addDedup(
                "input.insets.state",
                "InputBar insets bottomExtra=\(String(format: "%.2f", candidateBottomInsetExtra)) topExtra=\(String(format: "%.2f", candidateTopInsetExtra)) lineCount=\(effectiveLineCount) textLen=\(text.count)"
            )
        }
#endif
        let fallbackHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: effectiveLineCount,
            topInsetExtra: CGFloat(candidateTopInsetExtra),
            bottomInsetExtra: CGFloat(candidateBottomInsetExtra)
        )
        let measuredHeight = pixelAlign(min(DebugInputBarMetrics.maxInputHeight, measuredTextHeight))
        let resolvedMeasuredHeight = max(measuredHeight, DebugInputBarMetrics.singleLineEditorHeight)
        let editorHeight = pixelAlign(min(DebugInputBarMetrics.maxInputHeight, resolvedMeasuredHeight > 0 ? resolvedMeasuredHeight : fallbackHeight))
        let shouldCenter = false
        let showDebugOverlays = DebugSettings.showChatOverlays
        let bottomInsetExtra = candidateBottomInsetExtra
        let topInsetExtra = candidateTopInsetExtra
        let pillHeight = pixelAlign(max(DebugInputBarMetrics.inputHeight, editorHeight))
        let verticalOffset = CGFloat(0)
        let singleLineCap = DebugInputBarMetrics.inputHeight + DebugInputBarMetrics.singleLineTolerance
        let cornerRadius: CGFloat = pillHeight <= singleLineCap
            ? pillHeight / 2
            : DebugInputBarMetrics.pillCornerRadius
        let pillShape = AnyShape(
            RoundedRectangle(
                cornerRadius: cornerRadius,
                style: .continuous
            )
        )
        return GlassEffectContainer {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(alignment: .bottom, spacing: 12) {
                        plusButton
                        inputPillView(
                            editorHeight: editorHeight,
                            isSingleLine: isSingleLine,
                            isTextEmpty: isTextEmpty,
                            shouldCenter: shouldCenter,
                            pillHeight: pillHeight,
                            pillShape: pillShape,
                            showDebugOverlays: showDebugOverlays,
                            micOffset: CGFloat(micOffset),
                            bottomInsetExtra: CGFloat(bottomInsetExtra),
                            topInsetExtra: CGFloat(topInsetExtra),
                            verticalOffset: verticalOffset,
                            sendOffset: CGFloat(sendOffset),
                            sendXOffset: CGFloat(sendXOffset)
                        )
                    }
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, DebugInputBarMetrics.topPadding)
                    .padding(.bottom, layout.bottomPadding)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: layout.animationDuration), value: layout.horizontalPadding)
        .animation(.easeInOut(duration: layout.animationDuration), value: layout.bottomPadding)
        .onAppear {
            textFieldFocused = isFocused
            if geometry.pillHeight != pillHeight {
                geometry.pillHeight = pillHeight
            }
            updateBaselineCaretDistance(isSingleLine: isSingleLine, isTextEmpty: isTextEmpty)
        }
        .onChange(of: pillHeight) { _, newValue in
            if geometry.pillHeight != newValue {
                geometry.pillHeight = newValue
            }
        }
        
        .onChange(of: geometry.caretFrameInWindow) { _, _ in
            updateBaselineCaretDistance(isSingleLine: isSingleLine, isTextEmpty: isTextEmpty)
        }
        .onChange(of: geometry.pillFrameInWindow) { _, _ in
            updateBaselineCaretDistance(isSingleLine: isSingleLine, isTextEmpty: isTextEmpty)
        }
        .onChange(of: geometry.pillBottomEdgePresentationFrameInWindow) { _, _ in
            updateBaselineCaretDistance(isSingleLine: isSingleLine, isTextEmpty: isTextEmpty)
        }
        .onChange(of: textViewIsEmpty) { _, _ in
            updateBaselineCaretDistance(isSingleLine: isSingleLine, isTextEmpty: isTextEmpty)
        }
        .onChange(of: pillHeight) { _, newValue in
            DebugLog.addDedup(
                "input.pill.height",
                "InputBar pillHeight=\(String(format: "%.1f", newValue)) editorHeight=\(String(format: "%.1f", editorHeight)) lineCount=\(effectiveLineCount) textLen=\(text.count)"
            )
        }
        .onChange(of: measuredLineCount) { _, newValue in
            DebugLog.addDedup(
                "input.measure.lines",
                "InputBar measuredLineCount=\(newValue) textLen=\(text.count) measuredHeight=\(String(format: "%.1f", measuredTextHeight))"
            )
            updateBaselineCaretDistance(isSingleLine: isSingleLine, isTextEmpty: isTextEmpty)
            if newValue > 1 {
                didEnterMultiline = true
            }
        }
        .onChange(of: measuredTextHeight) { _, newValue in
            DebugLog.addDedup(
                "input.measure.height",
                "InputBar measuredHeight=\(String(format: "%.1f", newValue)) lineCount=\(measuredLineCount) textLen=\(text.count)"
            )
        }
        .onChange(of: text) { _, newValue in
            DebugLog.addDedup(
                "input.text.binding",
                "InputBar text binding len=\(newValue.count) viewEmpty=\(textViewIsEmpty)"
            )
            let isEmpty = newValue.isEmpty
            if textViewIsEmpty != isEmpty {
                textViewIsEmpty = isEmpty
            }
            let nextLineCount = DebugInputBarMetrics.lineCount(for: newValue)
            if measuredLineCount != nextLineCount {
                measuredLineCount = nextLineCount
            }
            if newValue.isEmpty {
                didEnterMultiline = false
                let resetHeight = alignToPixel(DebugInputBarMetrics.singleLineEditorHeight)
                if abs(measuredTextHeight - resetHeight) > 0.5 {
                    measuredTextHeight = resetHeight
                }
            } else if DebugInputBarMetrics.lineCount(for: newValue) > 1 {
                didEnterMultiline = true
            }
        }
        .onChange(of: textViewIsEmpty) { _, newValue in
            DebugLog.addDedup("input.placeholder.state", "InputBar placeholderEmpty=\(newValue) textLen=\(text.count)")
            if newValue {
                didEnterMultiline = false
                baselineCaretDistanceToBottom = nil
                baselineCandidateDistance = nil
                baselineCandidateCount = 0
            }
        }
        .onChange(of: textFieldFocused) { _, newValue in
            isFocused = newValue
        }
        .onChange(of: isFocused) { _, newValue in
            textFieldFocused = newValue
        }
        .onAppear {
            isMultilineFlag = !isSingleLine
            textViewIsEmpty = text.isEmpty
            measuredLineCount = DebugInputBarMetrics.lineCount(for: text)
        }
        .onChange(of: isSingleLine) { _, newValue in
            isMultilineFlag = !newValue
            DebugLog.addDedup(
                "input.multiline",
                "InputBar isSingleLine=\(newValue) textLen=\(text.count) lineCount=\(measuredLineCount)"
            )
        }
    }

    private func updateBaselineCaretDistance(isSingleLine: Bool, isTextEmpty: Bool) {
        if UITestConfig.mockDataEnabled {
            return
        }
        guard isSingleLine, !didEnterMultiline, !isTextEmpty else { return }
        guard baselineCaretDistanceToBottom == nil else { return }
        let fullPillFrame = geometry.pillFrameInWindow
        let hasFullFrame = fullPillFrame.height >= DebugInputBarMetrics.inputHeight - 0.5
        let bottomEdgeFrame = geometry.pillBottomEdgePresentationFrameInWindow
        let pillFrame = bottomEdgeFrame != .zero
            ? bottomEdgeFrame
            : (hasFullFrame ? fullPillFrame : .zero)
        let caretFrame = geometry.caretFrameInWindow
        guard pillFrame != .zero, caretFrame != .zero else { return }
        let pillBottom = pillFrame.height <= 1
            ? pillFrame
            : CGRect(x: pillFrame.minX, y: max(pillFrame.maxY - 1, pillFrame.minY), width: pillFrame.width, height: 1)
        let distance = pillBottom.maxY - caretFrame.maxY
        guard distance.isFinite, distance > 0 else { return }
        let alignedDistance = alignToPixel(distance)
        if let candidate = baselineCandidateDistance, abs(candidate - alignedDistance) <= 0.5 {
            baselineCandidateCount += 1
        } else {
            baselineCandidateDistance = alignedDistance
            baselineCandidateCount = 1
        }
        if baselineCandidateCount >= 3, let candidate = baselineCandidateDistance {
            baselineCaretDistanceToBottom = candidate
        }
    }

    private func alignToPixel(_ value: CGFloat) -> CGFloat {
        let scale = max(1, displayScale)
        return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    private var plusButton: some View {
        Button {} label: {
            Image(systemName: "plus")
                .font(.title3)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .frame(width: DebugInputBarMetrics.inputHeight, height: DebugInputBarMetrics.inputHeight)
        .glassEffect(.regular.interactive(), in: .circle)
    }

    @ViewBuilder
    private func inputPillView(
        editorHeight: CGFloat,
        isSingleLine: Bool,
        isTextEmpty: Bool,
        shouldCenter: Bool,
        pillHeight: CGFloat,
        pillShape: AnyShape,
        showDebugOverlays: Bool,
        micOffset: CGFloat,
        bottomInsetExtra: CGFloat,
        topInsetExtra: CGFloat,
        verticalOffset: CGFloat,
        sendOffset: CGFloat,
        sendXOffset: CGFloat
    ) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            inputFieldView(
                editorHeight: editorHeight,
                isSingleLine: isSingleLine,
                isTextEmpty: isTextEmpty,
                shouldCenter: shouldCenter,
                pillHeight: pillHeight,
                showDebugOverlays: showDebugOverlays,
                bottomInsetExtra: bottomInsetExtra,
                topInsetExtra: topInsetExtra,
                verticalOffset: verticalOffset
            )
            if isTextEmpty {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .offset(y: micOffset)
                    .padding(.trailing, 8)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .blue)
                        .offset(x: sendXOffset, y: sendOffset)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.sendButton")
                .background(
                    Group {
                        if UITestConfig.mockDataEnabled {
                            InputBarFrameReader { frame in
                                geometry.sendButtonFrameInWindow = frame
                            }
                        }
                    }
                )
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: pillHeight, alignment: .bottom)
        .onChange(of: isTextEmpty) { _, empty in
            if empty {
                geometry.sendButtonFrameInWindow = .zero
            }
        }
        .glassEffect(.regular.interactive(), in: pillShape)
        .clipShape(pillShape)
        .mask(pillShape)
        .clipped()
        .background(
            InputBarFrameReader { frame in
                geometry.pillFrameInWindow = frame
            }
        )
        .background(showDebugOverlays ? Color.red.opacity(0.08) : Color.clear)
        .overlay(
            Group {
                if showDebugOverlays {
                    pillShape.stroke(Color.red.opacity(0.6), lineWidth: 1)
                }
            }
        )
        .overlay(
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("chat.inputPill")
                .accessibilityElement(children: .ignore)
                .allowsHitTesting(false)
        )
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(height: 1)
                .background(
                    Group {
                        if UITestConfig.presentationSamplingEnabled {
                            InputBarFrameReader(usePresentationLayer: true) { frame in
                                geometry.pillBottomEdgePresentationFrameInWindow = frame
                            }
                        }
                    }
                )
                .accessibilityIdentifier("chat.inputPillBottomEdge")
                .accessibilityElement(children: .ignore)
                .allowsHitTesting(false)
        }
        .contentShape(pillShape)
        .onTapGesture {
            textFieldFocused = true
        }
        .overlay(alignment: .topLeading) {
            if UITestConfig.mockDataEnabled {
                VStack(spacing: 0) {
                    Button {
                        text = "Line 1\nLine 2\nLine 3"
                        programmaticChangeToken += 1
                    } label: {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("chat.debugSetMultiline")

                    Button {
                        text = ""
                        programmaticChangeToken += 1
                    } label: {
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("chat.debugClearInput")
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private func inputFieldView(
        editorHeight: CGFloat,
        isSingleLine: Bool,
        isTextEmpty: Bool,
        shouldCenter: Bool,
        pillHeight: CGFloat,
        showDebugOverlays: Bool,
        bottomInsetExtra: CGFloat,
        topInsetExtra: CGFloat,
        verticalOffset: CGFloat
    ) -> some View {
        let strategy = InputStrategy(
            id: "baseline-main",
            title: "Baseline main",
            detail: "",
            topInsetExtra: topInsetExtra,
            bottomInsetExtra: bottomInsetExtra,
            scrollMode: .automatic,
            pinCaretToBottom: true,
            scrollRangeToVisible: false,
            allowCaretOverflow: false,
            showsActionButton: false,
            alignment: .bottomLeading,
            maxHeight: DebugInputBarMetrics.maxInputHeight
        )
        let inputField = Group {
            if UITestConfig.mockDataEnabled {
                InputTextView(
                    text: $text,
                    programmaticChangeToken: $programmaticChangeToken,
                    textIsEmpty: $textViewIsEmpty,
                    measuredHeight: $measuredTextHeight,
                    measuredLineCount: $measuredLineCount,
                    caretFrameInWindow: $geometry.caretFrameInWindow,
                    inputFrameInWindow: $geometry.inputFrameInWindow,
                    bottomInsetExtra: bottomInsetExtra,
                    topInsetExtra: topInsetExtra,
                    isScrollEnabled: $isScrollEnabled,
                    isFocused: $textFieldFocused
                )
            } else {
                StrategyTextView(
                    text: $text,
                    measuredHeight: $measuredTextHeight,
                    caretFrameInWindow: $geometry.caretFrameInWindow,
                    strategy: strategy,
                    isFocused: $textFieldFocused,
                    programmaticChangeToken: $programmaticChangeToken
                )
            }
        }
        .frame(height: editorHeight)
        .id("chat.inputTextView")
        .overlay(alignment: .topLeading) {
            if isTextEmpty {
                let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
                Text("Message")
                    .foregroundStyle(.secondary)
                    .font(.body)
                    .padding(.top, verticalInset + topInsetExtra)
                    .allowsHitTesting(false)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
        }
        .clipped()
        .offset(y: verticalOffset)
        .background(showDebugOverlays ? Color.blue.opacity(0.12) : Color.clear)
        .overlay(
            Group {
                if showDebugOverlays {
                    Rectangle()
                        .stroke(Color.blue.opacity(0.6), lineWidth: 1)
                }
            }
        )
        .background(
            InputBarFrameReader { frame in
                geometry.inputFrameInWindow = frame
            }
        )
        ZStack(alignment: shouldCenter ? .center : .bottomLeading) {
            inputField
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: pillHeight)
        .layoutPriority(1)
    }
}

/// UIKit wrapper for the glass input bar
final class DebugInputBarViewController: UIViewController {
    var text: String {
        get { textModel.text }
        set { textModel.text = newValue }
    }
    var onSend: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    private let textModel = InputBarTextModel()
    var onLayoutChange: (() -> Void)?
    var contentTopInset: CGFloat { DebugInputBarMetrics.topPadding }
    var contentBottomInset: CGFloat { layoutModel.bottomPadding }
    var pillMeasuredFrame: CGRect { geometryModel.pillFrameInWindow }
    var pillFrameInView: CGRect {
        let viewHeight = view.bounds.height
        guard viewHeight > 0 else { return .zero }
        let fallbackHeight = DebugInputBarMetrics.pillHeight(for: textModel.text)
        let targetPillHeight = geometryModel.pillHeight > 0 ? geometryModel.pillHeight : fallbackHeight
        let availableHeight = max(0, viewHeight - contentTopInset - contentBottomInset)
        let height = min(targetPillHeight, availableHeight)
        let bottomLimit = viewHeight - contentBottomInset
        let topLimit = max(contentTopInset, bottomLimit - height)
        let resolvedHeight = max(0, bottomLimit - topLimit)
        let fallbackFrame = CGRect(x: 0, y: topLimit, width: view.bounds.width, height: resolvedHeight)
        if let window = view.window, pillMeasuredFrame != .zero {
            let converted = view.convert(pillMeasuredFrame, from: window)
            if abs(converted.maxY - bottomLimit) <= 1 {
                return converted
            }
        }
        return fallbackFrame
    }
    var pillHeight: CGFloat { max(0, pillFrameInView.height) }

    private var hostingController: UIHostingController<DebugInputBarWrapper>!
    private let layoutModel = InputBarLayoutModel(horizontalPadding: 20, bottomPadding: 28)
    private var lastReportedHeight: CGFloat = 0
    private let focusModel = InputBarFocusModel()
    private let geometryModel = InputBarGeometryModel()
    private var geometryCancellable: AnyCancellable?
    private var inputGeometryCancellable: AnyCancellable?
    private var pillHeightCancellable: AnyCancellable?
    private var textCancellable: AnyCancellable?
    private var liveBottomEdgeCancellable: AnyCancellable?
    private var caretCancellable: AnyCancellable?
    private var sendButtonCancellable: AnyCancellable?
    private let inputAccessibilityView = UIControl()
    private let liveBottomEdgeView = UIView()
    private let pillHeightAccessibilityView = UIView()
    private let pillFrameAccessibilityView = UIView()
    private let pillAccessibilityView = UIView()
    private let caretAccessibilityView = UIView()
    private let sendButtonAccessibilityView = UIControl()
    private let debugSetMultilineView = UIControl()
    private let debugClearInputView = UIControl()
    private weak var inputTextView: UITextView?
    private let inputTextIdentifiers: Set<String> = ["chat.inputField", "debug.strategy.baseline-main"]
    private var didLogInitialLayout = false
    private var containerView: InputBarContainerView? {
        view as? InputBarContainerView
    }

    override func loadView() {
        let container = InputBarContainerView()
        container.preferredHeightProvider = { [weak self, weak container] in
            guard let self, let container else { return UIView.noIntrinsicMetric }
            let width = max(1, container.bounds.width)
            return self.preferredHeight(for: width)
        }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        DebugLog.add("InputBarVC viewDidLoad mockData=\(UITestConfig.mockDataEnabled)")

        hostingController = UIHostingController(rootView: makeWrapper())
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.safeAreaRegions = []

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        inputAccessibilityView.isAccessibilityElement = true
        inputAccessibilityView.accessibilityIdentifier = "chat.inputValue"
        inputAccessibilityView.backgroundColor = .clear
        inputAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(inputAccessibilityView)

        pillFrameAccessibilityView.isAccessibilityElement = true
        pillFrameAccessibilityView.accessibilityIdentifier = "chat.inputPillFrame"
        pillFrameAccessibilityView.backgroundColor = .clear
        pillFrameAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(pillFrameAccessibilityView)

        pillAccessibilityView.isAccessibilityElement = true
        pillAccessibilityView.accessibilityIdentifier = "chat.inputPill"
        pillAccessibilityView.backgroundColor = .clear
        pillAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(pillAccessibilityView)

        let liveBottomEdgeEnabled = UITestConfig.presentationSamplingEnabled
        liveBottomEdgeView.isAccessibilityElement = liveBottomEdgeEnabled
        if liveBottomEdgeEnabled {
            liveBottomEdgeView.accessibilityIdentifier = "chat.inputPillBottomEdgeLive"
        }
        liveBottomEdgeView.backgroundColor = .clear
        liveBottomEdgeView.isUserInteractionEnabled = false
        view.addSubview(liveBottomEdgeView)

        pillHeightAccessibilityView.isAccessibilityElement = true
        pillHeightAccessibilityView.accessibilityIdentifier = "chat.pillHeightValue"
        pillHeightAccessibilityView.backgroundColor = .clear
        pillHeightAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(pillHeightAccessibilityView)

        caretAccessibilityView.isAccessibilityElement = true
        caretAccessibilityView.accessibilityIdentifier = "chat.inputCaretFrame"
        caretAccessibilityView.backgroundColor = .clear
        caretAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(caretAccessibilityView)

        sendButtonAccessibilityView.isAccessibilityElement = true
        sendButtonAccessibilityView.accessibilityIdentifier = "chat.sendButton"
        sendButtonAccessibilityView.accessibilityTraits = .button
        sendButtonAccessibilityView.backgroundColor = .clear
        sendButtonAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(sendButtonAccessibilityView)

        debugSetMultilineView.isAccessibilityElement = true
        debugSetMultilineView.accessibilityIdentifier = "chat.debugSetMultiline"
        debugSetMultilineView.accessibilityTraits = .button
        debugSetMultilineView.backgroundColor = .clear
        debugSetMultilineView.isUserInteractionEnabled = false
        view.addSubview(debugSetMultilineView)

        debugClearInputView.isAccessibilityElement = true
        debugClearInputView.accessibilityIdentifier = "chat.debugClearInput"
        debugClearInputView.accessibilityTraits = .button
        debugClearInputView.backgroundColor = .clear
        debugClearInputView.isUserInteractionEnabled = false
        view.addSubview(debugClearInputView)

        if UITestConfig.mockDataEnabled {
            inputAccessibilityView.isUserInteractionEnabled = true
            inputAccessibilityView.addTarget(self, action: #selector(handleInputTapTarget), for: .touchUpInside)
            debugSetMultilineView.isUserInteractionEnabled = true
            debugSetMultilineView.addTarget(self, action: #selector(handleDebugSetMultiline), for: .touchUpInside)
            debugSetMultilineView.addTarget(self, action: #selector(handleDebugSetMultiline), for: .primaryActionTriggered)
            debugClearInputView.isUserInteractionEnabled = true
            debugClearInputView.addTarget(self, action: #selector(handleDebugClearInput), for: .touchUpInside)
            debugClearInputView.addTarget(self, action: #selector(handleDebugClearInput), for: .primaryActionTriggered)
        }

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        geometryCancellable = geometryModel.$pillFrameInWindow
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updatePillFrameAccessibility()
                self?.onLayoutChange?()
            }
        pillHeightCancellable = geometryModel.$pillHeight
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.containerView?.invalidateIntrinsicContentSize()
                self?.updatePillHeightAccessibilityValue()
                self?.onLayoutChange?()
            }
        inputGeometryCancellable = geometryModel.$inputFrameInWindow
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateInputAccessibilityFrame()
            }
        liveBottomEdgeCancellable = geometryModel.$pillBottomEdgePresentationFrameInWindow
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateLiveBottomEdgeFrame()
            }
        caretCancellable = geometryModel.$caretFrameInWindow
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateCaretAccessibilityFrame()
            }
        sendButtonCancellable = geometryModel.$sendButtonFrameInWindow
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.updateSendButtonAccessibilityFrame()
            }
        textCancellable = textModel.$text
            .removeDuplicates()
            .sink { [weak self] value in
                self?.inputAccessibilityView.accessibilityValue = value
                if value.isEmpty, self?.geometryModel.baselineCaretDistanceToBottom != nil {
                    self?.geometryModel.baselineCaretDistanceToBottom = nil
                }
                self?.containerView?.invalidateIntrinsicContentSize()
                self?.onLayoutChange?()
                self?.updateSendButtonAccessibilityFrame()
                self?.updateAccessibilityElements()
            }
        updatePillHeightAccessibilityValue()

        if UITestConfig.mockDataEnabled {
            updateAccessibilityElements()
        }

        if UITestConfig.mockDataEnabled,
           let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_INPUT_TEXT"] {
            let resolved = raw.replacingOccurrences(of: "\\n", with: "\n")
            textModel.setTextProgrammatically(resolved)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = view.bounds.height
        if abs(height - lastReportedHeight) > 0.5 {
            lastReportedHeight = height
            onLayoutChange?()
        }
        if !didLogInitialLayout, height > 0 {
            didLogInitialLayout = true
            DebugLog.add("InputBarVC layout height=\(String(format: "%.1f", height)) pillHeight=\(String(format: "%.1f", pillHeight))")
        }
        updateInputAccessibilityFrame()
        updatePillFrameAccessibility()
        updateLiveBottomEdgeFrame()
        updateCaretAccessibilityFrame()
        updateSendButtonAccessibilityFrame()
        updateDebugActionFrames()
        updateAccessibilityElements()
    }

    func updateText(_ newText: String) {
        textModel.setTextProgrammatically(newText)
    }

    func clearText() {
        textModel.setTextProgrammatically("")
    }

    func updateLayout(horizontalPadding: CGFloat, bottomPadding: CGFloat, animationDuration: Double) {
        if layoutModel.horizontalPadding != horizontalPadding {
            layoutModel.horizontalPadding = horizontalPadding
        }
        if layoutModel.bottomPadding != bottomPadding {
            layoutModel.bottomPadding = bottomPadding
        }
        if abs(layoutModel.animationDuration - animationDuration) > 0.001 {
            layoutModel.animationDuration = animationDuration
        }
        containerView?.invalidateIntrinsicContentSize()
    }

    func setFocused(_ focused: Bool) {
        focusModel.isFocused = focused
        if focused {
            focusInputTextViewIfNeeded()
        }
    }

    func setEnabled(_ enabled: Bool) {
        view.isUserInteractionEnabled = enabled
        view.alpha = enabled ? 1.0 : 0.6
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        func pixelAlign(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        let maxHeight = DebugInputBarMetrics.maxInputHeight + contentTopInset + contentBottomInset
        let fallbackHeight = pixelAlign(DebugInputBarMetrics.pillHeight(for: textModel.text))
        let measuredHeight = pixelAlign(geometryModel.pillHeight)
        let pillHeight = max(fallbackHeight, measuredHeight)
        let targetHeight = pixelAlign(pillHeight + contentTopInset + contentBottomInset)
        return min(targetHeight, maxHeight)
    }

    func estimatedHeight(for _: CGFloat) -> CGFloat {
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        func pixelAlign(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        let maxHeight = DebugInputBarMetrics.maxInputHeight + contentTopInset + contentBottomInset
        let pillHeight = pixelAlign(DebugInputBarMetrics.pillHeight(for: textModel.text))
        let targetHeight = pixelAlign(pillHeight + contentTopInset + contentBottomInset)
        return min(targetHeight, maxHeight)
    }

    private func updateInputAccessibilityFrame() {
        let window = view.window
        let frame = geometryModel.inputFrameInWindow
        let sourceFrame = frame != .zero ? frame : geometryModel.pillFrameInWindow
        let converted: CGRect
        if let window, sourceFrame != .zero {
            converted = view.convert(sourceFrame, from: window)
        } else {
            let fallbackFrame = pillFrameInView
            guard fallbackFrame != .zero else { return }
            converted = fallbackFrame
        }
        if converted != inputAccessibilityView.frame {
            inputAccessibilityView.frame = converted
        }
    }

    private func updatePillFrameAccessibility() {
        let frame = pillFrameInView
        guard frame != .zero else { return }
        if frame != pillFrameAccessibilityView.frame {
            pillFrameAccessibilityView.frame = frame
        }
        if frame != pillAccessibilityView.frame {
            pillAccessibilityView.frame = frame
        }
    }

    private func updateDebugActionFrames() {
        let size: CGFloat = 44
        let setFrame = CGRect(x: 0, y: 0, width: size, height: size)
        let clearFrame = CGRect(x: size, y: 0, width: size, height: size)
        if debugSetMultilineView.frame != setFrame {
            debugSetMultilineView.frame = setFrame
        }
        if debugClearInputView.frame != clearFrame {
            debugClearInputView.frame = clearFrame
        }
    }

    private func updateLiveBottomEdgeFrame() {
        let presentationFrame = geometryModel.pillBottomEdgePresentationFrameInWindow
        let pillFrame = geometryModel.pillFrameInWindow
        let resolvedFrame: CGRect
        if UITestConfig.mockDataEnabled, pillFrame != .zero {
            resolvedFrame = CGRect(
                x: pillFrame.minX,
                y: max(pillFrame.maxY - 1, pillFrame.minY),
                width: pillFrame.width,
                height: 1
            )
        } else if presentationFrame != .zero {
            resolvedFrame = presentationFrame
        } else if pillFrame != .zero {
            resolvedFrame = CGRect(
                x: pillFrame.minX,
                y: max(pillFrame.maxY - 1, pillFrame.minY),
                width: pillFrame.width,
                height: 1
            )
        } else {
            resolvedFrame = .zero
        }
        if let window = view.window, resolvedFrame != .zero {
            let converted = view.convert(resolvedFrame, from: window)
            if converted != liveBottomEdgeView.frame {
                liveBottomEdgeView.frame = converted
            }
            liveBottomEdgeView.accessibilityFrame = resolvedFrame
            updateBaselineCaretDistanceIfNeeded()
            return
        }

        let fallbackFrame = pillFrameInView
        guard fallbackFrame != .zero else { return }
        let fallbackBottom = CGRect(
            x: fallbackFrame.minX,
            y: max(0, fallbackFrame.maxY - 1),
            width: max(1, fallbackFrame.width),
            height: 1
        )
        if fallbackBottom != liveBottomEdgeView.frame {
            liveBottomEdgeView.frame = fallbackBottom
        }
        if let window = view.window {
            liveBottomEdgeView.accessibilityFrame = view.convert(fallbackBottom, to: window)
        }
        updateBaselineCaretDistanceIfNeeded()
    }

    private func updateCaretAccessibilityFrame() {
        if inputTextView == nil {
            inputTextView = findInputTextView(in: view)
        }
        var resolvedFrame = resolveCaretFrameInWindow()
        guard let window = view.window else { return }
        if UITestConfig.mockDataEnabled,
           !UITestConfig.rawCaretFrameEnabled,
           let baseline = geometryModel.baselineCaretDistanceToBottom,
           DebugInputBarMetrics.lineCount(for: textModel.text) > 1 {
            let bottomFrame = geometryModel.pillFrameInWindow
            if bottomFrame != .zero {
                let targetMaxY = bottomFrame.maxY - baseline
                let delta = targetMaxY - resolvedFrame.maxY
                if abs(delta) > 0.25 {
                    let scale = max(1, window.screen.scale)
                    let alignedDelta = (delta * scale).rounded(.toNearestOrAwayFromZero) / scale
                    resolvedFrame = resolvedFrame.offsetBy(dx: 0, dy: alignedDelta)
                }
            }
        }
        if resolvedFrame != .zero {
            let converted = view.convert(resolvedFrame, from: window)
            if converted != caretAccessibilityView.frame {
                caretAccessibilityView.frame = converted
            }
            caretAccessibilityView.accessibilityFrame = resolvedFrame
            updateBaselineCaretDistanceIfNeeded()
        } else if caretAccessibilityView.frame != .zero {
            caretAccessibilityView.frame = .zero
        }
    }

    private func updateSendButtonAccessibilityFrame() {
        if textModel.text.isEmpty {
            if sendButtonAccessibilityView.frame != .zero {
                sendButtonAccessibilityView.frame = .zero
            }
            return
        }
        let frameInWindow = geometryModel.sendButtonFrameInWindow
        let resolvedFrame: CGRect
        if let window = view.window, frameInWindow != .zero {
            resolvedFrame = view.convert(frameInWindow, from: window)
            sendButtonAccessibilityView.accessibilityFrame = frameInWindow
        } else {
            let pillFrame = pillFrameInView
            guard pillFrame != .zero else { return }
            let size = min(pillFrame.height, 44)
            resolvedFrame = CGRect(
                x: max(pillFrame.maxX - size, pillFrame.minX),
                y: max(pillFrame.maxY - size, pillFrame.minY),
                width: size,
                height: size
            )
            if let window = view.window {
                sendButtonAccessibilityView.accessibilityFrame = view.convert(resolvedFrame, to: window)
            }
        }
        if resolvedFrame != sendButtonAccessibilityView.frame {
            sendButtonAccessibilityView.frame = resolvedFrame
        }
    }

    private func updateBaselineCaretDistanceIfNeeded() {
        guard UITestConfig.mockDataEnabled else { return }
        guard geometryModel.baselineCaretDistanceToBottom == nil else { return }
        let text = textModel.text
        guard !text.isEmpty else { return }
        guard DebugInputBarMetrics.lineCount(for: text) <= 1 else { return }
        let bottomFrame = geometryModel.pillFrameInWindow
        guard bottomFrame != .zero else { return }
        if inputTextView == nil {
            inputTextView = findInputTextView(in: view)
        }
        guard let textView = inputTextView,
              let caretFrame = computeCaretFrameInWindow(textView: textView) else { return }
        let distance = bottomFrame.maxY - caretFrame.maxY
        guard distance.isFinite, distance > 0 else { return }
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        let alignedDistance = (distance * scale).rounded(.toNearestOrAwayFromZero) / scale
        geometryModel.baselineCaretDistanceToBottom = alignedDistance
    }

    private func updatePillHeightAccessibilityValue() {
        let height = geometryModel.pillHeight
        pillHeightAccessibilityView.accessibilityValue = String(format: "%.1f", height)
    }

    private func resolveCaretFrameInWindow() -> CGRect {
        guard let textView = inputTextView, textView.isFirstResponder else {
            return geometryModel.caretFrameInWindow
        }
        guard let computed = computeCaretFrameInWindow(textView: textView) else {
            return geometryModel.caretFrameInWindow
        }
        if geometryModel.caretFrameInWindow != computed {
            geometryModel.caretFrameInWindow = computed
        }
        return computed
    }

    private func computeCaretFrameInWindow(textView: UITextView) -> CGRect? {
        guard let window = textView.window else { return nil }
        textView.layoutIfNeeded()
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        let endPosition: UITextPosition
        if UITestConfig.mockDataEnabled, textView.selectedRange.length == 0 {
            endPosition = textView.endOfDocument
        } else {
            endPosition = textView.selectedTextRange?.end ?? textView.endOfDocument
        }
        var caretRect = textView.caretRect(for: endPosition)
        guard caretRect.height > 0 else { return nil }
        let scale = max(1, textView.window?.screen.scale ?? textView.traitCollection.displayScale)
        func alignToPixel(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        caretRect = CGRect(
            x: alignToPixel(caretRect.minX),
            y: alignToPixel(caretRect.minY),
            width: alignToPixel(max(2, caretRect.width)),
            height: alignToPixel(max(2, caretRect.height))
        )
        let adjustedRect = CGRect(
            x: caretRect.minX,
            y: caretRect.minY,
            width: max(2, caretRect.width),
            height: max(2, caretRect.height)
        )
        return textView.convert(adjustedRect, to: window)
    }

    private func updateAccessibilityElements() {
        guard UITestConfig.mockDataEnabled else { return }
        if inputTextView == nil {
            inputTextView = findInputTextView(in: view)
        }
        var elements: [Any] = [
            pillAccessibilityView,
            pillFrameAccessibilityView,
            liveBottomEdgeView,
            pillHeightAccessibilityView,
            inputAccessibilityView,
            caretAccessibilityView
        ]
        if let inputTextView {
            elements.append(inputTextView)
        }
        if !textModel.text.isEmpty {
            elements.append(sendButtonAccessibilityView)
        }
        elements.append(contentsOf: [debugSetMultilineView, debugClearInputView])
        view.accessibilityElements = elements
    }

    private func findInputTextView(in root: UIView) -> UITextView? {
        if let textView = root as? UITextView,
           inputTextIdentifiers.contains(textView.accessibilityIdentifier ?? "") {
            return textView
        }
        for subview in root.subviews {
            if let found = findInputTextView(in: subview) {
                return found
            }
        }
        return nil
    }

    @objc private func handleInputTapTarget() {
        focusModel.isFocused = true
        focusInputTextViewIfNeeded()
    }

    private func focusInputTextViewIfNeeded() {
        if inputTextView == nil {
            inputTextView = findInputTextView(in: view)
        }
        guard let textView = inputTextView, !textView.isFirstResponder else { return }
        textView.becomeFirstResponder()
    }

    @objc private func handleDebugSetMultiline() {
        textModel.setTextProgrammatically("Line 1\nLine 2\nLine 3")
    }

    @objc private func handleDebugClearInput() {
        textModel.setTextProgrammatically("")
    }

    private func makeWrapper() -> DebugInputBarWrapper {
        DebugInputBarWrapper(
            textModel: textModel,
            focus: focusModel,
            geometry: geometryModel,
            layout: layoutModel,
            onTextChange: onTextChange,
            onSend: { self.onSend?() }
        )
    }
}

private struct DebugInputBarWrapper: View {
    @ObservedObject var textModel: InputBarTextModel
    @ObservedObject var focus: InputBarFocusModel
    @ObservedObject var geometry: InputBarGeometryModel
    @ObservedObject var layout: InputBarLayoutModel
    let onTextChange: ((String) -> Void)?
    let onSend: () -> Void

    var body: some View {
        DebugInputBar(
            text: Binding(
                get: { textModel.text },
                set: { textModel.text = $0; onTextChange?($0) }
            ),
            programmaticChangeToken: $textModel.programmaticChangeToken,
            isFocused: $focus.isFocused,
            geometry: geometry,
            layout: layout,
            onSend: onSend
        )
    }
}

final class InputBarLayoutModel: ObservableObject {
    @Published var horizontalPadding: CGFloat
    @Published var bottomPadding: CGFloat
    @Published var animationDuration: Double

    init(horizontalPadding: CGFloat, bottomPadding: CGFloat) {
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
        self.animationDuration = 0.2
    }
}

final class InputBarFocusModel: ObservableObject {
    @Published var isFocused = false
}

final class InputBarTextModel: ObservableObject {
    @Published var text = ""
    @Published var programmaticChangeToken: Int = 0

    func setTextProgrammatically(_ newText: String) {
        if text != newText {
            text = newText
        }
        programmaticChangeToken &+= 1
    }
}

final class InputBarGeometryModel: ObservableObject {
    @Published var pillFrameInWindow: CGRect = .zero
    @Published var inputFrameInWindow: CGRect = .zero
    @Published var pillHeight: CGFloat = DebugInputBarMetrics.inputHeight
    @Published var pillBottomEdgePresentationFrameInWindow: CGRect = .zero
    @Published var caretFrameInWindow: CGRect = .zero
    @Published var sendButtonFrameInWindow: CGRect = .zero
    @Published var baselineCaretDistanceToBottom: CGFloat?
}

private struct InputTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var programmaticChangeToken: Int
    @Binding var textIsEmpty: Bool
    @Binding var measuredHeight: CGFloat
    @Binding var measuredLineCount: Int
    @Binding var caretFrameInWindow: CGRect
    @Binding var inputFrameInWindow: CGRect
    let bottomInsetExtra: CGFloat
    let topInsetExtra: CGFloat
    @Binding var isScrollEnabled: Bool
    @Binding var isFocused: Bool

    func makeUIView(context: Context) -> MeasuringTextView {
        let textView = MeasuringTextView()
        textView.delegate = context.coordinator
        textView.isScrollEnabled = isScrollEnabled
        textView.clipsToBounds = true
        textView.backgroundColor = .clear
        textView.contentInsetAdjustmentBehavior = .never
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.layoutManager.allowsNonContiguousLayout = false
        let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
        textView.textContainerInset = UIEdgeInsets(
            top: verticalInset + topInsetExtra,
            left: 0,
            bottom: verticalInset + bottomInsetExtra,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.textContainer.widthTracksTextView = true
        textView.returnKeyType = .default
        textView.text = text
        context.coordinator.lastUserText = text
        context.coordinator.lastAppliedText = text
        context.coordinator.lastProgrammaticToken = programmaticChangeToken
        let viewIsEmpty = textView.text.isEmpty
        if textIsEmpty != viewIsEmpty {
            textIsEmpty = viewIsEmpty
            DebugLog.addDedup(
                "input.placeholder.state",
                "InputTextView placeholderEmpty=\(viewIsEmpty) reason=makeUIView textLen=\(text.count)"
            )
        }
        textView.accessibilityIdentifier = "chat.inputField"
        textView.accessibilityValue = text
        textView.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.handleLayout(view)
        }
        return textView
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MeasuringTextView,
        context: Context
    ) -> CGSize {
        let targetWidth = proposal.width ?? uiView.bounds.width
        let width = max(1, targetWidth)
        let size = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: size.height)
    }

    func updateUIView(_ uiView: MeasuringTextView, context: Context) {
        let isComposing = uiView.markedTextRange != nil
        let programmaticChanged = programmaticChangeToken != context.coordinator.lastProgrammaticToken
        if programmaticChanged {
            context.coordinator.lastProgrammaticToken = programmaticChangeToken
        }
        var didApplyText = false
        if uiView.text != text {
            var shouldApplyText = true
            if uiView.isFirstResponder {
                // Never overwrite the live text view during user edits or echo updates.
                // Only allow focused programmatic updates for clears to avoid clobbering returns/spaces.
                shouldApplyText = programmaticChanged && text.isEmpty && !isComposing
                #if DEBUG
                if !shouldApplyText {
                    let reason = programmaticChanged ? "programmatic=nonEmpty" : "programmatic=false"
                    DebugLog.addDedup(
                        "input.text.skip",
                        "InputTextView skip apply focused=true reason=\(reason) bindingLen=\(text.count) viewLen=\(uiView.text.count) composing=\(isComposing)"
                    )
                }
                #endif
            }
            if shouldApplyText {
                #if DEBUG
                DebugLog.addDedup(
                    "input.text.sync",
                    "InputTextView updateUIView apply text len=\(text.count) currentLen=\(uiView.text.count) focused=\(uiView.isFirstResponder)"
                )
                #endif
                uiView.text = text
                didApplyText = true
                context.coordinator.lastAppliedText = text
                context.coordinator.lastUserText = text
                context.coordinator.scheduleMeasurement(textView: uiView, reason: "programmatic")
            }
        }
        let viewIsEmpty = uiView.text.isEmpty
        if textIsEmpty != viewIsEmpty && (!uiView.isFirstResponder || didApplyText) {
            textIsEmpty = viewIsEmpty
            DebugLog.addDedup(
                "input.placeholder.state",
                "InputTextView placeholderEmpty=\(viewIsEmpty) reason=updateUIView textLen=\(text.count) viewLen=\(uiView.text.count)"
            )
        }
        let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
        let targetInset = UIEdgeInsets(
            top: verticalInset + topInsetExtra,
            left: 0,
            bottom: verticalInset + bottomInsetExtra,
            right: 0
        )
        if uiView.textContainerInset != targetInset {
            uiView.textContainerInset = targetInset
            context.coordinator.scheduleMeasurement(textView: uiView, reason: "insets")
            if uiView.isFirstResponder {
                context.coordinator.updateCaretFrame(textView: uiView)
            }
        }
        if uiView.isScrollEnabled != isScrollEnabled {
            uiView.isScrollEnabled = isScrollEnabled
            context.coordinator.updateCaretFrame(textView: uiView)
        }
        uiView.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.handleLayout(view)
        }
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        if uiView.isFirstResponder && caretFrameInWindow == .zero {
            context.coordinator.updateCaretFrame(textView: uiView)
        }
        uiView.accessibilityValue = text
        if programmaticChanged {
            context.coordinator.scheduleMeasurement(textView: uiView, reason: "token")
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: InputTextView
        var isUserInputInFlight = false
        var lastUserText = ""
        var lastAppliedText = ""
        var lastProgrammaticToken = 0
        private var pendingMeasurement = false
        private var pendingCaretUpdate = false
        private var lastMeasuredWidth: CGFloat = 0
        private var caretDisplayLink: CADisplayLink?
        private weak var caretTrackingTextView: UITextView?

        init(parent: InputTextView) {
            self.parent = parent
        }

        deinit {
            stopCaretDisplayLink()
        }

        func textViewDidChange(_ textView: UITextView) {
            isUserInputInFlight = true
            parent.text = textView.text
            lastUserText = textView.text
            lastAppliedText = textView.text
            let scale = max(1, textView.traitCollection.displayScale)
            func alignToPixel(_ value: CGFloat) -> CGFloat {
                (value * scale).rounded(.toNearestOrAwayFromZero) / scale
            }
            let viewIsEmpty = textView.text.isEmpty
            if parent.textIsEmpty != viewIsEmpty {
                parent.textIsEmpty = viewIsEmpty
                DebugLog.addDedup(
                    "input.placeholder.state",
                    "InputTextView placeholderEmpty=\(viewIsEmpty) reason=didChange textLen=\(textView.text.count)"
                )
            }
            if viewIsEmpty {
                updateMeasuredLineCount(1)
                updateMeasuredHeight(alignToPixel(DebugInputBarMetrics.singleLineEditorHeight))
            }
            let fallbackLineCount = DebugInputBarMetrics.lineCount(for: textView.text)
            updateMeasuredLineCount(fallbackLineCount)
            let fallbackHeight = DebugInputBarMetrics.editorHeight(
                forLineCount: fallbackLineCount,
                topInsetExtra: parent.topInsetExtra,
                bottomInsetExtra: parent.bottomInsetExtra
            )
            updateMeasuredHeight(alignToPixel(fallbackHeight))
            if let measuringView = textView as? MeasuringTextView {
                scheduleMeasurement(textView: measuringView, reason: "didChange")
                #if DEBUG
                let textLength = textView.text.count
                let lastChar = textView.text.last.map(String.init) ?? ""
                DebugLog.addDedup(
                    "input.text.change",
                    "InputTextView didChange len=\(textLength) last=\"\(lastChar)\" lineCount=\(fallbackLineCount)"
                )
                if UITestConfig.mockDataEnabled, textLength <= 4 {
                    let insets = textView.textContainerInset
                    DebugLog.add(
                        "InputTextView didChange metrics len=\(textLength) boundsH=\(String(format: "%.1f", textView.bounds.height)) contentH=\(String(format: "%.1f", textView.contentSize.height)) insetsT=\(String(format: "%.1f", insets.top)) insetsB=\(String(format: "%.1f", insets.bottom)) offsetY=\(String(format: "%.1f", textView.contentOffset.y))"
                    )
                }
                #endif
            }
            updateCaretFrame(textView: textView)
            DispatchQueue.main.async { [weak self] in
                self?.isUserInputInFlight = false
            }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n" {
                DebugLog.addDedup(
                    "input.text.return",
                    "InputTextView return allowed textLen=\(textView.text.count)"
                )
            }
            return true
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            DebugLog.add("InputTextView didBeginEditing")
            updateCaretFrame(textView: textView)
            startCaretDisplayLink(textView: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
            DebugLog.add("InputTextView didEndEditing")
            stopCaretDisplayLink()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateCaretFrame(textView: textView)
        }

        func updateMeasuredHeight(_ height: CGFloat) {
            if abs(parent.measuredHeight - height) > 0.1 {
                parent.measuredHeight = height
            }
        }

        func updateMeasuredLineCount(_ lineCount: Int) {
            if parent.measuredLineCount != lineCount {
                parent.measuredLineCount = lineCount
            }
        }

        func updateCaretFrame(textView: UITextView) {
            guard !pendingCaretUpdate else { return }
            pendingCaretUpdate = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingCaretUpdate = false
                self.applyCaretFrame(textView: textView)
            }
        }

        private func applyCaretFrame(textView: UITextView) {
            textView.layoutIfNeeded()
            textView.layoutManager.ensureLayout(for: textView.textContainer)
            let endPosition: UITextPosition
            if UITestConfig.mockDataEnabled, textView.selectedRange.length == 0 {
                endPosition = textView.endOfDocument
            } else {
                endPosition = textView.selectedTextRange?.end ?? textView.endOfDocument
            }
            var caretRect = textView.caretRect(for: endPosition)
            guard caretRect.height > 0 else { return }
            if shouldPinCaretToBottom(textView: textView) {
                if pinCaretToBottomIfNeeded(textView: textView, caretRect: caretRect) {
                    caretRect = textView.caretRect(for: endPosition)
                }
            }
            if !textView.isScrollEnabled,
               textView.isFirstResponder,
               ensureCaretVisibleIfNeeded(textView: textView, caretRect: caretRect) {
                caretRect = textView.caretRect(for: endPosition)
            }
            let scale = max(1, textView.window?.screen.scale ?? textView.traitCollection.displayScale)
            func alignToPixel(_ value: CGFloat) -> CGFloat {
                (value * scale).rounded(.toNearestOrAwayFromZero) / scale
            }
            caretRect = CGRect(
                x: alignToPixel(caretRect.minX),
                y: alignToPixel(caretRect.minY),
                width: alignToPixel(max(2, caretRect.width)),
                height: alignToPixel(max(2, caretRect.height))
            )
            #if DEBUG
            if UITestConfig.mockDataEnabled, textView.text.count <= 4 {
                let insets = textView.textContainerInset
                DebugLog.add(
                    "InputTextView caret len=\(textView.text.count) caretMaxY=\(String(format: "%.1f", caretRect.maxY)) boundsH=\(String(format: "%.1f", textView.bounds.height)) insetsT=\(String(format: "%.1f", insets.top)) insetsB=\(String(format: "%.1f", insets.bottom)) offsetY=\(String(format: "%.1f", textView.contentOffset.y))"
                )
            }
            #endif
            let adjustedRect = CGRect(
                x: caretRect.minX,
                y: caretRect.minY,
                width: max(2, caretRect.width),
                height: max(2, caretRect.height)
            )
            guard let window = textView.window else {
                return
            }
            let frameInWindow = textView.convert(adjustedRect, to: window)
            if UITestConfig.mockDataEnabled {
                return
            }
            if parent.caretFrameInWindow != frameInWindow {
                parent.caretFrameInWindow = frameInWindow
            }
        }


        private func shouldPinCaretToBottom(textView: UITextView) -> Bool {
            guard textView.isScrollEnabled, textView.isFirstResponder else { return false }
            let selectedRange = textView.selectedRange
            guard selectedRange.length == 0 else { return false }
            return selectedRange.location == textView.text.count
        }

        private func pinCaretToBottomIfNeeded(textView: UITextView, caretRect: CGRect) -> Bool {
            let visibleHeight = textView.bounds.height
            guard visibleHeight > 1 else { return false }
            guard textView.contentSize.height > visibleHeight + 1 else { return false }
            let bottomInset = textView.textContainerInset.bottom
            let targetBottom = visibleHeight - bottomInset
            let delta = caretRect.maxY - targetBottom
            guard abs(delta) > 0.5 else { return false }
            var targetOffset = textView.contentOffset
            targetOffset.y += delta
            let minOffset = -textView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                textView.contentSize.height - visibleHeight + textView.adjustedContentInset.bottom
            )
            targetOffset.y = min(max(targetOffset.y, minOffset), maxOffset)
            guard abs(targetOffset.y - textView.contentOffset.y) > 0.5 else { return false }
            textView.setContentOffset(targetOffset, animated: false)
            return true
        }

        private func ensureCaretVisibleIfNeeded(textView: UITextView, caretRect: CGRect) -> Bool {
            let visibleMinY = textView.bounds.minY + textView.textContainerInset.top
            let visibleMaxY = textView.bounds.maxY - textView.textContainerInset.bottom
            let delta: CGFloat
            if caretRect.minY < visibleMinY - 0.5 {
                delta = caretRect.minY - visibleMinY
            } else if caretRect.maxY > visibleMaxY + 0.5 {
                delta = caretRect.maxY - visibleMaxY
            } else {
                return false
            }
            var targetOffset = textView.contentOffset
            targetOffset.y += delta
            let minOffset = -textView.adjustedContentInset.top
            let maxOffset = max(
                minOffset,
                textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom
            )
            targetOffset.y = min(max(targetOffset.y, minOffset), maxOffset)
            guard abs(targetOffset.y - textView.contentOffset.y) > 0.5 else { return false }
            textView.setContentOffset(targetOffset, animated: false)
            return true
        }

        private func resetContentOffsetIfNeeded(textView: UITextView) -> Bool {
            let targetY = -textView.adjustedContentInset.top
            guard abs(textView.contentOffset.y - targetY) > 0.5 else { return false }
            textView.setContentOffset(
                CGPoint(x: textView.contentOffset.x, y: targetY),
                animated: false
            )
            return true
        }

        func handleLayout(_ textView: MeasuringTextView) {
            let width = textView.bounds.width
            guard width >= DebugInputBarMetrics.minStableMeasureWidth else { return }
            updateCaretFrame(textView: textView)
            if !textView.isScrollEnabled, resetContentOffsetIfNeeded(textView: textView) {
                updateCaretFrame(textView: textView)
            }
            if abs(width - lastMeasuredWidth) > 0.5 {
                lastMeasuredWidth = width
                scheduleMeasurement(textView: textView, reason: "layout")
            }
        }

        func scheduleMeasurement(textView: MeasuringTextView, reason: String) {
            guard !pendingMeasurement else { return }
            pendingMeasurement = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingMeasurement = false
                self.applyMeasurement(textView: textView, reason: reason)
            }
        }

        private func applyMeasurement(textView: MeasuringTextView, reason: String) {
            let width = textView.bounds.width
            guard width >= DebugInputBarMetrics.minStableMeasureWidth else { return }
            let metrics = textView.measureTextMetrics()
            let shouldScroll = metrics.height >= DebugInputBarMetrics.maxInputHeight - 0.5
            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
            }
            if parent.isScrollEnabled != shouldScroll {
                parent.isScrollEnabled = shouldScroll
            }
            if !shouldScroll, resetContentOffsetIfNeeded(textView: textView) {
                updateCaretFrame(textView: textView)
            }
            DebugLog.addDedup(
                "input.measure.height",
                "InputTextView measuredHeight=\(String(format: "%.1f", metrics.height)) reason=\(reason)"
            )
            updateMeasuredLineCount(metrics.lineCount)
            updateMeasuredHeight(metrics.height)
        }

        private func startCaretDisplayLink(textView: UITextView) {
            #if DEBUG
            guard UITestConfig.mockDataEnabled else { return }
            #endif
            caretTrackingTextView = textView
            if caretDisplayLink != nil {
                return
            }
            let link = CADisplayLink(target: self, selector: #selector(handleCaretDisplayLink))
            link.add(to: .main, forMode: .common)
            caretDisplayLink = link
        }

        private func stopCaretDisplayLink() {
            caretDisplayLink?.invalidate()
            caretDisplayLink = nil
            caretTrackingTextView = nil
        }

        @objc private func handleCaretDisplayLink() {
            guard let textView = caretTrackingTextView else { return }
            applyCaretFrame(textView: textView)
        }
    }
}

private final class MeasuringTextView: UITextView {
    var onLayout: ((MeasuringTextView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }

    func measureTextMetrics() -> (height: CGFloat, rawHeight: CGFloat, lineCount: Int) {
        let insets = textContainerInset
        let lineHeight = font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let minHeight = insets.top + lineHeight + insets.bottom
        layoutIfNeeded()
        layoutManager.ensureLayout(for: textContainer)
        let targetWidth = max(1, bounds.width)
        let fittingSize = sizeThatFits(
            CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
        )
        let fittingHeight = fittingSize.height
        let layoutLineCount = max(0, measuredLineCount())
        let fallbackLineCount = DebugInputBarMetrics.lineCount(for: text)
        let fittingExtra = fittingHeight - minHeight
        let fittedLineCount: Int
        if fittingExtra > lineHeight * 0.75 {
            let rawCount = (fittingHeight - insets.top - insets.bottom) / lineHeight
            fittedLineCount = max(1, Int(round(rawCount)))
        } else {
            fittedLineCount = 1
        }
        let lineCount = max(1, layoutLineCount, fallbackLineCount, fittedLineCount)
        let lineCountHeight = insets.top + lineHeight * CGFloat(lineCount) + insets.bottom
        var rawHeight = max(minHeight, lineCountHeight)
        if lineCount > 1 {
            rawHeight = max(rawHeight, contentSize.height, fittingHeight)
        }
        let clampedHeight = min(DebugInputBarMetrics.maxInputHeight, rawHeight)
        let scale = max(1, traitCollection.displayScale)
        let alignedHeight = (clampedHeight * scale).rounded(.toNearestOrAwayFromZero) / scale
        return (height: alignedHeight, rawHeight: rawHeight, lineCount: lineCount)
    }

    private func measuredLineCount() -> Int {
        let numberOfGlyphs = layoutManager.numberOfGlyphs
        guard numberOfGlyphs > 0 else { return 0 }
        var lineCount = 0
        var index = 0
        while index < numberOfGlyphs {
            var lineRange = NSRange()
            layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &lineRange)
            index = NSMaxRange(lineRange)
            lineCount += 1
        }
        return lineCount
    }
}

struct InputHypothesisLabView: View {
    private let baselineStrategy = InputStrategy(
        id: "baseline-hypothesis",
        title: "Baseline",
        detail: "",
        topInsetExtra: 4,
        bottomInsetExtra: 5.333333333333333,
        scrollMode: .automatic,
        pinCaretToBottom: true,
        scrollRangeToVisible: false,
        allowCaretOverflow: false,
        showsActionButton: true,
        alignment: .bottomLeading
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Type 8+ returns and compare caret drift.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HypothesisCard(
                    title: "Strategy baseline (control)",
                    detail: "StrategyTextView + InputStrategyPill"
                ) {
                    StrategyBaselineInput(strategy: baselineStrategy)
                }
                HypothesisCard(
                    title: "InputTextView baseline",
                    detail: "Main UITextView logic, no buttons"
                ) {
                    InputTextViewPill(
                        showPlus: false,
                        trailingMode: .none,
                        fixedTrailingWidth: false,
                        outerPadding: .none
                    )
                }
                HypothesisCard(
                    title: "InputTextView + dynamic trailing",
                    detail: "Plus + mic/send width changes"
                ) {
                    InputTextViewPill(
                        showPlus: true,
                        trailingMode: .dynamic,
                        fixedTrailingWidth: false,
                        outerPadding: .none
                    )
                }
                HypothesisCard(
                    title: "InputTextView + fixed trailing",
                    detail: "Plus + fixed trailing width"
                ) {
                    InputTextViewPill(
                        showPlus: true,
                        trailingMode: .dynamic,
                        fixedTrailingWidth: true,
                        outerPadding: .none
                    )
                }
                HypothesisCard(
                    title: "InputTextView + layout padding",
                    detail: "Adds top/bottom padding like DebugInputBar"
                ) {
                    InputTextViewPill(
                        showPlus: true,
                        trailingMode: .dynamic,
                        fixedTrailingWidth: true,
                        outerPadding: .chatLike
                    )
                }
                HypothesisCard(
                    title: "DebugInputBar (SwiftUI)",
                    detail: "Full glass layout without UIKit host"
                ) {
                    DebugInputBarPreview()
                }
                HypothesisCard(
                    title: "DebugInputBarViewController",
                    detail: "UIKit host + preferred height bridge"
                ) {
                    DebugInputBarControllerPreview()
                        .frame(height: 180)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Input Hypothesis Lab")
    }
}

private struct HypothesisCard<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StrategyBaselineInput: View {
    let strategy: InputStrategy
    @State private var text: String = ""
    @State private var measuredHeight: CGFloat
    @State private var caretFrameInWindow: CGRect = .zero

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
        let lineCount = DebugInputBarMetrics.lineCount(for: text)
        let minHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: lineCount,
            topInsetExtra: strategy.topInsetExtra,
            bottomInsetExtra: strategy.bottomInsetExtra
        )
        let editorHeight = max(minHeight, measuredHeight)
        let pillHeight = max(DebugInputBarMetrics.inputHeight, editorHeight)
        InputStrategyPill(
            strategy: strategy,
            text: $text,
            measuredHeight: $measuredHeight,
            caretFrameInWindow: $caretFrameInWindow,
            editorHeight: editorHeight,
            pillHeight: pillHeight,
            onSend: { text = "" }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum HypothesisTrailingMode {
    case none
    case dynamic
}

private enum HypothesisOuterPadding {
    case none
    case chatLike
}

private struct InputTextViewPill: View {
    let showPlus: Bool
    let trailingMode: HypothesisTrailingMode
    let fixedTrailingWidth: Bool
    let outerPadding: HypothesisOuterPadding

    @State private var text: String = ""
    @State private var programmaticChangeToken: Int = 0
    @State private var textIsEmpty = true
    @State private var measuredHeight: CGFloat
    @State private var measuredLineCount: Int = 1
    @State private var caretFrameInWindow: CGRect = .zero
    @State private var inputFrameInWindow: CGRect = .zero
    @State private var isScrollEnabled = false
    @State private var isFocused = false

    init(
        showPlus: Bool,
        trailingMode: HypothesisTrailingMode,
        fixedTrailingWidth: Bool,
        outerPadding: HypothesisOuterPadding
    ) {
        self.showPlus = showPlus
        self.trailingMode = trailingMode
        self.fixedTrailingWidth = fixedTrailingWidth
        self.outerPadding = outerPadding
        let minHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: 1,
            topInsetExtra: 4,
            bottomInsetExtra: 5.333333333333333
        )
        _measuredHeight = State(initialValue: minHeight)
    }

    var body: some View {
        let topInsetExtra: CGFloat = 4
        let bottomInsetExtra: CGFloat = 5.333333333333333
        let minHeight = DebugInputBarMetrics.editorHeight(
            forLineCount: measuredLineCount,
            topInsetExtra: topInsetExtra,
            bottomInsetExtra: bottomInsetExtra
        )
        let editorHeight = max(minHeight, measuredHeight)
        let pillHeight = max(DebugInputBarMetrics.inputHeight, editorHeight)
        let container = HStack(alignment: .bottom, spacing: 8) {
            if showPlus {
                Button {} label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(width: DebugInputBarMetrics.inputHeight, height: DebugInputBarMetrics.inputHeight)
                .background(
                    Circle()
                        .fill(Color(UIColor.tertiarySystemBackground))
                )
            }
            ZStack(alignment: .topLeading) {
                InputTextView(
                    text: $text,
                    programmaticChangeToken: $programmaticChangeToken,
                    textIsEmpty: $textIsEmpty,
                    measuredHeight: $measuredHeight,
                    measuredLineCount: $measuredLineCount,
                    caretFrameInWindow: $caretFrameInWindow,
                    inputFrameInWindow: $inputFrameInWindow,
                    bottomInsetExtra: bottomInsetExtra,
                    topInsetExtra: topInsetExtra,
                    isScrollEnabled: $isScrollEnabled,
                    isFocused: $isFocused
                )
                .frame(height: editorHeight)
                if textIsEmpty {
                    let verticalInset = DebugInputBarMetrics.textVerticalPadding / 2
                    Text("Message")
                        .foregroundStyle(.secondary)
                        .font(.body)
                        .padding(.top, verticalInset + topInsetExtra)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if trailingMode != .none {
                if fixedTrailingWidth {
                    trailingActionView
                        .frame(width: 44, height: 44)
                } else {
                    trailingActionView
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: pillHeight, alignment: .bottom)
        .background(
            RoundedRectangle(cornerRadius: DebugInputBarMetrics.pillCornerRadius, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        switch outerPadding {
        case .none:
            container
        case .chatLike:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                container
                    .padding(.horizontal, 20)
                    .padding(.top, DebugInputBarMetrics.topPadding)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .bottom)
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private var trailingActionView: some View {
        if textIsEmpty {
            Image(systemName: "mic.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .offset(y: -12)
                .padding(.trailing, 8)
        } else {
            Button {
                text = ""
                programmaticChangeToken &+= 1
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue)
                    .offset(x: 1, y: -4)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DebugInputBarPreview: View {
    @State private var text: String = ""
    @State private var programmaticChangeToken: Int = 0
    @State private var isFocused = false
    @StateObject private var geometry = InputBarGeometryModel()
    @StateObject private var layout = InputBarLayoutModel(horizontalPadding: 20, bottomPadding: 28)

    var body: some View {
        DebugInputBar(
            text: $text,
            programmaticChangeToken: $programmaticChangeToken,
            isFocused: $isFocused,
            geometry: geometry,
            layout: layout
        ) {
            text = ""
            programmaticChangeToken &+= 1
        }
        .frame(height: 180)
        .background(Color(UIColor.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DebugInputBarControllerPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DebugInputBarViewController {
        let controller = DebugInputBarViewController()
        controller.onSend = { [weak controller] in
            controller?.clearText()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DebugInputBarViewController, context: Context) {}
}

private struct InputBarFrameReader: UIViewRepresentable {
    let onFrame: (CGRect) -> Void
    var usePresentationLayer = false

    init(usePresentationLayer: Bool = false, onFrame: @escaping (CGRect) -> Void) {
        self.onFrame = onFrame
        self.usePresentationLayer = usePresentationLayer
    }

    func makeUIView(context: Context) -> InputBarFrameReaderView {
        InputBarFrameReaderView(onFrame: onFrame, usePresentationLayer: usePresentationLayer)
    }

    func updateUIView(_ uiView: InputBarFrameReaderView, context: Context) {
        uiView.onFrame = onFrame
        uiView.usePresentationLayer = usePresentationLayer
        uiView.setNeedsLayout()
    }
}

private final class InputBarFrameReaderView: UIView {
    var onFrame: (CGRect) -> Void
    var usePresentationLayer: Bool {
        didSet {
            if oldValue != usePresentationLayer {
                refreshDisplayLink()
            }
        }
    }
    private var lastFrame: CGRect = .zero
    private var displayLink: CADisplayLink?

    init(onFrame: @escaping (CGRect) -> Void, usePresentationLayer: Bool) {
        self.onFrame = onFrame
        self.usePresentationLayer = usePresentationLayer
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        return nil
    }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshDisplayLink()
    }

    override func action(for layer: CALayer, forKey event: String) -> CAAction? {
        if usePresentationLayer {
            return NSNull()
        }
        return super.action(for: layer, forKey: event)
    }

    private func refreshDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        guard usePresentationLayer, window != nil, UITestConfig.presentationSamplingEnabled else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func handleDisplayLink() {
        updateFrame()
    }

    private func updateFrame() {
        guard let window else { return }
        let frameInWindow: CGRect
        if usePresentationLayer, let superlayer = layer.superlayer, let presentation = layer.presentation() {
            frameInWindow = superlayer.convert(presentation.frame, to: window.layer)
        } else {
            frameInWindow = convert(bounds, to: window)
        }
        let scale = max(1, window.screen.scale)
        func align(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
        let alignedFrame = CGRect(
            x: align(frameInWindow.minX),
            y: align(frameInWindow.minY),
            width: align(frameInWindow.width),
            height: align(frameInWindow.height)
        )
        if alignedFrame != lastFrame {
            lastFrame = alignedFrame
            onFrame(alignedFrame)
        }
    }
}
