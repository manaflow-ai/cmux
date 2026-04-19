#if canImport(AppKit)
import AppKit
import Foundation
import RunestoneCore

private final class NativeTextView: NSTextView {
    weak var hostingTextView: TextView?

    override func scrollRangeToVisible(_ range: NSRange) {
        guard let hostingTextView else {
            super.scrollRangeToVisible(range)
            return
        }
        if hostingTextView.scrollRangeToVisibleMinimallyFromNative(range) {
            return
        }
        super.scrollRangeToVisible(range)
    }

    override func insertNewline(_ sender: Any?) {
        let previousOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        hostingTextView?.beginEnterShiftTrace(previousOrigin: previousOrigin)
        super.insertNewline(sender)
        hostingTextView?.constrainPostEnterScroll(previousOrigin: previousOrigin)
        hostingTextView?.finishEnterShiftTrace()
    }
}

/// A macOS text editor view with Runestone-compatible APIs.
open class TextView: NSScrollView {
    private static let debugUndoLagEnabled = ProcessInfo.processInfo.environment["RUNESTONE_DEMO_DEBUG_UNDO_LAG"] == "1"
    private static let debugLagTraceEnabled = ProcessInfo.processInfo.environment["RUNESTONE_DEMO_DEBUG_LAG_TRACE"] == "1"
    private static let debugEnterShiftEnabled = ProcessInfo.processInfo.environment["RUNESTONE_DEMO_DEBUG_ENTER_SHIFT"] == "1"
    private static let lagTraceNotificationName = Notification.Name("RunestoneLagTraceEvent")

    /// Delegate to receive callbacks for events triggered by the editor.
    public weak var editorDelegate: TextViewDelegate?

    /// The text that the text view displays.
    public var text: String {
        get {
            textView.string
        }
        set {
            isPerformingProgrammaticEdit = true
            textStorage.setString(newValue)
            textView.string = textStorage as String
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            isPerformingProgrammaticEdit = false
            needsTextStorageResync = false
            pendingNonWrappingLineBreakDelta = 0
            pendingNonWrappingLayoutReconciliation = nil
            stabilizeDocumentLayout()
            editorDelegate?.textViewDidChange(self)
            editorDelegate?.textViewDidChangeSelection(self)
        }
    }

    /// A Boolean value that indicates whether the text view is editable.
    public var isEditable: Bool {
        get {
            textView.isEditable
        }
        set {
            textView.isEditable = newValue
        }
    }

    /// A Boolean value that indicates whether the text view is selectable.
    public var isSelectable: Bool {
        get {
            textView.isSelectable
        }
        set {
            textView.isSelectable = newValue
        }
    }

    /// Colors and fonts to be used by the editor.
    public var theme: Theme {
        didSet {
            apply(theme: theme)
        }
    }

    /// The color of the insertion point.
    public var insertionPointColor: NSColor {
        get {
            textView.insertionPointColor
        }
        set {
            textView.insertionPointColor = newValue
        }
    }

    /// The color of the selection bar.
    public var selectionBarColor: NSColor {
        get {
            _selectionBarColor
        }
        set {
            _selectionBarColor = newValue
            textView.insertionPointColor = newValue
        }
    }

    /// The color of the selection highlight.
    public var selectionHighlightColor: NSColor {
        get {
            _selectionHighlightColor
        }
        set {
            _selectionHighlightColor = newValue
            applySelectionHighlightColorIfPossible()
        }
    }

    /// The current selection range of the text view.
    public var selectedRange: NSRange {
        get {
            textView.selectedRange()
        }
        set {
            let safeRange = clamped(range: newValue)
            textView.setSelectedRange(safeRange)
            editorDelegate?.textViewDidChangeSelection(self)
        }
    }

    /// Handles URLs activated through link interaction in the text view.
    public var openURLHandler: (URL) -> Bool = { url in
        NSWorkspace.shared.open(url)
    }

    /// Provides the modifier flags for the current event when handling link activation.
    public var currentEventModifierFlagsProvider: () -> NSEvent.ModifierFlags = {
        NSApp.currentEvent?.modifierFlags ?? []
    }

    /// Returns the undo manager used by the text view.
    override public var undoManager: UndoManager? {
        super.undoManager
    }

    /// Whether line numbers should be shown.
    public var showLineNumbers = false {
        didSet {
            updateGutterMetrics()
        }
    }

    /// Leading padding in the gutter area.
    public var gutterLeadingPadding: CGFloat = 0 {
        didSet {
            updateGutterMetrics()
        }
    }

    /// Trailing padding in the gutter area.
    public var gutterTrailingPadding: CGFloat = 0 {
        didSet {
            updateGutterMetrics()
        }
    }

    /// Computed gutter width.
    public private(set) var gutterWidth: CGFloat = 0

    /// Whether line wrapping is enabled.
    public var isLineWrappingEnabled = false {
        didSet {
            updateLineWrapping()
        }
    }

    /// Wrapping mode used when line wrapping is enabled.
    public var lineBreakMode: LineBreakMode = .byWordWrapping {
        didSet {
            updateLineWrapping()
        }
    }

    /// Whether page guide should be shown.
    public var showPageGuide = false

    /// Page guide column when page guide is visible.
    public var pageGuideColumn = 80

    /// Line endings to insert on line break operations.
    public var lineEndings: LineEnding = .lf
    /// Strategy to use when indenting text.
    public var indentStrategy: IndentStrategy = .space(length: 4)

    /// Underlying native text view.
    public let textView: NSTextView

    private struct PendingNonWrappingLayoutReconciliation {
        let beforeLocalHeight: CGFloat
        let beforeLineBreakCount: Int
        let afterLocationHint: Int
        let extraContextLines: Int
        var appliedEstimatedHeightDelta: CGFloat
    }

    private let textStorage = NSMutableString()
    private var isPerformingProgrammaticEdit = false
    private var needsTextStorageResync = false
    private var needsDocumentLayoutStabilizationAfterEdit = false
    private var pendingNonWrappingLineBreakDelta = 0
    private var pendingNonWrappingLayoutReconciliation: PendingNonWrappingLayoutReconciliation?
    private var lastNativeEditDate = Date.distantPast
    private var liveResizeAnchorOrigin: NSPoint?
    private var observedUndoManager: UndoManager?
    private var willUndoObserver: NSObjectProtocol?
    private var willRedoObserver: NSObjectProtocol?
    private var undoObserver: NSObjectProtocol?
    private var redoObserver: NSObjectProtocol?
    private var undoRedoSequence = 0
    private var enterTraceSequence = 0
    private var activeEnterTraceSequence: Int?
    private var lastEnterTraceDate = Date.distantPast
    private var _selectionBarColor: NSColor
    private var _selectionHighlightColor: NSColor

    public override init(frame frameRect: NSRect) {
        let defaultTheme = DefaultTheme()
        self.theme = defaultTheme
        self._selectionBarColor = defaultTheme.textColor
        self._selectionHighlightColor = defaultTheme.markedTextBackgroundColor.withAlphaComponent(0.45)

        let contentSize = frameRect.size
        let textView = NativeTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: max(contentSize.height, 1))
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.layoutManager?.allowsNonContiguousLayout = false
        if let textContainer = textView.textContainer {
            textContainer.heightTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        self.textView = textView
        super.init(frame: frameRect)
        textView.hostingTextView = self

        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        drawsBackground = true
        documentView = textView

        self.textView.delegate = self
        apply(theme: defaultTheme)
        updateGutterMetrics()
        updateLineWrapping()
        text = ""
        attachUndoObserversIfNeeded()
    }

