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
        let helperURL = try bundledHelper()
        let client = TerminalPastePreparationWorkerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            pasteboardService: TerminalPasteboardService(),
            plainTextExecutableURL: helperURL
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

    @MainActor
    @Test("rich paste payloads still require the full preparation worker")
    func richPasteDoesNotUsePlainTextHelper() async throws {
        let pasteboard = NSPasteboard(name: .init("cmux-tests-rich-startup-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        #expect(pasteboard.setString("visible text", forType: .string))
        #expect(pasteboard.setString("<p>visible text</p>", forType: .html))
        let helperURL = try bundledHelper()
        let client = TerminalPastePreparationWorkerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            pasteboardService: TerminalPasteboardService(),
            plainTextExecutableURL: helperURL
        )

        await #expect(throws: TerminalPastePreparationWorkerError.self) {
            _ = try await client.prepare(TerminalPastePreparationRequest(
                pasteboard: TerminalPasteboardReadRequest(pasteboard: pasteboard),
                mode: .paste,
                destination: .terminal
            ))
        }
    }

    private func bundledHelper() throws -> URL {
        try #require(Bundle.main.url(
            forResource: "cmux-paste-text-worker",
            withExtension: nil,
            subdirectory: "bin"
        ))
    }
}
