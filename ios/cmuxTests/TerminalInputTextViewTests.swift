import UIKit
import XCTest
@testable import cmux_DEV

@MainActor
final class TerminalInputTextViewTests: XCTestCase {
    func testCommittedUnicodeTextEmitsAndClearsBuffer() {
        let textView = TerminalInputTextView()
        var outputs: [String] = []
        textView.onText = { outputs.append($0) }

        textView.simulateTextChangeForTesting("日本", isComposing: false)

        XCTAssertEqual(outputs, ["日本"])
        XCTAssertEqual(textView.text, "")
    }

    func testInsertTextEmitsPlainTextOnceWithoutBuffering() {
        let textView = TerminalInputTextView()
        var outputs: [String] = []
        textView.onText = { outputs.append($0) }

        textView.insertText("pwd")

        XCTAssertEqual(outputs, ["pwd"])
        XCTAssertEqual(textView.text, "")
    }

    func testRepeatedInsertTextDoesNotDropRepeatedCharacters() {
        let textView = TerminalInputTextView()
        var outputs: [String] = []
        textView.onText = { outputs.append($0) }

        textView.insertText("l")
        textView.insertText("l")
        textView.insertText("s")

        XCTAssertEqual(outputs, ["l", "l", "s"])
        XCTAssertEqual(textView.text, "")
    }

    func testAccessoryToolbarKeepsEdgeControlsInsideRoundedScreenMargins() {
        let textView = TerminalInputTextView()
        guard let toolbar = textView.inputAccessoryView else {
            return XCTFail("Expected terminal input accessory toolbar")
        }

        toolbar.frame = CGRect(x: 0, y: 0, width: 393, height: 44)
        toolbar.setNeedsLayout()
        toolbar.layoutIfNeeded()

        let hideKeyboardButton = toolbar.subviewsRecursive().first {
            $0.accessibilityIdentifier == "terminal.inputAccessory.hideKeyboard"
        }
        let scrollView = toolbar.subviewsRecursive().compactMap { $0 as? UIScrollView }.first

        XCTAssertNotNil(hideKeyboardButton)
        XCTAssertNotNil(scrollView)
        XCTAssertGreaterThanOrEqual(hideKeyboardButton?.frame.minX ?? 0, 16)
        XCTAssertLessThanOrEqual(scrollView?.frame.maxX ?? .greatestFiniteMagnitude, toolbar.bounds.maxX - 16)
    }