    required public init?(coder: NSCoder) {
        let defaultTheme = DefaultTheme()
        self.theme = defaultTheme
        self._selectionBarColor = defaultTheme.textColor
        self._selectionHighlightColor = defaultTheme.markedTextBackgroundColor.withAlphaComponent(0.45)
        let textView = NativeTextView(frame: .zero)
        textView.minSize = NSSize(width: 0, height: 1)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        self.textView = textView
        super.init(coder: coder)
        textView.hostingTextView = self

        documentView = textView
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = true
        drawsBackground = true

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.layoutManager?.allowsNonContiguousLayout = false
        if let textContainer = textView.textContainer {
            textContainer.heightTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.delegate = self
        apply(theme: defaultTheme)
        updateGutterMetrics()
        updateLineWrapping()
        text = ""
        attachUndoObserversIfNeeded()
    }

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachUndoObserversIfNeeded()
        applySelectionHighlightColorIfPossible()
    }

    open override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeAnchorOrigin = contentView.bounds.origin
    }

    open override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        maintainLiveResizeAnchorIfNeeded(force: true)
        liveResizeAnchorOrigin = nil
    }

    open override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        maintainLiveResizeAnchorIfNeeded(force: false)
    }

    deinit {
        detachUndoObservers()
    }

    /// Returns the text location for the specified character location.
    public func textLocation(at location: Int) -> TextLocation? {
        ensureSynchronizedShadowTextStorageIfNeeded()
        guard location >= 0, location <= textStorage.length else {
            return nil
        }
        return textLocationUnchecked(at: location)
    }

    /// Returns the character location for the specified text location.
    public func location(at textLocation: TextLocation) -> Int? {
        ensureSynchronizedShadowTextStorageIfNeeded()
        guard textLocation.lineNumber >= 0, textLocation.column >= 0 else {
            return nil
        }
        let lineRanges = allLineRanges()
        guard textLocation.lineNumber < lineRanges.count else {
            return nil
        }
        let lineRange = lineRanges[textLocation.lineNumber]
        let lineLength = trimmedLineLength(for: lineRange)
        guard textLocation.column <= lineLength else {
            return nil
        }
        return lineRange.location + textLocation.column
    }

    /// Inserts text at the current selection.
    open func insertText(_ text: String) {
        ensureSynchronizedShadowTextStorageIfNeeded()
        replace(selectedRange, withText: text)
    }

    /// Replaces text in the specified range.
    public func replace(_ range: NSRange, withText replacementText: String) {
        ensureSynchronizedShadowTextStorageIfNeeded()
        _ = applyReplacement(in: range, withText: replacementText, respectDelegate: true)
    }

    /// Replaces text for all ranges in the replacement set.
    public func replaceText(in batchReplaceSet: BatchReplaceSet) {
        ensureSynchronizedShadowTextStorageIfNeeded()
        let orderedReplacements = batchReplaceSet.replacements.sorted { lhs, rhs in
            lhs.range.location > rhs.range.location
        }
        for replacement in orderedReplacements {
            replace(replacement.range, withText: replacement.text)
        }
    }

    /// Deletes backwards from the insertion point.
    public func deleteBackward() {
        ensureSynchronizedShadowTextStorageIfNeeded()
        let selection = selectedRange
        if selection.length > 0 {
            replace(selection, withText: "")
        } else if selection.location > 0 {
            replace(NSRange(location: selection.location - 1, length: 1), withText: "")
        }
    }

    /// Returns text in the specified range.
    public func text(in range: NSRange) -> String? {
        ensureSynchronizedShadowTextStorageIfNeeded()
        guard isValid(range: range) else {
            return nil
        }
        return textStorage.substring(with: range)
    }

    /// Decreases the indentation level of the selected lines.
    public func shiftLeft() {
        ensureSynchronizedShadowTextStorageIfNeeded()
        let originalSelection = selectedRange
        let lineRanges = selectedLineRanges(for: originalSelection)
        guard !lineRanges.isEmpty else {
            return
        }

        var totalRemoved = 0
        var firstLineRemoved = 0
        var locationOffset = 0
        for (index, lineRange) in lineRanges.enumerated() {
            let location = lineRange.location - locationOffset
            let currentLineRange = lineRangeContainingLocation(location)
            let lineText = textStorage.substring(with: currentLineRange)
            let removalLength = leadingIndentRemovalLength(in: lineText)
            guard removalLength > 0 else {
                continue
            }
            let removalRange = NSRange(location: location, length: removalLength)
            if applyReplacement(in: removalRange, withText: "", respectDelegate: true) {
                totalRemoved += removalLength
                locationOffset += removalLength
                if index == 0 {
                    firstLineRemoved = removalLength
                }
            }
        }

        let newLocation = max(0, originalSelection.location - firstLineRemoved)
        let newLength: Int
        if originalSelection.length == 0 {
            newLength = 0
        } else {
            newLength = max(0, originalSelection.length - totalRemoved)
        }
        selectedRange = NSRange(location: newLocation, length: newLength)
    }

    /// Increases the indentation level of the selected lines.
    public func shiftRight() {
        ensureSynchronizedShadowTextStorageIfNeeded()
        let originalSelection = selectedRange
        let lineRanges = selectedLineRanges(for: originalSelection)
        guard !lineRanges.isEmpty else {
            return
        }

        let indentString = indentationString()
        let indentLength = (indentString as NSString).length
        var offset = 0
        for lineRange in lineRanges {
            let insertionRange = NSRange(location: lineRange.location + offset, length: 0)
            if applyReplacement(in: insertionRange, withText: indentString, respectDelegate: true) {
                offset += indentLength
            }
        }

        let newLocation = originalSelection.location + indentLength
        let newLength: Int
        if originalSelection.length == 0 {
            newLength = 0
        } else {
            newLength = originalSelection.length + lineRanges.count * indentLength
        }
        selectedRange = NSRange(location: newLocation, length: newLength)
    }

    /// Moves the selected lines up by one line.
    public func moveSelectedLinesUp() {
        ensureSynchronizedShadowTextStorageIfNeeded()
        moveSelectedLines(by: -1)
    }

    /// Moves the selected lines down by one line.
    public func moveSelectedLinesDown() {
        ensureSynchronizedShadowTextStorageIfNeeded()
        moveSelectedLines(by: 1)
    }

    /// Attempts to detect the indentation strategy used in the current text.
    public func detectIndentStrategy() -> DetectedIndentStrategy {
        ensureSynchronizedShadowTextStorageIfNeeded()
        let lines = (textStorage as String).components(separatedBy: .newlines).prefix(200)
        var tabIndentedLines = 0
        var spaceIndentCount: [Int: Int] = [:]

        for line in lines {
            if line.hasPrefix("\t") {
                tabIndentedLines += 1
                continue
            }
            let leadingSpaces = line.prefix { $0 == " " }.count
            if leadingSpaces > 0 {
                spaceIndentCount[leadingSpaces, default: 0] += 1
            }
        }

        if tabIndentedLines == 0 && spaceIndentCount.isEmpty {
            return .unknown
        }

        let spaceLineCount = spaceIndentCount.values.reduce(0, +)
        if tabIndentedLines >= spaceLineCount {
            return .tab
        } else if let mostCommonSpaceLength = spaceIndentCount.max(by: { lhs, rhs in lhs.value < rhs.value })?.key {
            return .space(length: mostCommonSpaceLength)
        } else {
            return .unknown
        }
    }

    /// Performs text search.
    public func search(for query: SearchQuery) -> [SearchResult] {
        ensureSynchronizedShadowTextStorageIfNeeded()
        guard !query.text.isEmpty else {
            return []
        }
        guard let regex = regularExpression(for: query) else {
            return []
        }
        let searchRange = query.range ?? NSRange(location: 0, length: textStorage.length)
        let matches = regex.matches(in: textStorage as String, range: searchRange)
        return matches.compactMap { match in
            guard match.range.length > 0 else {
                return nil
            }
            guard let start = textLocation(at: match.range.location),
                  let end = textLocation(at: match.range.location + match.range.length) else {
                return nil
            }
            return SearchResult(range: match.range, startLocation: start, endLocation: end)
        }
    }

    /// Performs text search and expands replacement text for each result.
    public func search(for query: SearchQuery, replacingMatchesWith replacementString: String) -> [SearchReplaceResult] {
        ensureSynchronizedShadowTextStorageIfNeeded()
        guard !query.text.isEmpty else {
            return []
        }
        guard let regex = regularExpression(for: query) else {
            return []
        }
        let searchRange = query.range ?? NSRange(location: 0, length: textStorage.length)
        let matches = regex.matches(in: textStorage as String, range: searchRange)
        return matches.compactMap { match in
            guard match.range.length > 0 else {
                return nil
            }
            let replacementText = regex.replacementString(for: match, in: textStorage as String, offset: 0, template: replacementString)
            guard let start = textLocation(at: match.range.location),
                  let end = textLocation(at: match.range.location + match.range.length) else {
                return nil
            }
            return SearchReplaceResult(
                range: match.range,
                startLocation: start,
                endLocation: end,
                replacementText: replacementText
            )
        }
    }

    /// Go to the beginning of the line at the specified index.
    ///
    /// - Parameter lineIndex: Zero-based index of line to navigate to.
    /// - Parameter selection: The placement of the caret on the line.
    /// - Returns: True if the text view could navigate to the specified line index, otherwise false.
    @discardableResult
    public func goToLine(_ lineIndex: Int, select selection: GoToLineSelection = .beginning) -> Bool {
        ensureSynchronizedShadowTextStorageIfNeeded()
        guard lineIndex >= 0 else {
            return false
        }
        let lineRanges = allLineRanges()
        guard lineIndex < lineRanges.count else {
            return false
        }
        let lineRange = lineRanges[lineIndex]
        switch selection {
        case .beginning:
            selectedRange = NSRange(location: lineRange.location, length: 0)
        case .line:
            selectedRange = NSRange(location: lineRange.location, length: trimmedLineLength(for: lineRange))
        case .end:
            selectedRange = NSRange(location: lineRange.location + trimmedLineLength(for: lineRange), length: 0)
        }
        scrollRangeToVisible(selectedRange)
        return true
    }

    /// Scrolls so the given range is visible.
    public func scrollRangeToVisible(_ range: NSRange) {
        ensureSynchronizedShadowTextStorageIfNeeded()
        let safeRange = clamped(range: range)
        if !scrollRangeToVisibleMinimally(safeRange, from: contentView.bounds.origin) {
            textView.scrollRangeToVisible(safeRange)
        }
    }

    fileprivate func scrollRangeToVisibleMinimallyFromNative(_ range: NSRange) -> Bool {
        let nativeLength = (textView.string as NSString).length
        let safeRange = clamped(range: range, upperBound: nativeLength)
        return scrollRangeToVisibleMinimally(safeRange, from: contentView.bounds.origin)
    }

    fileprivate func constrainPostEnterScroll(previousOrigin: NSPoint) {
        let selection = textView.selectedRange()
        let currentOrigin = contentView.bounds.origin
        guard let targetOrigin = minimalScrollOriginToReveal(selection, from: previousOrigin) else {
            debugEnterShiftLog(
                "postEnter.noTarget seq=\(currentEnterTraceSequence) " +
                "selection=\(selection.location):\(selection.length) " +
                "prevY=\(formatDebug(previousOrigin.y)) curY=\(formatDebug(currentOrigin.y))"
            )
            return
        }
        debugEnterShiftLog(
            "postEnter.begin seq=\(currentEnterTraceSequence) " +
            "selection=\(selection.location):\(selection.length) " +
            "prevY=\(formatDebug(previousOrigin.y)) curY=\(formatDebug(currentOrigin.y)) " +
            "targetY=\(formatDebug(targetOrigin.y))"
        )
        guard abs(currentOrigin.x - targetOrigin.x) >= 0.5 ||
                abs(currentOrigin.y - targetOrigin.y) >= 0.5 else {
            debugEnterShiftLog(
                "postEnter.skip seq=\(currentEnterTraceSequence) " +
                "curY=\(formatDebug(currentOrigin.y)) targetY=\(formatDebug(targetOrigin.y))"
            )
            return
        }
        contentView.scroll(to: targetOrigin)
        reflectScrolledClipView(contentView)
        debugEnterShiftLog(
            "postEnter.end seq=\(currentEnterTraceSequence) endY=\(formatDebug(contentView.bounds.origin.y))"
        )
    }

    /// Ensures the document view frame matches the fully laid out text geometry.
    public func stabilizeDocumentLayout(preserveScrollOrigin: Bool = false, anchorOrigin: NSPoint? = nil) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let started = CFAbsoluteTimeGetCurrent()
        let preservedOrigin = anchorOrigin ?? (preserveScrollOrigin ? contentView.bounds.origin : nil)
        let previousSize = textView.frame.size
        let previousOrigin = contentView.bounds.origin
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let inset = textView.textContainerInset
        let targetHeight = max(contentView.bounds.height, ceil(usedRect.height + (inset.height * 2)))
        let targetWidth: CGFloat
        if textContainer.widthTracksTextView {
            targetWidth = max(contentView.bounds.width, textView.frame.width)
        } else {
            targetWidth = max(contentView.bounds.width, ceil(usedRect.width + (inset.width * 2)))
        }

        let targetSize = NSSize(width: targetWidth, height: targetHeight)
        debugEnterShiftLog(
            "stabilize.begin seq=\(currentEnterTraceSequence) " +
            "preserve=\(preserveScrollOrigin) anchorY=\(formatDebug(preservedOrigin?.y ?? -1)) " +
            "prevDocH=\(formatDebug(previousSize.height)) usedH=\(formatDebug(usedRect.height)) " +
            "targetDocH=\(formatDebug(targetHeight)) prevY=\(formatDebug(previousOrigin.y))"
        )
        if textView.frame.size != targetSize {
            textView.setFrameSize(targetSize)
        }
        if let preservedOrigin {
            restoreScrollOriginIfNeeded(preservedOrigin)
        }
        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        debugEnterShiftLog(
            "stabilize.end seq=\(currentEnterTraceSequence) " +
            "elapsedMS=\(formatDebug(elapsedMS)) docH=\(formatDebug(textView.frame.height)) " +
            "y=\(formatDebug(contentView.bounds.origin.y))"
        )
        let sizeChanged = abs(previousSize.height - targetSize.height) >= 0.5 || abs(previousSize.width - targetSize.width) >= 0.5
        if Self.debugLagTraceEnabled && (elapsedMS >= 4 || sizeChanged) {
            lagTrace(
                event: "stabilizeLayout",
                elapsedMS: elapsedMS,
                details:
                    "sizeChanged=\(sizeChanged) " +
                    "from=\(formatDebug(previousSize.width))x\(formatDebug(previousSize.height)) " +
                    "to=\(formatDebug(targetSize.width))x\(formatDebug(targetSize.height)) " +
                    "y=\(formatDebug(contentView.bounds.origin.y))"
            )
        }
    }

    /// Refreshes layout for the visible region without recomputing full document height.
    public func refreshVisibleLayout(preserveScrollOrigin: Bool = false) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let preservedOrigin = preserveScrollOrigin ? contentView.bounds.origin : nil
        let inset = textView.textContainerInset
        var visibleRect = contentView.bounds
        visibleRect.origin.x = 0
        visibleRect.origin.y = max(0, visibleRect.origin.y - (inset.height * 2))
        visibleRect.size.height += inset.height * 4

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange: NSRange
        if glyphRange.length > 0 {
            characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        } else {
            let selection = textView.selectedRange()
            characterRange = NSRange(location: selection.location, length: max(1, selection.length))
        }
        layoutManager.ensureLayout(forCharacterRange: characterRange)

        if let preservedOrigin {
            restoreScrollOriginIfNeeded(preservedOrigin)
        }
    }

    @discardableResult
    public func finalizePendingNonWrappingLayoutReconciliation(preserveScrollOrigin: Bool = false) -> Bool {
        consumePendingNonWrappingLayoutReconciliation(preserveScrollOrigin: preserveScrollOrigin)
    }
}

