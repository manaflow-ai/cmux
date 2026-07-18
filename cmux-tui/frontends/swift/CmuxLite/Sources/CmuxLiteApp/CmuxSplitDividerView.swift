import AppKit
import CmuxLiteCore

@MainActor
final class CmuxSplitDividerView: NSView {
    private let direction: CmuxSplitDirection
    private let line = NSView()
    var enabled = true
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragChanged: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    var onDragCancelled: (() -> Void)?

    init(direction: CmuxSplitDirection) {
        self.direction = direction
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        line.wantsLayer = true
        line.layer?.backgroundColor = CmuxPalette.tui.border.cgColor
        addSubview(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layout() {
        super.layout()
        switch direction {
        case .right:
            line.frame = NSRect(
                x: floor((bounds.width - 1) / 2),
                y: 0,
                width: 1,
                height: bounds.height
            )
        case .down:
            line.frame = NSRect(
                x: 0,
                y: floor((bounds.height - 1) / 2),
                width: bounds.width,
                height: 1
            )
        }
    }

    override func resetCursorRects() {
        addCursorRect(
            bounds,
            cursor: direction == .right ? .resizeLeftRight : .resizeUpDown
        )
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled, let window, let superview else { return }
        onDragBegan?(superview.convert(event.locationInWindow, from: nil))
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = superview.convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseDragged {
                onDragChanged?(point)
            } else {
                onDragEnded?(point)
                return
            }
        }
        onDragCancelled?()
    }
}
