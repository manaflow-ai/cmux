import SwiftUI
import UIKit

private func log(_ message: String) {
    NSLog("[CMUX_CHAT_FIX1] MAIN %@", message)
}

struct ChatFix1MainView: View {
    let conversation: Conversation
    private let topShimHeight: CGFloat

    init(conversation: Conversation) {
        self.conversation = conversation
        self.topShimHeight = 1 / UIScreen.main.scale
    }

    var body: some View {
        ZStack(alignment: .top) {
            Fix1MainViewController_Wrapper(conversation: conversation)
                .ignoresSafeArea()
            Color.clear
                .frame(height: topShimHeight)
                .accessibilityHidden(true)
        }
        .background(Color.clear)
        .ignoresSafeArea()
    }
}

private struct Fix1MainViewController_Wrapper: UIViewControllerRepresentable {
    let conversation: Conversation

    func makeUIViewController(context: Context) -> Fix1MainViewController {
        Fix1MainViewController(messages: conversation.messages)
    }

    func updateUIViewController(_ uiViewController: Fix1MainViewController, context: Context) {}
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

    private var messages: [Message]
    private var lastAppliedTopInset: CGFloat = 0
    private var lastContentHeight: CGFloat = 0
    private var hasUserScrolled = false
    private var didInitialScrollToBottom = false
    private var isInputBarMeasuring = false
    private var inputBarBottomConstraint: NSLayoutConstraint!
    private var inputBarHeightConstraint: NSLayoutConstraint!
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
    private var keyboardAnimationDuration: TimeInterval = 0.25
    private var keyboardAnimationOptions: UIView.AnimationOptions = [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
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
    private var didConfigureInteractivePopGesture = false
#if DEBUG
    private let uiTestFakeKeyboardEnabled: Bool = {
        let value = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD"] ?? "0"
        return value == "1" || value.lowercased() == "true"
    }()
    private let uiTestFakeKeyboardInitialOverlap: CGFloat = {
        guard let raw = ProcessInfo.processInfo.environment["CMUX_UITEST_FAKE_KEYBOARD_INITIAL_OVERLAP"],
              let value = Double(raw) else {
            return 0
        }
        return CGFloat(max(0, value))
    }()
    private var uiTestKeyboardOverlap: CGFloat?
    private var uiTestInteractiveDismissalActive = false
    private let uiTestKeyboardStep: CGFloat = 24
    private var uiTestKeyboardStepDownButton: UIButton?
    private var uiTestKeyboardStepUpButton: UIButton?
    private var uiTestLastDismissTranslation: CGFloat = 0
#endif

    init(messages: [Message]) {
        self.messages = messages
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )

        setupBackground()
        setupScrollView()
        setupInputBar()
        setupDebugOverlay()
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
        if let fraction = uiTestScrollFraction {
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
        scrollView.keyboardDismissMode = .interactive
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
            DispatchQueue.main.async {
                self.updateBottomInsetsForKeyboard()
            }
        }

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
        inputBarHeightConstraint = inputBarVC.view.heightAnchor.constraint(
            equalToConstant: DebugInputBarMetrics.inputHeight + DebugInputBarMetrics.topPadding + 28
        )
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
            inputBarHeightConstraint,

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
        log("  view.window: \(String(describing: view.window))")
        log("  inputBarVC.view.bounds: \(inputBarVC.view.bounds)")
        if isInputBarMeasuring, inputBarVC.view.bounds.height > 1 {
            isInputBarMeasuring = false
            inputBarVC.view.alpha = 1
        }
        updateTopFadeHeightIfNeeded()
        updateTopInsetIfNeeded()
        updateBottomInsetsForKeyboard()
        updateContentMinHeightIfNeeded()
        clampContentOffsetIfNeeded(keyboardOverlap: currentKeyboardOverlap())
        maybeScrollToBottomIfNeeded()
        let scale = max(1, view.traitCollection.displayScale)
        let pillTopY = currentPillTopY(scale: scale)
        previousLayoutPillTopY = lastLayoutPillTopY
        lastLayoutPillTopY = pillTopY
        logContentGeometry(reason: "viewDidLayoutSubviews")
        logVisibleMessages(reason: "viewDidLayoutSubviews")
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
        }
    }

    private func updateContentMinHeightIfNeeded() {
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.contentInset.bottom
        let contentHeight = naturalContentHeight()
        let boundsHeight = scrollView.bounds.height
        let fits = contentFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
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
        return size.height
    }

    private func updateBottomInsetsForKeyboard(animated: Bool = false) {
        let scale = max(1, view.traitCollection.displayScale)
        view.layoutIfNeeded()
        let oldPillFrame = computedPillFrameInView()
        let currentPillTopY = pixelAlign(inputBarVC.view.frame.minY + oldPillFrame.minY, scale: scale)
        let liveOldPillTopY = animated ? currentPillTopY : (lastLayoutPillTopY ?? currentPillTopY)
        let liveOldOffsetY = scrollView.contentOffset.y
        let liveOldMaxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        let liveDistanceFromBottom = max(0, liveOldMaxOffsetY - liveOldOffsetY)
        let oldBottomInset = scrollView.contentInset.bottom
        let liveIsAtBottom = liveDistanceFromBottom <= 1
        let transitionSnapshot = pendingKeyboardTransition
        let useTransitionSnapshot = transitionSnapshot?.applied == false
        let oldPillTopY = useTransitionSnapshot ? (transitionSnapshot?.oldPillTopY ?? liveOldPillTopY) : liveOldPillTopY
        let oldOffsetY = useTransitionSnapshot ? (transitionSnapshot?.oldOffsetY ?? liveOldOffsetY) : liveOldOffsetY
        let rawDistanceFromBottom = useTransitionSnapshot ? (transitionSnapshot?.distanceFromBottom ?? liveDistanceFromBottom) : liveDistanceFromBottom
        let wasAnchoredToBottom = (useTransitionSnapshot ? (transitionSnapshot?.wasAtBottom ?? liveIsAtBottom) : liveIsAtBottom)
            && !scrollView.isDragging
            && !scrollView.isDecelerating
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
            let keyboardFrame = self.view.keyboardLayoutGuide.layoutFrame
            let safeBottom = self.view.window?.safeAreaInsets.bottom ?? self.view.safeAreaInsets.bottom
            let keyboardOverlap: CGFloat
            #if DEBUG
            if let uiTestKeyboardOverlap = self.uiTestKeyboardOverlap {
                keyboardOverlap = uiTestKeyboardOverlap
            } else {
                keyboardOverlap = max(0, keyboardFrame.height - safeBottom)
            }
            #else
            keyboardOverlap = max(0, keyboardFrame.height - safeBottom)
            #endif
            let keyboardVisible = keyboardOverlap > 1
            let newInputBarConstant: CGFloat
            #if DEBUG
            if self.uiTestKeyboardOverlap != nil {
                newInputBarConstant = -keyboardOverlap
            } else {
                newInputBarConstant = 0
            }
            #else
            newInputBarConstant = 0
            #endif
            let keyboardIsMovingDown = self.keyboardIsMovingDown(current: keyboardOverlap)
            let gestureIsDismissing = self.isDismissingKeyboardGesture()
            self.updateInteractiveDismissalAnchorIfNeeded(
                keyboardOverlap: keyboardOverlap,
                keyboardIsMovingDown: keyboardIsMovingDown,
                gestureIsDismissing: gestureIsDismissing
            )
            self.lastKeyboardOverlap = keyboardOverlap

            var needsLayout = false
            var didToggleKeyboard = false
            if animated {
                let wasKeyboardVisible = self.isKeyboardVisible
                if keyboardVisible != wasKeyboardVisible {
                    didToggleKeyboard = true
                    self.isKeyboardVisible = keyboardVisible
                    let horizontalPadding: CGFloat = keyboardVisible ? 12 : 20
                    let bottomPadding: CGFloat = keyboardVisible ? 8 : 28
                    self.inputBarVC.updateLayout(
                        horizontalPadding: horizontalPadding,
                        bottomPadding: bottomPadding,
                        animationDuration: self.keyboardAnimationDuration
                    )
                    needsLayout = true
                }
            }

            if abs(self.inputBarBottomConstraint.constant - newInputBarConstant) > 0.5 {
                self.inputBarBottomConstraint.constant = newInputBarConstant
                needsLayout = true
            }

            let targetBarHeight: CGFloat
            if didToggleKeyboard {
                let bottomPadding: CGFloat = keyboardVisible ? 8 : 28
                targetBarHeight = DebugInputBarMetrics.inputHeight + DebugInputBarMetrics.topPadding + bottomPadding
            } else {
                targetBarHeight = self.inputBarVC.preferredHeight(for: self.view.bounds.width)
            }
            if targetBarHeight > 1,
               abs(self.inputBarHeightConstraint.constant - targetBarHeight) > 0.5 {
                self.inputBarHeightConstraint.constant = targetBarHeight
                needsLayout = true
            }

            if needsLayout {
                self.view.layoutIfNeeded()
            }

            let naturalHeight = self.naturalContentHeight()
            let fitsAboveInput = self.contentFitsAboveInput(
                contentHeight: naturalHeight,
                boundsHeight: self.scrollView.bounds.height,
                topInset: self.scrollView.adjustedContentInset.top,
                bottomInset: self.scrollView.contentInset.bottom
            )
            let shouldAnchorToBottom = wasAnchoredToBottom && !fitsAboveInput
            let isInteractiveDismissal = keyboardOverlap > 1
                && self.isInteractiveDismissalActive
                && self.interactiveDismissalAnchor != nil

            let desiredGap: CGFloat = 16
            let pillFrame = self.computedPillFrameInView()
            let pillTopY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.minY, scale: scale)
            let pillBottomY = self.pixelAlign(self.inputBarVC.view.frame.minY + pillFrame.maxY, scale: scale)
            let belowPillGap = max(0, self.view.bounds.maxY - pillBottomY)
            let targetExtraSpacerHeight = self.pixelAlign(desiredGap, scale: scale)
            let targetBottomSpacerHeight = self.pixelAlign(pillFrame.height, scale: scale)
            let targetBelowPillHeight = self.pixelAlign(belowPillGap, scale: scale)
            let targetBottomInset = self.pixelAlign(self.view.bounds.maxY - pillTopY + desiredGap, scale: scale)
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

        self.view.layoutIfNeeded()
        self.scrollView.layoutIfNeeded()

        let newMaxOffsetY = max(0, self.scrollView.contentSize.height - self.scrollView.bounds.height + targetBottomInset)
            let deltaInset = targetBottomInset - oldBottomInset
            let deltaPill = pillTopY - oldPillTopY
            let shouldAdjustOffset = animated || abs(deltaPill) > 0.5 || oldAnchorSample != nil || useTransitionSnapshot
            if shouldAdjustOffset {
                let adjustedTop = self.scrollView.adjustedContentInset.top
                var minY = -adjustedTop
                var maxY = max(minY, newMaxOffsetY)
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
                if !isInteractiveDismissal {
                    if shouldAnchorToBottom {
                        targetOffsetY = newMaxOffsetY
                    } else if fitsAboveInput {
                        targetOffsetY = minY
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

            #if DEBUG
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
            self.debugInfoLabel.text = String(
                format: "barH=%.1f pillY=%.1f pillH=%.1f gap=%.1f\nmeasY=%.1f measH=%.1f extra=%.1f below=%.1f\nkbdH=%.1f kbdMinY=%.1f kbdVis=%@ dist=%.1f anchor=%@ idx=%d aGap=%.1f %@ %@ %@ pΔ=%.1f",
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
            self.extraSpacerLabel.text = String(format: "h=%.1f c=%.1f", self.extraSpacerView.bounds.height, 0)
            self.bottomSpacerLabel.text = String(format: "h=%.1f c=%.1f", self.bottomSpacerView.bounds.height, 0)
            self.belowPillSpacerLabel.text = String(format: "h=%.1f c=%.1f", self.belowPillSpacerView.bounds.height, 0)
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
            #endif
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
        let bounds = contentOffsetBounds(keyboardOverlap: keyboardOverlap)
        let minY = bounds.minY
        let maxY = bounds.maxY
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
        let contentHeight = naturalContentHeight()
        let boundsHeight = scrollView.bounds.height
        var minY = -topInset
        let maxYRaw = contentHeight - boundsHeight + bottomInset
        let fits = contentFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        var maxY = fits ? minY : maxYRaw
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
        let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
        keyboardAnimationDuration = duration
        keyboardAnimationOptions = [curve, .beginFromCurrentState, .allowUserInteraction]
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
        let previousPillTopY = previousLayoutPillTopY
        let oldPillTopY: CGFloat
        if let previousPillTopY, abs(currentPillTopY - previousPillTopY) > 1 {
            oldPillTopY = previousPillTopY
        } else {
            oldPillTopY = currentPillTopY
        }
        let oldOffsetY = scrollView.contentOffset.y
        let oldMaxOffsetY = max(0, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
        let distanceFromBottom = max(0, oldMaxOffsetY - oldOffsetY)
        let wasAtBottom = distanceFromBottom <= 1
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
    private func setupUiTestKeyboardControlsIfNeeded() {
        guard uiTestFakeKeyboardEnabled else { return }
        let stepDown = UIButton(type: .custom)
        stepDown.translatesAutoresizingMaskIntoConstraints = false
        stepDown.alpha = 0.01
        stepDown.accessibilityIdentifier = "chat.fakeKeyboard.stepDown"
        stepDown.addTarget(self, action: #selector(handleUiTestKeyboardStepDown), for: .touchUpInside)
        view.addSubview(stepDown)
        let stepUp = UIButton(type: .custom)
        stepUp.translatesAutoresizingMaskIntoConstraints = false
        stepUp.alpha = 0.01
        stepUp.accessibilityIdentifier = "chat.fakeKeyboard.stepUp"
        stepUp.addTarget(self, action: #selector(handleUiTestKeyboardStepUp), for: .touchUpInside)
        view.addSubview(stepUp)
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
            stepUp.heightAnchor.constraint(equalToConstant: 44)
        ])

        if uiTestFakeKeyboardInitialOverlap > 0 {
            uiTestKeyboardOverlap = uiTestFakeKeyboardInitialOverlap
            DispatchQueue.main.async { [weak self] in
                self?.applyUiTestKeyboardOverlap(animated: true)
            }
        }
    }

    @objc private func handleUiTestKeyboardStepDown() {
        let current = uiTestKeyboardOverlap ?? 0
        uiTestKeyboardOverlap = max(0, current - uiTestKeyboardStep)
        applyUiTestKeyboardOverlap(animated: true)
    }

    @objc private func handleUiTestKeyboardStepUp() {
        let current = uiTestKeyboardOverlap ?? 0
        uiTestKeyboardOverlap = current + uiTestKeyboardStep
        applyUiTestKeyboardOverlap(animated: true)
    }

    private func applyUiTestKeyboardOverlap(animated: Bool) {
        uiTestInteractiveDismissalActive = true
        updateBottomInsetsForKeyboard(animated: animated)
        uiTestInteractiveDismissalActive = false
    }

    private func applyUiTestKeyboardDragIfNeeded() {
        guard scrollView != nil, scrollView.isTracking else { return }
        guard let overlap = uiTestKeyboardOverlap else { return }
        let translation = scrollView.panGestureRecognizer.translation(in: view)
        guard translation.y > 0.1 else { return }
        let delta = translation.y - uiTestLastDismissTranslation
        guard abs(delta) > 0.1 else { return }
        uiTestLastDismissTranslation = translation.y
        uiTestKeyboardOverlap = max(0, overlap - delta)
        applyUiTestKeyboardOverlap(animated: false)
        uiTestLastDismissTranslation = 0
        scrollView.panGestureRecognizer.setTranslation(.zero, in: view)
    }
    #endif

    private func currentKeyboardOverlap() -> CGFloat {
        #if DEBUG
        if let uiTestKeyboardOverlap {
            return uiTestKeyboardOverlap
        }
        #endif
        let keyboardFrame = view.keyboardLayoutGuide.layoutFrame
        let safeBottom = view.window?.safeAreaInsets.bottom ?? view.safeAreaInsets.bottom
        return max(0, keyboardFrame.height - safeBottom)
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
        let viewHeight = inputBarVC.view.bounds.height
        guard viewHeight > 0 else { return .zero }
        let contentTopInset = inputBarVC.contentTopInset
        let contentBottomInset = inputBarVC.contentBottomInset
        let expectedHeight = contentTopInset + contentBottomInset + DebugInputBarMetrics.inputHeight
        let extra = max(0, viewHeight - expectedHeight)
        let offset = extra / 2
        let topLimit = contentTopInset + offset
        let bottomLimit = max(topLimit, viewHeight - contentBottomInset - offset)
        let availableHeight = max(0, bottomLimit - topLimit)
        let height = min(DebugInputBarMetrics.inputHeight, availableHeight)
        return CGRect(x: 0, y: topLimit, width: inputBarVC.view.bounds.width, height: height)
    }

    private func maybeScrollToBottomIfNeeded() {
        let contentHeight = scrollView.contentSize.height
        if abs(contentHeight - lastContentHeight) > 1 {
            lastContentHeight = contentHeight
            if !hasUserScrolled && (didInitialScrollToBottom == false || contentHeight > 0) {
                didInitialScrollToBottom = true
                scrollToBottom(animated: false)
            }
        }
    }

    private func logContentGeometry(reason: String) {
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
        host.view.accessibilityIdentifier = "chat.message.\(message.id.uuidString)"
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
        let contentHeight = naturalContentHeight()
        let boundsHeight = scrollView.bounds.height
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.contentInset.bottom

        // Max offset: bottom of content aligns with visible area above input bar
        let maxOffsetY = contentHeight - boundsHeight + bottomInset
        // Min offset: content starts below header
        let minOffsetY = -topInset
        let fits = contentFitsAboveInput(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
        let targetOffsetY = fits ? minOffsetY : maxOffsetY

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
        guard !inputBarVC.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let message = Message(content: inputBarVC.text, timestamp: .now, isFromMe: true, status: .sent)
        messages.append(message)
        inputBarVC.clearText()

        addMessageBubble(message, showTail: true, showTimestamp: false)

        DispatchQueue.main.async {
            self.scrollToBottom(animated: true)
        }
    }

    private func logVisibleMessages(reason: String) {
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

    private func lastMessageFrameInView() -> CGRect {
        let messageViews = messageArrangedViews()
        guard let lastMessageView = messageViews.last else { return .zero }
        return contentStack.convert(lastMessageView.frame, to: view)
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
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateColors()
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
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateColors()
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
