import Foundation

public struct MarkdownHeading: Equatable {
    public let level: Int
    public let hashRange: NSRange
    public let titleRange: NSRange

    public init(level: Int, hashRange: NSRange, titleRange: NSRange) {
        self.level = level
        self.hashRange = hashRange
        self.titleRange = titleRange
    }
}

public enum MarkdownBlockSemantic: Equatable {
    case plain
    case heading(MarkdownHeading)
    case fencedCode
    case fencedCodeDelimiter
    case blockQuote
    case listItem
    case horizontalRule
    case tableRow
}

public struct MarkdownDocumentLine: Equatable {
    public let lineRange: NSRange
    public let contentRange: NSRange
    public let semantic: MarkdownBlockSemantic
    public let entersFence: Bool
    public let exitsFence: Bool
    public let requiresMarkdownProcessing: Bool

    public init(
        lineRange: NSRange,
        contentRange: NSRange,
        semantic: MarkdownBlockSemantic,
        entersFence: Bool,
        exitsFence: Bool,
        requiresMarkdownProcessing: Bool
    ) {
        self.lineRange = lineRange
        self.contentRange = contentRange
        self.semantic = semantic
        self.entersFence = entersFence
        self.exitsFence = exitsFence
        self.requiresMarkdownProcessing = requiresMarkdownProcessing
    }

    public var isInFencedCode: Bool {
        entersFence
    }

    public var isFenceDelimiter: Bool {
        entersFence != exitsFence
    }
}

public final class MarkdownDocumentModel {
    private static let inlineMarkdownSignalCharacterSet = CharacterSet(charactersIn: "*_`[]()!<>|")
    private static let structuralMarkdownSignalCharacterSet = CharacterSet(charactersIn: "#>-+|<")
    private static let decimalDigitsCharacterSet = CharacterSet.decimalDigits

    private var lines: [MarkdownDocumentLine] = []
    private var lineIndexNeedsRebuild = true
    private var invalidationLocation = Int.max

    public init() {}

    public var lineCount: Int {
        lines.count
    }

    public func line(at index: Int) -> MarkdownDocumentLine {
        lines[index]
    }

    public func invalidate(
        forEditedRange editedRange: NSRange,
        changeInLength: Int,
        text: NSString
    ) {
        guard editedRange.location != NSNotFound else {
            return
        }
        let clampedLocation = min(max(0, editedRange.location), max(0, text.length - 1))
        let lineStart = text.lineRange(for: NSRange(location: clampedLocation, length: 0)).location
        if changeInLength != 0 {
            invalidationLocation = min(invalidationLocation, lineStart)
            lineIndexNeedsRebuild = true
        } else if lines.isEmpty {
            lineIndexNeedsRebuild = true
            invalidationLocation = min(invalidationLocation, lineStart)
        } else {
            invalidationLocation = min(invalidationLocation, lineStart)
        }
    }

    @discardableResult
    public func prepare(text: NSString) -> Double {
        guard lineIndexNeedsRebuild || invalidationLocation != Int.max else {
            return 0
        }
        let started = CFAbsoluteTimeGetCurrent()
        let previousLines = lines
        let effectiveInvalidationLocation = invalidationLocation == Int.max ? 0 : invalidationLocation
        let clampedInvalidationLocation = min(max(0, effectiveInvalidationLocation), max(0, text.length))

        var preservedCount = 0
        if clampedInvalidationLocation > 0, !previousLines.isEmpty {
            while preservedCount < previousLines.count {
                let line = previousLines[preservedCount]
                if NSMaxRange(line.lineRange) <= clampedInvalidationLocation {
                    preservedCount += 1
                } else {
                    break
                }
            }
        }

        var rebuiltLines: [MarkdownDocumentLine] = []
        rebuiltLines.reserveCapacity(max(32, previousLines.count))
        if preservedCount > 0 {
            rebuiltLines.append(contentsOf: previousLines.prefix(preservedCount))
        }

        var location = 0
        var entryFenceState = false
        if let lastPreservedLine = rebuiltLines.last {
            location = NSMaxRange(lastPreservedLine.lineRange)
            entryFenceState = lastPreservedLine.exitsFence
        }
        location = min(max(0, location), text.length)

        if text.length > 0 {
            while location < text.length {
                let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                guard lineRange.length > 0 else {
                    break
                }
                let line = Self.makeLine(lineRange: lineRange, text: text, entryFenceState: entryFenceState)
                rebuiltLines.append(line)
                entryFenceState = line.exitsFence
                location = NSMaxRange(lineRange)
            }
        }

        lines = rebuiltLines
        lineIndexNeedsRebuild = false
        invalidationLocation = Int.max
        return (CFAbsoluteTimeGetCurrent() - started) * 1_000
    }