private extension TextView {
    func applySelectionHighlightColorIfPossible() {
        guard textView.window != nil else {
            return
        }
        var selectedTextAttributes = textView.selectedTextAttributes
        if let existingColor = selectedTextAttributes[.backgroundColor] as? NSColor,
           existingColor.isEqual(_selectionHighlightColor) {
            return
        }
        selectedTextAttributes[.backgroundColor] = _selectionHighlightColor
        textView.selectedTextAttributes = selectedTextAttributes
    }

    private func apply(theme: Theme) {
        textView.font = theme.font
        textView.textColor = theme.textColor
        textView.backgroundColor = theme.gutterBackgroundColor
        var typingAttributes = textView.typingAttributes
        typingAttributes[.font] = theme.font
        typingAttributes[.foregroundColor] = theme.textColor
        textView.typingAttributes = typingAttributes
        insertionPointColor = theme.textColor
        selectionBarColor = theme.textColor
        selectionHighlightColor = theme.markedTextBackgroundColor.withAlphaComponent(0.45)
    }

    @discardableResult
    private func applyReplacement(in range: NSRange, withText replacementText: String, respectDelegate: Bool) -> Bool {
        guard isValid(range: range) else {
            return false
        }
        let normalizedText = normalizeLineEndings(in: replacementText)
        let editAffectsDocumentLayout = editAffectsDocumentLayout(in: range, replacementText: normalizedText)
        let nonWrappingLineBreakDelta = lineBreakDelta(
            in: range,
            replacementText: normalizedText,
            currentText: textStorage
        )
        if editAffectsDocumentLayout {
            debugUndoLagLog(
                "edit.shouldChange range=\(range.location):\(range.length) " +
                "replacementLen=\((normalizedText as NSString).length) " +
                "selection=\(selectedRange.location):\(selectedRange.length) " +
                "nativeLen=\((textView.string as NSString).length)"
            )
        }
        if respectDelegate {
            let shouldChangeText = editorDelegate?.textView(self, shouldChangeTextIn: range, replacementText: normalizedText) ?? true
            guard shouldChangeText else {
                return false
            }
        }

        isPerformingProgrammaticEdit = true
        textStorage.replaceCharacters(in: range, with: normalizedText)
        textView.string = textStorage as String
        let selectedLocation = range.location + (normalizedText as NSString).length
        textView.setSelectedRange(NSRange(location: selectedLocation, length: 0))
        isPerformingProgrammaticEdit = false
        needsTextStorageResync = false
        pendingNonWrappingLayoutReconciliation = nil
        if editAffectsDocumentLayout {
            if isLineWrappingEnabled || !applyEstimatedNonWrappingDocumentHeightDelta(lineBreakDelta: nonWrappingLineBreakDelta) {
                stabilizeDocumentLayout(preserveScrollOrigin: true)
            }
            debugUndoLagLog(
                "edit.applied range=\(range.location):\(range.length) " +
                "replacementLen=\((normalizedText as NSString).length) " +
                "nativeLen=\((textView.string as NSString).length) " +
                "docH=\(formatDebug(textView.frame.height)) y=\(formatDebug(contentView.bounds.origin.y))"
            )
        }

        editorDelegate?.textViewDidChange(self)
        editorDelegate?.textViewDidChangeSelection(self)
        return true
    }

