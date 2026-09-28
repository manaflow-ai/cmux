import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal accessibility text")
struct TerminalAccessibilityTextTests {
    private let screen = "~/src main\n$ echo ready\nready\n$ "

    @Test("A value that splices text into what the client read inserts only that text")
    func splicedValueYieldsTheInsertion() {
        #expect(TerminalAccessibilityText.insertedText(settingValue: screen + "git status", over: screen) == "git status")
        #expect(TerminalAccessibilityText.insertedText(settingValue: "git status" + screen, over: screen) == "git status")
        let middle = screen.index(screen.startIndex, offsetBy: 11)
        var spliced = screen
        spliced.insert(contentsOf: "hello ", at: middle)
        #expect(TerminalAccessibilityText.insertedText(settingValue: spliced, over: screen) == "hello ")
    }

    @Test("A value that doesn't keep the text the client read is inserted as is")
    func unrelatedValueIsLiteral() {
        #expect(TerminalAccessibilityText.insertedText(settingValue: "hello world", over: screen) == "hello world")
        #expect(TerminalAccessibilityText.insertedText(settingValue: "$ ", over: "") == "$ ")
        #expect(TerminalAccessibilityText.insertedText(settingValue: "ends with a space ", over: screen) == "ends with a space ")
    }

    @Test("Setting the value the client read inserts nothing")
    func unchangedValueInsertsNothing() {
        #expect(TerminalAccessibilityText.insertedText(settingValue: screen, over: screen) == "")
    }

    @Test("Trailing line breaks split off as a submit")
    func trailingLineBreaksSplit() {
        for (text, body, lineBreaks) in [("one\ntwo\r\n", "one\ntwo", "\r\n"), ("one line", "one line", ""), ("\n", "", "\n")] {
            let split = TerminalAccessibilityText.splitTrailingLineBreaks(text)
            #expect(split.body == body)
            #expect(split.lineBreaks == lineBreaks)
        }
    }

    @Test("Paste payload keeps text, tabs and line breaks but drops other control characters")
    func pastePayloadDropsControls() {
        #expect(TerminalAccessibilityText.pastePayload("a\tb\nc\u{1b}[201~d\u{7f}\u{9b}e") == "a\tb\nc[201~de")
    }

    @Test("Snapshot answers repeated queries until it expires or is invalidated")
    func snapshotCaching() {
        let text = TerminalAccessibilityText()
        var reads = 0
        let read: () -> String? = {
            reads += 1
            return "read \(reads)"
        }
        #expect(text.value(now: 10, read: read) == "read 1")
        #expect(text.value(now: 10.2, read: read) == "read 1")
        #expect(text.value(now: 10 + TerminalAccessibilityText.snapshotLifetime, read: read) == "read 2")
        text.invalidate()
        #expect(text.value(now: 10.6, read: read) == "read 3")
        #expect(text.lastVendedValue == "read 3")
    }

    @Test("Only key events posted by another process count as foreign")
    func foreignKeyEventSource() throws {
        let hostPID = ProcessInfo.processInfo.processIdentifier
        for (sourcePID, isForeign) in [(Int64(0), false), (Int64(hostPID), false), (Int64(1), true)] {
            let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
            cgEvent.flags = [.maskCommand, .maskAlternate]
            cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: sourcePID)
            let event = try #require(NSEvent(cgEvent: cgEvent))
            #expect(GhosttyNSView.isKeyEventPostedByAnotherProcess(event) == isForeign)
        }
    }
}
