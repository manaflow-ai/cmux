import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Plain text paste startup")
struct TerminalPlainTextPasteStartupTests {
    @MainActor
    @Test("plain text completes without launching the full app worker", arguments: [
        "hello",
        "first\n\t日本語 🦀 e\u{301}\r\nlast\n",
        "  \t\n  "
    ])
    func plainTextDoesNotRequireAppWorker(text: String) async throws {
        let pasteboard = NSPasteboard(name: .init("cmux-tests-plain-startup-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        #expect(pasteboard.setString(text, forType: .string))
        // The expensive worker deliberately cannot prepare anything. The real
        // client must deliver plain text through its lightweight isolated path.
        let client = TerminalPastePreparationWorkerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            pasteboardService: TerminalPasteboardService()
        )
        let result = try await client.prepare(TerminalPastePreparationRequest(
            pasteboard: TerminalPasteboardReadRequest(pasteboard: pasteboard),
            mode: .paste,
            destination: .terminal
        ))
        guard case .terminal(.insertText(let received)) = result else {
            Issue.record("Expected plain text from the lightweight worker")
            return
        }
        #expect(Array(received.utf8) == Array(text.utf8))
    }
}
