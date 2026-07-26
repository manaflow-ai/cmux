import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal image transfer concurrency")
struct TerminalImageTransferConcurrencyTests {
    @MainActor
    @Test("lazy pasteboard providers materialize through isolated preparation")
    func lazyPasteboardProviderMaterializes() async throws {
        #expect(Thread.isMainThread)

        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-image-transfer-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        let mainThreadData = Data("resolved-on-main".utf8)
        let backgroundThreadData = Data("resolved-off-main".utf8)
        let provider = PasteboardThreadSignalingDataProvider(
            mainThreadData: mainThreadData,
            backgroundThreadData: backgroundThreadData
        )
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        #expect(pasteboard.writeObjects([item]))

        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste
        )
        guard case .fileURLs(let fileURLs) = preparedContent,
              let materializedURL = fileURLs.first else {
            Issue.record("Expected the lazy image payload to be materialized")
            return
        }
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
        }

        let materializedData = try Data(contentsOf: materializedURL)
        #expect(
            materializedData == mainThreadData
                || materializedData == backgroundThreadData
        )
    }

    @MainActor
    @Test("accepted paste preparations execute in FIFO order without drops")
    func pastePreparationPreservesFIFOOrder() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { try await operation.run($0) },
            cleanup: { _ in }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        let firstRequest = makeReadRequest(label: "first")
        let secondRequest = makeReadRequest(label: "second")
        let thirdRequest = makeReadRequest(label: "third")

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(2)
        let thirdTask = Task {
            await service.prepare(request: thirdRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(3)

        await operation.release(firstRequest.pasteboardName)
        let firstResult = await firstTask.value
        #expect(firstResult == .insertText(firstRequest.pasteboardName))

        let secondStarted = await started.next()
        #expect(secondStarted == secondRequest.pasteboardName)
        await operation.release(secondRequest.pasteboardName)
        let secondResult = await secondTask.value
        #expect(secondResult == .insertText(secondRequest.pasteboardName))

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

        await operation.release(thirdRequest.pasteboardName)
        let thirdResult = await thirdTask.value
        #expect(thirdResult == .insertText(thirdRequest.pasteboardName))
    }

    @MainActor
    @Test("a timed-out worker is reaped before the next paste runs")
    func timedOutWorkerAllowsReplacement() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let failures = PastePreparationFailureProbe()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { failures.record($0) }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        var reportedFailures = failures.events().makeAsyncIterator()
        let firstRequest = makeReadRequest(label: "deadline-first")
        let secondRequest = makeReadRequest(label: "deadline-second")

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let startedName = await started.next()
        #expect(startedName == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(2)

        let firedFirstDeadline = await deadlines.fireNext()
        #expect(firedFirstDeadline)
        let timedOutResult = await firstTask.value
        #expect(timedOutResult == .reject)
        let reportedFailure = await reportedFailures.next()
        #expect(reportedFailure == .deadlineExceeded)

        let replacementStarted = await started.next()
        #expect(replacementStarted == secondRequest.pasteboardName)
        #expect(await operation.snapshot().maximumActiveCount == 1)
        await operation.release(secondRequest.pasteboardName)
        let secondResult = await secondTask.value
        #expect(secondResult == .insertText(secondRequest.pasteboardName))
    }

    @MainActor
    @Test("timed-out workers remain serialized while the queue advances")
    func timedOutWorkersRemainSerialized() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        let firstRequest = makeReadRequest(label: "stuck-first")
        let secondRequest = makeReadRequest(label: "stuck-second")
        let thirdRequest = makeReadRequest(label: "stuck-third")

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)

        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(2)
        let thirdTask = Task {
            await service.prepare(request: thirdRequest, mode: .paste)
        }
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
        let firstRequest = makeReadRequest(label: "exhaustion-first")
        let secondRequest = makeReadRequest(label: "exhaustion-second")
        let thirdRequest = makeReadRequest(label: "exhaustion-third")

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
        await deadlines.waitForArrivalCount(2)
        #expect(await started.next() == secondRequest.pasteboardName)
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
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { failures.record($0) }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        var reportedFailures = failures.events().makeAsyncIterator()
        let firstRequest = makeReadRequest(label: "capacity-first")
        let secondRequest = makeReadRequest(label: "capacity-second")
        let rejectedRequest = makeReadRequest(label: "capacity-rejected")

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)
        let secondTask = Task {
            await service.prepare(request: secondRequest, mode: .paste)
        }
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
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        var started = operation.startedEvents().makeAsyncIterator()
        let firstRequest = makeReadRequest(label: "cancel-first")
        let cancelledRequest = makeReadRequest(label: "cancel-second")

        let firstTask = Task {
            await service.prepare(request: firstRequest, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let firstStarted = await started.next()
        #expect(firstStarted == firstRequest.pasteboardName)
        let cancelledTask = Task {
            await service.prepare(request: cancelledRequest, mode: .paste)
        }
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
    private func makeReadRequest(label: String) -> TerminalPasteboardReadRequest {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-paste-lane-\(label)-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return TerminalPasteboardReadRequest(pasteboard: pasteboard)
    }
}
