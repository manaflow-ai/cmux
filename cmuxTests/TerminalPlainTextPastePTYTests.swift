import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Uses a raw Python receiver, with no shell prompt, Codex, or agent hooks in the data path.
@MainActor
extension TerminalPlainTextPasteStartupTests {
    @Test("Cold and repeated keyboard, menu and runtime pastes preserve PTY bytes")
    func realPTYDelivery() async throws {
        defer { NSPasteboard.general.clearContents() }
        for optimized in [false, true] {
            let fixture = try PlainPastePTYFixture(optimized: optimized)
            defer { fixture.close() }
            try await fixture.waitUntilReady()
            try await fixture.warmPasteboardAccess()
            for trial in 0..<6 {
                let text = "paste-\(trial) 日本語 🦀 e\u{301}\nsecond\tline\n"
                NSPasteboard.general.clearContents()
                try #require(NSPasteboard.general.setString(text, forType: .string))
                let started = Date().timeIntervalSince1970
                switch trial % 3 {
                case 0:
                    let event = try #require(NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: fixture.window.windowNumber, context: nil,
                        characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
                    ))
                    // A real Cmd+V reaches the terminal through its key window,
                    // where the terminal is first responder. On a live window
                    // server (the owned Mac runners) this fixture window is not
                    // key, and cmux's focus handling has yielded the terminal's
                    // responder to the window by the time the key is sent.
                    // Restore the key-window precondition per keystroke.
                    try #require(fixture.window.makeFirstResponder(fixture.view))
                    try #require(
                        fixture.view.performKeyEquivalent(with: event),
                        "Cmd+V was not handled; firstResponder=\(String(describing: fixture.window.firstResponder))"
                    )
                case 1:
                    fixture.view.paste(nil)
                default:
                    try #require(fixture.view.performBindingAction("paste_from_clipboard"))
                }
                let receipt = try await fixture.receipt(trial: trial)
                let bytes = try #require(receipt["hex"] as? String)
                let expected = Data(("\u{1b}[200~" + text + "\u{1b}[201~").utf8)
                #expect(bytes == expected.map { String($0, radix: 16).leftPaddedByte }.joined())
                let received = try #require(receipt["received_at"] as? Double)
                print("PASTE_PTY optimized=\(optimized) trial=\(trial) entry=\(trial % 3) duration_ms=\((received - started) * 1000) bytes=\(expected.count)")
            }
            let launches = try String(contentsOf: fixture.launches, encoding: .utf8)
                .split(separator: "\n").map(String.init)
            #expect(launches == Array(repeating: optimized ? "text" : "full", count: 6))
            print("PASTE_SPAWNS optimized=\(optimized) full=\(launches.filter { $0 == "full" }.count) text=\(launches.filter { $0 == "text" }.count)")
        }
    }
}

private extension String {
    var leftPaddedByte: String { count == 1 ? "0" + self : self }
}