    private func isValid(range: NSRange) -> Bool {
        let upperBound = range.location + range.length
        return range.location >= 0 && range.length >= 0 && range.location <= textStorage.length && upperBound <= textStorage.length
    }

    private func clamped(range: NSRange) -> NSRange {
        let location = min(max(0, range.location), textStorage.length)
        let length = max(0, min(range.length, textStorage.length - location))
        return NSRange(location: location, length: length)
    }

    private func normalizeLineEndings(in text: String) -> String {
        guard text.contains("\n") || text.contains("\r") else {
            return text
        }
        let unifiedLineFeeds = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return unifiedLineFeeds.replacingOccurrences(of: "\n", with: lineEndings.symbol)
    }

    private func attachUndoObserversIfNeeded() {
        let currentUndoManager = textView.undoManager ?? super.undoManager
        guard observedUndoManager !== currentUndoManager else {
            return
        }
        detachUndoObservers()
        observedUndoManager = currentUndoManager
        guard let currentUndoManager else {
            return
        }
        undoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidUndoChange,
            object: currentUndoManager,
            queue: nil
        ) { [weak self] _ in
            self?.handleUndoRedoChange(kind: "undo")
        }
        willUndoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerWillUndoChange,
            object: currentUndoManager,
            queue: nil
        ) { [weak self] _ in
            self?.prepareUndoRedoLayoutReconciliation()
        }
        redoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerDidRedoChange,
            object: currentUndoManager,
            queue: nil
        ) { [weak self] _ in
            self?.handleUndoRedoChange(kind: "redo")
        }
        willRedoObserver = NotificationCenter.default.addObserver(
            forName: .NSUndoManagerWillRedoChange,
            object: currentUndoManager,
            queue: nil
        ) { [weak self] _ in
            self?.prepareUndoRedoLayoutReconciliation()
        }
    }

    private func ensureSynchronizedShadowTextStorageIfNeeded() {
        guard needsTextStorageResync else {
            return
        }
        _ = synchronizeShadowTextStorageIfNeeded(forceComparison: true)
    }

    private func detachUndoObservers() {
        if let willUndoObserver {
            NotificationCenter.default.removeObserver(willUndoObserver)
        }
        if let willRedoObserver {
            NotificationCenter.default.removeObserver(willRedoObserver)
        }
        if let undoObserver {
            NotificationCenter.default.removeObserver(undoObserver)
        }
        if let redoObserver {
            NotificationCenter.default.removeObserver(redoObserver)
        }
        willUndoObserver = nil
        willRedoObserver = nil
        undoObserver = nil
        redoObserver = nil
        observedUndoManager = nil
    }

    private func handleUndoRedoChange(kind: String) {
        undoRedoSequence += 1
        let currentSequence = undoRedoSequence
        let started = CFAbsoluteTimeGetCurrent()
        let beforeHeight = textView.frame.height
        let beforeOffset = contentView.bounds.origin.y
        let beforeSelection = textView.selectedRange()
        debugUndoLagLog(
            "\(kind).begin seq=\(currentSequence) " +
            "selection=\(beforeSelection.location):\(beforeSelection.length) " +
            "nativeLen=\((textView.string as NSString).length) " +
            "shadowLen=\(textStorage.length) " +
            "docH=\(formatDebug(beforeHeight)) y=\(formatDebug(beforeOffset))"
        )
        let didResync = synchronizeShadowTextStorageIfNeeded(forceComparison: true)
        let selectedRange = textView.selectedRange()
        if isLineWrappingEnabled {
            stabilizeDocumentLayout(preserveScrollOrigin: true)
        } else if didResync {
            let appliedEstimatedHeightDelta = applyEstimatedNonWrappingUndoRedoHeightDelta()
            pendingNonWrappingLayoutReconciliation?.appliedEstimatedHeightDelta = appliedEstimatedHeightDelta
            if !consumePendingNonWrappingLayoutReconciliation(preserveScrollOrigin: true) {
                stabilizeDocumentLayout(preserveScrollOrigin: true)
            }
        } else {
            pendingNonWrappingLayoutReconciliation = nil
        }
        _ = scrollRangeToVisibleMinimallyFromNative(selectedRange)
        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let afterSelection = selectedRange
        debugUndoLagLog(
            "\(kind).end seq=\(currentSequence) elapsedMS=\(formatDebug(elapsedMS)) " +
            "didResync=\(didResync) selection=\(afterSelection.location):\(afterSelection.length) " +
            "nativeLen=\((textView.string as NSString).length) shadowLen=\(textStorage.length) " +
            "docH=\(formatDebug(textView.frame.height)) y=\(formatDebug(contentView.bounds.origin.y))"
        )
        if didResync {
            editorDelegate?.textViewDidChange(self)
        }
        editorDelegate?.textViewDidChangeSelection(self)
    }

    @discardableResult
    private func synchronizeShadowTextStorageIfNeeded(forceComparison: Bool = false) -> Bool {
        let nativeText = textView.string
        if !forceComparison {
            let nativeLength = (nativeText as NSString).length
            guard nativeLength != textStorage.length else {
                return false
            }
        }
        guard forceComparison || nativeText != textStorage as String else {
            return false
        }
        textStorage.setString(nativeText)
        needsTextStorageResync = false
        return true
    }

    private func prepareUndoRedoLayoutReconciliation() {
        let selection = textView.selectedRange()
        preparePendingNonWrappingLayoutReconciliation(
            beforeLocation: selection.location,
            afterLocationHint: selection.location
        )
    }

    private func debugUndoLagLog(_ message: @autoclosure () -> String) {
        guard Self.debugUndoLagEnabled else {
            return
        }
        RunestoneDebugLog.write("[RunestoneUndo] \(message())")
    }

    private var currentEnterTraceSequence: Int {
        if let activeEnterTraceSequence,
           Date().timeIntervalSince(lastEnterTraceDate) <= 1.5 {
            return activeEnterTraceSequence
        }
        return -1
    }

    func beginEnterShiftTrace(previousOrigin: NSPoint) {
        guard Self.debugEnterShiftEnabled else {
            return
        }
        enterTraceSequence += 1
        activeEnterTraceSequence = enterTraceSequence
        lastEnterTraceDate = Date()
        let selection = textView.selectedRange()
        let caret = rectForSelectionRange(selection)
        debugEnterShiftLog(
            "enter.begin seq=\(enterTraceSequence) " +
            "selection=\(selection.location):\(selection.length) " +
            "prevY=\(formatDebug(previousOrigin.y)) docH=\(formatDebug(textView.frame.height)) " +
            "caretMinY=\(formatDebug(caret?.minY ?? -1)) caretMaxY=\(formatDebug(caret?.maxY ?? -1))"
        )
    }

    func finishEnterShiftTrace() {
        guard Self.debugEnterShiftEnabled else {
            return
        }
        let selection = textView.selectedRange()
        let caret = rectForSelectionRange(selection)
        debugEnterShiftLog(
            "enter.end seq=\(currentEnterTraceSequence) " +
            "selection=\(selection.location):\(selection.length) y=\(formatDebug(contentView.bounds.origin.y)) " +
            "docH=\(formatDebug(textView.frame.height)) " +
            "caretMinY=\(formatDebug(caret?.minY ?? -1)) caretMaxY=\(formatDebug(caret?.maxY ?? -1))"
        )
    }

    private func debugEnterShiftLog(_ message: @autoclosure () -> String) {
        guard Self.debugEnterShiftEnabled else {
            return
        }
        if let activeEnterTraceSequence,
           Date().timeIntervalSince(lastEnterTraceDate) > 1.5 {
            RunestoneDebugLog.write("[RunestoneEnter] traceExpired seq=\(activeEnterTraceSequence)")
            self.activeEnterTraceSequence = nil
        }
        RunestoneDebugLog.write("[RunestoneEnter] \(message())")
    }

    private func maintainLiveResizeAnchorIfNeeded(force: Bool) {
        guard force || inLiveResize,
              let documentView,
              let liveResizeAnchorOrigin else {
            return
        }

        let documentFrame = documentView.frame
        let clipBounds = contentView.bounds
        let maxX = max(0, documentFrame.width - clipBounds.width)
        let maxY = max(0, documentFrame.height - clipBounds.height)
        let anchoredOrigin = NSPoint(
            x: min(max(0, liveResizeAnchorOrigin.x), maxX),
            y: min(max(0, liveResizeAnchorOrigin.y), maxY)
        )
        let currentOrigin = clipBounds.origin
        guard abs(currentOrigin.x - anchoredOrigin.x) >= 0.5 ||
                abs(currentOrigin.y - anchoredOrigin.y) >= 0.5 else {
            return
        }

        contentView.scroll(to: anchoredOrigin)
        reflectScrolledClipView(contentView)
    }

    private func restoreScrollOriginIfNeeded(_ origin: NSPoint) {
        guard let documentView else {
            return
        }

        let documentFrame = documentView.frame
        let clipBounds = contentView.bounds
        let maxX = max(0, documentFrame.width - clipBounds.width)
        let maxY = max(0, documentFrame.height - clipBounds.height)
        let currentOrigin = clipBounds.origin
        let isActivelyEditingInTextView =
            (window?.firstResponder as AnyObject?) === textView &&
            Date().timeIntervalSince(lastNativeEditDate) < 0.4
        let targetY: CGFloat
        if isActivelyEditingInTextView {
            // Preserve current vertical position while typing to avoid fighting NSTextView's own minimal caret scrolling.
            targetY = min(max(0, currentOrigin.y), maxY)
        } else {
            targetY = min(max(0, origin.y), maxY)
        }
        let anchoredOrigin = NSPoint(
            x: min(max(0, origin.x), maxX),
            y: targetY
        )
        let xNeedsScrollRestore = abs(currentOrigin.x - anchoredOrigin.x) >= 0.5
        let yNeedsScrollRestore = abs(currentOrigin.y - anchoredOrigin.y) >= 2.0
        debugEnterShiftLog(
            "restore.evaluate seq=\(currentEnterTraceSequence) " +
            "activeEdit=\(isActivelyEditingInTextView) originY=\(formatDebug(origin.y)) " +
            "curY=\(formatDebug(currentOrigin.y)) targetY=\(formatDebug(anchoredOrigin.y)) " +
            "maxY=\(formatDebug(maxY)) yNeeds=\(yNeedsScrollRestore)"
        )
        guard xNeedsScrollRestore || yNeedsScrollRestore else {
            return
        }

        contentView.scroll(to: anchoredOrigin)
        reflectScrolledClipView(contentView)
        debugEnterShiftLog(
            "restore.end seq=\(currentEnterTraceSequence) endY=\(formatDebug(contentView.bounds.origin.y))"
        )
    }

    private func scrollRangeToVisibleMinimally(_ range: NSRange, from origin: NSPoint) -> Bool {
        guard let targetOrigin = minimalScrollOriginToReveal(range, from: origin) else {
            return false
        }
        let currentOrigin = contentView.bounds.origin
        guard abs(currentOrigin.x - targetOrigin.x) >= 0.5 ||
                abs(currentOrigin.y - targetOrigin.y) >= 0.5 else {
            return true
        }
        contentView.scroll(to: targetOrigin)
        reflectScrolledClipView(contentView)
        return true
    }

    private func minimalScrollOriginToReveal(_ range: NSRange, from origin: NSPoint) -> NSPoint? {
        guard let selectionRect = rectForSelectionRange(range) else {
            return nil
        }
        let normalizedOrigin = normalizedScrollOrigin(origin)
        let visibleRect = NSRect(origin: normalizedOrigin, size: contentView.bounds.size)
        let fontSize = textView.font?.pointSize ?? 14
        let horizontalPadding = max(6, floor(fontSize * 0.45))
        let verticalPadding = max(2, floor(fontSize * 0.35))

        var targetX = normalizedOrigin.x
        var targetY = normalizedOrigin.y

        if selectionRect.minX < visibleRect.minX + horizontalPadding {
            targetX = selectionRect.minX - horizontalPadding
        } else if selectionRect.maxX > visibleRect.maxX - horizontalPadding {
            targetX = selectionRect.maxX + horizontalPadding - visibleRect.width
        }

        if selectionRect.minY < visibleRect.minY + verticalPadding {
            targetY = selectionRect.minY - verticalPadding
        } else if selectionRect.maxY > visibleRect.maxY - verticalPadding {
            targetY = selectionRect.maxY + verticalPadding - visibleRect.height
        }

        return normalizedScrollOrigin(NSPoint(x: targetX, y: targetY))
    }

    private func normalizedScrollOrigin(_ origin: NSPoint) -> NSPoint {
        guard let documentView else {
            return origin
        }
        let documentFrame = documentView.frame
        let clipBounds = contentView.bounds
        let maxX = max(0, documentFrame.width - clipBounds.width)
        let maxY = max(0, documentFrame.height - clipBounds.height)
        return NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        )
    }

    private func rectForSelectionRange(_ range: NSRange) -> NSRect? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }

        let nativeTextLength = (textView.string as NSString).length
        let clampedRange = clamped(range: range, upperBound: nativeTextLength)
        if clampedRange.length == 0 {
            return caretRectForInsertionLocation(
                clampedRange.location,
                textLength: nativeTextLength,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
        }

        if nativeTextLength == 0 {
            return nil
        }

        let characterRange: NSRange
        characterRange = clampedRange

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound else {
            return nil
        }

        var selectionRect = layoutManager.boundingRect(
            forGlyphRange: glyphRange,
            in: textContainer
        )
        selectionRect.origin.x += textView.textContainerOrigin.x
        selectionRect.origin.y += textView.textContainerOrigin.y
        if selectionRect.height < 1 {
            selectionRect.size.height = max(1, textView.font?.pointSize ?? 1)
        }
        if selectionRect.width < 1 {
            selectionRect.size.width = 1
        }
        return selectionRect
    }

    private func caretRectForInsertionLocation(
        _ location: Int,
        textLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let clampedLocation = min(max(0, location), textLength)

        if clampedLocation == textLength,
           layoutManager.extraLineFragmentTextContainer === textContainer {
            let extraLineRect = layoutManager.extraLineFragmentRect
            if !extraLineRect.isEmpty {
                var caretRect = extraLineRect
                caretRect.origin.x += textView.textContainerOrigin.x
                caretRect.origin.y += textView.textContainerOrigin.y
                caretRect.size.width = max(1, caretRect.width)
                caretRect.size.height = max(1, caretRect.height)
                return caretRect
            }
        }

        guard textLength > 0 else {
            let fontSize = textView.font?.pointSize ?? 1
            return NSRect(
                x: textView.textContainerOrigin.x,
                y: textView.textContainerOrigin.y,
                width: 1,
                height: max(1, fontSize)
            )
        }

        let referenceLocation = min(clampedLocation, textLength - 1)
        let characterRange = NSRange(location: referenceLocation, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else {
            return nil
        }

        var caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        caretRect.origin.x += textView.textContainerOrigin.x
        caretRect.origin.y += textView.textContainerOrigin.y
        if clampedLocation > referenceLocation {
            caretRect.origin.x = caretRect.maxX
        }
        caretRect.size.width = 1
        if caretRect.height < 1 {
            caretRect.size.height = max(1, textView.font?.pointSize ?? 1)
        }
        return caretRect
    }

    private func formatDebug(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private func formatDebug(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func clamped(range: NSRange, upperBound: Int) -> NSRange {
        let location = min(max(0, range.location), upperBound)
        let length = max(0, min(range.length, upperBound - location))
        return NSRange(location: location, length: length)
    }

    private func lineBreakDelta(
        in range: NSRange,
        replacementText: String,
        currentText: NSString
    ) -> Int {
        let insertedLineBreaks = lineBreakCount(in: replacementText)
        let removedLineBreaks: Int
        if range.length > 0, isValid(range: range) {
            removedLineBreaks = lineBreakCount(in: currentText.substring(with: range))
        } else {
            removedLineBreaks = 0
        }
        return insertedLineBreaks - removedLineBreaks
    }

    private func lineBreakCount(in string: String) -> Int {
        lineBreakCount(in: string as NSString)
    }

    private func lineBreakCount(in string: NSString) -> Int {
        let nsString = string
        var count = 0
        var index = 0
        while index < nsString.length {
            let character = nsString.character(at: index)
            if character == 10 { // \n
                count += 1
            } else if character == 13 { // \r or \r\n
                count += 1
                if index + 1 < nsString.length, nsString.character(at: index + 1) == 10 {
                    index += 1
                }
            }
            index += 1
        }
        return count
    }

    @discardableResult
    private func applyEstimatedNonWrappingDocumentHeightDelta(lineBreakDelta: Int) -> Bool {
        applyEstimatedNonWrappingDocumentHeightDeltaValue(lineBreakDelta: lineBreakDelta) != 0
    }

    @discardableResult
    private func applyEstimatedNonWrappingDocumentHeightDeltaValue(lineBreakDelta: Int) -> CGFloat {
        guard !isLineWrappingEnabled,
              lineBreakDelta != 0 else {
            return 0
        }
        let estimatedLineHeight = max(
            1,
            rectForSelectionRange(textView.selectedRange())?.height ??
                textView.font.flatMap { textView.layoutManager?.defaultLineHeight(for: $0) } ??
                0
        )
        let currentHeight = textView.frame.height
        let targetHeight = max(
            contentView.bounds.height,
            currentHeight + (CGFloat(lineBreakDelta) * estimatedLineHeight)
        )
        let appliedDelta = targetHeight - currentHeight
        guard abs(appliedDelta) >= 0.5 else {
            return 0
        }
        textView.setFrameSize(NSSize(width: textView.frame.width, height: targetHeight))
        debugEnterShiftLog(
            "nonWrapHeightDelta seq=\(currentEnterTraceSequence) " +
            "lineBreakDelta=\(lineBreakDelta) lineHeight=\(formatDebug(estimatedLineHeight)) " +
            "from=\(formatDebug(currentHeight)) to=\(formatDebug(targetHeight))"
        )
        return appliedDelta
    }

    private func preparePendingNonWrappingLayoutReconciliation(
        beforeLocation: Int,
        afterLocationHint: Int,
        extraContextLines: Int = 6
    ) {
        guard !isLineWrappingEnabled,
              let beforeLocalHeight = captureLocalLayoutHeight(
                around: beforeLocation,
                extraLines: extraContextLines
              ) else {
            pendingNonWrappingLayoutReconciliation = nil
            return
        }
        pendingNonWrappingLayoutReconciliation = PendingNonWrappingLayoutReconciliation(
            beforeLocalHeight: beforeLocalHeight,
            beforeLineBreakCount: lineBreakCount(in: textView.string as NSString),
            afterLocationHint: afterLocationHint,
            extraContextLines: extraContextLines,
            appliedEstimatedHeightDelta: 0
        )
    }

    private func applyEstimatedNonWrappingUndoRedoHeightDelta() -> CGFloat {
        guard let pendingNonWrappingLayoutReconciliation else {
            return 0
        }
        let currentLineBreakCount = lineBreakCount(in: textView.string as NSString)
        return applyEstimatedNonWrappingDocumentHeightDeltaValue(
            lineBreakDelta: currentLineBreakCount - pendingNonWrappingLayoutReconciliation.beforeLineBreakCount
        )
    }

    @discardableResult
    func consumePendingNonWrappingLayoutReconciliation(preserveScrollOrigin: Bool) -> Bool {
        guard let pendingNonWrappingLayoutReconciliation else {
            return false
        }
        defer { self.pendingNonWrappingLayoutReconciliation = nil }

        let nativeLength = (textView.string as NSString).length
        let selectedLocation = textView.selectedRange().location
        let afterLocation = min(
            max(
                0,
                selectedLocation == NSNotFound ? pendingNonWrappingLayoutReconciliation.afterLocationHint : selectedLocation
            ),
            nativeLength
        )
        guard let afterLocalHeight = captureLocalLayoutHeight(
            around: afterLocation,
            extraLines: pendingNonWrappingLayoutReconciliation.extraContextLines
        ) else {
            return false
        }

        let correction =
            (afterLocalHeight - pendingNonWrappingLayoutReconciliation.beforeLocalHeight) -
            pendingNonWrappingLayoutReconciliation.appliedEstimatedHeightDelta
        guard abs(correction) >= 0.5 else {
            return true
        }

        let preservedOrigin = preserveScrollOrigin ? contentView.bounds.origin : nil
        let currentHeight = textView.frame.height
        let targetHeight = max(contentView.bounds.height, currentHeight + correction)
        guard abs(targetHeight - currentHeight) >= 0.5 else {
            return true
        }

        textView.setFrameSize(NSSize(width: textView.frame.width, height: targetHeight))
        if let preservedOrigin {
            restoreScrollOriginIfNeeded(preservedOrigin)
        }
        if Self.debugLagTraceEnabled {
            lagTrace(
                event: "localHeightReconcile",
                details:
                    "before=\(formatDebug(pendingNonWrappingLayoutReconciliation.beforeLocalHeight)) " +
                    "after=\(formatDebug(afterLocalHeight)) " +
                    "estimated=\(formatDebug(pendingNonWrappingLayoutReconciliation.appliedEstimatedHeightDelta)) " +
                    "correction=\(formatDebug(correction)) " +
                    "target=\(formatDebug(targetHeight))"
            )
        }
        return true
    }

    private func captureLocalLayoutHeight(around location: Int, extraLines: Int) -> CGFloat? {
        guard let layoutManager = textView.layoutManager,
              textView.textContainer != nil else {
            return nil
        }

        let nativeText = textView.string as NSString
        guard nativeText.length > 0 else {
            return 0
        }

        let characterRange = expandedNativeLineRange(
            around: location,
            extraLines: extraLines,
            text: nativeText
        )
        guard characterRange.length > 0 else {
            return 0
        }

        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.location != NSNotFound else {
            return nil
        }

        var unionRect = NSRect.null
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineFragmentRect, _, _, _, _ in
            unionRect = unionRect.isNull ? lineFragmentRect : unionRect.union(lineFragmentRect)
        }
        if unionRect.isNull {
            return rectForSelectionRange(NSRange(location: min(characterRange.location, nativeText.length), length: 0))?.height
        }
        return unionRect.height
    }

    private func expandedNativeLineRange(
        around location: Int,
        extraLines: Int,
        text: NSString
    ) -> NSRange {
        guard text.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let anchorLocation = min(max(0, location), max(0, text.length - 1))
        var startLocation = text.lineRange(for: NSRange(location: anchorLocation, length: 0)).location
        for _ in 0..<extraLines {
            guard startLocation > 0 else {
                break
            }
            startLocation = text.lineRange(for: NSRange(location: startLocation - 1, length: 0)).location
        }

        var endRange = text.lineRange(for: NSRange(location: anchorLocation, length: 0))
        var endLocation = endRange.location + endRange.length
        for _ in 0..<extraLines {
            guard endLocation < text.length else {
                break
            }
            endRange = text.lineRange(for: NSRange(location: endLocation, length: 0))
            endLocation = endRange.location + endRange.length
        }

        return NSRange(location: startLocation, length: endLocation - startLocation)
    }

    private func editAffectsDocumentLayout(in range: NSRange, replacementText: String) -> Bool {
        if isLineWrappingEnabled {
            return true
        }
        if replacementText.contains("\n") || replacementText.contains("\r") {
            return true
        }
        guard range.length > 0, isValid(range: range) else {
            return false
        }
        let removedText = textStorage.substring(with: range)
        return removedText.contains("\n") || removedText.contains("\r")
    }

    private func regularExpression(for query: SearchQuery) -> NSRegularExpression? {
        let pattern: String
        switch query.matchMethod {
        case .contains:
            pattern = NSRegularExpression.escapedPattern(for: query.text)
        case .fullWord:
            pattern = "\\b" + NSRegularExpression.escapedPattern(for: query.text) + "\\b"
        case .startsWith:
            pattern = "\\b" + NSRegularExpression.escapedPattern(for: query.text)
        case .endsWith:
            pattern = NSRegularExpression.escapedPattern(for: query.text) + "\\b"
        case .regularExpression:
            pattern = query.text
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !query.isCaseSensitive {
            options.insert(.caseInsensitive)
        }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    private func textLocationUnchecked(at location: Int) -> TextLocation {
        let safeLocation = min(max(0, location), textStorage.length)
        var row = 0
        var column = 0
        var index = 0
        while index < safeLocation {
            let character = textStorage.character(at: index)
            if character == 10 { // \n
                row += 1
                column = 0
            } else if character == 13 { // \r
                if index + 1 < safeLocation && textStorage.character(at: index + 1) == 10 {
                    index += 1
                }
                row += 1
                column = 0
            } else {
                column += 1
            }
            index += 1
        }
        return TextLocation(lineNumber: row, column: column)
    }

    private func allLineRanges() -> [NSRange] {
        let nsString = textStorage as NSString
        guard nsString.length > 0 else {
            return [NSRange(location: 0, length: 0)]
        }

        var ranges: [NSRange] = []
        var currentLocation = 0
        while currentLocation < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: currentLocation, length: 0))
            ranges.append(lineRange)
            currentLocation = lineRange.location + lineRange.length
        }
        return ranges
    }

    private func selectedLineRanges(for selectedRange: NSRange) -> [NSRange] {
        let lineRanges = allLineRanges()
        guard !lineRanges.isEmpty else {
            return []
        }

        let nsString = textStorage as NSString
        let maxLocation = max(0, nsString.length - 1)
        let safeStart = min(max(0, selectedRange.location), nsString.length)
        let safeEnd: Int
        if selectedRange.length > 0 {
            safeEnd = min(max(safeStart, selectedRange.location + selectedRange.length - 1), maxLocation)
        } else {
            safeEnd = min(safeStart, maxLocation)
        }

        let startRange = nsString.lineRange(for: NSRange(location: safeStart, length: 0))
        let endRange = nsString.lineRange(for: NSRange(location: safeEnd, length: 0))
        guard let startIndex = lineRanges.firstIndex(of: startRange),
              let endIndex = lineRanges.firstIndex(of: endRange),
              startIndex <= endIndex else {
            return [lineRanges[0]]
        }
        return Array(lineRanges[startIndex ... endIndex])
    }

    private func lineRangeContainingLocation(_ location: Int) -> NSRange {
        let safeLocation = min(max(0, location), textStorage.length)
        let nsString = textStorage as NSString
        return nsString.lineRange(for: NSRange(location: safeLocation, length: 0))
    }

    private func leadingIndentRemovalLength(in lineText: String) -> Int {
        switch indentStrategy {
        case .tab:
            return lineText.hasPrefix("\t") ? 1 : 0
        case .space(let length):
            let desiredLength = max(1, length)
            let leadingSpaces = lineText.prefix { $0 == " " }.count
            return min(desiredLength, leadingSpaces)
        }
    }

    private func indentationString() -> String {
        switch indentStrategy {
        case .tab:
            return "\t"
        case .space(let length):
            return String(repeating: " ", count: max(1, length))
        }
    }

    private func moveSelectedLines(by lineOffset: Int) {
        let originalSelection = selectedRange
        let selectedLines = selectedLineRanges(for: originalSelection)
        guard let firstLine = selectedLines.first, let lastLine = selectedLines.last else {
            return
        }

        let lineRanges = allLineRanges()
        guard let firstLineIndex = lineRanges.firstIndex(of: firstLine),
              let lastLineIndex = lineRanges.firstIndex(of: lastLine) else {
            return
        }

        let blockLocation = firstLine.location
        let blockLength = (lastLine.location + lastLine.length) - firstLine.location
        let blockRange = NSRange(location: blockLocation, length: blockLength)
        guard let blockText = text(in: blockRange) else {
            return
        }

        if lineOffset < 0 {
            guard firstLineIndex > 0 else {
                return
            }
            let previousLineRange = lineRanges[firstLineIndex - 1]
            guard let previousLineText = text(in: previousLineRange) else {
                return
            }
            let replacementRange = NSRange(location: previousLineRange.location, length: previousLineRange.length + blockRange.length)
            let replacementText = blockText + previousLineText
            let newSelection = NSRange(location: max(0, originalSelection.location - previousLineRange.length), length: originalSelection.length)
            if applyReplacement(in: replacementRange, withText: replacementText, respectDelegate: true) {
                selectedRange = newSelection
            }
        } else if lineOffset > 0 {
            guard lastLineIndex + 1 < lineRanges.count else {
                return
            }
            let nextLineRange = lineRanges[lastLineIndex + 1]
            guard let nextLineText = text(in: nextLineRange) else {
                return
            }
            let replacementRange = NSRange(location: blockRange.location, length: blockRange.length + nextLineRange.length)
            let replacementText = nextLineText + blockText
            let newSelection = NSRange(location: originalSelection.location + nextLineRange.length, length: originalSelection.length)
            if applyReplacement(in: replacementRange, withText: replacementText, respectDelegate: true) {
                selectedRange = newSelection
            }
        }
    }

    private func trimmedLineLength(for lineRange: NSRange) -> Int {
        guard lineRange.length > 0 else {
            return 0
        }
        let lineText = textStorage.substring(with: lineRange)
        if lineText.hasSuffix("\r\n") {
            return lineRange.length - 2
        } else if lineText.hasSuffix("\n") || lineText.hasSuffix("\r") {
            return lineRange.length - 1
        } else {
            return lineRange.length
        }
    }

    private func updateGutterMetrics() {
        if showLineNumbers {
            gutterWidth = max(0, gutterLeadingPadding + gutterTrailingPadding + 28)
        } else {
            gutterWidth = 0
        }
    }

    private func updateLineWrapping() {
        guard let textContainer = textView.textContainer else {
            return
        }

        textContainer.lineBreakMode = nsLineBreakMode(for: lineBreakMode)
        textView.isVerticallyResizable = true
        textContainer.heightTracksTextView = false
        if isLineWrappingEnabled {
            textView.isHorizontallyResizable = false
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textContainer.widthTracksTextView = false
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            hasHorizontalScroller = true
        }
        stabilizeDocumentLayout()
    }

    private func nsLineBreakMode(for mode: LineBreakMode) -> NSLineBreakMode {
        switch mode {
        case .byWordWrapping:
            return .byWordWrapping
        case .byCharWrapping:
            return .byCharWrapping
        }
    }
}

