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
    private let testNow: TimeInterval = 100

    /// Vends each value to a fresh model the way AX reads do, a snapshot apart.
    private func model(vending values: [String]) -> TerminalAccessibilityText {
        let text = TerminalAccessibilityText()
        for (offset, value) in values.enumerated() {
            _ = text.value(now: testNow + Double(offset), read: { value })
        }
        return text
    }

    @Test("A value that splices text into what the client read inserts only that text")
    func splicedValueYieldsTheInsertion() {
        let text = model(vending: [screen])
        #expect(text.insertedText(settingValue: screen + "git status", now: testNow) == "git status")
        #expect(text.insertedText(settingValue: "git status" + screen, now: testNow) == "git status")
        let middle = screen.index(screen.startIndex, offsetBy: 11)
        var spliced = screen
        spliced.insert(contentsOf: "hello ", at: middle)
        #expect(text.insertedText(settingValue: spliced, now: testNow) == "hello ")
    }

    @Test("A value spliced into an older read still inserts only the text after the screen changed")
    func staleReadStillYieldsTheInsertion() {
        let older = screen
        let newer = "ready\n$ \nagent output line one\nagent output line two\n"
        let text = model(vending: [older, newer])
        #expect(text.insertedText(settingValue: older + "git status", now: testNow) == "git status")
    }

    @Test("An exact older read wins over a newer screen that shares most of its text")
    func exactOlderReadBeatsPartialNewerMatch() {
        let history = (1...40).map { "build step \($0) done\n" }.joined()
        let older = history + "$ "
        let newer = history + "warning: cache miss\n$ "
        let text = model(vending: [older, newer])
        #expect(text.insertedText(settingValue: older + "git status", now: testNow + 1) == "git status")
    }

    @Test("A delayed edit survives more than eight newer screen reads")
    func delayedReadSurvivesScreenChurn() {
        let newerScreens = (1...10).map { "new screen \($0)\n$ " }
        let text = model(vending: [screen] + newerScreens)
        #expect(text.insertedText(settingValue: screen + "git status", now: testNow + 10) == "git status")
    }

    @Test("A vended value expires after the edit window")
    func expiredReadIsLiteral() {
        let text = model(vending: [screen])
        let expiredAt = testNow + TerminalAccessibilityText.vendedValueHistoryLifetime
        #expect(text.insertedText(settingValue: screen + "git status", now: expiredAt) == screen + "git status")
    }

    @Test("A cached AX read renews the edit window without rereading the screen")
    func cachedReadRenewsEditWindow() {
        let text = model(vending: [screen])
        #expect(text.value(now: testNow + 0.25, read: { "unexpected fresh screen" }) == screen)
        _ = text.value(now: testNow + 1, read: { "newer screen\n$ " })
        let originalExpiry = testNow + TerminalAccessibilityText.vendedValueHistoryLifetime
        #expect(text.insertedText(settingValue: screen + "git status", now: originalExpiry) == "git status")
        #expect(text.insertedText(settingValue: screen + "git status", now: originalExpiry + 0.25) == screen + "git status")
    }

    @Test("The UTF-8 byte budget evicts the least recently vended value first")
    func byteBudgetEvictsLeastRecentlyVendedValue() {
        let byteLimit = TerminalAccessibilityText.vendedValueHistoryByteLimit
        let older = String(repeating: "a", count: byteLimit / 2)
        let newer = String(repeating: "😀", count: byteLimit / 8)
        let text = model(vending: [older, newer, older, "last"])
        #expect(text.vendedValues == [older, "last"])
        #expect(text.vendedValues.reduce(0) { $0 + $1.utf8.count } <= byteLimit)
    }

    @Test("A value larger than the history budget does not evict retained reads")
    func oversizedValueIsNotRetained() {
        let oversized = String(repeating: "a", count: TerminalAccessibilityText.vendedValueHistoryByteLimit + 1)
        let text = model(vending: [screen, oversized])
        #expect(text.vendedValues == [screen])
        #expect(text.insertedText(settingValue: screen + "git status", now: testNow + 1) == "git status")
    }

    @Test("A value that doesn't keep the text the client read is inserted as is")
    func unrelatedValueIsLiteral() {
        #expect(model(vending: [screen]).insertedText(settingValue: "hello world", now: testNow) == "hello world")
        #expect(model(vending: []).insertedText(settingValue: "$ ", now: testNow) == "$ ")
        #expect(model(vending: [screen]).insertedText(settingValue: "ends with a space ", now: testNow) == "ends with a space ")
        #expect(model(vending: ["% "]).insertedText(settingValue: "hello ", now: testNow) == "hello ")
    }

    @Test("Setting the value the client read inserts nothing")
    func unchangedValueInsertsNothing() {
        #expect(model(vending: [screen]).insertedText(settingValue: screen, now: testNow) == "")
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
