import AppKit
import CmuxLiteCore

@MainActor
final class CmuxSplitView: NSView {
    private let direction: CmuxSplitDirection
    private let first: NSView
    private let second: NSView
    private let divider: CmuxSplitDividerView
    private let target: CmuxSplitTarget?
    private let authoritativeRatio: Double
    private var displayedRatio: Double
    private let onCommit: (CmuxSplitTarget, Double, Double) -> Void

    init(
        direction: CmuxSplitDirection,
        authoritativeRatio: Double,
        displayedRatio: Double,
        target: CmuxSplitTarget?,
        pending: Bool,
        first: NSView,
        second: NSView,
        onCommit: @escaping (CmuxSplitTarget, Double, Double) -> Void
    ) {
        self.direction = direction
        self.authoritativeRatio = CmuxSplitRatio(clamping: authoritativeRatio).value
        self.displayedRatio = CmuxSplitRatio(clamping: displayedRatio).value
        self.target = target
        self.first = first
        self.second = second
        self.onCommit = onCommit
        divider = CmuxSplitDividerView(direction: direction)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CmuxPalette.tui.background.cgColor
        addSubview(first)
        addSubview(second)
        addSubview(divider)
        divider.isHidden = target == nil
        divider.enabled = target != nil && !pending
        configureDragging()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        let ratio = CGFloat(displayedRatio)
        switch direction {
        case .right:
            let firstWidth = floor(bounds.width * ratio)
            first.frame = NSRect(x: 0, y: 0, width: firstWidth, height: bounds.height)
            second.frame = NSRect(
                x: firstWidth,
                y: 0,
                width: max(0, bounds.width - firstWidth),
                height: bounds.height
            )
            divider.frame = NSRect(
                x: firstWidth - 4,
                y: 0,
                width: 9,
                height: bounds.height
            )
        case .down:
            let firstHeight = floor(bounds.height * ratio)
            first.frame = NSRect(
                x: 0,
                y: bounds.height - firstHeight,
                width: bounds.width,
                height: firstHeight
            )
            second.frame = NSRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: max(0, bounds.height - firstHeight)
            )
            divider.frame = NSRect(
                x: 0,
                y: bounds.height - firstHeight - 4,
                width: bounds.width,
                height: 9
            )
        }
    }

    private func configureDragging() {
        divider.onDragChanged = { [weak self] point in
            self?.preview(at: point)
        }
        divider.onDragEnded = { [weak self] point in
            guard let self else { return }
            preview(at: point)
            guard let target,
                  let ratio = CmuxSplitRatio(clamping: displayedRatio)
                    .commit(comparedWith: authoritativeRatio)
            else {
                displayedRatio = authoritativeRatio
                needsLayout = true
                return
            }
            onCommit(target, authoritativeRatio, ratio)
        }
        divider.onDragCancelled = { [weak self] in
            guard let self else { return }
            displayedRatio = authoritativeRatio
            needsLayout = true
        }
    }

    private func preview(at point: NSPoint) {
        let value = switch direction {
        case .right:
            CmuxSplitRatio(offset: point.x, extent: bounds.width)
        case .down:
            CmuxSplitRatio(offset: bounds.height - point.y, extent: bounds.height)
        }
        guard let value else { return }
        displayedRatio = value.value
        needsLayout = true
        layoutSubtreeIfNeeded()
    }
}
