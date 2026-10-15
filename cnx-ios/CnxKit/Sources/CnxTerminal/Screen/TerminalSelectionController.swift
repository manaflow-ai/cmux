#if os(iOS)
import UIKit

/// Text selection over the terminal's rows, scrollback included (G-14,
/// T-SEL-01/02), with iOS conventions: a long press selects the word under the
/// finger (moving the finger then extends it), two handles move either end,
/// and the edit menu offers Copy and Select All. A tap clears it. The
/// highlight lives in the scroll view's content, so it scrolls with the rows.
/// The screen supplies the geometry; Ghostty supplies the text.
@MainActor
final class TerminalSelectionController: NSObject, @MainActor UIEditMenuInteractionDelegate, @MainActor UIGestureRecognizerDelegate {
    /// The cell under a point in the scroll view's content (nil off the document).
    var cellAt: (CGPoint) -> TerminalCellPoint? = { _ in nil }
    /// A cell's rect in the scroll view's content.
    var rectFor: (TerminalCellPoint) -> CGRect = { _ in .zero }
    var rowText: (Int) -> String? = { _ in nil }
    var text: (TerminalCellPoint, TerminalCellPoint) -> String? = { _, _ in nil }
    var columns: () -> Int = { 80 }
    /// The document's first row and one past its last.
    var documentRows: () -> Range<Int> = { 0..<0 }
    /// Selection is off (a TUI on the alternate screen draws its own).
    var isEnabled: () -> Bool = { true }

    private(set) var selection: TerminalTextSelection? {
        didSet { if selection != oldValue { redraw() } }
    }

    private weak var scrollView: UIScrollView?
    private let highlight = SelectionHighlightView()
    private let startHandle = SelectionHandleView(isStart: true)
    private let endHandle = SelectionHandleView(isStart: false)
    private var menu: UIEditMenuInteraction?
    private(set) var longPress: UILongPressGestureRecognizer?
    private var dragging: TerminalTextSelection.Handle?

