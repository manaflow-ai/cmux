import CmuxHomeRender
import UIKit

/// The transcript's scrolling is UIKit's: a UIScrollView owns the pan,
/// deceleration, the rubber band at both ends, the indicator, scroll to top,
/// keyboard dismissal and VoiceOver scrolling. The render core keeps the rows
/// and their motion; its offset is the scroll view's `contentOffset.y`.
///
/// Coordinates: content insets are not adjusted for the safe area, the top
/// inset is `-minOffset` and the content is `pinnedOffset + height` tall, so
/// UIKit's allowed offsets are exactly the core's `minOffset ... pinnedOffset`.
/// The row host is a subview kept on the visible area, so its coordinates
/// are the core's viewport points.
///
/// Two directions, never both in one pass:
/// - the user moved the content (drag, deceleration, bounce) -> `hostScrolled(to:)`;
/// - the core moved its offset or range (new rows while pinned, prepend,
///   resize) -> `apply(_:)` sets the content size, inset and offset.
@MainActor
final class HomeTranscriptScrollView: UIScrollView {
    weak var controller: HomeController?
    let rowHost = HomeRowHostView()
    private var applyingModel = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentInsetAdjustmentBehavior = .never
        alwaysBounceVertical = true
        alwaysBounceHorizontal = false
        showsHorizontalScrollIndicator = false
        keyboardDismissMode = .interactive
        scrollsToTop = true
        backgroundColor = .clear
        rowHost.isAccessibilityElement = false
        insertSubview(rowHost, at: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// UIKit sets `contentOffset` for every drag, deceleration and bounce
    /// step, and for `apply`; only the user's moves reach the core.
    override var contentOffset: CGPoint {
        didSet {
            pinRowHost()
            guard !applyingModel, contentOffset.y != oldValue.y, let controller else { return }
            controller.hostScrolled(to: contentOffset.y)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pinRowHost()
    }

    /// The core's range or offset changed: content size, inset and offset follow.
    /// The host resized the scroll view. UIKit may move the offset to keep it
    /// in range while the frame changes; that is not a user scroll, so it
    /// does not reach the core (which resizes itself next and keeps the
    /// transcript pinned or anchored).
    func setFrameFromHost(_ frame: CGRect) {
        guard self.frame != frame else { return }
        applyingModel = true
        defer { applyingModel = false }
        self.frame = frame
    }

    /// Never animated, even inside a UIKit animation (the keyboard's): the
    /// core already moved the rows, and an animated offset (the scroll
    /// view's bounds) would move them a second time.
    func apply(_ g: HomeController.ScrollGeometry) {
        applyingModel = true
        defer { applyingModel = false }
        UIView.performWithoutAnimation {
            let size = CGSize(width: bounds.width, height: max(0, g.pinnedOffset + bounds.height))
            if contentSize != size { contentSize = size }
            if contentInset.top != -g.minOffset { contentInset.top = -g.minOffset }
            // Also during a drag or deceleration: a rebase moves every row, and
            // UIKit continues the gesture from the moved offset.
            if contentOffset.y != g.offset {
                contentOffset = CGPoint(x: 0, y: g.offset)
            }
        }
    }

    /// The row host stays on the visible area whatever the offset.
    private func pinRowHost() {
        let frame = CGRect(origin: CGPoint(x: 0, y: contentOffset.y), size: bounds.size)
        guard rowHost.frame != frame else { return }
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rowHost.frame = frame
            CATransaction.commit()
        }
    }
}
