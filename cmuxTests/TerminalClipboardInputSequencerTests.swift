import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal clipboard input sequencing", .serialized)
struct TerminalClipboardInputSequencerTests {
    @Test("reserved clipboard read queues input before main-actor admission")
    func reservedClipboardReadQueuesInputBeforeAdmission() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []

        let reservationAccepted = await Task.detached {
            sequencer.reserveRequestAdmission(id: 1, onOverflow: {})
        }.value
        #expect(reservationAccepted)

        #expect(sequencer.shouldDefer("suffix"))
        #expect(delivered.isEmpty)

        sequencer.beginReservedRequest(id: 1)
        delivered.append("paste")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["paste", "suffix"])
    }

    @Test("OSC 52 read streams never defer terminal input")
    func unsequencedClipboardReadsNeverDeferInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var logicalCompletionCount = 0

        for requestID in 1...32 {
            sequencer.beginUnsequencedRequest(id: requestID, epoch: 7)
        }

        #expect(!sequencer.shouldDefer("ctrl-c", epoch: 7))
        #expect(!sequencer.shouldDefer("ordinary-input", epoch: 7))

        for requestID in 1...32 {
            sequencer.completeRequest(
                id: requestID,
                confirmed: false,
                onLogicalCompletion: { logicalCompletionCount += 1 },
                replay: { _ in Issue.record("Unsequenced input was buffered") }
            )
        }
        #expect(logicalCompletionCount == 32)
    }

    @Test("pre-admission overflow cancels paste before routing current input")
    func preAdmissionOverflowCancelsPasteFirst() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        let overflow: @MainActor @Sendable () -> Void = {
            delivered.append("paste-cancelled")
            sequencer.cancelReservedRequest(
                id: 1,
                requestEpoch: 0,
                currentEpoch: 0,
                deferredInputDisposition: .replay
            ) {
                delivered.append($0)
            }
        }

        let reservationAccepted = await Task.detached {
            sequencer.reserveRequestAdmission(
                id: 1,
                onOverflow: overflow
            )
        }.value
        #expect(reservationAccepted)
        #expect(sequencer.shouldDefer("first"))
        #expect(sequencer.shouldDefer("second"))

        #expect(!sequencer.shouldDefer("current"))
        delivered.append("current")

        #expect(
            delivered == [
                "paste-cancelled",
                "first",
                "second",
                "current",
            ]
        )
    }

    @Test("overlapping overflow cancels every reservation before replay")
    func overlappingPreAdmissionOverflowDefersReplay() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        let firstOverflow: @MainActor @Sendable () -> Void = {
            delivered.append("paste-1-cancelled")
            sequencer.cancelReservedRequest(
                id: 1,
                requestEpoch: 0,
                currentEpoch: 0,
                deferredInputDisposition: .replay
            ) {
                delivered.append($0)
            }
        }
        let secondOverflow: @MainActor @Sendable () -> Void = {
            delivered.append("paste-2-cancelled")
            sequencer.cancelReservedRequest(
                id: 2,
                requestEpoch: 0,
                currentEpoch: 0,
                deferredInputDisposition: .replay
            ) {
                delivered.append($0)
            }
        }

        await Task.detached {
            _ = sequencer.reserveRequestAdmission(
                id: 1,
                onOverflow: firstOverflow
            )
            _ = sequencer.reserveRequestAdmission(
                id: 2,
                onOverflow: secondOverflow
            )
        }.value
        #expect(sequencer.shouldDefer("first"))
        #expect(sequencer.shouldDefer("second"))

        #expect(!sequencer.shouldDefer("current"))
        delivered.append("current")

        #expect(
            Set(delivered.prefix(2))
                == Set(["paste-1-cancelled", "paste-2-cancelled"])
        )
        #expect(Array(delivered.dropFirst(2)) == ["first", "second", "current"])
    }

    @Test("overflow cancels pre-admission and active pastes in registration order")
    func overflowPreservesOrderAcrossAdmissionBoundary() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 1
        )
        var delivered: [String] = []

        #expect(sequencer.reserveRequestAdmission(
            id: 1,
            onOverflow: {
                delivered.append("paste-1-cancelled")
                sequencer.cancelReservedRequest(
                    id: 1,
                    requestEpoch: 0,
                    currentEpoch: 0,
                    deferredInputDisposition: .replay
                ) {
                    delivered.append($0)
                }
            }
        ))
        #expect(sequencer.reserveRequestAdmission(id: 2, onOverflow: {}))
        sequencer.beginReservedRequest(
            id: 2,
            onOverflow: {
                delivered.append("paste-2-cancelled")
                sequencer.cancelRequest(
                    id: 2,
                    currentEpoch: 0,
                    deferredInputDisposition: .replay
                ) {
                    delivered.append($0)
                }
            }
        )

        #expect(sequencer.shouldDefer("buffered"))
        #expect(!sequencer.shouldDefer("current"))
        delivered.append("current")

        #expect(
            delivered == [
                "paste-1-cancelled",
                "paste-2-cancelled",
                "buffered",
                "current",
            ]
        )
    }

    @Test("overflow preserves registration order after reverse admission")
    func overflowPreservesOrderAcrossReverseAdmission() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 1
        )
        var delivered: [String] = []

        #expect(sequencer.reserveRequestAdmission(id: 1, onOverflow: {}))
        #expect(sequencer.reserveRequestAdmission(id: 2, onOverflow: {}))
        sequencer.beginReservedRequest(
            id: 2,
            onOverflow: {
                delivered.append("paste-2-cancelled")
                sequencer.cancelRequest(
                    id: 2,
                    currentEpoch: 0,
                    deferredInputDisposition: .replay
                ) {
                    delivered.append($0)
                }
            }
        )
        sequencer.beginReservedRequest(
            id: 1,
            onOverflow: {
                delivered.append("paste-1-cancelled")
                sequencer.cancelRequest(
                    id: 1,
                    currentEpoch: 0,
                    deferredInputDisposition: .replay
                ) {
                    delivered.append($0)
                }
            }
        )
        sequencer.requireConfirmation(for: 1)
        sequencer.requireConfirmation(for: 2)

        #expect(sequencer.shouldDefer("buffered"))
        #expect(!sequencer.shouldDefer("current"))
        delivered.append("current")

        #expect(
            delivered == [
                "paste-1-cancelled",
                "paste-2-cancelled",
                "buffered",
                "current",
            ]
        )
    }

    @Test("overflow cancels active and reserved requests before replay")
    func activeAndReservedOverflowDefersReplay() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        var racingAdmissionAccepted = true

        sequencer.beginRequest(
            id: 1,
            onOverflow: {
                delivered.append("active-cancelled")
                racingAdmissionAccepted = sequencer.reserveRequestAdmission(
                    id: 3,
                    onOverflow: {}
                )
                sequencer.completeRequest(id: 1, confirmed: false) {
                    delivered.append($0)
                }
            }
        )
        let reservedOverflow: @MainActor @Sendable () -> Void = {
            delivered.append("reserved-cancelled")
            sequencer.cancelReservedRequest(
                id: 2,
                requestEpoch: 0,
                currentEpoch: 0,
                deferredInputDisposition: .replay
            ) {
                delivered.append($0)
            }
        }
        let reservationAccepted = await Task.detached {
            sequencer.reserveRequestAdmission(
                id: 2,
                onOverflow: reservedOverflow
            )
        }.value
        #expect(reservationAccepted)
        #expect(sequencer.shouldDefer("first"))
        #expect(sequencer.shouldDefer("second"))

        #expect(!sequencer.shouldDefer("current"))
        delivered.append("current")

        #expect(!racingAdmissionAccepted)
        #expect(
            delivered == [
                "active-cancelled",
                "reserved-cancelled",
                "first",
                "second",
                "current",
            ]
        )
    }

    @Test("overflow cleanup does not block a replacement runtime epoch")
    func overflowCancellationIsEpochScoped() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 0
        )
        var replacementInputWasDeferred = true
        var replacementAdmissionAccepted = false

        sequencer.beginRequest(
            id: 1,
            epoch: 7,
            onOverflow: {
                replacementInputWasDeferred = sequencer.shouldDefer(
                    "replacement-input",
                    epoch: 9
                )
                replacementAdmissionAccepted = sequencer
                    .reserveRequestAdmission(
                        id: 2,
                        epoch: 9,
                        onOverflow: {}
                    )
                sequencer.completeRequest(id: 1, confirmed: false) { _ in
                    Issue.record("Dying-runtime input was replayed")
                }
            }
        )

        #expect(!sequencer.shouldDefer("overflowing-input", epoch: 7))
        #expect(!replacementInputWasDeferred)
        #expect(replacementAdmissionAccepted)

        sequencer.cancelReservedRequest(
            id: 2,
            requestEpoch: 9,
            currentEpoch: 9,
            deferredInputDisposition: .discard,
            replay: { _ in Issue.record("Replacement input was buffered") }
        )
    }

    @Test("retained input cost is bounded independently of event count")
    func retainedInputCostOverflowCancelsPasteFirst() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8,
            maximumBufferedCost: 4
        )
        var delivered: [String] = []
        sequencer.beginRequest(
            id: 1,
            epoch: 7,
            onOverflow: {
                delivered.append("paste-cancelled")
                sequencer.completeRequest(id: 1, confirmed: false) {
                    delivered.append($0)
                }
            }
        )

        #expect(
            sequencer.shouldDefer("buffered", epoch: 7, estimatedCost: 4)
        )
        #expect(
            !sequencer.shouldDefer("current", epoch: 7, estimatedCost: 5)
        )
        delivered.append("current")

        #expect(delivered == ["paste-cancelled", "buffered", "current"])
    }

    @Test("overflow without cancellation progress drops buffered input before failing open")
    func overflowWithoutCancellationProgressDropsBufferedInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 1
        )
        var overflowCount = 0
        var delivered: [String] = []
        sequencer.beginRequest(
            id: 1,
            onOverflow: { overflowCount += 1 }
        )

        #expect(sequencer.shouldDefer("buffered"))
        let currentWasDeferred = sequencer.shouldDefer("current")
        #expect(!currentWasDeferred)
        if !currentWasDeferred {
            delivered.append("current")
        }
        #expect(overflowCount == 1)

        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["current"])
    }

    @Test("confirmation-phase overflow cannot drop the triggering input")
    func confirmationOverflowCancelsSequencingBeforeRoutingInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8,
            maximumBufferedCost: 4
        )
        var delivered: [String] = []
        sequencer.beginRequest(
            id: 1,
            epoch: 7,
            onOverflow: {
                delivered.append("paste-cancelled")
                sequencer.cancelRequest(
                    id: 1,
                    currentEpoch: 7,
                    deferredInputDisposition: .replay
                ) {
                    delivered.append($0)
                }
            }
        )
        sequencer.requireConfirmation(for: 1)
        #expect(
            sequencer.shouldDefer("buffered", epoch: 7, estimatedCost: 4)
        )
        sequencer.completeRequest(id: 1, confirmed: true) { _ in
            Issue.record("Confirmation released input before initial completion")
        }

        #expect(
            !sequencer.shouldDefer("current", epoch: 7, estimatedCost: 5)
        )
        delivered.append("current")

        #expect(delivered == ["paste-cancelled", "buffered", "current"])
    }

}
