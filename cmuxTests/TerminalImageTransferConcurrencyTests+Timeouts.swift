import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalImageTransferConcurrencyTests {
    @MainActor
    @Test("timed-out workers remain serialized while the queue advances")
    func timedOutWorkersRemainSerialized() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            admissionSignal: { operation.signalAdmission($0) },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        var admitted = operation.admittedEvents().makeAsyncIterator()
        var started = operation.startedEvents().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(
            label: "stuck-first"
        )
        let (secondPasteboard, secondRequest) = makeReadRequest(
            label: "stuck-second"
        )
        let (thirdPasteboard, thirdRequest) = makeReadRequest(
            label: "stuck-third"
        )
        defer {
            for pasteboard in [firstPasteboard, secondPasteboard, thirdPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        #expect(await admitted.next() == firstRequest.pasteboardName)
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        #expect(await admitted.next() == secondRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)
        let thirdTask = Task {
            await service.prepare(request: thirdRequest, mode: .paste)
        }
        #expect(await admitted.next() == thirdRequest.pasteboardName)
        await deadlines.waitForArrivalCount(3)

        let firedFirstDeadline = await deadlines.fireNext()
        #expect(firedFirstDeadline)
        let firstResult = await firstTask.value
        #expect(firstResult == .reject)
        let secondStarted = await started.next()
        #expect(secondStarted == secondRequest.pasteboardName)

        let firedSecondDeadline = await deadlines.fireNext()
        #expect(firedSecondDeadline)
        let secondResult = await secondTask.value
        #expect(secondResult == .reject)
        let thirdStarted = await started.next()
        #expect(thirdStarted == thirdRequest.pasteboardName)
        #expect(await operation.snapshot().maximumActiveCount == 1)
        #expect(
            await operation.snapshot().startedNames
                == [
                    firstRequest.pasteboardName,
                    secondRequest.pasteboardName,
                    thirdRequest.pasteboardName,
                ]
        )

        let firedThirdDeadline = await deadlines.fireNext()
        #expect(firedThirdDeadline)
        let thirdResult = await thirdTask.value
        #expect(thirdResult == .reject)
    }

    @MainActor
    @Test("timed-out providers cannot permanently exhaust paste preparation")
    func timedOutProvidersDoNotExhaustPastePreparation() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            maximumQueuedJobs: 1,
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(
            label: "exhaustion-first"
        )
        let (secondPasteboard, secondRequest) = makeReadRequest(
            label: "exhaustion-second"
        )
        let (thirdPasteboard, thirdRequest) = makeReadRequest(
            label: "exhaustion-third"
        )
        defer {
            for pasteboard in [firstPasteboard, secondPasteboard, thirdPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        #expect(await started.next() == firstRequest.pasteboardName)
        #expect(await deadlines.fireNext())
        #expect(await firstTask.value == .reject)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        #expect(await started.next() == secondRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)
        #expect(await deadlines.fireNext())
        #expect(await secondTask.value == .reject)

        await operation.release(thirdRequest.pasteboardName)
        let thirdResult = await service.prepare(
            request: thirdRequest,
            mode: .paste
        )
        #expect(thirdResult == .insertText(thirdRequest.pasteboardName))

        await operation.release(firstRequest.pasteboardName)
        await operation.release(secondRequest.pasteboardName)
    }

    @MainActor
    @Test("bounded queue overflow is reported explicitly")
    func queueOverflowIsExplicit() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let failures = PastePreparationFailureProbe()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            maximumQueuedJobs: 1,
            deadlineSleep: { _ in try await deadlines.sleep() },
            admissionSignal: { operation.signalAdmission($0) },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { failures.record($0) }
        )
        var admitted = operation.admittedEvents().makeAsyncIterator()
        var started = operation.startedEvents().makeAsyncIterator()
        var reportedFailures = failures.events().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(
            label: "capacity-first"
        )
        let (secondPasteboard, secondRequest) = makeReadRequest(
            label: "capacity-second"
        )
        let (rejectedPasteboard, rejectedRequest) = makeReadRequest(
            label: "capacity-rejected"
        )
        defer {
            for pasteboard in [firstPasteboard, secondPasteboard, rejectedPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        #expect(await admitted.next() == firstRequest.pasteboardName)
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)
        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        #expect(await admitted.next() == secondRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)

        let rejectedResult = await service.prepare(
            request: rejectedRequest,
            mode: .paste
        )
        #expect(rejectedResult == .reject)
        let reportedFailure = await reportedFailures.next()
        #expect(reportedFailure == .queueFull)

        await operation.release(firstRequest.pasteboardName)
        let firstResult = await firstTask.value
        #expect(firstResult == .insertText(firstRequest.pasteboardName))
        let secondStarted = await started.next()
        #expect(secondStarted == secondRequest.pasteboardName)
        await operation.release(secondRequest.pasteboardName)
        let secondResult = await secondTask.value
        #expect(secondResult == .insertText(secondRequest.pasteboardName))
    }

    @MainActor
    @Test("cancelling queued preparation removes it deterministically")
    func cancellingQueuedPreparationRemovesIt() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            admissionSignal: { operation.signalAdmission($0) },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        var admitted = operation.admittedEvents().makeAsyncIterator()
        var started = operation.startedEvents().makeAsyncIterator()
        let (firstPasteboard, firstRequest) = makeReadRequest(
            label: "cancel-first"
        )
        let (cancelledPasteboard, cancelledRequest) = makeReadRequest(
            label: "cancel-second"
        )
        defer {
            for pasteboard in [firstPasteboard, cancelledPasteboard] {
                pasteboard.clearContents()
                pasteboard.releaseGlobally()
            }
        }

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        #expect(await admitted.next() == firstRequest.pasteboardName)
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)
        let cancelledTask = Task {
            await service.prepare(request: cancelledRequest, mode: .paste)
        }
        #expect(await admitted.next() == cancelledRequest.pasteboardName)
        await deadlines.waitForArrivalCount(2)

        cancelledTask.cancel()
        let cancelledResult = await cancelledTask.value
        #expect(cancelledResult == .reject)
        await operation.release(firstRequest.pasteboardName)
        let firstResult = await firstTask.value
        #expect(firstResult == .insertText(firstRequest.pasteboardName))
        #expect(
            await operation.snapshot().startedNames
                == [firstRequest.pasteboardName]
        )
    }

    @MainActor
    func makeLivePreparationService()
        -> TerminalImageTransferPreparationService {
        let pasteboardService = GhosttyApp.terminalPasteboard
        return TerminalImageTransferPreparationService(
            operation: { request in
                let client = TerminalPastePreparationWorkerClient
                    .reexecingCurrentBinary(
                        pasteboardService: pasteboardService
                )
                return try await client.prepare(request)
            },
            cleanup: { result in
                result.cleanupTransferredTemporaryFiles(
                    using: pasteboardService
                )
            }
        )
    }

    @MainActor
    func makeReadRequest(
        label: String
    ) -> (NSPasteboard, TerminalPasteboardReadRequest) {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-paste-lane-\(label)-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return (
            pasteboard,
            TerminalPasteboardReadRequest(pasteboard: pasteboard)
        )
    }
}
