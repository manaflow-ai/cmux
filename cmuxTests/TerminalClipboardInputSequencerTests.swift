import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal clipboard input sequencing")
struct TerminalClipboardInputSequencerTests {
    @Test("blocked paste completes before queued suffix and return")
    func blockedPasteCompletesBeforeQueuedInput() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        let request = makeReadRequest(label: "ordered-input")
        var started = operation.startedEvents().makeAsyncIterator()
        var delivered: [String] = []

        sequencer.beginRequest(id: 1)
        let pasteTask = Task {
            await service.prepare(request: request, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let startedName = await started.next()
        #expect(startedName == request.pasteboardName)
        #expect(sequencer.route("suffix") == .queued)
        #expect(sequencer.route("return") == .queued)
        #expect(delivered.isEmpty)

        await operation.release(request.pasteboardName)
        let pasteResult = await pasteTask.value
        #expect(pasteResult == .insertText(request.pasteboardName))
        delivered.append("paste")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["paste", "suffix", "return"])
    }

    @Test("replayed paste pauses later suffix until its read completes")
    func replayedPastePausesDrain() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)
        #expect(sequencer.route("paste-2") == .queued)
        #expect(sequencer.route("suffix") == .queued)

        sequencer.completeRequest(id: 1, confirmed: false) { event in
            delivered.append(event)
            if event == "paste-2" {
                sequencer.beginRequest(id: 2)
            }
        }
        #expect(delivered == ["paste-2"])

        delivered.append("paste-2-complete")
        sequencer.completeRequest(id: 2, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["paste-2", "paste-2-complete", "suffix"])
    }

    @Test("confirmation keeps input queued until confirmed completion")
    func confirmationKeepsInputQueued() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)
        #expect(sequencer.route("suffix") == .queued)
        sequencer.requireConfirmation(for: 1)

        sequencer.completeRequest(id: 1, confirmed: true) {
            delivered.append($0)
        }
        #expect(delivered.isEmpty)

        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["suffix"])
    }

    @Test("bounded input queue reports overflow and keeps accepted order")
    func boundedInputQueueReportsOverflow() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)

        #expect(sequencer.route("first") == .queued)
        #expect(sequencer.route("second") == .queued)
        #expect(sequencer.route("overflow") == .rejected)
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["first", "second"])
    }

    private func makeReadRequest(
        label: String
    ) -> TerminalPasteboardReadRequest {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-input-sequence-\(label)-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return TerminalPasteboardReadRequest(pasteboard: pasteboard)
    }
}