    func install(in scrollView: UIScrollView) {
        self.scrollView = scrollView
        highlight.isUserInteractionEnabled = false
        highlight.isHidden = true
        scrollView.addSubview(highlight)
        for handle in [startHandle, endHandle] {
            handle.isHidden = true
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePanned(_:)))
            handle.addGestureRecognizer(pan)
            // A drag that starts on a handle moves the handle, not the page.
            scrollView.panGestureRecognizer.require(toFail: pan)
            scrollView.addSubview(handle)
        }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.45
        press.delegate = self
        scrollView.addGestureRecognizer(press)
        longPress = press
        let menu = UIEditMenuInteraction(delegate: self)
        scrollView.addInteraction(menu)
        self.menu = menu
    }

    /// The overlay stays above the surface as the screen re-adds views.
    func bringToFront() {
        guard let scrollView else { return }
        for view in [highlight, startHandle, endHandle] { scrollView.bringSubviewToFront(view) }
    }

    func clear() {
        guard selection != nil else { return }
        selection = nil
        menu?.dismissMenu()
    }

    /// The rows moved in the document (a prune renumbers them): keep the selection on its text.
    func shiftRows(by delta: Int) {
        guard var current = selection, delta != 0 else { return }
        // The selected rows left the history: nothing to keep.
        guard current.start.row + delta >= 0 else { return clear() }
        current.anchor.row += delta
        current.head.row += delta
        selection = current
    }

    /// Re-lays the highlight (the document or the cell size changed).
    func redraw() {
        guard let selection, isEnabled() else {
            highlight.isHidden = true
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        let spans = selection.rowSpans(columns: columns())
        highlight.rects = spans.map { span in
            let first = rectFor(TerminalCellPoint(row: span.row, column: span.columns.lowerBound))
            let last = rectFor(TerminalCellPoint(row: span.row, column: span.columns.upperBound - 1))
            return first.union(last)
        }
        let bounds = highlight.rects.reduce(CGRect.null) { $0.union($1) }
        highlight.frame = bounds.isNull ? .zero : bounds.insetBy(dx: -1, dy: -1)
        highlight.setNeedsDisplay()
        highlight.isHidden = bounds.isNull
        bringToFront()
        let start = rectFor(selection.start), end = rectFor(selection.end)
        startHandle.place(caretTop: CGPoint(x: start.minX, y: start.minY), height: start.height)
        endHandle.place(caretTop: CGPoint(x: end.maxX, y: end.minY), height: end.height)
        startHandle.isHidden = false
        endHandle.isHidden = false
    }

    // MARK: Gestures

    @objc private func longPressed(_ press: UILongPressGestureRecognizer) {
        guard let scrollView, isEnabled() else { return }
        let point = press.location(in: scrollView)
        switch press.state {
        case .began:
            guard let cell = cellAt(point) else { return }
            selection = TerminalTextSelection.word(at: cell, line: rowText(cell.row) ?? "", columns: columns())
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            // Moving after the press extends the selection, like a drag-select.
            guard var current = selection, let cell = cellAt(point) else { return }
            current.head = cell
            selection = current
        case .ended:
            showMenu()
        default:
            break
        }
    }

    @objc private func handlePanned(_ pan: UIPanGestureRecognizer) {
        guard let scrollView, var current = selection else { return }
        if pan.state == .began {
            menu?.dismissMenu()
            dragging = pan.view === startHandle ? .start : .end
        }
        // Every report moves the handle, the first and last included (a
        // quick drag can arrive as a begin and an end only).
        if [.began, .changed, .ended].contains(pan.state), let handle = dragging {
            // The finger sits on the handle's knob: aim at the row beside it.
            var point = pan.location(in: scrollView)
            point.y += handle == .start ? 10 : -10
            if let cell = cellAt(point) {
                current.move(handle, to: cell)
                dragging = current.headHandle
                selection = current
            }
        }
        if [.ended, .cancelled, .failed].contains(pan.state) {
            dragging = nil
            showMenu()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isEnabled()
    }

    // MARK: Edit menu

    private func showMenu() {
        guard let selection, let menu else { return }
        let start = rectFor(selection.start)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: start.midX, y: start.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard selection != nil else { return nil }
        let copy = UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy() }
        let all = UIAction(title: String(localized: "Select All"), image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            self?.selectAll()
        }
        return UIMenu(children: [copy, all])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        highlight.isHidden ? .null : highlight.frame
    }

    func copy() {
        guard let selection, let raw = text(selection.start, selection.end) else { return }
        UIPasteboard.general.string = TerminalTextSelection.cleaned(raw)
        clear()
    }

    func selectAll() {
        let rows = documentRows()
        guard !rows.isEmpty else { return }
        selection = TerminalTextSelection.all(originRow: rows.lowerBound, endRow: rows.upperBound, columns: columns())
        showMenu()
    }
}

/// The selection's tint, one rect per row.
private final class SelectionHighlightView: UIView {
    var rects: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        UIColor.tintColor.withAlphaComponent(0.35).setFill()
        for row in rects {
            UIBezierPath(rect: row.offsetBy(dx: -frame.minX, dy: -frame.minY)).fill()
        }
    }
}

/// An iOS selection handle: a caret with a knob above (start) or below (end),
/// with a 44 pt touch area.
private final class SelectionHandleView: UIView {
    let isStart: Bool
    private let caret = UIView()
    private let knob = UIView()

    init(isStart: Bool) {
        self.isStart = isStart
        super.init(frame: .zero)
        backgroundColor = .clear
        caret.backgroundColor = .tintColor
        knob.backgroundColor = .tintColor
        knob.layer.cornerRadius = 5
        addSubview(caret)
        addSubview(knob)
        isAccessibilityElement = true
        accessibilityLabel = isStart ? String(localized: "Selection start") : String(localized: "Selection end")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func place(caretTop: CGPoint, height: CGFloat) {
        let width: CGFloat = 44
        frame = CGRect(x: caretTop.x - width / 2, y: caretTop.y - 22, width: width, height: height + 44)
        caret.frame = CGRect(x: width / 2 - 1, y: 22, width: 2, height: height)
        knob.frame = CGRect(x: width / 2 - 5, y: isStart ? 12 : 22 + height, width: 10, height: 10)
    }
}
#endif
