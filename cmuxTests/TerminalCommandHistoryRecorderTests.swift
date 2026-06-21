import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Round-trips the per-tab command-history recorder: OSC 133 marks in the PTY
/// stream become persisted entries (command + exit code, no output), survive a
/// reopen (new recorder, same tab), and keep unique ids.
final class TerminalCommandHistoryRecorderTests: XCTestCase {
    private func esc(_ body: String) -> String { "\u{1b}]\(body)\u{07}" }
    private func mark(_ k: String) -> String { esc("133;\(k)") }

    private func makeTempAppSupport() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cmdhist-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRecordsCommandsWithExitCodesAndDropsOutput() {
        let appSupport = makeTempAppSupport()
        let surfaceID = UUID()
        let recorder = TerminalCommandHistoryRecorder(clock: { 100 }, appSupportDirectory: appSupport)

        recorder.ingest(surfaceID: surfaceID, text:
            mark("A") + mark("B") + "echo hi" + mark("C") + "hi\n" + mark("D;0")
            + mark("A") + mark("B") + "false" + mark("C") + mark("D;1")
        )

        let entries = TerminalCommandHistoryRecorder.load(surfaceID: surfaceID, appSupportDirectory: appSupport)
        XCTAssertEqual(entries.map(\.command), ["echo hi", "false"])
        XCTAssertEqual(entries.map(\.exitCode), [0, 1])
        XCTAssertEqual(entries.map(\.recordedAt), [100, 100])
        // The model has no output field — verify size stays bounded regardless
        // of command output volume.
        XCTAssertTrue(entries.allSatisfy { !$0.command.contains("hi\n") })
    }

    func testEmptyCommandsAreSkipped() {
        let appSupport = makeTempAppSupport()
        let surfaceID = UUID()
        let recorder = TerminalCommandHistoryRecorder(clock: { 1 }, appSupportDirectory: appSupport)

        // A bare prompt with no command between B and C must not be recorded.
        recorder.ingest(surfaceID: surfaceID, text: mark("A") + mark("B") + mark("C") + mark("D;0"))
        recorder.ingest(surfaceID: surfaceID, text: mark("A") + mark("B") + "ls" + mark("C") + mark("D;0"))

        let entries = TerminalCommandHistoryRecorder.load(surfaceID: surfaceID, appSupportDirectory: appSupport)
        XCTAssertEqual(entries.map(\.command), ["ls"])
    }

    func testReopenAppendsWithUniqueIDs() {
        let appSupport = makeTempAppSupport()
        let surfaceID = UUID()

        let first = TerminalCommandHistoryRecorder(clock: { 1 }, appSupportDirectory: appSupport)
        first.ingest(surfaceID: surfaceID, text: mark("A") + mark("B") + "one" + mark("C") + mark("D;0"))

        // Reopen: a fresh recorder with the same tab loads prior history and
        // appends, keeping ids monotonic across sessions.
        let second = TerminalCommandHistoryRecorder(clock: { 2 }, appSupportDirectory: appSupport)
        second.ingest(surfaceID: surfaceID, text: mark("A") + mark("B") + "two" + mark("C") + mark("D;0"))

        let entries = TerminalCommandHistoryRecorder.load(surfaceID: surfaceID, appSupportDirectory: appSupport)
        XCTAssertEqual(entries.map(\.command), ["one", "two"])
        XCTAssertEqual(Set(entries.map(\.id)).count, 2, "ids must be unique across reopen")
    }

    func testSeparateTabsGetSeparateHistory() {
        let appSupport = makeTempAppSupport()
        let tabA = UUID()
        let tabB = UUID()
        let recorder = TerminalCommandHistoryRecorder(clock: { 1 }, appSupportDirectory: appSupport)

        recorder.ingest(surfaceID: tabA, text: mark("A") + mark("B") + "cmdA" + mark("C") + mark("D;0"))
        recorder.ingest(surfaceID: tabB, text: mark("A") + mark("B") + "cmdB" + mark("C") + mark("D;0"))

        XCTAssertEqual(
            TerminalCommandHistoryRecorder.load(surfaceID: tabA, appSupportDirectory: appSupport).map(\.command),
            ["cmdA"]
        )
        XCTAssertEqual(
            TerminalCommandHistoryRecorder.load(surfaceID: tabB, appSupportDirectory: appSupport).map(\.command),
            ["cmdB"]
        )
    }
}
