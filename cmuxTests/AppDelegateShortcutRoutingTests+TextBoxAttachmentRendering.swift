import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Text box attachment rendering and layout tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxImageAttachmentInsertionAddsTrailingEditorSpace() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello "
        textView.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        textView.insertAttachments([attachment])

        XCTAssertEqual(textView.inlineAttachments().count, 1)
        XCTAssertTrue(textView.attributedString().string.hasSuffix(" "))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: textView.attributedString().length, length: 0))
    }

    func testTextBoxImageAttachmentInsertionDoesNotDuplicateExistingFollowingSpace() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "hello world"
        textView.setSelectedRange(NSRange(location: ("hello" as NSString).length, length: 0))
        textView.insertAttachments([attachment])

        XCTAssertEqual(
            submissionPartSummaries(textView.submissionParts()),
            [
                .text("hello "),
                .attachment(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)),
                .text(" world")
            ]
        )
    }

    func testTextBoxImageAttachmentDoesNotMoveRenderedSingleLineText() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 30)
        let text = "hello world"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let textRange = NSRange(location: 0, length: (text as NSString).length)
        let scanRange = NSRange(location: 0, length: ("hello" as NSString).length)
        let scanRect = try renderedTextScanRect(in: textView, characterRange: scanRange)
        let beforeBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: scanRect)

        textView.setSelectedRange(NSRange(location: textRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let afterBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: scanRect)
        assertRenderedVerticalBoundsUnchanged(beforeBounds, afterBounds, accuracy: 1)
    }

    func testTextBoxImageAttachmentDoesNotMoveRenderedMultilineText() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 64)
        let firstLine = "hello world"
        let secondLine = "second line"
        let text = "\(firstLine)\n\(secondLine)"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let firstLineRange = NSRange(location: 0, length: (firstLine as NSString).length)
        let firstScanRange = NSRange(location: 0, length: ("hello" as NSString).length)
        let secondScanRange = NSRange(
            location: firstLineRange.upperBound + 1,
            length: ("second" as NSString).length
        )
        let firstScanRect = try renderedTextScanRect(in: textView, characterRange: firstScanRange)
        let secondScanRect = try renderedTextScanRect(in: textView, characterRange: secondScanRange)
        let beforeFirstBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: firstScanRect)
        let beforeSecondBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: secondScanRect)

        textView.setSelectedRange(NSRange(location: firstLineRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let afterFirstBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: firstScanRect)
        let afterSecondBounds = try renderedNonBackgroundPixelBounds(in: textView, scanRect: secondScanRect)
        assertRenderedVerticalBoundsUnchanged(beforeFirstBounds, afterFirstBounds, accuracy: 1)
        assertRenderedVerticalBoundsUnchanged(beforeSecondBounds, afterSecondBounds, accuracy: 1)
    }

    func testTextBoxInlineAttachmentPixelsDoNotSitAboveTextPixelsWithoutChangingTextBaseline() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = makeRenderableTextBoxInput(width: 420, height: 30)
        let text = "hello world"
        textView.string = text
        textView.normalizeTextBaselineOffsets()
        textView.recenterSingleLineTextContainer()

        let textRange = NSRange(location: 0, length: (text as NSString).length)

        textView.setSelectedRange(NSRange(location: textRange.upperBound, length: 0))
        textView.insertAttachments([attachment])

        let textPixelBounds = try renderedNonBackgroundPixelBounds(
            in: textView,
            scanRect: renderedTextScanRect(
                in: textView,
                characterRange: NSRange(location: 0, length: ("hello" as NSString).length)
            )
        )
        let attachmentPixelBounds = try renderedNonBackgroundPixelBounds(
            in: textView,
            scanRect: try visibleAttachmentCellFrame(in: textView).insetBy(dx: -2, dy: -10)
        )

        XCTAssertEqual(baselineOffsetsForTextRuns(in: textView), [0])
        XCTAssertGreaterThanOrEqual(
            attachmentPixelBounds.midY,
            textPixelBounds.midY,
            "Inline image pills should not sit above adjacent text or move the text baseline."
        )
        XCTAssertLessThan(
            attachmentPixelBounds.midY - textPixelBounds.midY,
            8,
            "Inline image pills should not be pushed so low that they look detached from text."
        )
    }

    func testTextBoxInlineAttachmentVerticalPaddingIsBalancedAcrossLineStates() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let pillOnly = makeRenderableTextBoxInput(width: 420, height: 30)
        pillOnly.insertAttachments([attachment])
        let pillOnlyCell = try visibleAttachmentCellFrame(in: pillOnly)
        let pillOnlyPixels = try renderedNonBackgroundPixelBounds(
            in: pillOnly,
            scanRect: pillOnlyCell.insetBy(dx: -2, dy: -12)
        )

        let inline = makeRenderableTextBoxInput(width: 420, height: 30)
        inline.string = "hello "
        inline.normalizeTextBaselineOffsets()
        inline.recenterSingleLineTextContainer()
        inline.setSelectedRange(NSRange(location: ("hello " as NSString).length, length: 0))
        inline.insertAttachments([attachment])
        inline.insertText(" world", replacementRange: inline.selectedRange())
        let inlineCell = try visibleAttachmentCellFrame(in: inline)
        let inlinePillPixels = try renderedNonBackgroundPixelBounds(
            in: inline,
            scanRect: inlineCell.insetBy(dx: -2, dy: -12)
        )
        let inlineTextPixels = try renderedNonBackgroundPixelBounds(
            in: inline,
            scanRect: renderedTextScanRect(
                in: inline,
                characterRange: NSRange(location: 0, length: ("hello" as NSString).length)
            )
        )

        let multiline = makeRenderableTextBoxInput(width: 420, height: 64)
        let multilinePrefix = "x\n          "
        multiline.string = multilinePrefix
        multiline.normalizeTextBaselineOffsets()
        multiline.recenterSingleLineTextContainer()
        multiline.setSelectedRange(NSRange(location: (multilinePrefix as NSString).length, length: 0))
        multiline.insertAttachments([attachment])
        multiline.insertText(" world", replacementRange: multiline.selectedRange())
        let multilineCell = try visibleAttachmentCellFrame(in: multiline)
        let multilinePillPixels = try renderedNonBackgroundPixelBounds(
            in: multiline,
            scanRect: multilineCell.insetBy(dx: -2, dy: -12)
        )
        XCTAssertLessThanOrEqual(
            pillOnlyPixels.verticalPaddingDelta,
            2,
            "Pill-only TextBox padding should stay visually centered. Got \(pillOnlyPixels.debugDescription())."
        )
        XCTAssertLessThanOrEqual(
            inlinePillPixels.verticalPaddingDelta,
            1,
            "Inline pill padding should stay centered inside the single-line TextBox. Got \(inlinePillPixels.debugDescription())."
        )
        XCTAssertLessThanOrEqual(
            multilinePillPixels.verticalPaddingDelta,
            1,
            "Multiline pill padding should stay centered in the expanded TextBox. Got \(multilinePillPixels.debugDescription())."
        )
        XCTAssertEqual(baselineOffsetsForTextRuns(in: inline), [0])
        XCTAssertEqual(baselineOffsetsForTextRuns(in: multiline), [0])
        XCTAssertGreaterThan(
            inlinePillPixels.midY,
            inlineTextPixels.midY,
            "The inline pill should remain slightly lower than adjacent text."
        )
    }

    private struct RenderedPixelBounds {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let rasterHeight: Int

        var midY: CGFloat {
            CGFloat(minY + maxY) / 2
        }

        var topPadding: Int { minY }

        var bottomPadding: Int { max(0, rasterHeight - 1 - maxY) }

        var verticalPaddingDelta: Int {
            abs(topPadding - bottomPadding)
        }

        func debugDescription() -> String {
            "(minY:\(minY), maxY:\(maxY), midY:\(midY), top:\(topPadding), bottom:\(bottomPadding))"
        }
    }

    private func makeRenderableTextBoxInput(width: CGFloat, height: CGFloat) -> TextBoxInputTextView {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.font = NSFont.systemFont(ofSize: 16)
        textView.textColor = .white
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 30)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 1, height: height > 30 ? 4 : 5)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        Self.retainedTextBoxRenderScrollViews.append(scrollView)
        addTeardownBlock {
            Self.retainedTextBoxRenderScrollViews.removeAll { $0 === scrollView }
        }
        return textView
    }

    private func renderedTextScanRect(
        in textView: TextBoxInputTextView,
        characterRange: NSRange
    ) throws -> NSRect {
        let glyphFrame = try visibleGlyphFrame(in: textView, characterRange: characterRange)
        return NSRect(
            x: max(0, floor(glyphFrame.minX) - 2),
            y: max(0, floor(glyphFrame.minY) - 10),
            width: ceil(glyphFrame.width) + 4,
            height: ceil(glyphFrame.height) + 20
        )
    }

    private func renderedNonBackgroundPixelBounds(
        in textView: TextBoxInputTextView,
        scanRect: NSRect
    ) throws -> RenderedPixelBounds {
        let bitmap = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: bitmap)

        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let scaleX = CGFloat(width) / max(1, textView.bounds.width)
        let scaleY = CGFloat(height) / max(1, textView.bounds.height)

        let minScanX = max(0, Int(floor(scanRect.minX * scaleX)))
        let minScanY = max(0, Int(floor(scanRect.minY * scaleY)))
        let maxScanX = min(width - 1, Int(ceil(scanRect.maxX * scaleX)))
        let maxScanY = min(height - 1, Int(ceil(scanRect.maxY * scaleY)))

        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        guard minScanX <= maxScanX, minScanY <= maxScanY else {
            XCTFail("Expected scan rect \(scanRect) inside text bounds \(textView.bounds)")
            return RenderedPixelBounds(minX: 0, minY: 0, maxX: 0, maxY: 0, rasterHeight: height)
        }

        for y in minScanY...maxScanY {
            for x in minScanX...maxScanX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                guard brightness > 0.08 || color.alphaComponent > 0.08 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX != Int.max else {
            XCTFail("Expected rendered text pixels inside \(scanRect)")
            return RenderedPixelBounds(minX: 0, minY: 0, maxX: 0, maxY: 0, rasterHeight: height)
        }

        return RenderedPixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY, rasterHeight: height)
    }

    private func assertRenderedVerticalBoundsUnchanged(
        _ before: RenderedPixelBounds,
        _ after: RenderedPixelBounds,
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(CGFloat(after.minY), CGFloat(before.minY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(CGFloat(after.maxY), CGFloat(before.maxY), accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(after.midY, before.midY, accuracy: accuracy, file: file, line: line)
    }

    private func visibleGlyphFrame(
        in textView: TextBoxInputTextView,
        characterRange: NSRange
    ) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func visibleAttachmentCellFrame(in textView: TextBoxInputTextView) throws -> NSRect {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        let attributed = textView.attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        var attachmentRange: NSRange?
        var attachmentCell: NSTextAttachmentCellProtocol?
        attributed.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, stop in
            guard let attachment = value as? NSTextAttachment,
                  let cell = attachment.attachmentCell else { return }
            attachmentRange = range
            attachmentCell = cell
            stop.pointee = true
        }

        let range = try XCTUnwrap(attachmentRange)
        let cell = try XCTUnwrap(attachmentCell)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let lineFragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let glyphPosition = layoutManager.location(forGlyphAt: glyphRange.location)
        return cell
            .cellFrame(
                for: textContainer,
                proposedLineFragment: lineFragment,
                glyphPosition: glyphPosition,
                characterIndex: range.location
            )
            .offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func baselineOffsetsForTextRuns(in textView: TextBoxInputTextView) -> [CGFloat] {
        let attributed = textView.attributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        var offsets: [CGFloat] = []
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, _, _ in
            guard attributes[.attachment] == nil else { return }
            if let value = attributes[.baselineOffset] as? CGFloat {
                offsets.append(value)
            } else if let number = attributes[.baselineOffset] as? NSNumber {
                offsets.append(CGFloat(truncating: number))
            } else {
                offsets.append(0)
            }
        }
        return Array(Set(offsets)).sorted()
    }

}
