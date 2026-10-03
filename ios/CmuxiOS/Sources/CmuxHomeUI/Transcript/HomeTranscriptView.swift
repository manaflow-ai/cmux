import CmuxHomeCore
import CmuxHomeRender
import CmuxiOSDesign
import UIKit

/// The Home transcript on the shared render core with native UIKit parts
/// (plans/cmux-next/mac-home-rendering.md option B, the iOS host): the rows,
/// their springs and the send morph come from `CmuxHomeRender`; scrolling is
/// a UIScrollView and the compose field a UITextView that rides the
/// keyboard. Data comes in only through `controller.update` (the screen uses
/// `HomeStoreBinding`); intents leave through `controller.onIntent`.
///
/// The rows scroll under the navigation bar (`topInset` is the top safe
/// area). When the field moves (keyboard, more lines, a send) the core moves
/// the rows above it with its shared field spring; a height change moves the
/// field itself along the same spring (`fieldKeyframes`).
///
/// Rows follow Dynamic Type (`textScale` is the body style's size over the
/// core's 13 pt reference) and draw at the screen's scale (`contentsScale`).
@MainActor
final class HomeTranscriptView: UIView {
    let controller: HomeController
    let scroll = HomeTranscriptScrollView()
    let field = HomeFieldView()
    private let fieldGuide = UILayoutGuide()
    private var fieldIsSend = false
    /// The rows changed (not only the viewport): an older page, a new message.
    var onRowsChange: () -> Void = {}

    static let fieldInset: CGFloat = 8
    static let fieldBottom: CGFloat = 8

    /// False while the owner is unreachable (nothing queues; the text stays a draft).
    var disabledReason: String? {
        get { field.disabledReason }
        set { field.disabledReason = newValue }
    }

    init(conversation: ConversationID, me: ParticipantID, traits: UITraitCollection) {
        controller = HomeController(conversation: conversation, me: me, palette: HomeRenderTheme.palette(for: traits),
                                    deadline: HomeRunLoopDeadline())
        super.init(frame: .zero)
        controller.reduceMotion = UIAccessibility.isReduceMotionEnabled
        applyScales(traits)
        backgroundColor = CmuxiOSDesign.HomePalette.background
        addSubview(scroll)
        addSubview(field)
        addLayoutGuide(fieldGuide)
        // The field's bottom edge follows the keyboard (or the safe area).
        NSLayoutConstraint.activate([
            fieldGuide.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: Self.fieldInset),
            fieldGuide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -Self.fieldInset),
            fieldGuide.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -Self.fieldBottom),
            fieldGuide.heightAnchor.constraint(equalToConstant: 1),
        ])
        keyboardLayoutGuide.usesBottomSafeArea = true

        scroll.controller = controller
        scroll.rowHost.controller = controller
        scroll.rowHost.host(controller.rootLayer)
        controller.onScrollGeometryChange = { [weak self] g in self?.scroll.apply(g) }
        controller.onAccessibilityChange = { [weak self] in self?.scroll.rowHost.invalidateAccessibility() }
        controller.onRowsChange = { [weak self] in
            self?.scroll.rowHost.rowsChanged()
            self?.onRowsChange()
        }
        // A send the owner refused before logging it (HomeStoreBinding ->
        // restoreDraft): the text comes back into this field if it is empty.
        controller.onRestoreDraft = { [weak self] text in
            guard let self, self.field.text.isEmpty else { return }
            self.field.text = text
        }
        field.onSend = { [weak self] in self?.send() }
        field.onHeightChange = { [weak self] in self?.setNeedsLayout() }

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: HomeTranscriptView, _) in
            view.controller.palette = HomeRenderTheme.palette(for: view.traitCollection)
        }
        registerForTraitChanges([UITraitDisplayScale.self, UITraitPreferredContentSizeCategory.self]) {
            (view: HomeTranscriptView, _) in
            view.applyScales(view.traitCollection)
            view.setNeedsLayout()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func reduceMotionChanged() {
        controller.reduceMotion = UIAccessibility.isReduceMotionEnabled
    }

    /// Bitmaps at the screen's pixel density; text at the Dynamic Type body
    /// size (17 pt at the default size, 53 pt at the largest accessibility
    /// size), relative to the core's 13 pt reference.
    private func applyScales(_ traits: UITraitCollection) {
        if traits.displayScale > 0 { controller.contentsScale = traits.displayScale }
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits).pointSize
        controller.textScale = body / Self.referenceBodySize
    }

    /// The core's body size at `textScale` 1 (the Mac default).
    static let referenceBodySize: CGFloat = 13

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        controller.topInset = safeAreaInsets.top
        setNeedsLayout()
    }

    /// The field's frame in the core's viewport points (the scroll view's visible area).
    private var fieldFrameInViewport: CGRect {
        field.frame.offsetBy(dx: -scroll.frame.minX, dy: -scroll.frame.minY)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The rows keep clear of the landscape sensor housing; the field has its own guide.
        let scrollFrame = CGRect(x: safeAreaInsets.left, y: 0,
                                 width: max(1, bounds.width - safeAreaInsets.left - safeAreaInsets.right), height: bounds.height)
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        controller.resize(to: scrollFrame.size)

        let guide = fieldGuide.layoutFrame
        let height = field.preferredHeight(width: guide.width)
        let send = fieldIsSend
        placeField(CGRect(x: guide.minX, y: guide.maxY - height, width: guide.width, height: height), send: send)
        controller.setHostedField(fieldFrameInViewport, send: send)
        fieldIsSend = false
        scroll.apply(controller.scrollGeometry)
        scroll.verticalScrollIndicatorInsets = UIEdgeInsets(top: safeAreaInsets.top, left: 0,
                                                            bottom: max(0, bounds.height - field.frame.minY), right: 0)
    }

    /// A height change (more lines, the shrink after a send) moves the field
    /// along the shared field spring, the curve the rows above it follow.
    /// Keyboard moves keep UIKit's own animation; everything else is direct.
    private func placeField(_ frame: CGRect, send: Bool) {
        let old = field.frame
        guard old != frame else { return }
        if old.height > 0, old.height != frame.height, window != nil, UIView.inheritedAnimationDuration == 0,
           let keyframes = controller.fieldKeyframes(from: old, to: frame, send: send) {
            HomeFieldSpring.animate(field, to: frame, keyframes: keyframes)
        } else {
            field.frame = frame
        }
    }

    private func send() {
        guard field.disabledReason == nil,
              controller.sendHosted(text: field.text, from: fieldFrameInViewport) != nil else { return }
        fieldIsSend = true
        field.text = ""
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Returns when every visible row bitmap is drawn (screenshots).
    func rendered() async {
        layoutIfNeeded()
        await controller.bitmapsSettled()
    }
}
