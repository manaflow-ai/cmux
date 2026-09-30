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

    /// Vends each value to a fresh model the way AX reads do, a snapshot apart.
    private func model(vending values: [String]) -> TerminalAccessibilityText {
        let text = TerminalAccessibilityText()
        for (offset, value) in values.enumerated() {
            _ = text.value(now: Double(offset), read: { value })
        }
        return text
    }

    @Test("A value that splices text into what the client read inserts only that text")
    func splicedValueYieldsTheInsertion() {
        let text = model(vending: [screen])
        #expect(text.insertedText(settingValue: screen + "git status") == "git status")
        #expect(text.insertedText(settingValue: "git status" + screen) == "git status")
        let middle = screen.index(screen.startIndex, offsetBy: 11)
        var spliced = screen
        spliced.insert(contentsOf: "hello ", at: middle)
        #expect(text.insertedText(settingValue: spliced) == "hello ")
    }

    @Test("A value spliced into an older read still inserts only the text after the screen changed")
    func staleReadStillYieldsTheInsertion() {
        let older = screen
        let newer = "ready\n$ \nagent output line one\nagent output line two\n"
        let text = model(vending: [older, newer])
        #expect(text.insertedText(settingValue: older + "git status") == "git status")
    }

    @Test("A delayed edit survives more than eight newer screen reads")
    func delayedReadSurvivesScreenChurn() {
        let newerScreens = (1...10).map { "new screen \($0)\n$ " }
        let text = model(vending: [screen] + newerScreens)
        #expect(text.insertedText(settingValue: screen + "git status") == "git status")
    }

    @Test("A value that doesn't keep the text the client read is inserted as is")
    func unrelatedValueIsLiteral() {
        #expect(model(vending: [screen]).insertedText(settingValue: "hello world") == "hello world")
        #expect(model(vending: []).insertedText(settingValue: "$ ") == "$ ")
        #expect(model(vending: [screen]).insertedText(settingValue: "ends with a space ") == "ends with a space ")
        #expect(model(vending: ["% "]).insertedText(settingValue: "hello ") == "hello ")
    }

    @Test("Setting the value the client read inserts nothing")
    func unchangedValueInsertsNothing() {
        #expect(model(vending: [screen]).insertedText(settingValue: screen) == "")
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
        #expect(text.vendedValues == ["read 1", "read 2", "read 3"])
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
