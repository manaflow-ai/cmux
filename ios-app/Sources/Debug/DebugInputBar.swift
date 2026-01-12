import Combine
import SwiftUI
import UIKit

enum DebugInputBarMetrics {
    static let inputHeight: CGFloat = 42
    static let topPadding: CGFloat = 8
}

/// Shared floating glass input bar for all debug approaches
struct DebugInputBar: View {
    @Binding var text: String
    let onSend: () -> Void
    @Binding var isFocused: Bool
    @ObservedObject var layout: InputBarLayoutModel
    @ObservedObject var geometry: InputBarGeometryModel

    @FocusState private var textFieldFocused: Bool

    init(
        text: Binding<String>,
        isFocused: Binding<Bool> = .constant(false),
        geometry: InputBarGeometryModel,
        layout: InputBarLayoutModel,
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self._isFocused = isFocused
        self.geometry = geometry
        self.layout = layout
        self.onSend = onSend
    }

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
                .frame(width: DebugInputBarMetrics.inputHeight, height: DebugInputBarMetrics.inputHeight)
                .glassEffect(.regular.interactive(), in: .circle)

                // Text field with glass capsule
                HStack(spacing: 8) {
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($textFieldFocused)
                        .accessibilityIdentifier("chat.inputField")

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
                .frame(height: DebugInputBarMetrics.inputHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("chat.inputPill")
                .contentShape(Rectangle())
                .onTapGesture {
                    textFieldFocused = true
                }
                .overlay(
                    InputBarFrameReader { frame in
                        geometry.pillFrameInWindow = frame
                    }
                )
            }
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.top, DebugInputBarMetrics.topPadding)
            .padding(.bottom, layout.bottomPadding)
        }
        .animation(.easeInOut(duration: 0.15), value: text.isEmpty)
        .animation(.easeInOut(duration: layout.animationDuration), value: layout.horizontalPadding)
        .animation(.easeInOut(duration: layout.animationDuration), value: layout.bottomPadding)
        .onAppear {
            textFieldFocused = isFocused
        }
        .onChange(of: textFieldFocused) { _, newValue in
            isFocused = newValue
        }
        .onChange(of: isFocused) { _, newValue in
            textFieldFocused = newValue
        }
    }
}

/// UIKit wrapper for the glass input bar
final class DebugInputBarViewController: UIViewController {
    var text: String = ""
    var onSend: (() -> Void)?
    var onTextChange: ((String) -> Void)?
    var onLayoutChange: (() -> Void)?
    var contentTopInset: CGFloat { DebugInputBarMetrics.topPadding }
    var contentBottomInset: CGFloat { layoutModel.bottomPadding }
    var pillMeasuredFrame: CGRect { geometryModel.pillFrameInWindow }
    var pillFrameInView: CGRect {
        let viewHeight = view.bounds.height
        guard viewHeight > 0 else { return .zero }
        let expectedHeight = contentTopInset + contentBottomInset + DebugInputBarMetrics.inputHeight
        let extra = max(0, viewHeight - expectedHeight)
        let offset = extra / 2
        let topLimit = contentTopInset + offset
        let bottomLimit = max(topLimit, viewHeight - contentBottomInset - offset)
        let availableHeight = max(0, bottomLimit - topLimit)
        let height = min(DebugInputBarMetrics.inputHeight, availableHeight)
        return CGRect(x: 0, y: topLimit, width: view.bounds.width, height: height)
    }
    var pillHeight: CGFloat { max(0, pillFrameInView.height) }

    private var hostingController: UIHostingController<DebugInputBarWrapper>!
    private let layoutModel = InputBarLayoutModel(horizontalPadding: 20, bottomPadding: 28)
    private var lastReportedHeight: CGFloat = 0
    private let focusModel = InputBarFocusModel()
    private let geometryModel = InputBarGeometryModel()
    private var geometryCancellable: AnyCancellable?
    private let pillAccessibilityView = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        hostingController = UIHostingController(rootView: makeWrapper())
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.safeAreaRegions = []

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        pillAccessibilityView.isAccessibilityElement = true
        pillAccessibilityView.accessibilityIdentifier = "chat.inputPill"
        pillAccessibilityView.backgroundColor = .clear
        pillAccessibilityView.isUserInteractionEnabled = false
        view.addSubview(pillAccessibilityView)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        geometryCancellable = geometryModel.$pillFrameInWindow
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.onLayoutChange?()
                self?.updatePillAccessibilityFrame()
            }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = view.bounds.height
        if abs(height - lastReportedHeight) > 0.5 {
            lastReportedHeight = height
            onLayoutChange?()
        }
        updatePillAccessibilityFrame()
    }

    func updateText(_ newText: String) {
        text = newText
        hostingController.rootView = makeWrapper()
    }

    func clearText() {
        updateText("")
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
    }

    func setFocused(_ focused: Bool) {
        focusModel.isFocused = focused
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let targetWidth = max(1, width)
        if #available(iOS 16.0, *) {
            let size = hostingController.sizeThatFits(
                in: CGSize(width: targetWidth, height: .greatestFiniteMagnitude)
            )
            if size.height > 0 {
                return size.height
            }
        }
        let targetSize = CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height)
        let size = hostingController.view.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return size.height
    }

    private func updatePillAccessibilityFrame() {
        let frame = pillFrameInView
        if frame != pillAccessibilityView.frame {
            pillAccessibilityView.frame = frame
        }
    }

    private func makeWrapper() -> DebugInputBarWrapper {
        DebugInputBarWrapper(
            text: Binding(get: { self.text }, set: { self.text = $0; self.onTextChange?($0) }),
            focus: focusModel,
            geometry: geometryModel,
            layout: layoutModel,
            onSend: { self.onSend?() }
        )
    }
}

private struct DebugInputBarWrapper: View {
    @Binding var text: String
    @ObservedObject var focus: InputBarFocusModel
    @ObservedObject var geometry: InputBarGeometryModel
    @ObservedObject var layout: InputBarLayoutModel
    let onSend: () -> Void

    var body: some View {
        DebugInputBar(
            text: $text,
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

final class InputBarGeometryModel: ObservableObject {
    @Published var pillFrameInWindow: CGRect = .zero
}

private struct InputBarFrameReader: UIViewRepresentable {
    let onFrame: (CGRect) -> Void

    func makeUIView(context: Context) -> InputBarFrameReaderView {
        InputBarFrameReaderView(onFrame: onFrame)
    }

    func updateUIView(_ uiView: InputBarFrameReaderView, context: Context) {
        uiView.onFrame = onFrame
        uiView.setNeedsLayout()
    }
}

private final class InputBarFrameReaderView: UIView {
    var onFrame: (CGRect) -> Void
    private var lastFrame: CGRect = .zero

    init(onFrame: @escaping (CGRect) -> Void) {
        self.onFrame = onFrame
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window else { return }
        let frameInWindow = convert(bounds, to: window)
        if frameInWindow != lastFrame {
            lastFrame = frameInWindow
            onFrame(frameInWindow)
        }
    }
}