    public func lineIndexRange(for characterRange: NSRange, in text: NSString) -> Range<Int>? {
        guard !lines.isEmpty else {
            return nil
        }
        let safeRange = NSIntersectionRange(characterRange, NSRange(location: 0, length: text.length))
        guard safeRange.length > 0 else {
            return nil
        }

        let firstLineIndex = lineIndex(for: safeRange.location)
        let endLocation = max(safeRange.location, NSMaxRange(safeRange) - 1)
        let lastLineIndex = lineIndex(for: endLocation)
        return firstLineIndex..<(lastLineIndex + 1)
    }

    public func lineIndex(for location: Int) -> Int {
        guard !lines.isEmpty else {
            return 0
        }
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = lines[mid].lineRange
            if location < range.location {
                high = mid - 1
            } else if location >= NSMaxRange(range) {
                low = mid + 1
            } else {
                return mid
            }
        }
        return min(max(0, low), lines.count - 1)
    }
}

private extension MarkdownDocumentModel {
    static func makeLine(
        lineRange: NSRange,
        text: NSString,
        entryFenceState: Bool
    ) -> MarkdownDocumentLine {
        let contentRange = trimmedContentRange(for: lineRange, text: text)
        guard contentRange.length > 0 else {
            return MarkdownDocumentLine(
                lineRange: lineRange,
                contentRange: contentRange,
                semantic: .plain,
                entersFence: entryFenceState,
                exitsFence: entryFenceState,
                requiresMarkdownProcessing: false
            )
        }

        let lineText = text.substring(with: contentRange) as NSString
        let hasFenceDelimiter = isFenceDelimiter(lineText)
        let exitsFenceState: Bool
        let semantic: MarkdownBlockSemantic

        if hasFenceDelimiter {
            semantic = .fencedCodeDelimiter
            exitsFenceState = !entryFenceState
        } else if entryFenceState {
            semantic = .fencedCode
            exitsFenceState = entryFenceState
        } else if let heading = headingMetadata(in: lineText) {
            semantic = .heading(heading)
            exitsFenceState = false
        } else if isHorizontalRule(lineText) {
            semantic = .horizontalRule
            exitsFenceState = false
        } else if isBlockQuote(lineText) {
            semantic = .blockQuote
            exitsFenceState = false
        } else if isListItem(lineText) {
            semantic = .listItem
            exitsFenceState = false
        } else if isTableRow(lineText) {
            semantic = .tableRow
            exitsFenceState = false
        } else {
            semantic = .plain
            exitsFenceState = false
        }

        let requiresMarkdownProcessing = semantic != .plain || lineNeedsMarkdownProcessing(lineText)
        return MarkdownDocumentLine(
            lineRange: lineRange,
            contentRange: contentRange,
            semantic: semantic,
            entersFence: entryFenceState,
            exitsFence: exitsFenceState,
            requiresMarkdownProcessing: requiresMarkdownProcessing
        )
    }

    static func trimmedContentRange(for lineRange: NSRange, text: NSString) -> NSRange {
        var contentLength = lineRange.length
        while contentLength > 0 {
            let character = text.character(at: lineRange.location + contentLength - 1)
            if character == 10 || character == 13 {
                contentLength -= 1
            } else {
                break
            }
        }
        return NSRange(location: lineRange.location, length: contentLength)
    }

