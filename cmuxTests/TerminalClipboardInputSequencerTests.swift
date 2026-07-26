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
    @Test("reserved clipboard read queues input before main-actor admission")
    func reservedClipboardReadQueuesInputBeforeAdmission() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []

        await Task.detached {
            sequencer.reserveRequestAdmission()
        }.value

        #expect(sequencer.shouldDefer("suffix"))
        #expect(delivered.isEmpty)

        sequencer.beginReservedRequest(id: 1)
        delivered.append("paste")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["paste", "suffix"])
    }

    @Test("overlapping reservations hold input through every request")
    func overlappingReservationsHoldInputThroughEveryRequest() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []

        await Task.detached {
            sequencer.reserveRequestAdmission()
            sequencer.reserveRequestAdmission()
        }.value
        #expect(sequencer.shouldDefer("suffix"))

        sequencer.beginReservedRequest(id: 1)
        delivered.append("paste-1")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["paste-1"])

        sequencer.beginReservedRequest(id: 2)
        delivered.append("paste-2")
        sequencer.completeRequest(id: 2, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["paste-1", "paste-2", "suffix"])
    }

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
        #expect(sequencer.shouldDefer("suffix"))
        #expect(sequencer.shouldDefer("return"))
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
        #expect(sequencer.shouldDefer("paste-2"))
        #expect(sequencer.shouldDefer("suffix"))

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
        #expect(sequencer.shouldDefer("suffix"))
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

    @Test("bounded input queue flushes instead of dropping overflow")
    func boundedInputQueueFlushesOverflow() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)

        #expect(sequencer.shouldDefer("first", replay: { _ in }))
        #expect(sequencer.shouldDefer("second", replay: { _ in }))
        #expect(
            !sequencer.shouldDefer(
                "overflow",
                replay: { delivered.append($0) }
            )
        )
        delivered.append("overflow")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["first", "second", "overflow"])
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