extension TextView: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        if !isPerformingProgrammaticEdit {
            let started = CFAbsoluteTimeGetCurrent()
            lastNativeEditDate = Date()
            let didExpectNativeMutation = needsTextStorageResync
            needsTextStorageResync = true
            let nativeTextLength = (textView.string as NSString).length
            let shadowTextLength = textStorage.length
            let nativeEditAffectsLayout =
                needsDocumentLayoutStabilizationAfterEdit ||
                (
                    isLineWrappingEnabled &&
                    (
                        !didExpectNativeMutation ||
                            nativeTextLength != shadowTextLength
                    )
                )
            let didResyncDirectMutation: Bool
            if didExpectNativeMutation {
                didResyncDirectMutation = false
            } else {
                didResyncDirectMutation = synchronizeShadowTextStorageIfNeeded(forceComparison: true)
            }
            if nativeEditAffectsLayout {
                let selection = textView.selectedRange()
                debugEnterShiftLog(
                    "textDidChange.begin seq=\(currentEnterTraceSequence) " +
                    "selection=\(selection.location):\(selection.length) " +
                    "nativeLen=\(nativeTextLength) shadowLenBefore=\(shadowTextLength) " +
                    "didExpect=\(didExpectNativeMutation) docH=\(formatDebug(textView.frame.height)) " +
                    "y=\(formatDebug(contentView.bounds.origin.y))"
                )
                debugUndoLagLog(
                    "textDidChange selection=\(selection.location):\(selection.length) " +
                    "nativeLen=\(nativeTextLength) shadowLenBefore=\(shadowTextLength) " +
                    "didResyncDirectMutation=\(didResyncDirectMutation) " +
                    "docHBefore=\(formatDebug(textView.frame.height)) " +
                    "yBefore=\(formatDebug(contentView.bounds.origin.y))"
                )
            }
            if needsDocumentLayoutStabilizationAfterEdit {
                needsDocumentLayoutStabilizationAfterEdit = false
                if isLineWrappingEnabled {
                    stabilizeDocumentLayout(preserveScrollOrigin: true)
                } else {
                    let appliedEstimatedHeightDelta = applyEstimatedNonWrappingDocumentHeightDeltaValue(
                        lineBreakDelta: pendingNonWrappingLineBreakDelta
                    )
                    pendingNonWrappingLayoutReconciliation?.appliedEstimatedHeightDelta = appliedEstimatedHeightDelta
                }
                pendingNonWrappingLineBreakDelta = 0
            } else if nativeEditAffectsLayout {
                stabilizeDocumentLayout(preserveScrollOrigin: true)
            }
            if nativeEditAffectsLayout {
                debugEnterShiftLog(
                    "textDidChange.end seq=\(currentEnterTraceSequence) " +
                    "nativeLen=\((textView.string as NSString).length) shadowLen=\(textStorage.length) " +
                    "docH=\(formatDebug(textView.frame.height)) y=\(formatDebug(contentView.bounds.origin.y))"
                )
                debugUndoLagLog(
                    "textDidChange.stabilized nativeLen=\((textView.string as NSString).length) " +
                    "shadowLen=\(textStorage.length) docH=\(formatDebug(textView.frame.height)) " +
                    "y=\(formatDebug(contentView.bounds.origin.y))"
                )
            }
            let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
            if Self.debugLagTraceEnabled && (elapsedMS >= 6 || nativeEditAffectsLayout) {
                let selection = textView.selectedRange()
                lagTrace(
                    event: "textDidChange",
                    elapsedMS: elapsedMS,
                    details:
                        "layout=\(nativeEditAffectsLayout) didResync=\(didResyncDirectMutation) " +
                        "selection=\(selection.location):\(selection.length) " +
                        "nativeLen=\(nativeTextLength) shadowLenBefore=\(shadowTextLength) " +
                        "docH=\(formatDebug(textView.frame.height)) y=\(formatDebug(contentView.bounds.origin.y))"
                )
            }
            editorDelegate?.textViewDidChange(self)
        }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        editorDelegate?.textViewDidChangeSelection(self)
    }

    public func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        let replacementText = replacementString ?? ""
        let normalizedText = normalizeLineEndings(in: replacementText)
        if normalizedText != replacementText {
            _ = applyReplacement(in: affectedCharRange, withText: normalizedText, respectDelegate: true)
            return false
        }
        let shouldChange = editorDelegate?.textView(self, shouldChangeTextIn: affectedCharRange, replacementText: normalizedText) ?? true
        if shouldChange && !isPerformingProgrammaticEdit {
            needsDocumentLayoutStabilizationAfterEdit = editAffectsDocumentLayout(
                in: affectedCharRange,
                replacementText: normalizedText
            )
            pendingNonWrappingLineBreakDelta = lineBreakDelta(
                in: affectedCharRange,
                replacementText: normalizedText,
                currentText: textStorage
            )
            if needsDocumentLayoutStabilizationAfterEdit && !isLineWrappingEnabled {
                preparePendingNonWrappingLayoutReconciliation(
                    beforeLocation: affectedCharRange.location,
                    afterLocationHint: affectedCharRange.location + (normalizedText as NSString).length
                )
            } else {
                pendingNonWrappingLayoutReconciliation = nil
            }
            needsTextStorageResync = true
        } else if !shouldChange {
            pendingNonWrappingLineBreakDelta = 0
            pendingNonWrappingLayoutReconciliation = nil
        }
        return shouldChange
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let modifierFlags = currentEventModifierFlagsProvider()
        guard modifierFlags.contains(.command) else {
            // Do not open links on plain click.
            return false
        }

        if let url = link as? URL {
            return openURLHandler(url)
        }
        if let urlString = link as? String, let url = URL(string: urlString) {
            return openURLHandler(url)
        }
        return false
    }

    private func lagTrace(event: String, elapsedMS: Double? = nil, details: String = "") {
        guard Self.debugLagTraceEnabled else {
            return
        }
        var userInfo: [String: Any] = [
            "component": "textView",
            "event": event,
            "details": details
        ]
        if let elapsedMS {
            userInfo["elapsedMS"] = NSNumber(value: elapsedMS)
        }
        NotificationCenter.default.post(
            name: Self.lagTraceNotificationName,
            object: nil,
            userInfo: userInfo
        )
    }
}
#endif
