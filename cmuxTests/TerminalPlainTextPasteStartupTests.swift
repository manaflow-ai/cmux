import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Plain text paste startup", .serialized, .timeLimit(.minutes(2)))
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

    @MainActor
    @Test("A changed clipboard generation is rejected before reading replacement bytes")
    func staleGeneration() async throws {
        let board = NSPasteboard(name: .init("cmux-stale-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let request = TerminalPasteboardReadRequest(pasteboard: board)
        board.clearContents()
        board.setString("replacement", forType: .string)
        let client = TerminalPastePreparationWorkerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            pasteboardService: TerminalPasteboardService(), plainTextExecutableURL: try bundledHelper()
        )
        let result = try await client.prepare(.init(pasteboard: request, mode: .paste, destination: .terminal))
        guard case .terminal(.reject) = result else {
            Issue.record("A stale request must reject, not paste replacement content")
            return
        }
        #expect(board.string(forType: .string) == "replacement")
    }

    @MainActor
    @Test("Absent optional helper preserves the isolated full-worker fallback")
    func missingHelperFallback() async throws {
        let board = NSPasteboard(name: .init("cmux-no-helper-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("fallback\n日本語", forType: .string)
        let client = TerminalPastePreparationWorkerClient(
            executableURL: try #require(Bundle.main.executableURL),
            pasteboardService: TerminalPasteboardService(), plainTextExecutableURL: nil
        )
        let result = try await client.prepare(.init(
            pasteboard: TerminalPasteboardReadRequest(pasteboard: board), mode: .paste, destination: .terminal
        ))
        guard case .terminal(.insertText(let text)) = result else {
            Issue.record("Expected the isolated full-worker fallback")
            return
        }
        #expect(text == "fallback\n日本語")
    }

    @Test("Cancelled preparation does not launch a replacement worker")
    func alreadyCancelled() async throws {
        let client = TerminalPastePreparationWorkerClient(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            pasteboardService: TerminalPasteboardService(), plainTextExecutableURL: try bundledHelper()
        )
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { break }
            return try await client.prepare(.init(
                pasteboard: .init(pasteboardName: "cmux-cancelled-\(UUID())", changeCount: -1),
                mode: .paste, destination: .terminal
            ))
        }
        task.cancel()
        continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @MainActor
    @Test("Rich text and image ownership match the full worker", arguments: [false, true])
    func richAndImageControls(image: Bool) async throws {
        let board = NSPasteboard(name: .init("cmux-rich-control-\(UUID())"))
        defer { board.releaseGlobally() }
        let owner = TerminalPasteboardService()
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lS2cWQAAAABJRU5ErkJggg=="
        ))
        if image {
            board.setData(png, forType: .png)
            board.setString("https://example.com/auxiliary", forType: .URL)
        } else {
            board.setString("??", forType: .string)
            board.setString("<p>日本語</p>", forType: .html)
        }
        for helper in [nil, try bundledHelper()] {
            let client = TerminalPastePreparationWorkerClient(
                executableURL: try #require(Bundle.main.executableURL),
                pasteboardService: owner, plainTextExecutableURL: helper
            )
            let result = try await client.prepare(.init(
                pasteboard: TerminalPasteboardReadRequest(pasteboard: board), mode: .paste, destination: .terminal
            ))
            defer { result.cleanupTransferredTemporaryFiles(using: owner) }
            if image {
                guard case .terminal(.fileURLs(let urls)) = result else {
                    Issue.record("Image pixels must take priority over auxiliary URLs")
                    return
                }
                let url = try #require(urls.first)
                #expect(owner.isOwnedTemporaryImageFile(url))
                #expect(try Data(contentsOf: url) == png)
            } else {
                guard case .terminal(.insertText(let text)) = result else {
                    Issue.record("Expected faithful rich text")
                    return
                }
                #expect(text == "日本語")
            }
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