    func testAccessoryToolbarIncludesZoomButtons() {
        let textView = TerminalInputTextView()
        guard let toolbar = textView.inputAccessoryView else {
            return XCTFail("Expected terminal input accessory toolbar")
        }

        let zoomOutButton = toolbar.subviewsRecursive().compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == TerminalInputAccessoryAction.zoomOut.accessibilityIdentifier
        }
        let zoomInButton = toolbar.subviewsRecursive().compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == TerminalInputAccessoryAction.zoomIn.accessibilityIdentifier
        }

        XCTAssertNotNil(zoomOutButton?.image(for: .normal))
        XCTAssertNotNil(zoomInButton?.image(for: .normal))
        XCTAssertEqual(zoomOutButton?.accessibilityLabel, TerminalInputAccessoryAction.zoomOut.accessibilityLabel)
        XCTAssertEqual(zoomInButton?.accessibilityLabel, TerminalInputAccessoryAction.zoomIn.accessibilityLabel)
    }

    func testAccessoryZoomButtonsMatchStandardButtonDimensions() {
        let textView = TerminalInputTextView()
        guard let toolbar = textView.inputAccessoryView else {
            return XCTFail("Expected terminal input accessory toolbar")
        }

        toolbar.frame = CGRect(x: 0, y: 0, width: 393, height: 44)
        toolbar.setNeedsLayout()
        toolbar.layoutIfNeeded()

        let buttons = toolbar.subviewsRecursive().compactMap { $0 as? UIButton }
        let zoomOutButton = buttons.first {
            $0.accessibilityIdentifier == TerminalInputAccessoryAction.zoomOut.accessibilityIdentifier
        }
        let zoomInButton = buttons.first {
            $0.accessibilityIdentifier == TerminalInputAccessoryAction.zoomIn.accessibilityIdentifier
        }
        let escapeButton = buttons.first {
            $0.accessibilityIdentifier == TerminalInputAccessoryAction.escape.accessibilityIdentifier
        }

        guard let zoomOutButton, let zoomInButton, let escapeButton else {
            return XCTFail("Missing one or more accessory buttons needed for sizing assertions")
        }

        XCTAssertEqual(zoomOutButton.bounds.height, escapeButton.bounds.height, accuracy: 0.5)
        XCTAssertEqual(zoomInButton.bounds.height, escapeButton.bounds.height, accuracy: 0.5)
        XCTAssertEqual(zoomOutButton.bounds.width, escapeButton.bounds.width, accuracy: 0.5)
        XCTAssertEqual(zoomInButton.bounds.width, escapeButton.bounds.width, accuracy: 0.5)
    }

    func testAccessoryZoomActionsCallZoomHandlerWithoutTerminalBytes() {
        let textView = TerminalInputTextView()
        var zooms: [TerminalFontZoomDirection] = []
        var escapeOutputs: [Data] = []
        var textOutputs: [String] = []
        textView.onZoom = { zooms.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }
        textView.onText = { textOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.zoomOut)
        textView.simulateAccessoryActionForTesting(.zoomIn)

        XCTAssertEqual(zooms, [.decrease, .increase])
        XCTAssertTrue(escapeOutputs.isEmpty)
        XCTAssertTrue(textOutputs.isEmpty)
    }

    func testAccessoryZoomDisarmsModifierState() {
        let textView = TerminalInputTextView()
        var zooms: [TerminalFontZoomDirection] = []
        var escapeOutputs: [Data] = []
        var textOutputs: [String] = []
        textView.onZoom = { zooms.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }
        textView.onText = { textOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateAccessoryActionForTesting(.zoomIn)
        textView.simulateTextChangeForTesting("c", isComposing: false)

        XCTAssertEqual(zooms, [.increase])
        XCTAssertTrue(escapeOutputs.isEmpty)
        XCTAssertEqual(textOutputs, ["c"])
    }

    func testInsertTextSuppressesMirroredTextViewChange() {
        let textView = TerminalInputTextView()
        var outputs: [String] = []
        textView.onText = { outputs.append($0) }

        textView.insertText("xy")
        textView.simulateTextChangeForTesting("xy", isComposing: false)

        XCTAssertEqual(outputs, ["xy"])
        XCTAssertEqual(textView.text, "")
    }

    func testComposingTextStaysBufferedWithoutEmitting() {
        let textView = TerminalInputTextView()
        var outputs: [String] = []
        textView.onText = { outputs.append($0) }

        textView.simulateTextChangeForTesting("nihon", isComposing: true)

        XCTAssertTrue(outputs.isEmpty)
        XCTAssertEqual(textView.text, "nihon")
    }

    func testHardwareControlChordEmitsControlByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "c",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x03])])
    }

    func testHardwareControlTwoEmitsNullByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "2",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x00])])
    }

    func testHardwareControlThreeEmitsEscapeByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "3",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B])])
    }

    func testHardwareControlFourEmitsFileSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "4",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1C])])
    }

    func testHardwareControlFiveEmitsGroupSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "5",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1D])])
    }

    func testHardwareControlSixEmitsRecordSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "6",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1E])])
    }

    func testHardwareControlSevenEmitsUnitSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "7",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1F])])
    }

    func testHardwareControlShiftAtEmitsNullByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "@",
            modifierFlags: [.control, .shift]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x00])])
    }

    func testHardwareControlShiftCaretEmitsRecordSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "^",
            modifierFlags: [.control, .shift]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1E])])
    }

    func testHardwareControlShiftUnderscoreEmitsUnitSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "_",
            modifierFlags: [.control, .shift]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1F])])
    }

    func testHardwareControlShiftQuestionMarkEmitsDeleteByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "?",
            modifierFlags: [.control, .shift]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x7F])])
    }

    func testHardwareControlSlashEmitsUnitSeparatorByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "/",
            modifierFlags: UIKeyModifierFlags.control
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1F])])
    }

    func testHardwareTabEmitsTabByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "\t",
            modifierFlags: []
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x09])])
    }

    func testHardwareShiftTabEmitsBacktabSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: "\t",
            modifierFlags: UIKeyModifierFlags.shift
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x5A])])
    }

    func testHardwareHomeEmitsHomeSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputHome,
            modifierFlags: []
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x48])])
    }

    func testHardwareEndEmitsEndSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputEnd,
            modifierFlags: []
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x46])])
    }

    func testHardwarePageUpEmitsPageUpSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputPageUp,
            modifierFlags: []
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x35, 0x7E])])
    }

    func testHardwarePageDownEmitsPageDownSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputPageDown,
            modifierFlags: []
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x36, 0x7E])])
    }

    func testHardwareDeleteEmitsForwardDeleteSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputDelete,
            modifierFlags: []
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x33, 0x7E])])
    }

    func testHardwareOptionLeftEmitsBackwardWordSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputLeftArrow,
            modifierFlags: [.alternate]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x62])])
    }

    func testHardwareOptionRightEmitsForwardWordSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputRightArrow,
            modifierFlags: [.alternate]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x66])])
    }

    func testHardwareOptionDeleteEmitsBackwardWordDeleteSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        let handled = textView.simulateHardwareKeyCommandForTesting(
            input: UIKeyCommand.inputDelete,
            modifierFlags: [.alternate]
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(outputs, [Data([0x1B, 0x7F])])
    }

    func testSoftwareKeyboardAccessoryExists() {
        let textView = TerminalInputTextView()

        XCTAssertNotNil(textView.inputAccessoryView)
    }

    func testAccessoryEscapeEmitsEscapeByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        textView.simulateAccessoryActionForTesting(.escape)

        XCTAssertEqual(outputs, [Data([0x1B])])
    }

    func testAccessoryTabEmitsTabByte() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        textView.simulateAccessoryActionForTesting(.tab)

        XCTAssertEqual(outputs, [Data([0x09])])
    }

    func testAccessoryUpArrowEmitsArrowSequence() {
        let textView = TerminalInputTextView()
        var outputs: [Data] = []
        textView.onEscapeSequence = { outputs.append($0) }

        textView.simulateAccessoryActionForTesting(.upArrow)

        XCTAssertEqual(outputs, [Data([0x1B, 0x5B, 0x41])])
    }

    func testAccessoryControlArmsNextCharacterAsControlSequence() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateTextChangeForTesting("c", isComposing: false)

        XCTAssertTrue(textOutputs.isEmpty)
        XCTAssertEqual(escapeOutputs, [Data([0x03])])
        XCTAssertEqual(textView.text, "")
    }

    func testAccessoryControlLatchClearsAfterOneUse() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateTextChangeForTesting("c", isComposing: false)
        textView.simulateTextChangeForTesting("c", isComposing: false)

        XCTAssertEqual(textOutputs, ["c"])
        XCTAssertEqual(escapeOutputs, [Data([0x03])])
    }

    func testAccessoryControlSupportsDigitAlias() {
        let textView = TerminalInputTextView()
        var escapeOutputs: [Data] = []
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateTextChangeForTesting("2", isComposing: false)

        XCTAssertEqual(escapeOutputs, [Data([0x00])])
    }

    func testAccessoryControlCanBeToggledOff() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateTextChangeForTesting("c", isComposing: false)

        XCTAssertEqual(textOutputs, ["c"])
        XCTAssertTrue(escapeOutputs.isEmpty)
    }

    func testAccessoryControlLeftArrowEmitsPlainArrowAndClearsLatch() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.control)
        textView.simulateAccessoryActionForTesting(.leftArrow)
        textView.simulateTextChangeForTesting("c", isComposing: false)

        XCTAssertEqual(escapeOutputs, [Data([0x1B, 0x5B, 0x44])])
        XCTAssertEqual(textOutputs, ["c"])
    }

    func testAccessoryControlBackspaceEmitsNormalBackspaceAndClearsLatch() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var backspaceCount = 0
        textView.onText = { textOutputs.append($0) }
        textView.onBackspace = { backspaceCount += 1 }

        textView.simulateAccessoryActionForTesting(.control)
        textView.deleteBackward()
        textView.simulateTextChangeForTesting("c", isComposing: false)

        XCTAssertEqual(backspaceCount, 1)
        XCTAssertEqual(textOutputs, ["c"])
    }

    func testAccessoryAltPrefixesNextCommittedCharacterWithEscape() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateTextChangeForTesting("b", isComposing: false)

        XCTAssertTrue(textOutputs.isEmpty)
        XCTAssertEqual(escapeOutputs, [Data([0x1B, 0x62])])
        XCTAssertEqual(textView.text, "")
    }

    func testAccessoryAltLatchClearsAfterOneUse() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateTextChangeForTesting("b", isComposing: false)
        textView.simulateTextChangeForTesting("f", isComposing: false)

        XCTAssertEqual(textOutputs, ["f"])
        XCTAssertEqual(escapeOutputs, [Data([0x1B, 0x62])])
    }

    func testAccessoryAltCanBeToggledOff() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateTextChangeForTesting("b", isComposing: false)

        XCTAssertEqual(textOutputs, ["b"])
        XCTAssertTrue(escapeOutputs.isEmpty)
    }

    func testAccessoryAltEscapePrefixesEscapeAndClearsLatch() {
        let textView = TerminalInputTextView()
        var escapeOutputs: [Data] = []
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateAccessoryActionForTesting(.escape)
        textView.simulateAccessoryActionForTesting(.escape)

        XCTAssertEqual(
            escapeOutputs,
            [
                Data([0x1B, 0x1B]),
                Data([0x1B]),
            ]
        )
    }

    func testAccessoryAltTabPrefixesTabAndClearsLatch() {
        let textView = TerminalInputTextView()
        var escapeOutputs: [Data] = []
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateAccessoryActionForTesting(.tab)
        textView.simulateAccessoryActionForTesting(.tab)

        XCTAssertEqual(
            escapeOutputs,
            [
                Data([0x1B, 0x09]),
                Data([0x09]),
            ]
        )
    }

    func testAccessoryAltLeftArrowEmitsBackwardWordSequenceAndClearsLatch() {
        let textView = TerminalInputTextView()
        var escapeOutputs: [Data] = []
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateAccessoryActionForTesting(.leftArrow)
        textView.simulateAccessoryActionForTesting(.leftArrow)

        XCTAssertEqual(
            escapeOutputs,
            [
                Data([0x1B, 0x62]),
                Data([0x1B, 0x5B, 0x44]),
            ]
        )
    }

    func testAccessoryAltRightArrowEmitsForwardWordSequenceAndClearsLatch() {
        let textView = TerminalInputTextView()
        var escapeOutputs: [Data] = []
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.simulateAccessoryActionForTesting(.rightArrow)
        textView.simulateAccessoryActionForTesting(.rightArrow)

        XCTAssertEqual(
            escapeOutputs,
            [
                Data([0x1B, 0x66]),
                Data([0x1B, 0x5B, 0x43]),
            ]
        )
    }

    func testAccessoryAltBackspaceEmitsBackwardWordDeleteSequenceAndClearsLatch() {
        let textView = TerminalInputTextView()
        var textOutputs: [String] = []
        var escapeOutputs: [Data] = []
        textView.onText = { textOutputs.append($0) }
        textView.onEscapeSequence = { escapeOutputs.append($0) }

        textView.simulateAccessoryActionForTesting(.alternate)
        textView.deleteBackward()
        textView.simulateTextChangeForTesting("b", isComposing: false)

        XCTAssertEqual(escapeOutputs, [Data([0x1B, 0x7F])])
        XCTAssertEqual(textOutputs, ["b"])
    }
}

private extension UIView {
    func subviewsRecursive() -> [UIView] {
        subviews + subviews.flatMap { $0.subviewsRecursive() }
    }
}
