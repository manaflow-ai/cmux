import AppKit
import CmuxLiteCore

@MainActor
final class CmuxRenderView: NSView, @preconcurrency NSTextInputClient {
    let metrics: CmuxRenderFontMetrics
    var onInput: ((CmuxTerminalKeyAction) -> Void)?
    var onPaste: ((String) -> Void)?
    var onScrollRows: ((Int) -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    private var model: CmuxRenderModel?
    private var historyRows: [CmuxRenderRow]?
    private var historyOffset = 0
    private var paneActive = false
    private var blinkPhase = true
    private var blinkTimer: Timer?
    private var markedText = NSMutableAttributedString()
    private var selectedTextRange = NSRange(location: 0, length: 0)

    init(configuration: CmuxGhosttyViewConfiguration) {
        metrics = CmuxRenderFontMetrics(configuration: configuration)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(String(
            localized: "terminal.accessibility_label",
            defaultValue: "Remote terminal",
            bundle: .module
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(model: CmuxRenderModel) {
        self.model = model
        historyRows = nil
        historyOffset = 0
        updateBlinkTimer()
        needsDisplay = true
    }

    func updateHistory(rows: [CmuxRenderRow], offset: Int) {
        historyRows = rows
        historyOffset = max(0, min(offset, max(0, rows.count - visibleRowCount)))
        updateBlinkTimer()
        needsDisplay = true
    }

    func returnToLive() {
        historyRows = nil
        historyOffset = 0
        updateBlinkTimer()
        needsDisplay = true
    }

    func setPaneActive(_ active: Bool) {
        paneActive = active
        needsDisplay = true
    }

    var visibleRowCount: Int {
        guard metrics.cellHeightPoints > 0 else { return 1 }
        return max(1, Int(floor(bounds.height / metrics.cellHeightPoints)))
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChanged?(true)
            needsDisplay = true
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            onFocusChanged?(false)
            needsDisplay = true
        }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            return
        }
        updateBlinkTimer()
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        guard let input = event.cmuxTerminalKeyEvent,
              let action = input.terminalAction()
        else {
            super.keyDown(with: event)
            return
        }
        switch action {
        case .text where !input.control && !input.option:
            interpretKeyEvents([event])
        default:
            onInput?(action)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc
    func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        onPaste?(text)
    }

    override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let divisor = precise ? max(1, metrics.cellHeightPoints) : 1
        let raw = event.scrollingDeltaY / divisor
        let rows = raw == 0 ? 0 : (raw > 0 ? Int(ceil(raw)) : Int(floor(raw)))
        guard rows != 0 else { return }
        onScrollRows?(rows)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let defaultForeground = CmuxRenderColor(model.defaultForeground)?.color ?? .white
        let defaultBackground = CmuxRenderColor(model.defaultBackground)?.color ?? .black
        defaultBackground.setFill()
        bounds.fill()

        let sourceRows = historyRows ?? model.rows
        let start = historyRows == nil ? 0 : historyOffset
        let end = min(sourceRows.count, start + visibleRowCount)
        guard start < end else { return }
        for displayIndex in 0..<(end - start) {
            draw(
                row: sourceRows[start + displayIndex],
                displayIndex: displayIndex,
                defaultForeground: defaultForeground,
                defaultBackground: defaultBackground
            )
        }
        if historyRows == nil {
            drawCursor(model.cursor, defaultForeground: defaultForeground)
        }
    }

    private func draw(
        row: CmuxRenderRow,
        displayIndex: Int,
        defaultForeground: NSColor,
        defaultBackground: NSColor
    ) {
        let line = NSMutableAttributedString()
        var column = 0
        var underlineSpans: [(style: CmuxRenderUnderline, column: Int, width: Int, color: NSColor)] = []
        for run in row.runs {
            let style = run.attributes.style(underline: run.underline)
            var foreground = CmuxRenderColor(run.foreground)?.color ?? defaultForeground
            var background = CmuxRenderColor(run.background)?.color ?? defaultBackground
            if style.inverse { swap(&foreground, &background) }
            if style.dim { foreground = foreground.withAlphaComponent(0.55) }
            if style.invisible || (style.blink && !blinkPhase) { foreground = background }

            let width = max(0, run.cellWidth)
            let rowRect = NSRect(
                x: CGFloat(column) * metrics.cellWidthPoints,
                y: CGFloat(displayIndex) * metrics.cellHeightPoints,
                width: CGFloat(width) * metrics.cellWidthPoints,
                height: metrics.cellHeightPoints
            )
            background.setFill()
            rowRect.fill()

            var text = run.text
            let estimated = run.estimatedCellWidth
            if width > estimated {
                text.append(String(repeating: " ", count: width - estimated))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: metrics.font(for: style),
                .foregroundColor: foreground,
            ]
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            line.append(NSAttributedString(string: text, attributes: attributes))
            if let underline = style.underline {
                underlineSpans.append((underline, column, width, foreground))
            }
            column += width
        }

        let y = CGFloat(displayIndex) * metrics.cellHeightPoints
            + max(0, metrics.baselinePoints - metrics.regularFont.ascender)
        line.draw(at: NSPoint(x: 0, y: y))
        for span in underlineSpans {
            drawUnderline(
                span.style,
                x: CGFloat(span.column) * metrics.cellWidthPoints,
                y: CGFloat(displayIndex + 1) * metrics.cellHeightPoints - 2,
                width: CGFloat(span.width) * metrics.cellWidthPoints,
                color: span.color
            )
        }
    }

    private func drawUnderline(
        _ style: CmuxRenderUnderline,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        color: NSColor
    ) {
        guard width > 0 else { return }
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        switch style {
        case .single:
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + width, y: y))
        case .double:
            path.move(to: NSPoint(x: x, y: y - 1))
            path.line(to: NSPoint(x: x + width, y: y - 1))
            path.move(to: NSPoint(x: x, y: y + 1))
            path.line(to: NSPoint(x: x + width, y: y + 1))
        case .dotted:
            path.setLineDash([1, 2], count: 2, phase: 0)
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + width, y: y))
        case .dashed:
            path.setLineDash([4, 2], count: 2, phase: 0)
            path.move(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + width, y: y))
        case .curly:
            path.move(to: NSPoint(x: x, y: y))
            var cursor = x
            var up = true
            while cursor < x + width {
                let next = min(cursor + 2, x + width)
                path.line(to: NSPoint(x: next, y: y + (up ? -1 : 1)))
                cursor = next
                up.toggle()
            }
        }
        path.stroke()
    }

    private func drawCursor(_ cursor: CmuxRenderCursor, defaultForeground: NSColor) {
        guard cursor.visible else { return }
        let color = CmuxRenderColor(cursor.color)?.color ?? defaultForeground
        let cell = NSRect(
            x: CGFloat(cursor.x) * metrics.cellWidthPoints,
            y: CGFloat(cursor.y) * metrics.cellHeightPoints,
            width: metrics.cellWidthPoints,
            height: metrics.cellHeightPoints
        )
        let focused = paneActive && window?.firstResponder === self && window?.isKeyWindow == true
        guard !focused || blinkPhase || !cursor.blink else { return }
        let shape: NSRect
        switch cursor.style {
        case .block: shape = cell
        case .bar: shape = NSRect(x: cell.minX, y: cell.minY, width: 2, height: cell.height)
        case .underline: shape = NSRect(x: cell.minX, y: cell.maxY - 2, width: cell.width, height: 2)
        }
        if focused {
            color.withAlphaComponent(cursor.style == .block ? 0.72 : 1).setFill()
            shape.fill()
        } else {
            color.setStroke()
            let path = NSBezierPath(rect: cell.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func updateBlinkTimer() {
        guard window != nil else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            return
        }
        let rowsBlink = (historyRows ?? model?.rows ?? []).contains { row in
            row.runs.contains { $0.attributes.contains(.blink) }
        }
        let cursorBlinks = historyRows == nil && model?.cursor.blink == true
        guard rowsBlink || cursorBlinks else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkPhase = true
            return
        }
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.toggleBlink()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func toggleBlink() {
        blinkPhase.toggle()
        needsDisplay = true
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? String(describing: string)
        markedText = NSMutableAttributedString()
        selectedTextRange = NSRange(location: 0, length: 0)
        if !text.isEmpty { onInput?(.text(text)) }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        markedText = NSMutableAttributedString(
            attributedString: (string as? NSAttributedString)
                ?? NSAttributedString(string: String(describing: string))
        )
        selectedTextRange = selectedRange
    }

    func unmarkText() { markedText = NSMutableAttributedString() }
    func selectedRange() -> NSRange { selectedTextRange }
    func markedRange() -> NSRange {
        markedText.length == 0 ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.length)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
