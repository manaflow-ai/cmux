import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class TerminalClipboardApprovalRecorder: TerminalClipboardAccessRequesting {
    struct Request {
        let operation: TerminalClipboardAccessOperation
        let contents: String
        let window: NSWindow?
    }

    private(set) var requests: [Request] = []
    private var completions: [(Bool) -> Void] = []

    func requestApproval(
        operation: TerminalClipboardAccessOperation,
        contents: String,
        window: NSWindow?,
        completion: @escaping (Bool) -> Void
    ) {
        requests.append(Request(operation: operation, contents: contents, window: window))
        completions.append(completion)
    }

    func resolveNext(approved: Bool) {
        completions.removeFirst()(approved)
    }
}

@Suite("Terminal clipboard access", .serialized)
@MainActor
struct TerminalClipboardAccessTests {
    @Test
    func writeWithoutConfirmationRemainsImmediate() {
        let recorder = TerminalClipboardApprovalRecorder()
        var writes: [String] = []

        TerminalClipboardRuntimeBridge.handleWrite(
            contents: "selection copy",
            requiresConfirmation: false,
            window: nil,
            requester: recorder
        ) {
            writes.append("selection copy")
        }

        #expect(recorder.requests.isEmpty)
        #expect(writes == ["selection copy"])
    }

    @Test
    func writeRequiringConfirmationWaitsAndHonorsDenial() {
        let recorder = TerminalClipboardApprovalRecorder()
        var writes: [String] = []

        TerminalClipboardRuntimeBridge.handleWrite(
            contents: "replacement",
            requiresConfirmation: true,
            window: nil,
            requester: recorder
        ) {
            writes.append("replacement")
        }

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.operation == .write)
        #expect(recorder.requests.first?.contents == "replacement")
        #expect(writes.isEmpty)

        recorder.resolveNext(approved: false)

        #expect(writes.isEmpty)
    }

    @Test
    func writeRequiringConfirmationRunsAfterApproval() {
        let recorder = TerminalClipboardApprovalRecorder()
        var writes: [String] = []

        TerminalClipboardRuntimeBridge.handleWrite(
            contents: "replacement",
            requiresConfirmation: true,
            window: nil,
            requester: recorder
        ) {
            writes.append("replacement")
        }

        #expect(writes.isEmpty)

        recorder.resolveNext(approved: true)

        #expect(writes == ["replacement"])
    }

    @Test(arguments: [
        (approved: true, expectedContents: "clipboard value"),
        (approved: false, expectedContents: ""),
    ])
    func readConfirmationCompletesOnce(
        approved: Bool,
        expectedContents: String
    ) {
        let recorder = TerminalClipboardApprovalRecorder()
        var completions: [(contents: String, confirmed: Bool)] = []

        TerminalClipboardRuntimeBridge.handleReadConfirmation(
            contents: "clipboard value",
            window: nil,
            requester: recorder
        ) { contents, confirmed in
            completions.append((contents, confirmed))
        }

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.operation == .read)
        #expect(recorder.requests.first?.contents == "clipboard value")
        #expect(completions.isEmpty)

        recorder.resolveNext(approved: approved)

        #expect(completions.count == 1)
        #expect(completions.first?.contents == expectedContents)
        #expect(completions.first?.confirmed == true)
    }

    @Test
    func promptTextEscapesControlCharacters() {
        let contents = "\u{1B}]52;c;payload\u{7}"

        #expect(
            TerminalClipboardAccessPromptText.preview(contents)
                == #"\u{1B}]52;c;payload\u{7}"#
        )
    }

    @Test
    func promptTextBoundsVisibleContents() {
        let contents = String(
            repeating: "a",
            count: TerminalClipboardAccessPromptText.maximumVisibleScalarCount + 1
        )

        #expect(
            TerminalClipboardAccessPromptText.preview(contents)
                == String(
                    repeating: "a",
                    count: TerminalClipboardAccessPromptText.maximumVisibleScalarCount
                ) + "\n…"
        )
    }

    @Test
    func missingWindowFailsClosed() {
        let prompter = TerminalClipboardAccessPrompter()
        var approved: Bool?

        prompter.requestApproval(
            operation: .read,
            contents: "clipboard value",
            window: nil
        ) {
            approved = $0
        }

        #expect(approved == false)
    }
}