    static func isFenceDelimiter(_ lineText: NSString) -> Bool {
        let length = lineText.length
        guard length >= 3 else {
            return false
        }
        var index = 0
        while index < length, CharacterSet.whitespaces.contains(UnicodeScalar(lineText.character(at: index)) ?? " ") {
            index += 1
        }
        guard index + 2 < length else {
            return false
        }
        return lineText.character(at: index) == 96 &&
            lineText.character(at: index + 1) == 96 &&
            lineText.character(at: index + 2) == 96
    }

    static func headingMetadata(in lineText: NSString) -> MarkdownHeading? {
        let length = lineText.length
        guard length >= 3, lineText.character(at: 0) == 35 else {
            return nil
        }

        var hashCount = 0
        while hashCount < min(6, length), lineText.character(at: hashCount) == 35 {
            hashCount += 1
        }

        guard hashCount > 0,
              hashCount < length,
              lineText.character(at: hashCount) == 32 else {
            return nil
        }

        let titleLocation = hashCount + 1
        guard titleLocation < length else {
            return nil
        }

        return MarkdownHeading(
            level: hashCount,
            hashRange: NSRange(location: 0, length: hashCount),
            titleRange: NSRange(location: titleLocation, length: length - titleLocation)
        )
    }

    static func isHorizontalRule(_ lineText: NSString) -> Bool {
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
    }

    static func isBlockQuote(_ lineText: NSString) -> Bool {
        let first = firstNonWhitespaceIndex(in: lineText)
        guard first != NSNotFound else {
            return false
        }
        return lineText.character(at: first) == 62
    }

    static func isListItem(_ lineText: NSString) -> Bool {
        let first = firstNonWhitespaceIndex(in: lineText)
        guard first != NSNotFound else {
            return false
        }
        let character = lineText.character(at: first)
        if character == 45 || character == 42 || character == 43 {
            return first + 1 < lineText.length && lineText.character(at: first + 1) == 32
        }
        var index = first
        var foundDigit = false
        while index < lineText.length,
              let scalar = UnicodeScalar(lineText.character(at: index)),
              decimalDigitsCharacterSet.contains(scalar) {
            foundDigit = true
            index += 1
        }
        return foundDigit &&
            index + 1 < lineText.length &&
            lineText.character(at: index) == 46 &&
            lineText.character(at: index + 1) == 32
    }

    static func isTableRow(_ lineText: NSString) -> Bool {
        let string = lineText as String
        let pipeCount = string.reduce(into: 0) { partialResult, character in
            if character == "|" {
                partialResult += 1
            }
        }
        return pipeCount >= 2
    }

    static func lineNeedsMarkdownProcessing(_ lineText: NSString) -> Bool {
        let searchRange = NSRange(location: 0, length: lineText.length)
        if lineText.rangeOfCharacter(from: inlineMarkdownSignalCharacterSet, options: [], range: searchRange).location != NSNotFound {
            return true
        }

        let firstNonWhitespace = firstNonWhitespaceIndex(in: lineText)
        guard firstNonWhitespace != NSNotFound else {
            return false
        }
        let firstCharacterRange = NSRange(location: firstNonWhitespace, length: 1)
        if lineText.rangeOfCharacter(
            from: structuralMarkdownSignalCharacterSet,
            options: [],
            range: firstCharacterRange
        ).location != NSNotFound {
            return true
        }
        return lineText.rangeOfCharacter(
            from: decimalDigitsCharacterSet,
            options: [],
            range: firstCharacterRange
        ).location != NSNotFound
    }

    static func firstNonWhitespaceIndex(in lineText: NSString) -> Int {
        let searchRange = NSRange(location: 0, length: lineText.length)
        let range = lineText.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted,
            options: [],
            range: searchRange
        )
        return range.location
    }
}
