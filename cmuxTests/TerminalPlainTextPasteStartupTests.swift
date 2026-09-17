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
        let helperURL = try makeHelper(for: text)
        defer { try? FileManager.default.removeItem(at: helperURL) }
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
        let helperURL = try makeHelper(for: "incorrect helper result")
        defer { try? FileManager.default.removeItem(at: helperURL) }
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

    @MainActor
    private func makeHelper(for text: String) throws -> URL {
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-plain-text-helper-\(UUID().uuidString)")
        let encodedText = Data(text.utf8).base64EncodedString()
        let script = """
        #!/bin/sh
        if [ \"$1\" != \"--cmux-plain-text-paste-worker\" ]; then exit 64; fi
        directory=\"$3\"
        printf '%s' '\(encodedText)' | /usr/bin/base64 -D > \"$directory/text-payload.txt\"
        printf '%s' '{\"status\":\"text\",\"destination\":\"terminal\",\"filename\":\"text-payload.txt\"}' > \"$directory/response.json\"
        exit 0
        """
        try script.data(using: .utf8)?.write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )
        return helperURL
    }
}
